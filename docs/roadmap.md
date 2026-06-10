# Brown Sign — feature roadmap

Saved from the 2026-06-10 deep review's competitor and platform research
(ranked by two product-judge passes; full reasoning in
`docs/investigations/2026-06-10-deep-review-3-findings.md`). Sean chose
the launcher bundle as the next release and asked for the rest to be
kept here for future releases.

## Next up: 1.9.0 — the "launcher bundle" + LookAround

One tab-selection/deep-link refactor, amortized across every launcher
surface at once:

- **App Shortcuts + Siri phrases** ("Scan a sign", "Landmarks near me")
  via `AppShortcutsProvider` — lights up Siri, Spotlight actions, and
  the Shortcuts app.
- **Control Center / Lock Screen / Action button control** — a
  `ControlWidgetButton` that launches straight into the scan camera.
  Serves the app's most time-critical moment: the sign sliding past.
  Note: needs the app's first widget-extension target.
- **Home Screen quick actions** — "Scan a sign" and "Nearby" on the
  app-icon long-press (static `UIApplicationShortcutItems`).
- **LookAroundPreview** in `LandmarkDetailView` — street-level view of
  the landmark, answering "is this worth pulling off for". Under a day,
  no entitlement; degrades gracefully where Look Around has no coverage.

## Saved for later releases (in recommended order)

1. **Visual Intelligence integration** — iOS 26 App Intents
   (`IntentValueQuery` receiving a `SemanticContentDescriptor`) lets
   Brown Sign answer inside the system point-the-camera-at-it UI. A
   premise-level match for this app and free discovery; builds directly
   on the 1.9.0 App Intents plumbing.
2. **Geocoded area search** — type "Moab" instead of panning there:
   `MKLocalSearch` the place name, then drive the existing
   area-anchored fetch/list machinery (built in 1.7.0, hardened in
   1.8.0) at the geocoded center. Turns Nearby into a trip-planning
   tool.
3. **Offline "save this area" packs** — pre-download a region's
   landmarks (and thumbnails) for no-signal country; the category's
   table-stakes road-trip feature (Merlin, onX, and Autio all solve
   it). Largest scope; deserves its own release and a design pass
   (storage model, pack management UI, staleness).
4. **Good-tier backlog** (small/medium, slot in opportunistically):
   - **"Your finds" stats card** — Been-style aggregation over existing
     History data (counts by type, year span, states visited), no new
     user action required.
   - **Live OCR hints in the viewfinder** — a throttled on-device
     Vision pass showing detected sign text before the shutter press
     (Seek/Lens-style feedback; frames never leave the device).
   - **SPARQL-level category filters** on Nearby — filter the VALUES
     allowlist server-side (parks vs museums vs bridges), so filtering
     makes fetches faster, not slower.
   - **Spotlight indexing of finds** — donate saved lookups via
     `IndexedEntity` so "Wadsworth Mansion" in system search reopens
     the saved detail view.
   - **TipKit** for the three least-discoverable interactions: the
     follow-the-map list header chip, swipe-to-hide, and camera
     pinch-zoom.

## Robustness backlog (from review 3, unscheduled)

Camera session interruption/runtime-error observers (dead preview after
a media-services reset); SwiftData container open guarded by do-catch
(migration crash-loop); `backfillSummaryIfNeeded` in-flight guard; stale
`selectCandidate` date-bump; thumbnail NSCache cost limit; Nearby cache
write debounce; rounding coordinates before sending to Wikimedia;
delimiting untrusted text in on-device LLM prompts.

## Explicitly rejected (don't re-propose)

Badges/gamification, watchOS companion, road-trip Live Activity,
CarPlay driving-task category (the one-category rule would foreclose a
future CarPlay audio mode), App Clips (needs a share domain the app
deliberately doesn't have), Apple place cards on the Nearby map (cuts
against the curated brown-sign layer).
