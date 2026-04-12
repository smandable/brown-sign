# Brown Sign

Point your iPhone at one of those brown roadside landmark signs and instantly find out what it is.

A fully on-device OCR + Apple Intelligence pipeline with a four-source landmark resolver (Wikipedia, NPS, Wikidata, Google Knowledge Graph) and location-aware ranking.

## How it works

```
Camera/text → Vision OCR → Apple Intelligence normalize →
  Wikipedia geosearch (near you)
  Wikipedia text search        ──┐
                                 ├── merged candidate list
  (NPS parks + places fallback)  │
                                 ▼
                       per-candidate Wikidata enrichment
                     (coordinates, type, inception year)
                                 │
                                 ▼
                   drop non-landmark types (bands, films,
                         people, surnames, etc.)
                                 │
                                 ▼
                 sort by distance from user (500 m → 500 km)
                                 │
                                 ▼
         top result enriched with: Apple Intelligence summary polish,
       on-device match score, Google KG relevance, article image bytes
                                 │
                                 ▼
                     SwiftData history (deduped by URL)
```

## Features

- **Live camera with tap-to-focus** and a close button for backing out
- **On-device OCR** via Vision, run off the main thread with async/await
- **On-device LLM** via Apple's FoundationModels framework for:
  - Cleaning up noisy OCR text into a searchable landmark name
  - Polishing long Wikipedia extracts into 2–3 sentence card summaries
  - Scoring whether a candidate actually matches the query
- **Geographic bias** — uses CoreLocation to find Wikipedia articles within 10 km of you that match the query, then sorts all candidates by distance. A museum 20 miles away beats one on the other side of the country even if Wikipedia's text ranking disagrees.
- **Disambiguation picker** — when a query has multiple plausible matches, the result card shows the top one and lists the alternatives below. Tap any alternative to swap the card instantly.
- **NPS fallback** for historic places that don't have Wikipedia coverage, querying both `/parks` and `/places` (which includes NRHP-listed sites).
- **Wikidata enrichment** pulls coordinates (P625), inception year (P571), and instance-of type (P31) for every candidate.
- **Google Knowledge Graph** score as an external confidence signal.
- **Persistent article images** — landmark photos are downloaded and stored locally during enrichment, so history scrolling is instant and images never disappear due to transient network failures.
- **SwiftData history** with newest-first sort, swipe-to-delete, dedupe by canonical Wikipedia/NPS URL, and a push-to-detail view showing the full (unpolished) article extract.

## Tech stack

- **SwiftUI** + **SwiftData** — UI and persistence
- **Vision** — on-device OCR (`VNRecognizeTextRequest`)
- **AVFoundation** — camera viewfinder with tap-to-focus and flash
- **FoundationModels** — on-device Apple Intelligence (iOS 26+)
- **CoreLocation** — location-aware search biasing
- **SafariServices** — in-app article reading
- **Wikipedia MediaWiki API** — text search, geosearch, page images, extracts
- **Wikidata API** — structured entity enrichment via sitelinks lookup
- **NPS developer API** — parks + NRHP places fallback
- **Google Knowledge Graph Search API** — external confidence scoring

No third-party Swift packages. Everything is stock Apple frameworks.

## Requirements

- **iOS 26+** — required for FoundationModels. The three Apple Intelligence passes fall back silently on older devices (raw OCR / raw summary / no match score), but the app won't build against iOS < 26.
- **iPhone 15 Pro / iPhone 16 or later** for Apple Intelligence to actually run on-device. Other devices still work, just without normalization, summary polish, and on-device match scoring.
- **Xcode 26+**
- Physical device for the camera flow; simulator works for typed-text searches.

## Setup

1. Clone the repo and open `BrownSign/BrownSign.xcodeproj` in Xcode.
2. Create `BrownSign/BrownSign/APIKeys.swift` (gitignored) with:
   ```swift
   import Foundation

   let npsAPIKey = "YOUR_NPS_KEY"
   let googleKnowledgeGraphAPIKey = "YOUR_GOOGLE_KG_KEY"
   ```
   - **NPS:** free, get one at [developer.nps.gov](https://www.nps.gov/subjects/developer/get-started.htm).
   - **Google KG:** create a project in [Google Cloud Console](https://console.cloud.google.com/), enable the "Knowledge Graph Search API", then create an API key under Credentials.
   - Missing keys are handled gracefully — NPS and Google KG paths short-circuit to `nil` without crashing.
3. Ensure these Info.plist build settings are set on the target:
   - `INFOPLIST_KEY_NSCameraUsageDescription` — e.g. "To read brown signs and identify landmarks"
   - `INFOPLIST_KEY_NSLocationWhenInUseUsageDescription` — e.g. "To bias landmark searches toward places near you"
4. Select your development team under Signing & Capabilities, then Cmd-R onto a real device.

## Project layout

| File | Purpose |
| --- | --- |
| `BrownSignApp.swift` | `@main`, SwiftData container, TabView root |
| `ContentView.swift` | Scan tab — camera, text field, result card, "Other matches" |
| `HistoryView.swift` | History tab, row, and detail view |
| `CameraView.swift` | UIKit camera view controller wrapped for SwiftUI |
| `SafariView.swift` | `SFSafariViewController` wrapper |
| `OCRHelper.swift` | Vision text recognition, async |
| `AppleIntelligence.swift` | FoundationModels — normalize, polish, match-score |
| `LocationManager.swift` | CoreLocation async wrapper with in-flight guard |
| `WikipediaSearch.swift` | Text search, geosearch, batch extracts/pageimages |
| `WikidataSearch.swift` | Sitelinks-based entity lookup (P625/P571/P31) |
| `NPSSearch.swift` | `/parks` and `/places` fallback |
| `GoogleKnowledgeGraphSearch.swift` | External confidence scoring |
| `LandmarkResult.swift` | Two-phase orchestrator + landmark type filter |
| `LandmarkLookup.swift` | SwiftData `@Model` for history entries |
| `APIKeys.swift` | **Gitignored.** Local API keys only. |

## Status

Working end-to-end. Everything from the pipeline diagram above is implemented and running on device.

Possible next steps:
- MapKit detail view with a pin at the landmark coordinates
- Share sheet for the landmark URL
- Widget showing the most recent lookup
- Richer OCR — pass multi-line Vision output to Apple Intelligence for structured extraction (separating landmark name from directions/distances)

## License

MIT
