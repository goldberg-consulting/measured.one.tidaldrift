#!/usr/bin/env python3
"""Exercise the bundled helper's peer restriction using only sockets on this Mac."""

import json
import re
import socket
import struct
import subprocess
import sys
import tempfile
import time
import uuid


def check_peer(helper):
    # Both source addresses must belong to this machine. All traffic is bound
    # to the loopback destination; no alias, raw socket, or remote peer is needed.
    addresses = re.findall(r"^\s+inet ([0-9.]+)\s", subprocess.check_output(
        ["/sbin/ifconfig", "-a"], text=True), re.MULTILINE)
    other = next(address for address in addresses if address != "127.0.0.1")
    allowed = "127.0.0.1"
    with socket.socket() as reservation:
        reservation.bind((allowed, 0))
        target = reservation.getsockname()

    with tempfile.TemporaryFile() as log, subprocess.Popen(
        [helper, "-s", "-1", "-4", "-B", allowed, "-p", str(target[1]),
         "--tidaldrift-peer", allowed, "--forceflush", "--idle-timeout", "5",
         "--server-max-duration", "2"], stdout=log, stderr=log
    ) as server:
        try:
            # A connection from a different IP must never even reach iperf's
            # cookie read. Waiting for the socket to close tests that condition.
            deadline = time.monotonic() + 3
            while True:
                try:
                    stranger = socket.create_connection(target, 0.5, source_address=(other, 0))
                    break
                except ConnectionRefusedError:
                    if time.monotonic() >= deadline or server.poll() is not None:
                        raise
                    time.sleep(0.03)
            with stranger:
                assert not stranger.recv(1), "foreign iperf control connection admitted"

            with socket.create_connection(target, 2, source_address=(allowed, 0)) as control:
                control.sendall(str(uuid.uuid4()).encode("ascii") + b"\0")
                assert control.recv(1) == bytes([9]), "missing PARAM_EXCHANGE"
                parameters = json.dumps({"udp": True, "reverse": True, "time": 1,
                                         "parallel": 1, "len": 256, "bandwidth": 64000}).encode()
                control.sendall(struct.pack("!I", len(parameters)) + parameters)
                assert control.recv(1) == bytes([10]), "missing CREATE_STREAMS"

                with socket.socket(type=socket.SOCK_DGRAM) as wrong:
                    wrong.bind((other, 0))
                    wrong.settimeout(0.3)
                    wrong.sendto(b"6789", target)
                    try:
                        wrong.recv(2048)
                    except socket.timeout:
                        pass
                    else:
                        raise AssertionError("foreign UDP destination received a reply")

                # Ignoring the wrong source should leave the same lease usable.
                with socket.socket(type=socket.SOCK_DGRAM) as right:
                    right.bind((allowed, 0))
                    right.settimeout(2)
                    right.sendto(b"6789", target)
                    assert len(right.recv(2048)) == 4, "missing legitimate stream acknowledgement"
                    assert len(right.recv(2048)) == 256, "missing legitimate reverse test payload"
        finally:
            if server.poll() is None:
                server.kill()
            server.wait()


if __name__ == "__main__":
    check_peer(sys.argv[1])
    print("Rejected foreign control and UDP endpoints; reverse UDP reached the permitted peer.")
