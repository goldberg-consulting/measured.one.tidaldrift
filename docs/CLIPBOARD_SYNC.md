# Copy and paste between Macs

LocalCast shares supported clipboard content in both directions during a connected session. Copy on one Mac and paste on the other, including pasting into a remote app through the viewer.

## Turn it on

Enable **Clipboard Sync** in the TidalDrift menu on **both Macs**. The same switch is available at **Settings → General → Sync clipboard during LocalCast sessions**. It is enabled by default, and each Mac remembers its own setting.

Connect with [LocalCast](LOCALCAST.md), then make a new copy for automatic synchronization. Content copied before the session started is not sent automatically, but pressing **⌘V in the viewer** explicitly sends the current clipboard. A session viewing the same Mac disables synchronization because both sides share one clipboard.

Install the updated build on **both Macs** for synchronized viewer Paste and file drops at a remote destination. An older host cannot perform these actions; the viewer requests an upgrade or refuses the unsupported drop.

For files and large content, use a password-protected session. With authentication disabled, only small inline content can sync; it travels without session encryption.

## What you can copy

- **Text:** plain text, rich text (RTF), and HTML. Available representations travel together so the receiving app can choose a suitable format.
- **Images:** supported clipboard images are converted for transfer. Application-specific image formats are not copied verbatim.
- **Regular files:** copy one or more files, then paste into an app that accepts files. Ordinary background sync uses macOS file promises; explicit viewer Paste transfers the files first and supplies local file URLs on the host. Empty files are supported.

The limit is **100 MiB for the complete transfer** and **64 regular files**. The inline message limit is **32 KiB after encoding**, including base64 overhead; larger text/images and all files use the authenticated bulk channel. Images above **64 Mi pixels** are rejected before decoding.

Folders, application bundles, resource forks, extended attributes, file permissions, and arbitrary application-specific clipboard types are not transferred. A transfer preserves file contents, not a complete macOS filesystem object.

## Paste into the remote app

With **Remote Control** enabled and Stream Controls closed, focus the destination in the viewer and press **⌘V**. The viewer sends the current clipboard together with the Paste request, including content copied before connecting. The host verifies and applies the content before sending Paste to the app. Files transfer immediately for this action, so the app receives actual host file URLs rather than an unresolved file promise.

The host snapshots the active app, window, and focused control when the request arrives. If that focus changes during transfer, Paste is cancelled instead of being sent to the new destination. Select the intended destination and paste again. Clipboard Sync must remain enabled, and the host needs Accessibility permission.

The viewer reports progress and the host's success or failure result. **Clipboard ready; Paste sent to the remote app** confirms delivery to the host clipboard and dispatch of the command. The receiving app still decides whether it accepts that content.

**⌘C** and **⌘X** while controlling the viewer act on the host. A following **⌘V** uses the host's copy, even before clipboard polling has brought it back to the viewer. A new copy made in a local app makes the next viewer Paste use that local content. With remote control released or Stream Controls open, keyboard input stays local.

## Paste files outside the viewer

Automatic background synchronization sends an offer with file names and sizes. File bytes transfer when the receiving app requests them on paste, using macOS file promises. This still applies when pasting host files into a local Finder window. Keep the source files readable and unchanged in size until the paste finishes.

The receiving app chooses the destination. TidalDrift verifies the received bytes before delivering them and does not overwrite an existing destination file; an unresolved name collision fails the paste. Different receiving apps handle file promises and destination naming differently.

You can paste the same offered files more than once. If a transfer fails, paste again while the offer is still current. Copying newer content invalidates the old offer and its unfinished transfers.

## Drop content onto the viewer

Drop regular files onto an **open Finder folder in the streamed image** to save them there. The host resolves the folder at that location before downloading, then copies the verified files into that captured destination. For app/window streams, the shared window must be uncovered at the drop point on the host; a covering window causes rejection rather than receiving the files. Switching to another window during transfer does not redirect the files. A moved or replaced destination fails delivery. Existing files are never overwritten; collisions receive a numbered name such as `report (1).pdf`.

File drops transfer immediately and report **Delivered N files to the drop destination** only after saving succeeds. A failure reports the reason and, if applicable, how many files were saved before it stopped. This is folder delivery, not arbitrary application drag-and-drop: the Desktop, app windows, package icons, search views, and other unresolved targets are unsupported. Drop onto visible video, not the letterbox bars or local controls.

Dropped text and images still offer content to the **host's clipboard**. Paste into the desired remote app after it arrives; the offer message does not acknowledge completion. Drops do not replace the viewer Mac's clipboard.

All viewer drops require a password-protected session, Clipboard Sync on both Macs, and compatible builds. File delivery also requires host Accessibility permission. Folders, symbolic links, and file promises are unsupported drop sources; the same size/count limits apply. A newer copy or disabling sync can cancel a pending transfer. Once verified files are being saved, delivery keeps the captured destination and does not roll back files already saved.

TidalDrop is a separate feature for sending files to a device. Its transfers do not use LocalCast clipboard sync.

## Privacy and session behavior

Copies made before a session begins, or observed while sync is disabled, are not sent automatically when synchronization starts. Explicit viewer Paste is a request to send the current supported clipboard. Privacy markers still apply. Turning sync off cancels pending work on the next clipboard poll; late incoming completions check the setting before writing. Disconnecting or reauthenticating cancels pending clipboard actions, so reconnect and request Paste or drop again. Ending the session leaves existing clipboard content in place.

Clipboard content marked concealed, transient, or automatically generated is skipped. Password managers often use those markers; an app that omits them cannot be recognized as confidential by this engine. A newer unsupported or concealed copy also invalidates the previous outbound offer.

A slow incoming text/image transfer cannot replace a newer local copy: completion checks the current update, clipboard change count, session state, and sync setting before applying content.

Received files are staged in temporary storage. Successful ordinary file promises retain staging files until their offer is invalidated or the session ends. A crash can leave temporary directories behind; the engine does not currently sweep those at startup.

## If a paste does not work

1. Confirm both Macs have the updated build, LocalCast is connected, Clipboard Sync is enabled, and Remote Control is active in the viewer. For automatic sync outside the viewer, make a fresh copy after connecting.
2. For files or large content, confirm the session uses the host password and that TCP **5906** can reach the host.
3. Try one small regular file. For background sync, use a receiving app that supports file promises. For a viewer drop, use an open Finder folder and grant host Accessibility. Check the original still exists.
4. Wait for the transfer before copying something else. New copies cancel older offers.
5. Read the viewer's result. After an unconfirmed action, inspect the remote destination before retrying; the operation may have completed while its acknowledgment was lost. For a missing automatic text/image update, copy again.

Automatic clipboard announcements are sent three times without acknowledgment. If all attempts are lost, another copy is needed. Explicit Paste and targeted file drops retry with the same action ID for about three minutes while awaiting the host's result. Automatic background transfers still have no progress or failure panel; video can continue even when the bulk channel fails.

See [Troubleshooting](TROUBLESHOOTING.md) for connection and permission checks.

## Implementation details

`ClipboardSyncEngine` runs on the main actor and polls every **0.5 seconds**. It checks files before images and images before text, because Finder also puts filenames on the clipboard as text. Update IDs and a short-lived content digest suppress duplicates and echoes.

Background announcements are sent immediately, then after 80 ms and a further 160 ms. Explicit actions continue with bounded backoff while awaiting a result. Retries retain the same update ID so a completed action can return its cached result without running again. Cache retention is bounded to 64 results.

Each updated sender includes a `senderID` for its engine lifetime and a monotonically increasing `revision`. The receiver rejects obsolete revisions and retired sender IDs, preventing delayed announcements from replacing newer content. This orders one sender's updates; it does not establish a cross-peer total order for simultaneous copies.

A newer copy invalidates the previous token, retries, transfers, and file promises. File tokens remain valid until superseded so repeated pastes and retrying a failed promise are possible. Invalid inline payloads and image headers are rejected before clearing the receiving clipboard.

The `clipboardSyncEnabled` preference is checked on each peer. The privacy exclusions are `org.nspasteboard.ConcealedType`, `org.nspasteboard.TransientType`, and `org.nspasteboard.AutoGeneratedType`. The former standalone `_tidalclip._tcp` service is no longer used; synchronization belongs to a LocalCast session.

## Protocol and security

Inline updates and bulk offers use LocalCast UDP packet type **22**, `clipboardUpdate`, on the session channel. Explicit Paste carries its modifiers in that update; targeted file drops carry coordinates normalized to the streamed image. Type **23**, `clipboardFetchRequest`, asks the viewer to push an offered token. Type **24**, `clipboardActionResult`, returns an explicit action's ID, success flag, and status message. The viewer initiates all bulk TCP connections to the host on **5906**, regardless of which Mac owns the copied content:

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

The Swift package tests use private named pasteboards, never the general clipboard. They need access to the macOS pasteboard service, which can be unavailable in a restricted test environment. Coverage includes format round trips, privacy markers, malformed offers, stale completions, action ordering, focus validation, destination selection, collision handling, disable/re-enable behavior, empty files, transfer limits, manifest checks, encryption/tamper rejection, and filename sanitization. The in-app test suite also includes a bulk TCP loopback transfer.

For a focused run from the repository root:

```sh
cd TidalDrift
swift test --filter Clipboard
```

Before shipping clipboard changes, run these checks on two Macs with the same build, a password-protected session, Clipboard Sync enabled, and host Accessibility granted. These are required manual regressions, not a record of completed hardware validation:

1. Copy text before connecting, then focus a host text field and immediately press ⌘V. Repeat with RTF/HTML, a screenshot, an empty file, and multiple files into remote Finder. Check content and confirm each physical key press pastes once, including a held V key.
2. Select text in a remote app, press ⌘C then ⌘V immediately, and verify the remote copy wins. Copy different text in a local app and repeat viewer Paste. Repeat with viewer Accessibility disabled to exercise the keyboard fallback; check local copy/paste with Stream Controls open and Remote Control released.
3. Paste host files into local Finder using background sync, then paste them again. Verify bytes transfer on paste and a failed promise can be retried while its offer remains current.
4. Drop files into two different open remote Finder folders, including an empty file and duplicate names. Verify the folder under the drop point receives the files without overwriting existing content. Repeat in full-display, app, and window capture with scaling or letterboxing. Drops on Desktop, other apps, packages, search views, folders as sources, and letterbox bars must not save files elsewhere.
5. Cover a streamed Finder window with another Finder window on the host before dropping: the drop must fail without saving into the covering window. During a slowed accepted drop, focus another Finder window: delivery must retain the original folder. Move or replace that destination during transfer and check the failure. During a slowed Paste, change the host app, window, or focused field: no Paste command should reach the new focus.
6. Copy B while A downloads, disable sync, disconnect, and force reauthentication in separate runs. Confirm obsolete content cannot replace B or dispatch a delayed Paste after recovery. Inspect the destination for any files saved before a drop failed; partial results must match the receipt.
7. Drop or delay announcements and receipts. A retry with the same action ID must not duplicate delivery or Paste; after an unconfirmed result, inspect the destination before manually retrying. Check exactly-at-limit and over-limit content, 64 and 65 files, unreadable sources, and changed source sizes.
8. Use an older host, authentication disabled, and a loopback session. Confirm unsupported Paste/drop actions are rejected or identify the required upgrade, files cannot transfer without a password, and loopback sync stays disabled. Test text/image drops separately: they offer clipboard content and do not insert it automatically.

[LocalCast guide](LOCALCAST.md) · [Documentation index](README.md)
