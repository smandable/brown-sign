# Brown Sign

Point your iPhone at one of those brown roadside landmark signs and instantly find out what it is — or skip the scan entirely and discover geo-tagged Wikipedia landmarks around you via the Nearby tab, including a pan-to-search map that lets you explore any stretch of road.

A fully on-device OCR + Apple Intelligence pipeline with a four-source landmark resolver (Wikipedia, NPS, Wikidata, Google Knowledge Graph), location-aware ranking, an interactive map view of every find, and a directions launcher for Google Maps, Waze, and Apple Maps.

[![Download on the App Store](https://developer.apple.com/assets/elements/badges/download-on-the-app-store.svg)](https://apps.apple.com/app/brown-sign/id000000000)

## How it works

### Scan flow (camera or typed query)

```
Camera / typed text
        │
        ▼
  Vision OCR (multi-line, sorted top-to-bottom)
        │
        ▼
  Apple Intelligence normalization
  (extract landmark name, ignore directions/distances)
        │
        ▼
┌───────┴────────┐
│ Wikipedia       │  Wikipedia
│ geosearch       │  text search
│ (within 10 km)  │  (top 15)
└───────┬────────┘
        │  merged, deduped
        ▼
  Wikidata enrichment (parallel, per candidate)
  → coordinates (P625)
  → inception year (P571)
  → instance-of type (P31)
  → heritage designation flag (P1435)
  → dissolution year (P576)
        │
        ▼
  Filter: blocklist → place-indicator whitelist
  → title-token overlap → default reject
        │
        ▼
  Sort: exact title matches first, then by distance
        │
        ▼
  Phase-2 enrichment (top candidate only):
  → Apple Intelligence summary polish
  → Apple Intelligence match score
  → Google Knowledge Graph confidence
  → Article image download + resize
        │
        ▼
  SwiftData history (deduped by canonical URL)
```

### Nearby flow (location-driven discovery)

```
User location (or panned map center)
        │
        ▼
  Wikidata SPARQL geo-spatial query
  → P1435 (heritage designation)        ── retried on 5xx via
    OR                                     `httpDataWithRetry`
    P31/P279* in landmark allowlist
  → English Wikipedia article required
        │  (up to 300 hits, server-side filtered)
        ▼
  Distance-sort (haversine) + truncate to 100
        │
   ┌────┴─────────────────────┐
   ▼                          ▼
  Wikipedia REST hydrate   Operating-institution gate
  (titles → extracts +     (parallel Wikidata claims fetch
   thumbnails)              for ambiguous-titled hits;
                            strict drops Seymour HS,
                            lenient keeps NRHP churches)
   └────┬─────────────────────┘
        ▼
  Render list / map. Tap a row or pin →
  enrich (full Wikidata + AI polish + Google KG +
  match score + image) and push the detail view.
```

## Features

- **Nearby discovery tab** — surfaces brown-sign-worthy landmarks around you, no scan required. The fetch primary is a Wikidata SPARQL query that returns only items with a heritage designation (P1435 — NRHP, state register, etc.) or a curated landmark P31 type (museum, park, monument, lighthouse, theatre building, university campus building, …) via `wdt:P31/wdt:P279*` so subclasses like "state park" or "art museum" come along automatically. List shows the closest 100 hits within 5 miles. Map supports **pan-to-search**: as you move the map center more than ~2.5 miles away from the last fetch, a new SPARQL query fires at the new location and pins accumulate. Pan across a state and you build up a dotted trail of landmarks as you go. Wikipedia summaries and thumbnails hydrate in parallel via the REST endpoints; tap a row (or pin) to enrich (full Wikidata + AI polish + Google KG + match score + image) in the background and push the standard detail view, just like a scan result. Cold-start auto-retry: if the GPS first-fix didn't land in time, the view waits 1 second and tries once more before showing the empty state. **Transient SPARQL failure** (Wikidata timeout, retry exhaustion, task cancellation) routes to a distinct `Couldn't load landmarks` state with a brand-brown "Try again" button — the empty-area copy is reserved for cases where Wikidata actually answered with zero hits.
- **Stale-while-revalidate cold-start** — the most recent Nearby fetch is cached to disk (`Caches/nearby_results_cache.json`) and rendered instantly on the next cold-start while a fresh SPARQL + hydration runs in the background. Pins from your last session show immediately; the fresh results swap in atomically when the stream finishes. Spatial invalidation drops the cached pins if your new GPS fix is more than one search radius from the cached center (you've moved cities). Combined with **progressive rendering** that hydrates and gates the closest 30 hits as a first batch before the remaining 70, and **pre-warming the GPS** at app launch via `LocationManager.warmUpIfAuthorized()` (no permission prompt — only fires when already authorized), the perceived cold-start time approaches zero on subsequent opens.
- **Chained thumbnail resolver** — articles where MediaWiki's `prop=pageimages` doesn't have an indexed lead thumbnail get patched in two more steps: REST `/page/summary/{title}` (smarter "lead image" heuristic), then if that's also empty, the first gallery-worthy image from `/page/media-list/{title}`. The media-list step catches articles like the Middletown–Portland Railroad Bridge whose only photo lives inline in the body. The bulk hydration in `wikipediaFetchPageDetailsByTitles` runs the chain in parallel for any nil-thumbnail rows so the Nearby list/map agree with what the detail-view's carousel finds.
- **Hide and restore Nearby landmarks** — swipe left on any Nearby row to tuck a place you've already explored into a SwiftData-backed Hidden Landmarks list. The bottom of the Nearby list surfaces a "Hidden landmarks (N)" entry that opens a sheet to swipe-restore individual items, restore in bulk via a custom green eye affordance in edit mode, or "Restore All" at once. The HiddenLandmark model snapshots title, summary, and article-image bytes at hide-time so the sheet renders the same rich row treatment as Nearby/History.
- **Live search filtering** — both Nearby and History have a search field under the List/Map picker. Partial-word, case-insensitive matching against the result title; the list (and map pins) shrink in real time as you type. Keyboard "Done" toolbar + scroll-to-dismiss both clear focus. Nearby's list mode shows an explicit "No results" `ContentUnavailableView` when the search narrows to zero — map mode keeps the empty map so the user can pan-search.
- **Per-row parchment card pattern** — Scan, Nearby, and History list rows all carry their own `Color("CardBackground")` via `.listRowBackground`, with the first and last rows using an `UnevenRoundedRectangle` so only the outer corners of the card are rounded. Combined with a list-level `clipShape(RoundedRectangle)` on the viewport, the parchment ends exactly at the last row (no extra below on a sparse list) AND stays rounded at the top as the first row scrolls out of view. Section-header label-and-icon HStacks (`signpost.right.fill` / `location.fill` / `clock.fill` + label) all use `.font(.subheadline.weight(.semibold))` and `.foregroundStyle(Color.accentColor)` with matching 16pt-top / 8pt-bottom padding so the three section labels read identically across tabs and the gap to the list below matches Scan's `VStack(spacing: 8)`.
- **Map view in History and Nearby** — every saved lookup and every nearby discovery drops as a brown signpost pin on a MapKit map. Tap a pin for a callout card with thumbnail, summary, and a "View details" button; tap anywhere on the card body (not the X dismiss) to open the full detail view. List/Map toggle on both tabs; History fits the camera to the bounding box of all your finds, Nearby centers on you.
- **Live camera** with tap-to-focus, auto flash, and a close button
- **On-device OCR** via Vision — multi-line output sorted top-to-bottom by bounding box, with structured line-by-line prompting so Apple Intelligence can distinguish "Wadsworth Mansion" from "2 MI"
- **On-device Apple Intelligence** via FoundationModels:
  - Cleans up noisy OCR text into a searchable landmark name
  - Polishes long Wikipedia extracts into 2–3 sentence card summaries
  - Scores whether a candidate actually matches the query (0–1 confidence)
- **Location-aware search** — Wikipedia geosearch within 10 km finds articles near you, merged with global text search. Exact title matches sort first, then by distance. "Wadsworth" near Middletown, CT returns the mansion down the road, not a city in Ohio.
- **Smart filtering** — three-pass type filter (Wikidata P31 blocklist → place-indicator whitelist → default reject) drops bands, films, food, hoaxes, people, and other non-landmarks. Title-token overlap rejects Wikipedia body-text matches ("East Haven" won't appear for "Fort Nathan Hale"). NPS fallback is also gated on title relevance.
- **Operating-institution gate (Nearby second pass)** — even after the SPARQL filter, NRHP-listed buildings can still house active institutions: Seymour High School in Connecticut has a heritage-designated building AND is a working high school, so SPARQL surfaces it via P1435. The gate strips these. **Strict tier** (schools, hospitals, fire stations, post offices, train stations) requires Wikidata P576 (closure date) — heritage designation alone is not enough. **Lenient tier** (churches) accepts P576 *or* P1435, since a recognized landmark church is typically both active and historic ("unless they are historic or a landmark"). Titles that already advertise themselves as historic ("Old Greenwich High School", "Former Hartford Hospital") skip the fetch entirely.
- **Disambiguation picker** — when a query matches multiple landmarks, all candidates are shown sorted by distance. Tap any alternative to swap the result card instantly.
- **Directions** — tap coordinates or the Directions link to open a sheet with a MapKit preview and one-tap launch into Google Maps, Waze, or Apple Maps
- **NPS fallback** for historic places without Wikipedia coverage — queries both `/parks` and `/places` (NRHP-listed sites), with article images from the NPS `images` array
- **Wikidata enrichment** — coordinates, inception year, instance-of type label, heritage-designation flag (P1435), and dissolution year (P576) for every candidate, via exact sitelinks lookup (not fuzzy search)
- **Coordinate fallback chain** — sparse Wikidata stubs (e.g. Drakes Bay Oyster Company / Q17514736) have no P625 (coordinate location), which used to leave the lookup pinless on the History map even though the Wikipedia article publishes a perfectly good coord in its lead sentence. Phase-2 enrichment now fills in nil coordinates from two cheaper sources before giving up: first MediaWiki `prop=coordinates` (some articles tag coords without a Wikidata claim), then a regex pass over the article extract that recognizes DMS (`38°04'57.3"N 122°55'55.0"W`), decimal-with-hemisphere (`38.0826° N, 122.9319° W`), and signed-pair (`38.0826, -122.9319`) formats. Structured sources first, regex last. Wikipedia-host gated so NPS extracts can't false-match. The next lookup of an existing nil-coord history row backfills it via `upsertLookup`.
- **Persistent article images** — downloaded and resized during enrichment, stored locally in SwiftData. History scrolling is instant; images never disappear from transient network failures.
- **Image carousel in the detail view** — slot 0 always reserves the primary article image: persisted JPEG bytes when available, otherwise the article-image URL rendered through `AsyncImage` while those bytes finish downloading. Additional gallery-worthy images from the Wikipedia article (`/api/rest_v1/page/media-list` filtered by Wikipedia's `showInGallery: true` flag, with SVGs and primary-thumbnail duplicates filtered out) populate slides 2..N and load lazily via `AsyncImage` only when the user swipes to them. Each slide has a fixed-frame placeholder so loading states don't shift the layout, and the carousel uses an explicit selection binding pinned to a stable id (`"primary"`) so it never drifts when extras arrive before the persistent bytes do — the Nearby flow opens the detail view before `enrichDiscoveredLandmark` has finished downloading the image, and reserving the slot up-front prevents the visible "jump" when the bytes land. Page dots only appear when there's more than one slide.
- **SwiftData history** — newest-first sort, swipe-to-delete, Delete All in edit mode, dedupe by canonical URL, push-to-detail with full raw summary. Edit mode hides the picker / search field / "Recently viewed landmarks" header and the tab bar (Mail/Notes pattern) so the user is focused on selection.
- **Selectable text** — titles and descriptions use UITextView (read-only) for full iOS text selection: tap, double-tap, drag handles, copy
- **Share sheet** — one-tap sharing of the article URL from the result card or detail view
- **Source badge links** — tap "Wikipedia" or "NPS" in the detail view to open the full article in Safari
- **UIKit text input** — the search field is a UIViewRepresentable wrapping UITextField for reliable focus, cursor placement, and text selection inside a ScrollView
- **Keyboard toolbar** — dismiss button (⌨↓) and search button (🔍) built into the text field's input accessory view
- **Graceful fallbacks** — every external call (Wikipedia, NPS, Wikidata, Google KG, Apple Intelligence, CoreLocation) fails silently to nil. The app works end-to-end even with no API keys, no location permission, and no Apple Intelligence.
- **Adaptive color palette** — four asset-catalog colors with separate light/dark values: `AccentColor` for caption text and toolbar tinting (forest green light, muted sage dark — tuned for readable contrast on each surface), `AccentButton` for filled controls (slightly more saturated so white-on-green clears WCAG AA in dark mode), `CardBackground` for list rows, the Scan recents card, and the detail-view metadata block (warm parchment light, warm dark dark), and `BrandBrown` for the signpost hero, secondary brown action buttons (View full details / Read full article / Share / View details), the Nearby map pins, the gradient wash at the top of the Scan tab, and placeholder thumbnails — replaces a scatter of inline `Color(red:green:blue:)` literals and lighter `Color.brown` references with one canonical token. Lists hide iOS's default `systemGroupedBackground` and paint `CardBackground` instead, with `.scrollContentBackground(.hidden)` so swipe-action areas inherit the same surface (no seam between sliding row and page bg). Switched lists from `.insetGrouped` to `.plain` style with explicit `listRowInsets` so row content lines up with the picker / search field above instead of double-padding.
- **Unified 12pt corner-radius language** — every card-class element across all three tabs renders at 12pt: Scan textfield + signpost hero + result card outer + alternatives panel + metadata chips + recent-finds list, Nearby + History textfields + lists + map clipShape + map-pin callout cards, primary action buttons (Snap / Look it up) and secondary action buttons (View full details / Read full article / Share). Thumbnails scale proportionally — 8pt for 56×56, 6pt for 44×44 — at the iOS-HIG sweet spot of ~14% radius:dimension. Custom `DisplayModeSegmentedPicker` replaces SwiftUI's `.pickerStyle(.segmented)` (whose inner `UISegmentedControl` ignores `.frame(height:)`) so the List/Map switcher on Nearby + History matches the textfield height below it and uses the same 12pt outer radius, with a per-trait adaptive selected-pill fill so dark mode lifts the selection instead of sinking it.
- **Focus-driven textfield strokes** — all three search fields (Scan, Nearby, History) carry a `RoundedRectangle` overlay stroke that's `Color.accentColor` lineWidth 2 when focused and `Color.secondary.opacity(0.35)` lineWidth 1 when not, with a leading magnifying-glass icon. Driven from each field's `@FocusState` so the visual state always matches keyboard ownership.

## Tech stack

| Layer | Technology |
| --- | --- |
| UI | SwiftUI + UIKit (UIViewRepresentable for text input, camera, Safari) |
| Persistence | SwiftData |
| OCR | Vision (`VNRecognizeTextRequest`) |
| Camera | AVFoundation (photo preset, tap-to-focus, auto flash) |
| On-device LLM | FoundationModels (iOS 26+) |
| Location | CoreLocation (async wrapper with in-flight guard + timeout) |
| Maps | MapKit (preview) + URL schemes (Google Maps, Waze, Apple Maps) |
| Search | Wikipedia MediaWiki API (text search, geosearch, pageimages, extracts) |
| Enrichment | Wikidata API (sitelinks entity lookup, P625/P571/P31 claims) |
| Fallback | NPS developer API (`/parks` + `/places`) |
| Confidence | Google Knowledge Graph Search API |
| Article reading | SafariServices (`SFSafariViewController`) |

No third-party Swift packages. Stock Apple frameworks only.

## Requirements

- **iOS 26+** (required for FoundationModels)
- **iPhone 15 Pro / iPhone 16 or later** for Apple Intelligence. Other iOS 26 devices still work — Apple Intelligence features fall back silently.
- **Xcode 26+**
- Physical device for camera. Simulator works for typed searches.

## Setup

1. Clone the repo and open `BrownSign/BrownSign.xcodeproj`
2. Create `BrownSign/BrownSign/APIKeys.swift` (gitignored) with:
   ```swift
   import Foundation

   let npsAPIKey = "YOUR_NPS_KEY"
   let googleKnowledgeGraphAPIKey = "YOUR_GOOGLE_KG_KEY"
   ```
   - **NPS:** free — [developer.nps.gov](https://www.nps.gov/subjects/developer/get-started.htm)
   - **Google KG:** [Google Cloud Console](https://console.cloud.google.com/) → enable Knowledge Graph Search API → create API key
   - Missing keys are handled gracefully (NPS and Google KG paths return nil)
3. Verify these Info.plist / build settings are set:
   - `NSCameraUsageDescription` — "To read brown signs and identify landmarks"
   - `NSLocationWhenInUseUsageDescription` — "To bias landmark searches toward places near you"
   - `LSApplicationQueriesSchemes` — `comgooglemaps`, `waze`
   - `ITSAppUsesNonExemptEncryption` — `NO`
4. Select your development team under Signing & Capabilities
5. Cmd-R onto a real device

## Project layout

| File | Purpose |
| --- | --- |
| `BrownSignApp.swift` | `@main`, SwiftData container (registers `LandmarkLookup` + `HiddenLandmark`), TabView (Scan / Nearby / History), root `.task` that pre-warms `LocationManager` so the Nearby tab doesn't pay GPS cold-radio first-fix latency |
| `ContentView.swift` | Scan tab — camera button, text field, result card, alternatives list, recent finds card |
| `NearMeView.swift` | Nearby tab — discovery list + map view of brown-sign-worthy landmarks within 5 miles (SPARQL-filtered, see `WikidataLandmarkSearch.swift`); stale-while-revalidate cold-start (renders the cached fetch instantly, swaps fresh results in atomically); progressive rendering of the closest 30 hits before the rest of the list; pan-to-search; swipe-to-hide; cancellation-tracked refresh task |
| `NearbyResultsCache.swift` | Disk-backed JSON snapshot of the most recent Nearby fetch in `Caches/nearby_results_cache.json`. Schema-versioned + 7-day TTL'd; `NearMeView` spatially invalidates when the user moves more than one search radius from the cached center. `nonisolated` so file IO can run off the main actor under the project's Swift 6 isolation flags |
| `HistoryView.swift` | History tab — list and map view, row, detail view (with source badge links, selectable text) |
| `HiddenLandmark.swift` | SwiftData `@Model` for landmarks the user has hidden from Nearby (keyed on canonical page URL, snapshots title/summary/article-image) |
| `HiddenLandmarksView.swift` | Modal sheet listing hidden landmarks — swipe-to-restore, custom green eye edit affordance, "Restore All" with confirmation |
| `SearchField.swift` | Shared search-field component used by Nearby and History — magnifying-glass icon, clear button, FocusState-driven keyboard "Done" toolbar |
| `CameraView.swift` | UIKit camera VC with tap-to-focus, capture button, close button |
| `SafariView.swift` | `SFSafariViewController` wrapper |
| `LandmarkTextField.swift` | UIViewRepresentable wrapping UITextField (keyboard toolbar built in) |
| `SelectableText.swift` | UIViewRepresentable wrapping read-only UITextView for text selection |
| `MapsLauncher.swift` | Directions sheet with MapKit preview + Google Maps / Waze / Apple Maps |
| `OCRHelper.swift` | Vision OCR — returns `[String]` lines sorted top-to-bottom |
| `AppleIntelligence.swift` | FoundationModels — normalize (line-aware), polish, match-score |
| `LocationManager.swift` | CoreLocation async wrapper with in-flight guard + timeout. `warmUpIfAuthorized()` is called from `BrownSignApp`'s root `.task` so the GPS first-fix is already populated by the time the user opens Nearby; no-op when authorization is `.notDetermined` so launch never pops the permission prompt |
| `WikipediaSearch.swift` | Text search, geosearch, batch extracts/pageimages by page-id or title, REST summary fallback for empty intros, **chained thumbnail resolver** (REST summary → media-list) for articles whose only photo lives inline in the body, word-boundary truncation, REST media-list lookup for the detail-view image carousel |
| `WikidataSearch.swift` | Sitelinks-based entity lookup (P625 / P571 / P31 / P1435 / P576 + label resolution) and lighter historic-signals fetch for the operating-institution gate |
| `CoordinateFallback.swift` | Backfills `LandmarkResult.coordinates` when Wikidata had no P625. Tries MediaWiki `prop=coordinates` first, then the regex parser. Wikipedia-host gated. |
| `CoordinateParser.swift` | Pure-logic regex parser for DMS / decimal / signed-pair coordinate strings in article extracts. Zero project dependencies — testable standalone via the sibling `CoordinateParserTests` Swift Package (`swift test --package-path BrownSign/CoordinateParserTests`). |
| `WikidataLandmarkSearch.swift` | SPARQL geo-spatial query against `query.wikidata.org` — primary fetch for the Nearby tab. Returns only items with a heritage designation (P1435) or a curated landmark P31 type (recursive via P279*). Returns `nil` on transport failure (HTTP retries exhausted) and `[]` only on a successful empty response, so the caller can route transient WDQS hiccups to a retryable `serviceUnavailable` UI rather than silently rendering "No landmarks nearby" |
| `HTTPRetry.swift` | Shared retry helper (`httpDataWithRetry`) — default 3 attempts with 500 ms + 1.5 s backoff, retries on 502/503/504/429 + URL errors, honors task cancellation. Used by the SPARQL fetch and the Nearby Wikipedia REST hydration |
| `NPSSearch.swift` | `/parks` + `/places` fallback with article images |
| `GoogleKnowledgeGraphSearch.swift` | External confidence scoring |
| `LandmarkResult.swift` | Two-phase scan orchestrator + Nearby orchestrator (SPARQL + Wikipedia hydration + operating-institution gate), type filter, title-match filter, place indicators |
| `LandmarkLookup.swift` | SwiftData `@Model` — history entries with all enrichment fields |
| `APIKeys.swift` | **Gitignored.** Local API keys only. |

## Privacy

Brown Sign collects no personal data. Camera images are processed on-device. Location is used only to rank nearby results. Search queries go to Wikipedia, Wikidata, NPS, and Google KG with no personal identifiers attached. No accounts, no analytics, no ads, no tracking.

Full privacy policy: [docs/privacy-policy.md](docs/privacy-policy.md)

## License

MIT
