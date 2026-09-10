# File transfer

[Documentation](README.md) · [Clipboard sync](CLIPBOARD_SYNC.md)

TidalDrift offers three ways to move files: send them with TidalDrop, browse a shared folder in Finder, or copy and paste during a LocalCast session.

## Send with TidalDrop

1. Run TidalDrift on the receiving Mac and confirm it appears under **Nearby Devices**.
2. On the sender, drag one or more files from Finder onto TidalDrift’s Dock icon. If it is missing, first drag TidalDrift from **Applications** to the apps area of the Dock to keep it there.
3. Select the destination devices and click **Send**.

A transfer does not require an open LocalCast session. The Dock picker can send the same files to multiple devices.

For a folder, create an archive in Finder and send the archive. TidalDrop’s direct sender handles individual file contents, not a directory tree.

### Where files go

For direct transfers, the receiver chooses the destination in **Settings → General → TidalDrop**. The default is:

```text
~/Public/Drop Box
```

TidalDrift creates the destination if needed. If a direct incoming file has the same name as an existing file, it receives a numbered name such as `report (1).pdf`.

If a matching share is already mounted on the sender, TidalDrop copies to that share instead. It looks for a Drop Box or Public folder within the share, then falls back to the share’s root. This path does not use the receiver’s configured TidalDrop folder, and a same-name file can be replaced.

### Direct transfer behavior

The receiving app listens on TCP port 5902 while its TidalDrop service is running. It accepts transfers from local/private network addresses and writes incoming files without a per-file acceptance prompt.

Direct TidalDrop uses an unauthenticated TCP connection without application-level encryption. Use it on a trusted local network. For files within a password-authenticated LocalCast session, [clipboard file transfer](CLIPBOARD_SYNC.md) uses that session’s encrypted channel.

## Browse a shared folder

Enable **File Sharing** on the target and configure the folders and accounts allowed to access them.

Hover over the device in TidalDrift and click **File Share**. Finder opens the SMB connection and handles sign-in and share selection. After mounting a share, use Finder to copy, move, and organize its files.

The target does not need TidalDrift for ordinary SMB access. A discovered Linux peer needs an SMB server if you want to use this path; the Pi companion does not configure one.

## Copy and paste in LocalCast

During a password-authenticated LocalCast session, enable **Clipboard Sync** on both Macs, copy files in Finder on one Mac, and paste on the other. The destination app chooses where the pasted files go.

This is separate from the TidalDrop receiving folder. Read [Clipboard sync](CLIPBOARD_SYNC.md) for file limits, supported formats, and how large transfers work.

## If a transfer fails

- **No receiving device:** choose **Discover Devices**, then confirm the target’s app is running.
- **Direct transfer cannot connect:** check the receiver’s **Drop** status indicator and firewall access for TidalDrift. Direct transfers use TCP 5902.
- **Files are not in the expected folder:** check the receiver’s TidalDrop destination and whether the sender used an already-mounted share.
- **Cannot write to the destination:** choose a writable folder on the receiver; for mounted shares, check the remote account’s write access.
- **A folder will not send:** compress it in Finder first, then send the archive.
- **A Pi is visible but does not receive:** the companion advertises VNC and SSH, not a TidalDrop receiver. Use SSH-based file transfer or configure a shared folder.

See [Troubleshooting](TROUBLESHOOTING.md) for discovery and permission checks.
