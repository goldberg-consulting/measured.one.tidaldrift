# Raspberry Pi and Linux

Use TidalDrift on your Mac to open a Linux desktop in macOS Screen Sharing or start an SSH session in Terminal. The `tidaldrift-pi` companion package advertises the Linux machine through Bonjour and supplies a TigerVNC virtual desktop.

LocalCast and app-window streaming require a Mac host. The Linux package does not provide a LocalCast host, a TidalDrop receiver, or an SMB file server. The **TD** badge reflects the package's peer advertisement, not support for every TidalDrift feature.

## Before installing

You need:

- A Raspberry Pi or Debian-family Linux machine with `apt` and `systemd`, reachable from the Mac.
- An existing non-root account with a home directory at `/home/<username>`. The packaged VNC service checks for its password file there.
- A desktop environment that TigerVNC can start. The package installs the VNC server, but does not install or configure a desktop environment. A minimal or Lite OS image needs that additional setup.
- Access to a terminal on the Linux machine, either locally or over SSH.

The package creates an independent **virtual desktop**, 1920 × 1080, on display `:1` and TCP port **5900**. It can work without a monitor once a desktop session is configured. It does not mirror the physical display.

Only one `tidaldrift-vnc@<username>` instance can run at a time: every instance uses the same display and port. Another VNC server must not occupy port 5900.

## Install and start the desktop

Download the `.deb` companion asset from a [TidalDrift release](https://github.com/goldberg-consulting/measured.one.tidaldrift/releases) and copy it to the Linux machine. The package currently declares version `0.1.2`; use the filename of the asset you downloaded.

Run on Linux, replacing `youruser` with the existing account that should own the desktop:

```bash
sudo apt install ./tidaldrift-pi_0.1.2_all.deb
sudo apt install openssh-server
sudo systemctl enable --now ssh avahi-daemon
```

`avahi-daemon` and `tigervnc-standalone-server` are package dependencies. `openssh-server` is only recommended by the package, so the explicit install above ensures the SSH path is available even when recommended packages are disabled.

Before starting TigerVNC, check whether another server already owns its port:

```bash
sudo ss -ltnp 'sport = :5900'
```

If you are switching from a system `wayvnc` service, stop that service first:

```bash
sudo systemctl disable --now wayvnc.service
```

Other VNC services may use different names or run as user services. Stop the actual competing service before continuing. **The setup helper does not disable other VNC servers for you.**

Set the VNC password and start the desktop:

```bash
sudo tidaldrift-pi-setup youruser
sudo systemctl status tidaldrift-vnc@youruser.service
```

The helper runs TigerVNC's password tool as that user, enables the VNC service at boot, starts it immediately, and reloads Avahi. Use the password you set here when macOS Screen Sharing asks for a password. It is separate from the Linux account password; classic VNC authentication uses at most eight password characters.

This VNC configuration uses password authentication without transport encryption and listens on the LAN. Keep port 5900 on a trusted network; do not expose it directly to the internet.

## Connect from the Mac

1. Open TidalDrift's menu bar panel and choose **Discover Devices**.
2. Find the Linux hostname under **Nearby Devices** and hover over its row.
3. Choose the display icon, **Screen Share (VNC)**. Enter the VNC password in macOS Screen Sharing.
4. For a terminal session, choose **SSH**.

The menu bar's SSH shortcut uses your current **Mac account name**. If the Linux username differs, run an explicit command in Terminal:

```bash
ssh youruser@raspberrypi.local
```

Replace `raspberrypi.local` with the machine's hostname or IP address. SSH uses your SSH keys or asks for the Linux account password in Terminal; the VNC password is not used for SSH.

You can also open Screen Sharing directly:

```bash
open 'vnc://raspberrypi.local:5900'
```

A device can appear before its VNC desktop or SSH server is ready: the Avahi service records are static. The connection actions are not service health checks.

## Keep the desktop running

Change the VNC password by signing in as the desktop's Linux user and running:

```bash
tigervncpasswd
sudo systemctl restart tidaldrift-vnc@youruser.service
```

Use `tigervncpasswd` explicitly when RealVNC is also installed; a generic `vncpasswd` command may invoke the wrong password tool. The setup helper prefers `tigervncpasswd` and falls back to `vncpasswd` only if needed.

To stop hosting, disable the selected instance:

```bash
sudo systemctl disable --now tidaldrift-vnc@youruser.service
```

The static VNC advertisement remains while the package is installed. If you switch to a different VNC server, keep its port and `/etc/avahi/services/tidaldrift-rfb.service` in agreement, and confirm that it supports macOS Screen Sharing authentication. Sharing a physical Wayland desktop with `wayvnc` is a separate configuration; this package does not configure it.

## Troubleshooting

### The machine does not appear

On Linux, check Avahi and reload its records:

```bash
systemctl status avahi-daemon
sudo systemctl reload-or-restart avahi-daemon
```

On the Mac, check whether the VNC advertisement is visible:

```bash
dns-sd -B _rfb._tcp local.
```

Press **Control-C** to stop browsing. If the advertisement is absent, check multicast handling, guest-network isolation, and the Linux firewall. See [device discovery](BONJOUR_DISCOVERY.md) for more checks.

### Screen Sharing cannot connect

Check the VNC service, its recent log, and the listener on Linux:

```bash
systemctl status tidaldrift-vnc@youruser.service
journalctl -u tidaldrift-vnc@youruser.service -n 80 --no-pager
sudo ss -ltnp 'sport = :5900'
```

A missing-password error means the password must be created for the same account as the service instance. A port-in-use error means another VNC process or another `tidaldrift-vnc` instance is running. A session that exits immediately usually requires checking the installed desktop and the user's TigerVNC session configuration.

To check the listener from the Mac:

```bash
nc -w 3 raspberrypi.local 5900 </dev/null
```

An `RFB ...` banner confirms a reachable VNC server, but does not test password acceptance or desktop startup.

### “Incompatible with this version of Screen Sharing”

The packaged unit pins TigerVNC to `-SecurityTypes VncAuth` for compatibility with macOS Screen Sharing. If you changed the server configuration, restore that setting and restart the service. The unit deliberately uses `-rfbport 5900`; display `:1` otherwise normally uses 5901.

For password-only VNC servers, connect without a username in the `vnc://` URL. TidalDrift probes the server's advertised authentication types when a username is supplied and omits credentials for password-only servers. If that probe cannot complete, a direct URL with no username is a useful diagnostic.

### Password is rejected

Use the VNC password set by `tidaldrift-pi-setup`, not the SSH or Linux login password. Reset it with the TigerVNC password tool under the correct Linux account, then restart that user's service.

### Blank desktop or immediate disconnect

The package does not select or install a desktop session. Check the service log and the user's TigerVNC logs, then configure a compatible desktop session for the Linux distribution in use. A running VNC listener alone does not establish that a desktop environment started successfully.

## Package contents and identity

The package installs:

- `/etc/avahi/services/tidaldrift-ssh.service`: advertises SSH on TCP 22.
- `/etc/avahi/services/tidaldrift-rfb.service`: advertises VNC on TCP 5900.
- `/etc/avahi/services/tidaldrift-peer.service`: generated during installation, advertises `_tidaldrift._tcp` with the machine's model, OS, package version, and stable `peerId`.
- `/lib/systemd/system/tidaldrift-vnc@.service`: the TigerVNC service template.
- `/usr/bin/tidaldrift-pi-setup`: the password and service setup helper.

The peer ID lives in `/etc/tidaldrift/peer-id`. It lets TidalDrift associate the machine with saved credentials even after its address changes. It is discovery metadata, not an authentication secret. The peer beacon advertises port 5959 for metadata only; the package does not run a server on that port.

`sudo apt remove tidaldrift-pi` stops the VNC instances and removes the generated peer advertisement, while retaining the peer ID and packaged configuration files. `sudo apt purge tidaldrift-pi` also removes the peer ID and package configuration. User-owned VNC password/session files remain in the user's home directory.

## Build the package from source

With `dpkg-deb` available, run from the repository root:

```bash
./linux/tidaldrift-pi/build-deb.sh
```

On macOS, install the build tool with `brew install dpkg`. The script reads the version from [the package control file](../linux/tidaldrift-pi/pkg/DEBIAN/control) and writes `linux/tidaldrift-pi/tidaldrift-pi_<version>_all.deb`. The release workflow builds and uploads this asset after the Mac app release steps.

Implementation references: [setup helper](../linux/tidaldrift-pi/pkg/usr/bin/tidaldrift-pi-setup), [VNC unit](../linux/tidaldrift-pi/pkg/lib/systemd/system/tidaldrift-vnc@.service), [installation script](../linux/tidaldrift-pi/pkg/DEBIAN/postinst), and [Screen Sharing connection service](../TidalDrift/Services/ScreenShareConnectionService.swift).
