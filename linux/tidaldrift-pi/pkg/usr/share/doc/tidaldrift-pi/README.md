# tidaldrift-pi

Make a Raspberry Pi or Debian-family Linux machine discoverable in TidalDrift on a Mac. This package advertises SSH and VNC through Bonjour and provides a TigerVNC virtual desktop.

The desktop is independent of the physical display: 1920 × 1080, display `:1`, TCP port 5900. It can run headless once a compatible desktop environment is installed and configured. The package does not install a desktop environment, LocalCast, a TidalDrop receiver, or a file server.

## Set up

Use a systemd-based machine and an existing non-root account with a home directory at `/home/<username>`. Replace `youruser` below with that account.

The package depends on `avahi-daemon` and `tigervnc-standalone-server`. SSH is a recommended package, so ensure it is installed and enabled:

```bash
sudo apt install openssh-server
sudo systemctl enable --now ssh avahi-daemon
```

Check for another VNC server before starting this one:

```bash
sudo ss -ltnp 'sport = :5900'
```

Stop any competing server. For a system `wayvnc.service`, use `sudo systemctl disable --now wayvnc.service`. The setup helper does not disable competing servers automatically. Only one `tidaldrift-vnc` user instance can run because every instance uses the same display and port.

Set the VNC password, then start and enable the desktop:

```bash
sudo tidaldrift-pi-setup youruser
systemctl status tidaldrift-vnc@youruser.service
```

The password belongs to VNC and is separate from the Linux login password. Classic VNC authentication uses at most eight password characters. This server uses `VncAuth` for macOS Screen Sharing compatibility; its traffic is not encrypted. Keep TCP 5900 on a trusted local network.

## Connect from a Mac

Open TidalDrift's menu bar panel, choose **Discover Devices**, and find the machine under **Nearby Devices**. Hover over its row and select **Screen Share (VNC)**. Enter the VNC password when macOS Screen Sharing prompts.

The **SSH** shortcut uses the current Mac account name. When the Linux username differs, open Terminal and supply it explicitly:

```bash
ssh youruser@raspberrypi.local
```

Use the machine's real hostname or IP in place of `raspberrypi.local`. To connect directly to its desktop:

```bash
open 'vnc://raspberrypi.local:5900'
```

Use the VNC password for Screen Sharing and SSH keys or the Linux account password for SSH. LocalCast's **Start Cast** action requires a Mac host and is not provided by this package.

## Maintain and troubleshoot

Read service state and logs:

```bash
systemctl status tidaldrift-vnc@youruser.service
journalctl -u tidaldrift-vnc@youruser.service -n 80 --no-pager
sudo ss -ltnp 'sport = :5900'
```

- **Missing password:** run the setup helper for the same user as the service instance. The unit checks `/home/<username>/.config/tigervnc/passwd` and `/home/<username>/.vnc/passwd`.
- **Port already in use:** stop the other VNC server or user instance.
- **Blank desktop or session exits:** install and configure a compatible desktop environment; check the user's TigerVNC logs as well as the service journal.
- **Incompatible server error:** the packaged unit requires `-SecurityTypes VncAuth`. Use a `vnc://` URL without a username for password-only VNC.
- **Not discovered:** check `systemctl status avahi-daemon`, then run `sudo systemctl reload-or-restart avahi-daemon`. Verify both machines can communicate on the local network.

To change the VNC password, run `tigervncpasswd` while signed in as the desktop user, then restart the service:

```bash
sudo systemctl restart tidaldrift-vnc@youruser.service
```

To stop hosting:

```bash
sudo systemctl disable --now tidaldrift-vnc@youruser.service
```

The VNC Bonjour advertisement remains while the package is installed; an advertised machine can therefore appear even if its desktop service is stopped.

## Installed files and removal

- `/etc/avahi/services/tidaldrift-ssh.service`: SSH advertisement on TCP 22.
- `/etc/avahi/services/tidaldrift-rfb.service`: VNC advertisement on TCP 5900.
- `/etc/avahi/services/tidaldrift-peer.service`: generated TidalDrift peer metadata.
- `/etc/tidaldrift/peer-id`: stable ID used to associate device records and saved credentials across address changes. It is not an authentication secret.
- `/lib/systemd/system/tidaldrift-vnc@.service`: the virtual desktop service.
- `/usr/bin/tidaldrift-pi-setup`: setup helper.

The peer advertisement's port 5959 is metadata only; no server listens there. Its **TD** badge does not imply support for all Mac features.

`apt remove tidaldrift-pi` stops VNC instances and removes the generated peer advertisement, but retains the peer ID and packaged configuration files. `apt purge tidaldrift-pi` also removes the peer ID and package configuration. Neither deletes user-owned VNC files from home directories.

For installation, build instructions, and additional diagnostics, see the [Raspberry Pi and Linux guide](https://github.com/goldberg-consulting/measured.one.tidaldrift/blob/main/docs/RASPBERRY_PI.md).
