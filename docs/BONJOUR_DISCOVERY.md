# Bonjour Discovery Reliability

**Date:** 2026-06
**Scope:** Why TidalDrift peer discovery was intermittently slow/absent, and the fix shipped in v1.6.7.
**Status:** Resolved (Option A). Native rewrite (Option C) planned as a follow-up.

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

Confirmed in real two-Mac use: discovery is fast and consistent, survives
Wi-Fi/Ethernet switches and sleep/wake. Host-side log signal:

```
log stream --predicate 'subsystem == "com.tidaldrift"' --level info
```

Expect `dns-sd advertising ... ip=...` on start and, on changes,
`Local IP changed ... re-advertising` / `Woke from sleep — re-advertising`.
Repeated `registration unconfirmed` lines would indicate a deeper mDNS issue.

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
