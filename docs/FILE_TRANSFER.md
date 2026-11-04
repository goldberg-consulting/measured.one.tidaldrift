# File transfer

[Documentation](README.md) · [Clipboard sync](CLIPBOARD_SYNC.md)

Use **Tidal Transfer** for batches of files and folders. TidalDrop, Finder file sharing, and LocalCast clipboard transfer are also available.

## Tidal Transfer

Open **Tidal Transfer…** from the menu-bar app, choose a destination, and drop Finder items into the window. You can add more drops while a copy runs. Each queued batch keeps the destination selected for that drop.

- **Another Mac:** install TidalDrift 1.9.0 or later on both Macs. On the receiver, open Tidal Transfer and turn on **Allow incoming Tidal Transfer batches**. On the sender, choose the nearby Mac and check its displayed address. The receiver can accept or decline the batch and see its size and sender address. An accepted batch appears in a new dated folder inside the receiver’s **Settings → General → TidalDrop** destination. The sender reports completion after the receiver verifies and saves the batch. If that receipt is lost, check the receiver before retrying.
- **A network folder or NAS:** mount the share in Finder and choose the actual destination folder in Tidal Transfer. The other computer does not need TidalDrift. Up to four files copy concurrently and existing names are kept; a collision gets a numbered name. On compatible local volumes, macOS can clone an ordinary file without copying all of its data immediately.

Closing the window stops receiving direct batches. Outgoing copies continue while TidalDrift runs; reopen the window to see progress or cancel.

**Why batching helps:** small files share one TCP connection and one manifest. Their contents are packed into writes of up to 1 MiB without building a temporary archive. The receiver verifies a SHA-256 digest before publishing the directory. This reduces setup work per file; actual speed still depends on the link, disks and filesystem. In a loopback test on one Mac, 300 files of 4 KiB each took 0.042–0.043 seconds as a batch versus 1.89 seconds as 300 separate Tidal Transfer jobs. This timed planning, sending, verification and saving with automatic test approval. It does not measure Finder, SMB, or throughput between physical Macs.

**What a direct batch preserves:** ordinary file contents, names, folder structure (including empty folders), executable status and modification times to the second. It does not reproduce ownership, ACLs, Finder tags, general extended attributes or hard-link identity. Links, special files and resource forks are refused. Use a mounted folder for Mac metadata or bundles that need these features. Limits per direct batch: 50,000 entries, 64 GiB of file contents and an 8 MiB manifest. Incoming files carry macOS quarantine and use private permissions.

**Network access:** direct batches use the existing TidalDrop TCP port 5902. Receiving is off until enabled in the window, with approval per batch. The connection is unencrypted and does not authenticate the peer’s identity; use it on a trusted LAN, or choose an appropriately secured mounted share. The toggle applies to Tidal Transfer batches, not legacy Dock drops.

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
- **A folder will not send via the Dock:** use the Tidal Transfer window for a directory tree, or compress the folder first.
- **A Pi is visible but does not receive:** the companion advertises VNC and SSH, not a TidalDrop receiver. Use SSH-based file transfer or configure a shared folder.

See [Troubleshooting](TROUBLESHOOTING.md) for discovery and permission checks.
