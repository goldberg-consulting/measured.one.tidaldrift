#!/bin/bash
# Test if UDP port 5904 is reachable on a host (e.g. the other Mac running LocalCast).
# Usage: ./test-port-5904.sh [host]
#   host = IP or hostname (default: 127.0.0.1 for loopback test)

HOST="${1:-127.0.0.1}"
PORT=5904

echo "Testing UDP port $PORT on $HOST..."
echo "(Sending one UDP packet; no response is normal — check the *host* Mac has LocalCast on.)"
echo ""

if echo "" | nc -u -w 2 "$HOST" "$PORT" 2>&1; then
  echo "Send completed (UDP is fire-and-forget; this does not prove the host replied)."
else
  echo "nc exit code: $?"
fi

echo ""
echo "On the *host* Mac, check if something is listening on 5904:"
echo "  lsof -i UDP:$PORT"
echo "  # or: netstat -an | grep $PORT"
