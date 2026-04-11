# Brown Sign

Point your iPhone at one of those brown roadside landmark signs and instantly find out what it is.

## What it does

1. **Snap** a photo of a brown sign (or type the text manually)
2. **OCR** reads the sign text on-device using Apple's Vision framework
3. **Normalize** — Apple Intelligence cleans up the raw text into a searchable landmark name
4. **Search** — Wikipedia is checked first; NPS is used as a fallback
5. **Read** — a result card appears with a summary and a link to the full article
6. Every lookup is saved to a local history log with a thumbnail of the sign

## Tech stack

- **SwiftUI** — UI
- **Vision** — on-device OCR
- **AVFoundation** — live camera viewfinder with tap-to-focus
- **Apple Intelligence** — on-device landmark name normalization (FoundationModels)
- **Wikipedia API** — primary search (no key required)
- **NPS API** — fallback search (free key from [developer.nps.gov](https://developer.nps.gov))
- **SwiftData** — local history persistence
- **SafariServices** — in-app article reading

## Requirements

- iOS 18.1+
- Xcode 15+
- iPhone 16 or M1 iPad (Apple Intelligence required)
- NPS API key (free, [sign up here](https://developer.nps.gov/signup))

## Setup

1. Clone the repo and open `BrownSign.xcodeproj` in Xcode
2. Add your NPS API key in `NPSSearch.swift`
3. Build and run on a physical device (camera required)

## Status

Early development. Core pipeline is working; MapKit pins, share sheet, and widget planned.

## License

MIT
