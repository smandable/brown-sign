# Brown Sign

Point your iPhone at one of those brown roadside landmark signs and instantly find out what it is — or skip the scan entirely and discover Wikipedia-eligible landmarks within 10 km of where you are via the Nearby tab.

A fully on-device OCR + Apple Intelligence pipeline with a four-source landmark resolver (Wikipedia, NPS, Wikidata, Google Knowledge Graph), location-aware ranking, an interactive map view of every find, and a directions launcher for Google Maps, Waze, and Apple Maps.

[![Download on the App Store](https://developer.apple.com/assets/elements/badges/download-on-the-app-store.svg)](https://apps.apple.com/app/brown-sign/id000000000)

## How it works

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

## Features

- **Nearby discovery tab** — surfaces all geo-tagged Wikipedia landmarks within 10 km of you, no scan required. Reuses the geosearch pipeline; defers per-entity Wikidata enrichment to tap time so a dense city stays fast. Tap a row (or pin in map mode) to enrich (Wikidata + AI polish + Google KG + match score + image) in the background and push the standard detail view, just like a scan result.
- **Map view in History and Nearby** — every saved lookup and every nearby discovery drops as a brown signpost pin on a MapKit map. Tap a pin for a callout card with thumbnail, summary, and a "View details" link. List/Map toggle on both tabs; History fits the camera to the bounding box of all your finds, Nearby centers on you.
- **Live camera** with tap-to-focus, auto flash, and a close button
- **On-device OCR** via Vision — multi-line output sorted top-to-bottom by bounding box, with structured line-by-line prompting so Apple Intelligence can distinguish "Wadsworth Mansion" from "2 MI"
- **On-device Apple Intelligence** via FoundationModels:
  - Cleans up noisy OCR text into a searchable landmark name
  - Polishes long Wikipedia extracts into 2–3 sentence card summaries
  - Scores whether a candidate actually matches the query (0–1 confidence)
- **Location-aware search** — Wikipedia geosearch within 10 km finds articles near you, merged with global text search. Exact title matches sort first, then by distance. "Wadsworth" near Middletown, CT returns the mansion down the road, not a city in Ohio.
- **Smart filtering** — three-pass type filter (Wikidata P31 blocklist → place-indicator whitelist → default reject) drops bands, films, food, hoaxes, people, and other non-landmarks. Title-token overlap rejects Wikipedia body-text matches ("East Haven" won't appear for "Fort Nathan Hale"). NPS fallback is also gated on title relevance.
- **Disambiguation picker** — when a query matches multiple landmarks, all candidates are shown sorted by distance. Tap any alternative to swap the result card instantly.
- **Directions** — tap coordinates or the Directions link to open a sheet with a MapKit preview and one-tap launch into Google Maps, Waze, or Apple Maps
- **NPS fallback** for historic places without Wikipedia coverage — queries both `/parks` and `/places` (NRHP-listed sites), with article images from the NPS `images` array
- **Wikidata enrichment** — coordinates, inception year, and human-readable type label for every candidate, via exact sitelinks lookup (not fuzzy search)
- **Persistent article images** — downloaded and resized during enrichment, stored locally in SwiftData. History scrolling is instant; images never disappear from transient network failures.
- **SwiftData history** — newest-first sort, swipe-to-delete, Delete All in edit mode, dedupe by canonical URL, push-to-detail with full raw summary
- **Selectable text** — titles and descriptions use UITextView (read-only) for full iOS text selection: tap, double-tap, drag handles, copy
- **Share sheet** — one-tap sharing of the article URL from the result card or detail view
- **Source badge links** — tap "Wikipedia" or "NPS" in the detail view to open the full article in Safari
- **UIKit text input** — the search field is a UIViewRepresentable wrapping UITextField for reliable focus, cursor placement, and text selection inside a ScrollView
- **Keyboard toolbar** — dismiss button (⌨↓) and search button (🔍) built into the text field's input accessory view
- **Graceful fallbacks** — every external call (Wikipedia, NPS, Wikidata, Google KG, Apple Intelligence, CoreLocation) fails silently to nil. The app works end-to-end even with no API keys, no location permission, and no Apple Intelligence.

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
| `BrownSignApp.swift` | `@main`, SwiftData container, TabView (Scan / Nearby / History) |
| `ContentView.swift` | Scan tab — camera button, text field, result card, alternatives list |
| `NearMeView.swift` | Nearby tab — discovery list + map view of geo-tagged Wikipedia landmarks within 10 km, with tap-to-enrich-and-save flow |
| `HistoryView.swift` | History tab — list and map view, row, detail view (with source badge links, selectable text) |
| `CameraView.swift` | UIKit camera VC with tap-to-focus, capture button, close button |
| `SafariView.swift` | `SFSafariViewController` wrapper |
| `LandmarkTextField.swift` | UIViewRepresentable wrapping UITextField (keyboard toolbar built in) |
| `SelectableText.swift` | UIViewRepresentable wrapping read-only UITextView for text selection |
| `MapsLauncher.swift` | Directions sheet with MapKit preview + Google Maps / Waze / Apple Maps |
| `OCRHelper.swift` | Vision OCR — returns `[String]` lines sorted top-to-bottom |
| `AppleIntelligence.swift` | FoundationModels — normalize (line-aware), polish, match-score |
| `LocationManager.swift` | CoreLocation async wrapper with in-flight guard + timeout |
| `WikipediaSearch.swift` | Text search, geosearch, nearby-discovery candidates, batch extracts/pageimages, word-boundary truncation |
| `WikidataSearch.swift` | Sitelinks-based entity lookup (P625 / P571 / P31 + label resolution) |
| `NPSSearch.swift` | `/parks` + `/places` fallback with article images |
| `GoogleKnowledgeGraphSearch.swift` | External confidence scoring |
| `LandmarkResult.swift` | Two-phase scan orchestrator + nearby-discovery orchestrator, type filter, title-match filter, place indicators |
| `LandmarkLookup.swift` | SwiftData `@Model` — history entries with all enrichment fields |
| `APIKeys.swift` | **Gitignored.** Local API keys only. |

## Privacy

Brown Sign collects no personal data. Camera images are processed on-device. Location is used only to rank nearby results. Search queries go to Wikipedia, Wikidata, NPS, and Google KG with no personal identifiers attached. No accounts, no analytics, no ads, no tracking.

Full privacy policy: [docs/privacy-policy.md](docs/privacy-policy.md)

## License

MIT
