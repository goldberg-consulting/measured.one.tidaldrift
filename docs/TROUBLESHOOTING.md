# Troubleshooting

[Documentation](README.md) · [Getting started](GETTING_STARTED.md)

Start with the section that matches what you see. Most connection problems come down to the target service, network reachability, the credential for that service, or macOS permissions.

## TidalDrift opens without a main window

This is expected. Click the menu-bar icon for **Nearby Devices**, hosting controls, and **Settings…**. Clicking the Dock icon activates the app.

## A device is missing

1. Confirm the target is awake and connected to the same local network.
2. Leave **Peer Discovery** enabled and choose **Discover Devices**.
3. Allow TidalDrift local network access on macOS versions that request it.
4. Check that the target advertises or runs the service you want: TidalDrift, VNC, SMB, or SSH.
5. Check whether guest Wi-Fi, network isolation, or a VPN prevents the two computers from reaching each other.

Bonjour discovery usually stays on the local network segment. **Discover Devices** also probes the local IPv4 /24 subnet, which does not cover every address on larger networks. See [Discovery and networking](BONJOUR_DISCOVERY.md) for service details and diagnostics.

## “Metal Stream Unavailable”

On the target Mac:

1. Confirm TidalDrift is running.
2. Open **Settings → Metal Streaming** and check the displayed error, if any.
3. With authentication enabled, set a nonempty host password.
4. Grant Screen Recording and enable **Host this Mac**.

On the viewer, refresh discovery and retry **Start Cast**. For authenticated hosting, its saved device password must match the LocalCast host password. The menu-bar button does not prompt for a missing password; see [LocalCast](LOCALCAST.md).

A working VNC connection does not establish that LocalCast is enabled. LocalCast uses UDP port 5904; its bulk clipboard channel uses TCP 5906.

## The picture works, but mouse or keyboard control does not

On the host, grant TidalDrift **Accessibility** permission. In the viewer, enable remote input and make the viewer window active. **Command–Shift–I** toggles remote input capture.

If ordinary keys work but system shortcuts stay local, check Accessibility on the viewer too. Some shortcuts are intentionally kept local, including **Command–Tab** and **Command–Option–Escape**.

Reconnect after changing permissions if input still does not work. See [LocalCast](LOCALCAST.md) for input behavior.

## The stream is blurry, delayed, or stutters

Open the viewer’s **Stream Controls → Quality** and try a lower resolution or bitrate. Adjust **Transport profile** on the host under **Settings → Metal Streaming**. A stable wired connection can help distinguish a network problem from a host or viewer limit.

For a TidalDrift peer, open **Details → Network Speed Test → Run Test** to measure latency and UDP throughput. Both Macs need a version with the speed-test responder.

The [LocalCast guide](LOCALCAST.md) explains which controls apply live and which rebuild capture. Keep both apps updated when comparing behavior.

## Screen Sharing refuses the connection

Confirm **Screen Sharing** is enabled on the target and the account is allowed to connect. VNC credentials and the LocalCast host password serve different purposes.

If macOS reports that access is “not permitted,” review the allowed users and try turning Screen Sharing off and back on at the target. Check that the target’s firewall permits the service.

For Linux targets, confirm the VNC server is listening and use its VNC password. The [Pi guide](RASPBERRY_PI.md) includes service and port checks.

## SSH signs in as the wrong user

The menu-bar SSH shortcut uses the username of your current Mac account. When the target has a different username, open Terminal and specify it:

```bash
ssh remote-user@computer.local
```

Terminal handles SSH authentication. Changing a LocalCast password does not change the SSH account.

## Clipboard content or files do not arrive

Enable **Clipboard Sync** on both Macs and keep the LocalCast session open. Small content can use the session’s control channel; files and bulk content require a password-authenticated session and TCP 5906.

Content marked confidential or transient is intentionally skipped. See [Clipboard sync](CLIPBOARD_SYNC.md) for supported formats and limits, or [File transfer](FILE_TRANSFER.md) for a TidalDrop problem.

## Permissions stopped working after a development build

The development build script resets TidalDrift’s Screen Recording, Accessibility, Input Monitoring, and Local Network grants. Reopen the app and grant the permissions it needs.

First check the individual settings from **Settings → Permissions**. If grants remain stuck, **Fix All Permission Issues** attempts to reset those four permission categories; you will need to grant them again. Despite older explanatory text in the app, that combined action does not restart the Screen Sharing service.

If you have multiple copies installed, use **Settings → Maintenance → Scan & Cleanup…** to review them. Run the intended copy from Applications. See [Contributing](../CONTRIBUTING.md) for development-install details.

## A sleeping device does not wake

Check **Settings → Network → Enable Wake-on-LAN** and the target’s Wake for network access setting. Open **Details** to review or discover its MAC address and use **Wake Device**.

Wake-on-LAN depends on the target’s hardware, power state, and network. A successful wake-packet send does not guarantee that the computer has woken or that its services are ready.

## Report a reproducible problem

Open an [issue](https://github.com/goldberg-consulting/measured.one.tidaldrift/issues) with:

- TidalDrift versions on both computers, macOS/Linux versions, and computer models.
- The action you used: Start Cast, Screen Share, File Share, SSH, TidalDrop, or clipboard sync.
- Steps to reproduce, expected result, actual result, and the exact error.
- Whether the connection uses Wi-Fi, Ethernet, a VPN, or separate network segments.
- Relevant results from **Settings → Tests**, and whether you were hosting during those tests.

For logs, use Console on macOS and filter by the TidalDrift process or subsystem `com.tidaldrift`. Review excerpts before posting: logs can include device names, addresses, usernames, and file paths.
