# Raspberry Pi and Linux Targets

**Scope:** How TidalDrift connects to non-Mac machines (SSH and Screen
Share), the `tidaldrift-pi` companion package, and the VNC compatibility
work that makes macOS Screen Sharing interoperate with Linux VNC servers.
Shipped across app v1.6.53 and v1.6.54 and package 0.1.2.

## What works

A Raspberry Pi (or any Debian-family machine) running the companion
package appears in TidalDrift's device list like a Mac, with two working
connection paths:

| Path | Transport | Auth |
|---|---|---|
| SSH button | `ssh <user>@<host>.local` in Terminal | SSH keys (or the account password) |
| Screen Share button | macOS Screen Sharing over RFB, port 5900 | Classic VNC password (VncAuth) |

LocalCast (the custom Metal streaming pipeline) remains Mac-to-Mac; for a
Pi's desktop, VNC is the appropriate tier.

## The tidaldrift-pi package

`tidaldrift-pi_<version>_all.deb` is attached to each GitHub release and
built from `linux/tidaldrift-pi/` (`build-deb.sh`, works on macOS with
Homebrew dpkg and on Debian).

| Piece | Purpose |
|---|---|
| `/etc/avahi/services/tidaldrift-ssh.service` | Advertises `_ssh._tcp` (22) over Bonjour, which TidalDrift browses |
| `/etc/avahi/services/tidaldrift-rfb.service` | Advertises `_rfb._tcp` (5900), producing the Screen Share button |
| `/etc/avahi/services/tidaldrift-peer.service` | `_tidaldrift._tcp` peer beacon with a persisted `peerId`, generated at install |
| `tidaldrift-vnc@<user>.service` | TigerVNC virtual desktop, pinned to port 5900 |
| `tidaldrift-pi-setup` | One-time helper: sets the VNC password, enables the service |

Install:

```bash
sudo apt install -y ./tidaldrift-pi_<version>_all.deb
sudo tidaldrift-pi-setup <username>
```

The peer beacon's stable `peerId` plugs into the credential identity
system introduced in v1.6.52: saved logins for the machine are keyed by
identity, not IP or hostname, so they survive DHCP lease changes and
multi-NIC ambiguity. `apt remove` preserves the ID; `apt purge` discards
it.

## VNC server choices and pitfalls

**TigerVNC virtual desktop (what the package runs).** The unit starts
`tigervncserver :1 -rfbport 5900 -localhost no -SecurityTypes VncAuth`.
A virtual desktop works headless (no monitor, no GPU session) and renders
the Pi's full desktop environment at 1920x1080. Two settings are
deliberate:

- **`-rfbport 5900`**: display `:1` would default to port 5901; pinning
  5900 matches both the Bonjour advertisement and what `vnc://host`
  implies, so every path lands on the same server.
- **`-SecurityTypes VncAuth`**: TigerVNC's default list (`VncAuth,TLSVnc`)
  makes the server advertise VeNCrypt ahead of classic VncAuth. macOS
  Screen Sharing does not implement VeNCrypt and, rather than falling
  back, aborts with "the software on the remote computer appears to be
  incompatible with this version of Screen Sharing." Pinning VncAuth
  removes the poison type. (Fixed in package 0.1.1 -> 0.1.2.)

**wayvnc (Raspberry Pi OS default).** Pi OS ships a `wayvnc.service`
sharing the physical Wayland desktop, with `Restart=always`. If both are
enabled, wayvnc crash-loops against TigerVNC's port and can steal 5900
after a restart race. The setup flow disables it. To share the physical
display instead of a virtual one, re-enable wayvnc deliberately and
remove the TigerVNC unit; the Avahi advertisements work for either.

**vncpasswd shadowing.** On systems where RealVNC coexists with TigerVNC,
plain `vncpasswd` resolves to RealVNC's incompatible tool; the setup
helper prefers `tigervncpasswd` (package 0.1.1). Note that classic
VncAuth uses at most 8 password characters.

## Client-side compatibility: the RFB security probe (v1.6.54)

macOS Screen Sharing changes its authentication mode based on whether the
`vnc://` URL carries a username. With a username present it insists on
Mac-style authentication; against a password-only server it reports the
same misleading "incompatible" error. TidalDrift previously always passed
saved device credentials into the URL, which broke non-Mac targets the
moment credentials were saved.

Since v1.6.54, `ScreenShareConnectionService` probes the server's RFB
handshake (server version, client version reply, security-type list;
2.5 s timeout) before building the URL, and omits the username and
password when the server offers no username-capable type. Screen Sharing
then shows its plain password prompt, which authenticates cleanly.

| Offered security types | Username sent | Typical server |
|---|---|---|
| 30, 33, 35, 36 (Apple auth family) | Yes | macOS Screen Sharing host (measured on Tahoe) |
| 5, 6, 129, 130, 133, 134 (RSA-AES family) | Yes | RealVNC |
| 2 (VncAuth), 1 (None), 16 (Tight), 19 (VeNCrypt) only | No | TigerVNC, wayvnc, x11vnc |

A failed probe (timeout, non-RFB banner, pre-3.7 server) leaves the
existing behavior untouched, so Mac-to-Mac connections cannot regress.
The decision table is unit-tested in `RFBSecurityProbeTests` with type
sets measured from live servers.

## Security notes

- RFB traffic is password-gated but unencrypted. Treat it as LAN-only;
  tunnel over SSH for anything else.
- The VNC password is independent of the account password. Change it on
  the machine with `tigervncpasswd`, then
  `sudo systemctl restart tidaldrift-vnc@<user>`.
- SSH key auth is the recommended posture for the SSH path; disable
  password authentication in `sshd_config` once keys are installed.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| "Incompatible with this version of Screen Sharing" immediately | Server advertises VeNCrypt/TLS (TigerVNC default list) | Package 0.1.2 pins `-SecurityTypes VncAuth` |
| Same error, but after a password dialog | Username in the vnc:// URL against a password-only server | App v1.6.54 probes and omits the username; or connect with the username field empty |
| Auth fails repeatedly | Wrong credential: the prompt wants the VNC password, not the SSH/login password | Use the password set by `tidaldrift-pi-setup` / `tigervncpasswd` |
| Screen Share button missing in TidalDrift | Avahi advertisement not live | `systemctl reload-or-restart avahi-daemon`; verify with `dns-sd -B _rfb._tcp local.` from the Mac |
| Port 5900 flapping between servers | wayvnc and TigerVNC both enabled | `sudo systemctl disable --now wayvnc` (or choose wayvnc and remove the TigerVNC unit) |
| Blank/black desktop in the viewer | No desktop environment installed for the virtual session | Install a desktop (e.g. `raspberrypi-ui-mods`) or share the physical desktop via wayvnc |

Verification one-liners from the Mac:

```bash
dns-sd -B _rfb._tcp local.          # advertisement visible?
nc -w 3 <host> 5900 </dev/null      # prints "RFB 003.008" if the server is up
```
