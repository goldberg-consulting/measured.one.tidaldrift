# Getting started

[Documentation](README.md) · [Troubleshooting](TROUBLESHOOTING.md)

TidalDrift lives in the menu bar. This guide takes you from first launch to a connection, then points you to streaming and file transfer.

## Install and launch

Install TidalDrift using the [download or Homebrew instructions](../README.md#install). Run the app from **Applications** on macOS 13 Ventura or later.

Click the TidalDrift icon in the menu bar to see your Mac’s sharing status and **Nearby Devices**. Hover over a device to reveal its connection buttons. Clicking the Dock icon activates the app; it does not open a dashboard.

For LocalCast, install TidalDrift on both Macs. For VNC, shared folders, or SSH, the target can run a compatible server without TidalDrift.

## Run the setup wizard

The first launch opens the setup wizard. You can reopen it from **Run Setup Wizard** in the menu bar.

The wizard helps configure macOS Screen Sharing, a sharing account, File Sharing, Remote Login, and the firewall. Use **Skip for Now** or **Skip SSH** for services you don’t need. Changing system services or creating an account may ask for an administrator password.

These services are independent:

- **Screen Sharing** lets macOS Screen Sharing and other VNC clients connect to this Mac.
- **File Sharing** makes selected folders available through Finder over SMB.
- **Remote Login** permits SSH access.
- **Metal Streaming Host** enables TidalDrift’s LocalCast engine. Configure this separately in **Settings → Metal Streaming**.

## Allow the permissions you need

TidalDrift links to the relevant macOS settings from **Settings → Permissions** and **Settings → Metal Streaming**.

- **Local Network:** allow discovery and direct connections when macOS prompts.
- **Screen Recording:** grant on the LocalCast host so it can capture the display or app. Some macOS versions label this Screen & System Audio Recording.
- **Accessibility:** grant on the host for remote mouse and keyboard control. The viewer also uses Accessibility to forward system keyboard shortcuts.
- **Notifications:** optional, for transfer and connection notifications.

If macOS asks you to quit and reopen after granting permission, do so before reconnecting. You can view a LocalCast stream without host Accessibility, but remote input will not work.

## Find another computer

1. Put the computers on the same local network and make sure the target is awake.
2. Leave **Peer Discovery** enabled in the menu bar.
3. Look under **Nearby Devices**. If the target is missing, choose **Discover Devices** to refresh discovery and scan the local subnet.
4. Hover over the device row to see its actions. **Details**, the information icon, opens its services, credentials, connection history, and network tools.

A device appearing in the list means TidalDrift found it; the target still needs to enable each service you want to use. See [Discovery and networking](BONJOUR_DISCOVERY.md) if the list is empty or an address looks wrong.

## Open a desktop with Screen Sharing

On the target Mac, enable **Screen Sharing** in system Sharing settings and allow access for the account you’ll use. TidalDrift’s setup wizard can help with this.

On the connecting Mac:

1. Hover over the target under **Nearby Devices**.
2. Click **Screen Share (VNC)**, the display icon.
3. Authenticate in macOS Screen Sharing using an account allowed on the target.

The **Details → Saved Credentials** fields can supply credentials to the **Screen Share** button inside Details. With **Save credentials in Keychain** selected and a nonempty username, TidalDrift saves those fields after it successfully launches a connection. Typing into the fields or clicking **Done** alone does not save them.

Linux VNC servers can use a separate VNC password. Follow the [Raspberry Pi guide](RASPBERRY_PI.md) for that setup.

## Set up LocalCast (Metal Streaming)

LocalCast opens TidalDrift’s own streaming viewer. The **host** shares its display or app; the **viewer** connects to it.

1. On the host, open **Settings → Metal Streaming**. Configure its host password with authentication enabled.
2. Grant Screen Recording, then enable **Host this Mac**. You can also control hosting with **Metal Streaming Host** in the menu bar.
3. On the viewer, prepare a matching saved device password using the [LocalCast connection instructions](LOCALCAST.md#start-a-session).
4. Use **Start Cast**, the purple lightning bolt on the host’s device row.

The menu-bar action uses the password already saved for that device and does not display a password-entry sheet. The LocalCast host password is configured separately from a Mac login password.

Once connected, use the viewer’s **Stream Controls** for quality, app selection, and session information. See [LocalCast](LOCALCAST.md) for the complete workflow and [Clipboard sync](CLIPBOARD_SYNC.md) for copying between Macs.

## Open shared folders or a terminal

**File Share**, the folder icon, opens Finder for the target’s SMB service. Authenticate with an account that has access to its shared folders.

**SSH**, the terminal icon, opens Terminal. The menu-bar shortcut uses your current Mac username on the remote machine. If the remote username differs, connect from Terminal with the correct account:

```bash
ssh remote-user@computer.local
```

Replace the username and hostname with the target’s values. Remote Login or another SSH server must be enabled on that computer.

## Send files

Keep TidalDrift in the Dock by dragging the app from **Applications** to the apps area of the Dock. It normally runs as a menu-bar app, so the Dock icon may not appear automatically.

Drag files from Finder onto that icon, select destination devices, and click **Send**. Direct TidalDrop transfers require TidalDrift running on the receiving Mac; an existing mounted share can also be used.

The default receiving folder is `~/Public/Drop Box`. Change it in **Settings → General → TidalDrop**. See [File transfer](FILE_TRANSFER.md) for destination behavior and the differences between TidalDrop, shared folders, and clipboard files.

## Make it your own

In **Settings → General**, choose launch at login, notifications, appearance, and clipboard sync. In the menu bar, use the pencil beside your Mac’s name to set the name other TidalDrift peers see.

For sleeping devices, review **Settings → Network → Wake-on-LAN**. Waking also depends on the target’s hardware, power state, network connection, and Wake for network access setting.

If something fails, start with [Troubleshooting](TROUBLESHOOTING.md).
