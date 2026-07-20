# tidaldrift-pi

Companion package that makes a Raspberry Pi (or any Debian-family machine)
a first-class target for TidalDrift on macOS: the Pi shows up in the
device list with working SSH and Screen Share buttons.

## What it installs

| Piece | Purpose |
|---|---|
| `/etc/avahi/services/tidaldrift-ssh.service` | Advertises `_ssh._tcp` (port 22) over Bonjour |
| `/etc/avahi/services/tidaldrift-rfb.service` | Advertises `_rfb._tcp` (port 5900) over Bonjour |
| `/etc/avahi/services/tidaldrift-peer.service` | TidalDrift peer beacon (`_tidaldrift._tcp`) with a stable `peerId` and hardware metadata, generated at install time |
| `tidaldrift-vnc@.service` | TigerVNC virtual desktop, per user, pinned to port 5900 |
| `tidaldrift-pi-setup` | One-time helper: sets the VNC password and starts the service |

## Install

```bash
sudo apt install -y ./tidaldrift-pi_0.1.2_all.deb
sudo tidaldrift-pi-setup <username>
```

`tigervnc-standalone-server` and `avahi-daemon` come in as dependencies.
The setup step prompts for a VNC password (this is what macOS Screen
Sharing asks for when connecting).

## Notes

- The VNC session is a **virtual desktop** (1920x1080): it works headless,
  with no monitor attached, and is independent of anything on the Pi's
  physical display. To share the physical Wayland desktop instead, use
  `wayvnc` and keep only this package's Avahi advertisements.
- The stable peer ID in the beacon means TidalDrift keys this machine's
  saved login by identity, not IP, so credentials survive DHCP changes.
  `apt remove` keeps the ID; `apt purge` discards it.
- RFB traffic is password-gated but not encrypted. Treat it as a
  LAN-only service; for remote access, tunnel over SSH.
