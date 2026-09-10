# Device discovery

TidalDrift finds nearby computers through Bonjour and supplements that with local network probes. Open the menu bar panel to see **Nearby Devices**; choose **Discover Devices** to refresh Bonjour and run a subnet scan.

A device appearing in the list means TidalDrift has discovered it or retained a recent record. It does not guarantee that every connection option is enabled on that computer. The **TD** badge identifies a TidalDrift peer advertisement, including the Linux companion package; it is not an authentication or security indicator.

## Get a device to appear

1. Connect both computers to a network that lets them communicate. Guest Wi-Fi, client isolation, separate VLANs, and VPN routing can prevent discovery or connections.
2. Enable the service on the destination computer: Screen Sharing for VNC, File Sharing for SMB, or Remote Login for SSH. For a Linux target, follow the [Raspberry Pi and Linux guide](RASPBERRY_PI.md).
3. To discover another TidalDrift Mac as a peer, leave TidalDrift running there and turn on **Peer Discovery** in both menu bar panels. LocalCast also requires **Metal Streaming Host** on the destination Mac.
4. Choose **Discover Devices** on the connecting Mac, then hover over the destination in **Nearby Devices** to see its connection actions.

TidalDrift can discover standard VNC, SMB, AFP, and SSH services without TidalDrift installed on the destination. Installing TidalDrift adds its peer information and Mac-specific features.

## Discovery settings

Open **Settings… → Network**:

- **Enable Peer Discovery** starts or stops the dedicated TidalDrift peer advertisement and discovery service. The menu bar's **Peer Discovery** switch controls the same preference. This switch does not turn off all standard service discovery.
- **Enable SSH Discovery** controls SSH Bonjour browsing and active probes of TCP port 22. Turning it off removes SSH capabilities from the discovery cache; peer rows may still offer an SSH shortcut.
- **Device cleanup interval** controls stale-device maintenance, from 15 seconds to 5 minutes. Bonjour updates continuously, so this is not a network scanning frequency.

The app runs one subnet scan shortly after launch when a local IPv4 address is available. Further full subnet scans are initiated through **Discover Devices**. The scan probes ports 5900 (VNC), 445 (SMB), 548 (AFP), and, when enabled, 22 (SSH). It also checks addresses from the local ARP table.

## Diagnose a missing device

### Check the destination service

First try the connection directly from the Mac. Replace `computer.local` with the destination's hostname or IP address:

```bash
open 'vnc://computer.local:5900'
ssh username@computer.local
```

If the direct connection fails, check the destination's service, account permissions, firewall, and address before changing discovery settings. A Bonjour advertisement can exist even when its corresponding server is stopped; the Linux package's static advertisements are one example.

### Check Bonjour from Terminal

Run the command for the missing service on the Mac:

```bash
dns-sd -B _rfb._tcp local.
```

Substitute `_ssh._tcp`, `_smb._tcp`, `_tidaldrift._tcp`, `_tidaldrop._tcp`, or `_tidaldrift-cast._udp` as needed. Browsing continues until you press **Control-C**. An `Add` line means the advertisement reached this Mac.

Resolve an instance using the exact name printed in the browse output:

```bash
dns-sd -L 'Service Instance Name' _rfb._tcp local.
```

Check the target hostname and advertised port. If Bonjour sees the expected service but TidalDrift does not, choose **Discover Devices** and check the app log. If neither sees it, check the destination advertisement and network's multicast handling. If macOS offers a Local Network permission for TidalDrift, allow it.

### Capture an app log

Run this on the affected Mac, reproduce the problem, then press **Control-C**:

```bash
log stream --predicate 'subsystem == "com.tidaldrift"' --level info
```

Useful context for a report includes the service type, whether direct connection works, whether `dns-sd` sees it, Wi-Fi or Ethernet use, and whether the issue followed sleep, a network change, or an address change. Logs can contain device names and addresses; remove anything you do not want to share.

## How discovery is implemented

The current implementation combines native APIs and `dns-sd` helpers:

- **Standard TCP services:** `NetworkDiscoveryService` uses `NWBrowser` for `_rfb._tcp`, `_smb._tcp`, `_afpovertcp._tcp`, `_ssh._tcp`, `_tidaldrift._tcp`, and `_tidaldrop._tcp`, with fallback resolution where needed.
- **TidalDrift peers:** `TidalDriftPeerService` advertises `_tidaldrift._tcp` on port 5959 using `dns-sd -R`. It browses through both a `dns-sd` helper and a native `NetServiceBrowser`. The beacon carries identity and hardware metadata; its advertised port is not a remote-control endpoint.
- **LocalCast hosts:** `_tidaldrift-cast._udp` advertises UDP port 5904. LocalCast advertising and browsing use `dns-sd` helpers. This advertisement exists while the Mac is hosting.
- **TidalDrop:** its `NWListener` advertises `_tidaldrop._tcp` on TCP port 5902. This is a separate service from the peer beacon.

The peer advertiser checks registration, helper health, and address changes every four seconds, and re-advertises on wake. It re-resolves known peers every 45 seconds and prunes peer records after five minutes without confirmation. The LocalCast host checks its listener and advertisement every five seconds and can restart them after failure or an address change. Unlike the peer advertiser, it does not parse registration confirmation from helper output.

Bonjour names and TXT records are unauthenticated discovery hints. A stable `peerId` helps associate device records and saved credentials across address changes; it does not prove that the remote computer is trusted. Connection services must enforce their own access controls.

## Limits and development checks

Subnet scanning currently assumes a `/24` IPv4 range rather than deriving a range from the interface's netmask. Hostname resolution and several fallback paths also favor IPv4. Do not treat IPv6 URL handling as complete IPv6 or link-local discovery support. Bonjour discovery normally stays within the local multicast domain unless the network explicitly forwards it.

Browser restarts preserve relevant cached state and reject obsolete delayed callbacks. Discovery helper parsing buffers complete lines, handles EOF, and limits line size. Resolution and connection probes have deadlines and cancellation handling; discovering SMB or SSH preserves the device's VNC port.

When modifying this area, run the discovery and resolver tests, then verify two computers through offline launch, Wi-Fi/Ethernet changes, DHCP renewal, sleep/wake, and repeated stop/start. Unit tests alone do not establish real-network recovery time. Watch for duplicate browsers, stale addresses, or helper processes remaining after discovery stops.

Source references: [network discovery](../TidalDrift/Services/NetworkDiscoveryService.swift), [peer discovery](../TidalDrift/Services/TidalDriftPeerService.swift), [LocalCast service](../TidalDrift/LocalCast/Core/LocalCastService.swift), [discovery tests](../TidalDrift/Tests/TidalDriftTests/DiscoverySettingsTests.swift), and [resolver tests](../TidalDrift/Tests/TidalDriftTests/ConnectionResolverTests.swift).
