# Bonjour Discovery Reliability

**Updated:** 2026-09-07
**Scope:** Discovery lifecycle, connection resolution, settings, and historical peer-advertisement fixes.
**Status:** Targeted reliability fixes implemented. Native discovery migration and two-Mac recovery qualification remain open.

## Current behavior and engineering review

TCP services use `NWBrowser`. LocalCast UDP browsing and peer registration
still use `dns-sd` subprocesses. Bonjour advertisements and TXT records are
discovery hints, not authenticated device identities. Credentials and stream
authorization must be verified by the connection protocol.

The September review addressed these failure modes:

- Starting periodic discovery cancelled its network-path monitor and never
  restored it. Starting browsing now creates a monitor when needed, including
  after a full stop. An initial offline path followed by connectivity is handled.
- Deferred restart callbacks could restart obsolete browsers or launch an
  untracked LocalCast browse after stopping. TCP retries check the exact browser
  instance, and delayed browse starts check the current lifecycle generation.
- DNS timeout tasks cancelled a task group whose lookup continuation could
  never cancel. The group therefore waited for `getaddrinfo` anyway. A
  cancellation-aware callback result now releases the waiter at its deadline.
  The operating-system DNS call can finish later on the existing resolver
  queue; its result is discarded. TCP probes also release their waiters and
  cancel their connection when the caller cancels.
- SMB, AFP, and SSH discovery overwrote the device's VNC port. Screen Sharing
  keeps its own destination port regardless of the arrival order of other
  services. Invalid ports are rejected before integer conversion or connection
  creation.
- `ip=` TXT values were accepted after a loose numeric prefix match. Discovery
  now validates the complete address and rejects unspecified, loopback, and
  IPv4 broadcast destinations. This validation does not authenticate a peer.
- A deferred startup subnet scan could run after discovery stopped, or scan an
  assumed `192.168.1.*` network while offline. It is now cancelled on stop and
  requires an actual local IPv4 address. Cancelling a scan preserves devices
  that have not been probed yet.
- LocalCast name matching accepted substrings, so a short instance name could
  mark a different Mac as a host. Only complete normalized names now match;
  multiple matching devices require address resolution before any update.
- Pipe reads can split lines and UTF-8 characters. LocalCast browsing now buffers
  complete lines, discards lines over 16 KiB, and resumes parsing at the next
  newline. An incomplete line cannot be mistaken for a complete service name.
- Generic Bonjour services do not repeatedly announce an unchanged service.
  Cleanup now refreshes non-peer devices still present in live browser results
  before applying the age threshold.
- The GitHub release bundle omitted `_tidaldrift-cast._udp` from
  `NSBonjourServices`. Its generated list now agrees with `Info.plist` and the
  local build scripts, so release packaging declares the same discovery types.

## Settings contract

Bonjour updates continuously. **Device cleanup interval** controls stale-cache
maintenance, between 15 seconds and 5 minutes. It does not cause repeated
subnet scans. Changing this setting updates the running timer. SSH discovery
controls both Bonjour SSH browsing and active SSH probes; disabling it removes
the SSH capability from cached devices. The inactive automatic-connection
control has been removed from Settings because no automatic connection policy
is implemented.

Settings files from older versions retain their saved values when newer fields
are absent. Unknown themes fall back to the system theme. Out-of-range cleanup
intervals, Wake-on-LAN ports, and retry counts revert to safe defaults. Wrong
JSON types still reject the file. Resetting the received-files folder clears
both its path and its security-scoped bookmark.

`DiscoverySettingsTests` covers settings migration, round trips, invalid values,
folder reset, VNC port preservation, TXT validation, exact name matching, and
fragmented or oversized helper output.
`ConnectionResolverTests` uses a deliberately blocked lookup to verify deadline
and cancellation behavior without depending on live DNS, and checks invalid
connection inputs and IPv6 VNC URL construction.

## Remaining qualification

Automated tests do not establish real-network discovery performance. Before a
release, verify two Macs through Wi-Fi to Ethernet changes, DHCP renewal,
offline launch followed by connectivity, sleep/wake, mDNSResponder restart,
and stop/start cycles. Check that one browser exists per enabled service and
that stopped discovery leaves no LocalCast browse child running.

The following limitations remain:

- The hostname lookup and subnet scan paths still favor IPv4. IPv6 URL support
  alone does not establish end-to-end IPv6 discovery or link-local scope support.
- Subnet discovery assumes a `/24` range. It does not yet derive the scan range
  from the selected interface's netmask, and multi-interface address selection
  needs dedicated tests.
- Generic Bonjour fallback resolution still derives some hostnames from service
  display names and assumes a default port in the subprocess fallback. Native
  service-endpoint resolution should preserve the actual target host and port.
- Discovery still has mixed queue ownership. A native migration must include
  cancellation, interface scope, removal, and identity regression tests.

---

## Symptom

Discovery of other Macs over Bonjour was unreliable: sometimes a Mac appeared
in the Nearby Devices list within a second or two, sometimes it took ~10s, and
sometimes it did not appear at all until an app restart or network change.

## How advertising works

TidalDrift advertises two Bonjour services by forking `dns-sd` helper
processes (there is no native `NWListener`/`NetService` advertising; the
`listener`/`netService` fields in `TidalDriftPeerService` are vestigial):

| Service | Type | Port | Owner |
|---|---|---|---|
| Peer beacon | `_tidaldrift._tcp` | 5959 | `TidalDriftPeerService.launchAdvertiseProcess` |
| LocalCast host | `_tidaldrift-cast._udp` | 5904 | `LocalCastService.advertiseLocalCast` |

A `dns-sd -R` registration lives only as long as its helper process *and*
mDNSResponder's acceptance of it. The TXT record carries `ip=<localIP>`, which
the discovery side uses as a fast path (resolve the IP directly from the TXT
instead of the slower `dns-sd -L` -> `dns-sd -G` hostname chain).

## Root causes

1. **Registration success was never verified.** The helper's stdout went to
   `/dev/null` and the 10s watchdog only checked `process.isRunning`. A helper
   that was alive but had **failed to register** with mDNSResponder (busy at
   launch, a transient error, or a name-collision rename) looked healthy
   forever and was never restarted, so the Mac stayed silently un-advertised.

2. **Stale/empty `ip=` in the TXT.** `ip=` was captured once at launch as
   `getLocalIPAddress() ?? localInfo.ipAddress`. Advertising starts ~0.3s after
   launch; if the network was not up yet, `ip=` fell back to a value captured at
   init (possibly `Unknown`). The discovery fast path then keyed on a bad IP,
   forcing the slow hostname-lookup fallback or failing outright, and it was
   never refreshed except on a network-path change.

3. **The first network-up event was swallowed.** `setupNetworkMonitor` ignores
   the first `.satisfied` path event, so the common "launched just before
   Wi-Fi came up" case never re-advertised with the now-valid IP, locking in
   the bad `ip=` from cause 2.

4. **0-10s invisibility windows + App Nap.** If the helper did die (sleep/wake,
   mDNSResponder restart), the Mac was invisible until the next 10s watchdog
   tick, and App Nap could throttle that watchdog/helper while the menu-bar
   app was backgrounded.

## Fix (Option A, shipped v1.6.7)

Hardened the peer-beacon advertiser in `TidalDriftPeerService` without changing
the architecture:

- **Confirm registration.** Parse the helper's stdout for `"registered and
  active"`; track it in `advertiseRegistered`.
- **Smarter watchdog (4s).** Restart the advertisement when the helper dies,
  when registration stays unconfirmed past a grace window, or when the local IP
  changes (which re-bakes a fresh `ip=` into the TXT). This also covers the
  swallowed-first-path-event case, since the IP-change check fires regardless of
  the path monitor.
- **Re-advertise on wake.** Observe `NSWorkspace.didWakeNotification` and
  relaunch the advertisement.
- **Suppress App Nap.** Hold a `ProcessInfo.beginActivity`
  (`.userInitiatedAllowingIdleSystemSleep`) while advertising so the watchdog
  and helper stay responsive in the background; idle system sleep is still
  allowed.

Net effect: the TXT reliably carries a current IP, so the discovery fast path
hits consistently, and a failed/dropped registration self-heals within a few
seconds instead of persisting until a restart.

## Verification

The original v1.6.7 notes recorded a successful two-Mac check. Those historical
observations are not a performance or recovery qualification of the September
changes. Host-side log signal:

```
log stream --predicate 'subsystem == "com.tidaldrift"' --level info
```

Expect `dns-sd advertising ... ip=...` on start and, on changes,
`Local IP changed ... re-advertising` / `Woke from sleep — re-advertising`.
Repeated `registration unconfirmed` lines would indicate a deeper mDNS issue.

## Follow-on fixes

### Peers aged out after ~1-2 min (v1.6.8)

`dns-sd -B` emits an Add for a service only once, and mDNS does not re-announce
existing services often. The earlier CPU pass had replaced the periodic
`refreshScan()` (which used to restart browsers and re-emit Adds) with
prune-only maintenance, so discovered peers were never re-confirmed: their
`lastSeen` aged past the 2-minute peer prune and the device dropped its
TidalDrift-peer status (red outline). Fix: `TidalDriftPeerService` re-resolves
known peers every 45s (`reconfirmTimer`); present peers stay fresh, departed
peers fail to resolve and age out. Peer prune threshold raised to 3 minutes as
a backstop alongside the Bonjour Remove event.

### 100% CPU spin on dns-sd helper EOF (v1.6.9)

A `sample` of a 99%-CPU TidalDrift pinned it to the
`com.apple.NSFileHandle.fd_monitoring` queue inside the LocalCast browse
readability handler. When a `dns-sd` helper process exits, its pipe hits EOF and
`FileHandle.availableData` returns empty, but the `readabilityHandler` stays
installed and is re-invoked immediately, forever, spinning a core. The LocalCast
browse (`startNetServiceBrowserForLocalCast`) had no watchdog, so it spun
indefinitely. Fix: every dns-sd readability handler now treats empty data as
EOF, removes itself, and the LocalCast browse relaunches after a short backoff.
This is a structural argument for Option C: the entire bug class only exists
because discovery is driven through subprocess pipes and readability handlers.

## Not yet done / follow-up (Option C)

- The **LocalCast cast advertiser** (`LocalCastService.advertiseLocalCast`) has
  the same `dns-sd -R` pattern and stale-`ip=`/unverified-registration risk. It
  was intentionally left for the native migration rather than duplicating the
  watchdog.
- **Option C:** migrate advertising and discovery to native
  `NWListener` + `NWBrowser` (with `NWTXTRecord`), retiring the `dns-sd`
  subprocesses entirely. Benefits: framework-managed registration/lifecycle
  (no stdout parsing or watchdogs), structured results (no `-B`/`-L`/`-G` chain
  or text parsing), lower footprint (no helper processes/pipes), and App
  Sandbox / Mac App Store compatibility (a sandboxed app cannot fork
  `dns-sd`). Option A was the low-risk stabilization step that de-risks this
  rewrite; behavior parity (every current capability preserved) is the success
  criterion.
