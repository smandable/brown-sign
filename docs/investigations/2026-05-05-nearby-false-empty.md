# Nearby false-empty — investigation log

**Date:** 2026-05-05
**Versions:** found in 1.4.3 (build 18), fixed in 1.4.4 (build 19)
**Reporter:** Sean
**Fix commit:** `be7e58a` ("Fix Nearby false-empty: distinguish SPARQL transport failure from empty area")
**Investigation branch:** `diagnostics/nearby-empty` (kept for reference, not merged)

## Symptom

The Nearby tab intermittently rendered "No landmarks nearby" in areas that
demonstrably contain landmarks. Refreshing did not help. Toggling Location
Services off and on did not help. The bug surfaced multiple times in a single
afternoon at the same coordinates (`41.544, -72.677` — Middletown, CT —
where SPARQL routinely returns 50+ hits).

## Root cause

`discoverLandmarksViaSPARQL` returned `[]` indistinguishably for three
distinct conditions:

1. The endpoint successfully answered with zero hits — area is genuinely empty.
2. The endpoint timed out (`URLError.timedOut`) and `httpDataWithRetry`
   exhausted its retry budget.
3. The in-flight `Task` was cancelled (e.g. by a sibling refresh trigger),
   propagating into `URLSession.data(for:)` as `URLError.cancelled`.

The consumer in `NearMeView.refresh` then mapped any empty result to
`state = .empty`, which renders the "No landmarks nearby" copy. So a
transient WDQS hiccup or a benign cancellation would surface to the user
as a definitive claim that no landmarks exist in the area, with no retry
affordance.

The 8-second per-attempt timeout (× 2 attempts = 16 s ceiling) was also
too tight for the `wikibase:around` query branch under realistic WDQS load
— the radius branch would routinely take 8–12 s and fall off the timeout
ceiling, producing the failure case at non-trivial rates rather than only
during full Wikidata outages.

## Fix shape

Five files. ~150 lines net. No new dependencies.

1. **`WikidataLandmarkSearch.swift`** — `discoverLandmarksViaSPARQL` now
   returns `[WikidataLandmarkHit]?`. `nil` means transport failure (HTTP
   retries exhausted, URL/encoding error). `[]` is reserved for "endpoint
   answered with zero hits". Per-attempt timeout 8 s → 12 s. Attempts
   2 → 3.

2. **`LandmarkResult.swift`** — new `NearbyStreamYield` enum
   (`.batch([LandmarkResult])` | `.sparqlFailed`). `discoverLandmarksAt`
   yields `.sparqlFailed` when the upstream returns nil. The stream
   shape became richer; both consumers in `NearMeView` updated.

3. **`NearMeView.swift`** —
   - New `.serviceUnavailable` state with a `ContentUnavailableView`
     ("Couldn't load landmarks" / "wifi.exclamationmark" / brand-brown
     "Try again" button calling `startRefresh(force: true)`).
   - The cold-start/refresh consumer tracks `sparqlFailed` during the
     stream and routes to `.serviceUnavailable` instead of `.empty` when
     SPARQL didn't deliver.
   - Failure path skips `lastFetchCenter` updates, the `recenterSignal`
     bump, and `NearbyResultsCache.save` — a failed fetch shouldn't
     overwrite the last successful cache with empty results.
   - When existing pins are already shown, refresh failure is silent
     (`hasResults` check). The failure UI only appears when there are
     no pins to keep — don't blow away the user's view.
   - `Task.isCancelled` check after `currentLocation` so cancelled
     refresh Tasks exit before `discoverLandmarksAt`.
   - Pan-fetch (`fetchAroundMapCenter`) skips when `isReloading` (primary
     refresh in flight) or `lastFetchCenter` is nil (cold-start /
     mid-refresh nil-out window).
   - GPS-fix timeout 5 s → 12 s; `bypassCache: force` plumbed through.

4. **`LocationManager.swift`** — clear `lastLocation` on any
   `authorizationStatus` transition (off→on Location Services routes
   through `.denied`, so a pre-toggle GPS fix was surviving the 5-min
   cache TTL and refresh became a no-op against the GPS). Add
   `bypassCache: Bool = false` to `currentLocation(withTimeout:)`.

5. **`BrownSignApp.swift`** — `TabView` switched from legacy
   `.tabItem`-modifier syntax to the iOS 18+ explicit `Tab(...) { ... }`
   declarative form. (Modern API; was attempted as a fix for the open
   mystery below — didn't help, but kept since it's the right API.)

## Triage that produced this fix

In rough order, the Console.app log evidence collected on device
(`subsystem:com.seanmandable.brownsign`):

1. First repro showed `query.wikidata.org error=cancelled attempt=1/2`
   followed by `SPARQL returned 0 hits`. The empty result was a
   cancellation propagated as zero hits.
2. Second repro showed `query.wikidata.org error=The request timed out.
   attempt=1/2 ... attempt=2/2 ... retries exhausted after 2 attempts`
   followed by `SPARQL returned 0 hits`. Real timeout, also collapsed
   to zero.
3. The Wikipedia REST hydration was always healthy
   (`hydrate drops noDetails=0` on every successful fetch). The
   strongest hypothesis going in (Wikipedia REST silently failing) was
   wrong — confirmed empirically before writing any fix.

The triage logging itself (per-hit drop counts in `hydrateAndGateBatch`,
HTTP host/status/attempt logging in `httpDataWithRetry`, location
auth/error logging) is preserved on `diagnostics/nearby-empty` and can
be re-applied if a similar issue surfaces again.

## Open mystery

The investigation also surfaced a SwiftUI / Swift Concurrency oddity in
this iOS 26 + NavigationStack + TabView configuration that I could not
explain or work around at any layer:

- `.task` and `.onAppear` on `NearMeView` fire **three times** on cold
  start, on the **same instance** (proven via per-instance UUID
  logging — same `instanceID` across all three firings).
- Three resulting `startRefresh` calls on that same instance all logged
  `Task.isCancelled = false`, even though each was supposed to cancel
  its predecessor via `refreshTask?.cancel()`.
- Attempting to deduplicate at `startRefresh` failed for **every**
  synchronization primitive tried:
  - `@State` Bool/Date debounce — three concurrent reads all saw the
    pre-write value
  - `@MainActor` singleton class — same
  - `NSLock`-guarded class — same
  - `OSAllocatedUnfairLock` at file scope — same
  - Swift `actor` with `await dedupOrFire(...)` — same
- Diagnostic logging inside the `withLock` closure showed three
  concurrent callers all entering with `count=0`, all exiting with
  `count=1`, on what should be a single shared dictionary. Each call
  saw its own initial state. This violates the documented contract of
  every primitive tried.

The fix sidestepped this by **not depending on dedup**: the stream
consumer correctly handles the duplicate output (each refresh writes
the same final state), and the false-empty bug is fixed regardless of
how many times `refresh` runs. The remaining triple-fire is wasteful
(3× Wikidata bandwidth, 3× battery on the cold-start fetch) but
user-invisible.

If a future iOS update changes this behavior, dedup at the SPARQL
fetch level (in-flight `Task` keyed on `centerLat|centerLon|radiusKm`)
would cleanly halve cold-start Wikidata load and reduce 429/timeout
amplification. The `diagnostics/nearby-empty` branch has a working
implementation (`SparqlDeduplicator` actor in
`WikidataLandmarkSearch.swift`) ready to drop in.

If repro is needed:

- Force-quit Brown Sign and relaunch with Console.app filtering
  `subsystem:com.seanmandable.brownsign category:NearMe` (after
  re-applying the entry-point logging from `diagnostics/nearby-empty`).
- Three `NearMeView onAppear` lines and three `refresh entered` lines
  per cold start, all sharing the same `instance=...` UUID, is the
  signature.
- Reproduced consistently on iPhone 16 Pro running iOS 26.x. Not yet
  tested on simulator or other devices.

## Update 2026-05-11: open mystery retracted

The "multi-fire `.task` / 3× Wikidata bandwidth" claim above was a
misreading. Re-instrumented shipping main on the same iPhone 16 Pro,
same iOS 26.4.2 build `23E261`, same Xcode 26.4.1 — no toolchain change
since this doc was written — with a fresh probe (`diag/sparql-fire-count`,
not merged) logging `.onAppear`, `refresh` entry, the `discoverLandmarksAt`
call site, and every `httpDataWithRetry` attempt with attempt#/outcome.
Every test scenario (cold-launch → tap Nearby, manual refresh button,
pull-to-refresh) consistently shows **1 `onAppear`, 1 `refresh ENTRY`,
1 `query.wikidata.org` HTTP attempt with success-200**.

Re-adding the diagnostics-branch `.onAppear { isReloading = true }`
on top of that probe did **not** bring back the multi-fire — so the
diagnostic instrumentation itself wasn't the cause either.

What was originally observed and misinterpreted: after the single
SPARQL succeeds, `discoverLandmarksAt` hydrates each landmark with a
Wikipedia REST request, producing a burst of ~15-17 simultaneous
`en.wikipedia.org` HTTP calls in ~400 ms. In Xcode's network inspector
or a busy Console.app filter, that fan-out reads exactly like "the
same request firing multiple times". It isn't — it's N parallel
hydrations of distinct landmarks, working as designed.

Implications:

- **No multi-fire bug.** The "3× Wikidata bandwidth" claim is wrong.
  Shipping main has been doing 1 SPARQL + N hydrations per refresh
  all along — correct behavior.
- **No iOS / Swift Concurrency mystery.** Every primitive (locks,
  actors, `@State`, MainActor) was working correctly during the
  original investigation. The diagnostic logs that "proved"
  serialization failure were either reading the hydration burst or
  had a measurement bug we never identified.
- **No "if Apple fixes the underlying issue" path needed.** The
  `SparqlDeduplicator` actor sitting on `diagnostics/nearby-empty`
  is a fix for a problem that doesn't exist; don't land it.

The cancellation gate (`if Task.isCancelled { return }` after
`currentLocation`, in [BrownSign/BrownSign/NearMeView.swift](../../BrownSign/BrownSign/NearMeView.swift))
is still load-bearing — when a user pull-to-refreshes during an
in-flight cold-start, it does cancel the cold-start's HTTP request
mid-flight (observed in the same probe as
`outcome=error-cancelled`). That part of the fix is real.

## Lessons

- **Distinguish failure modes at the API boundary.** A function that
  returns `[]` for "empty result" and "transport failure" forces every
  caller to choose one interpretation. The `Optional<Array>` return
  shape (`nil` = failed, `[] ` = empty) is a one-character change that
  preserves the fast path while making the failure case representable
  upstream.
- **Trust the OS Logger output, not the App Store-Connect report.**
  The first hypothesis (Wikipedia REST silently dropping hits) had
  strong "shape" evidence but turned out to be wrong on the actual
  device. Sean's logs killed it in 30 seconds — earlier instrumentation
  would have saved an investigation-day.
- **Cooperative cancellation is not silent cancellation.** A Task
  cancelled mid-`URLSession.data` does not return early on its own;
  the call propagates as `URLError.cancelled` and looks identical to a
  network timeout to anything that doesn't check `Task.isCancelled`
  explicitly. Add cancellation checks at every async boundary, not
  just at the top of long-running loops.
- **When debugging a SwiftUI lifecycle quirk, instrument first.**
  Trying to fix multi-fire `.task` with cancellation, then debounce,
  then locks burned ~5 build-install-test cycles before the
  per-instance UUID instrumentation revealed the actual shape (one
  instance, multiple firings, locks not serializing). The diagnostic
  cost up-front would have been one cycle.
- **Count what you actually observe, not what you assume you're
  observing.** The 2026-05-11 retraction above happened because the
  fan-out of parallel landmark-hydration requests looked identical
  in the network inspector to the multi-fire pattern we were
  hunting. Before declaring "every primitive in Swift Concurrency
  is broken", instrument with a *labelled* counter at the layer
  where you think the bug lives (per-call attempt-number outcome
  log, in our case) rather than eyeballing the request stream.
