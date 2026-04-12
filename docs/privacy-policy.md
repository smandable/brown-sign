# Brown Sign — Privacy Policy

**Effective date:** April 12, 2026

Brown Sign is developed by Sean Mandable. This privacy policy explains what data the app accesses, how it's used, and what leaves your device.

## What the app accesses

| Data | Why | Leaves your device? |
| --- | --- | --- |
| **Camera** | To photograph brown roadside signs for OCR text recognition | No. Photos are processed on-device and never uploaded. A small thumbnail is saved locally for your history log. |
| **Location** | To rank landmark search results by distance from you | Only as coordinates in API queries to Wikipedia and Wikidata (e.g., "find articles near 41.5, -72.6"). Never sent to any analytics or tracking service. |
| **Text you type** | To search for landmarks by name | Sent to Wikipedia, the National Park Service API, Wikidata, and Google Knowledge Graph as search queries. No personal identifiers are attached. |

## On-device processing

- **OCR** (reading sign text from photos) runs entirely on-device using Apple's Vision framework.
- **Apple Intelligence** features (text cleanup, summary polishing, match scoring) run on-device using Apple's FoundationModels framework. No text is sent to Apple or any cloud LLM.
- **Search history** is stored locally on your device using SwiftData. It is never synced, uploaded, or backed up to any server.

## Third-party services

The app makes network requests to these services to look up landmark information:

| Service | What's sent | Privacy policy |
| --- | --- | --- |
| **Wikipedia / Wikimedia** | Search queries, coordinates | [wikimediafoundation.org/wiki/Privacy_policy](https://foundation.wikimedia.org/wiki/Privacy_policy) |
| **Wikidata** | Landmark titles | Same as Wikipedia |
| **National Park Service API** | Search queries | [nps.gov/aboutus/privacy.htm](https://www.nps.gov/aboutus/privacy.htm) |
| **Google Knowledge Graph** | Landmark titles | [policies.google.com/privacy](https://policies.google.com/privacy) |

No personal information (name, email, device ID, IP address) is intentionally sent to any of these services. Standard HTTPS requests may expose your IP address to the server, as with any internet connection.

## Data collection

Brown Sign does **not** collect, store, or transmit:

- Personal information (name, email, phone number)
- Device identifiers (IDFA, IDFV)
- Analytics or usage data
- Crash reports (unless you opt in via Apple's standard iOS crash reporting)
- Advertising data

There are **no ads**, **no accounts**, **no sign-up**, and **no tracking** of any kind.

## Data retention

All data stays on your device. Deleting the app removes all stored history, thumbnails, and cached images. There is nothing to delete on any server because nothing was ever uploaded.

## Children's privacy

Brown Sign does not knowingly collect any personal information from anyone, including children under 13.

## Changes to this policy

If this policy changes, the updated version will be posted at this URL with a new effective date. The app does not collect contact information, so there is no way to notify users directly — check this page if you have concerns.

## Contact

Questions or concerns about this privacy policy can be directed to:

Sean Mandable
smandable@gmail.com
