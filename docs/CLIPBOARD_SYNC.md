# Copy and paste between Macs

LocalCast shares supported clipboard content in both directions during a connected session. Copy on one Mac and paste on the other, including pasting into a remote app through the viewer.

## Turn it on

Enable **Clipboard Sync** in the TidalDrift menu on **both Macs**. The same switch is available at **Settings → General → Sync clipboard during LocalCast sessions**. It is enabled by default, and each Mac remembers its own setting.

Connect with [LocalCast](LOCALCAST.md), then make a new copy. Content copied before the session started is not sent. A session viewing the same Mac disables synchronization because both sides share one clipboard.

For files and large content, use a password-protected session. With authentication disabled, only small inline content can sync; it travels without session encryption.

## What you can copy

- **Text:** plain text, rich text (RTF), and HTML. Available representations travel together so the receiving app can choose a suitable format.
- **Images:** supported clipboard images are converted for transfer. Application-specific image formats are not copied verbatim.
- **Regular files:** copy one or more files, then paste into an app that accepts macOS file promises. Empty files are supported.

The limit is **100 MiB for the complete transfer** and **64 regular files**. The inline message limit is **32 KiB after encoding**, including base64 overhead; larger text/images and all files use the authenticated bulk channel. Images above **64 Mi pixels** are rejected before decoding.

Folders, application bundles, resource forks, extended attributes, file permissions, and arbitrary application-specific clipboard types are not transferred. A transfer preserves file contents, not a complete macOS filesystem object.

## Paste files

Copying files sends an offer with names and sizes. File bytes transfer when the receiving app requests them on paste, using macOS file promises. Keep the source files readable and unchanged in size until the paste finishes.

The receiving app chooses the destination. TidalDrift verifies the received bytes before delivering them and does not overwrite an existing destination file; an unresolved name collision fails the paste. Different receiving apps handle file promises and destination naming differently.

You can paste the same offered files more than once. If a transfer fails, paste again while the offer is still current. Copying newer content invalidates the old offer and its unfinished transfers.

## Drop content onto the viewer

Drop regular files, text, or images onto the LocalCast viewer to put them on the **host’s clipboard**, then paste into the desired remote app. A viewer drop does not simulate native drag-and-drop into that app or replace the viewer Mac’s own clipboard.

Unlike ordinary file copy/paste, dropped files are fetched immediately into the host’s clipboard cache. This requires updated peers with drop support, a password-protected session, and Clipboard Sync enabled on both Macs. Folders and file promises are unsupported as drop sources, and the same size/count limits apply.

The viewer’s **Drop offered — paste on the host after transfer** message confirms that an offer was sent. It is not a completion acknowledgment. A newer copy or disabling sync can cancel an unfinished drop.

TidalDrop is a separate feature for sending files to a device. Its transfers do not use LocalCast clipboard sync.

## Privacy and session behavior

Copies made before a session begins, or observed while sync is disabled, are not sent later when synchronization starts. Turning sync off cancels pending work on the next clipboard poll; late incoming completions check the setting before writing. Ending the session leaves existing clipboard content in place.

Clipboard content marked concealed, transient, or automatically generated is skipped. Password managers often use those markers; an app that omits them cannot be recognized as confidential by this engine. A newer unsupported or concealed copy also invalidates the previous outbound offer.

A slow incoming text/image transfer cannot replace a newer local copy: completion checks the current update, clipboard change count, session state, and sync setting before applying content.

Received files are staged in temporary storage. Successful ordinary file promises retain staging files until their offer is invalidated or the session ends. A crash can leave temporary directories behind; the engine does not currently sweep those at startup.

## If a paste does not work

1. Confirm LocalCast is connected and Clipboard Sync is enabled on both Macs; make a fresh copy after connecting.
2. For files or large content, confirm the session uses the host password and that TCP **5906** can reach the host.
3. Try one small regular file in a receiving app that supports file promises. Check the original still exists and the destination has no filename conflict.
4. Wait for the transfer before copying something else. New copies cancel older offers.
5. Paste again after a failed file transfer. For a missing text/image update, copy again.

Clipboard announcements are retried three times but are not acknowledged. If all attempts are lost, another copy is needed. Ordinary clipboard transfers currently have no progress or failure panel; video can continue even when the bulk channel fails. Older peers may ignore unsupported clipboard packets without a visible hint.

See [Troubleshooting](TROUBLESHOOTING.md) for connection and permission checks.

## Implementation details

`ClipboardSyncEngine` runs on the main actor and polls every **0.5 seconds**. It checks files before images and images before text, because Finder also puts filenames on the clipboard as text. Update IDs and a short-lived content digest suppress duplicates and echoes.

Announcements are sent immediately, then after 80 ms and a further 160 ms. This spreads the three attempts across network bursts. There is no cross-peer total ordering for simultaneous copies.

A newer copy invalidates the previous token, retries, transfers, and file promises. File tokens remain valid until superseded so repeated pastes and retrying a failed promise are possible. Invalid inline payloads and image headers are rejected before clearing the receiving clipboard.

The `clipboardSyncEnabled` preference is checked on each peer. The privacy exclusions are `org.nspasteboard.ConcealedType`, `org.nspasteboard.TransientType`, and `org.nspasteboard.AutoGeneratedType`. The former standalone `_tidalclip._tcp` service is no longer used; synchronization belongs to a LocalCast session.

## Protocol and security

Inline updates and bulk offers use LocalCast UDP packet type **22**, `clipboardUpdate`, on the session channel. Type **23**, `clipboardFetchRequest`, asks the viewer to push an offered token. The viewer initiates all bulk TCP connections to the host on **5906**, regardless of which Mac owns the copied content:

- **Host → viewer:** the viewer connects to fetch the host’s offer.
- **Viewer → host:** the host requests the token over UDP; the viewer connects and pushes it.

Each peer has one active bulk connection shared between incoming and outgoing work. New viewer transfers cancel the previous connection; host stop or offer invalidation cancels active host transfers. Operations have a **30-second idle timeout**, and host connections have a **160-second total lifetime limit**. Listener failures retry with bounded backoff.

A bulk frame contains a four-byte big-endian length followed by sealed bytes. Frame types are hello, hello acknowledgment, chunk, trailer, and done. Chunks carry a monotonic sequence and at most **256 KiB** of content. Empty chunks, oversized frames, invalid manifests, and overflowing file totals are rejected. The manifest must match the announced kind, size, and file names/sizes.

Password-protected UDP uses the session AES-GCM key. Bulk derives a separate HKDF-SHA256 subkey with info `LocalCast-Clipboard-v1`. Keyed receivers reject plaintext frames, including hello. The host accepts pushes only for a requested 32-byte token. Peer address is a soft check; possession of the key authenticates a keyed connection across interfaces.

AES-GCM authenticates each bulk frame, chunk sequences enforce transfer order, and a SHA-256 trailer verifies received content before file promises deliver bytes. The protocol reuses the clipboard session subkey and does not cryptographically bind every frame to its transfer token or provide complete replay defense. Per-transfer keys or authenticated transfer identifiers/nonces would be needed for those stronger guarantees.

UDP fragmentation headers sit outside the encrypted packet, so authentication happens after reassembly. Bounded buffering limits allocation, but an unauthenticated sender can still disrupt reassembly.

File names must be a final path component. Hidden names, NUL, backslashes, and overlong components are rejected or sanitized before exposure through a file promise. Verified files stream through temporary storage. Image dimension checks bound decoding, though an accepted large image can still use substantial memory when AppKit creates its TIFF representation.

## Developer verification

Implementation lives in [LocalCast/Clipboard](../TidalDrift/LocalCast/Clipboard), with session integration in [HostSession+Clipboard.swift](../TidalDrift/LocalCast/Host/HostSession+Clipboard.swift) and [ClientSession.swift](../TidalDrift/LocalCast/Client/ClientSession.swift).

The Swift package tests use private named pasteboards, never the general clipboard. They need access to the macOS pasteboard service, which can be unavailable in a restricted test environment. Coverage includes format round trips, privacy markers, malformed offers, stale completions, disable/re-enable behavior, empty files, transfer limits, manifest checks, encryption/tamper rejection, and filename sanitization. The in-app test suite also includes a bulk TCP loopback transfer.

For a focused run from the repository root:

```sh
cd TidalDrift
swift test --filter Clipboard
```

Before shipping clipboard changes, test both directions on two Macs:

1. Plain text, RTF/HTML, screenshots, empty files, and multiple files; verify exact contents after paste.
2. Exactly-at-limit and over-limit content, folders, destination collisions, and unreadable or changed source files.
3. Repeated paste, cancelled/failed bulk connections, and retry; verify ordinary file bytes move only on paste and dropped files move immediately.
4. Copy B while A downloads; disable sync or disconnect mid-transfer. Confirm A never replaces B or writes after teardown.
5. Reconnect, sleep/wake, and dropped announcements, including deliberate loss of all three retries.
6. An older peer, authentication disabled, and a loopback session; verify the documented capability boundaries.

[LocalCast guide](LOCALCAST.md) · [Documentation index](README.md)
