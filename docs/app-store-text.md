# Brown Sign — App Store Text

## App Name
Brown Sign

## Subtitle (30 characters max)
Identify roadside landmarks

## Promotional Text (170 characters max)
Shown above the description on your App Store page. Can be updated anytime without a new app review.

```
Ever drive past a brown highway sign and wonder what it's pointing to? Snap a photo, type the name, or open Nearby to see what's around you.
```

## Description

```
Ever drive past a brown roadside sign and wonder what it's pointing to? Brown Sign tells you instantly.

SNAP OR TYPE
Point your camera at a brown highway sign — or just type the name — and Brown Sign identifies the landmark, pulls up a summary, and shows you a photo.

NEARBY DISCOVERY
Open the Nearby tab to see landmarks within 5 miles of you — no scan needed. Switch to map view and pan to keep exploring; pins accumulate as you go. Hiking trails, museums, parks, monuments, lighthouses, covered bridges, historic districts, and dozens of other categories.

SMART SEARCH
Brown Sign searches Wikipedia, the National Park Service, and Wikidata to find the right match. It uses Apple Intelligence to clean up messy camera text and polish summaries into quick, readable cards.

LOCATION-AWARE
Results are ranked by distance from you, so local landmarks come first. Searching "Wadsworth" near Middletown, CT? You'll see the mansion down the road, not a city in Ohio.

MULTIPLE MATCHES
When a name matches multiple places, Brown Sign shows all of them sorted by distance. Tap any alternative to switch instantly.

GET DIRECTIONS
Tap "Directions" on any result to open Google Maps, Waze, or Apple Maps with turn-by-turn navigation to the landmark.

HISTORY
Every lookup is saved with a photo and full details. Swipe to delete, or tap to revisit any landmark you've looked up before.

RICH DETAIL CARDS
Each result includes coordinates, founding year, type (museum, park, fort, etc.), a Wikipedia photo, and the full article summary — with a one-tap link to read more in Safari. Text is fully selectable for easy copying.

SHARE
Share any landmark's article link with friends, family, or fellow travelers in one tap.

PRIVACY FIRST
Everything runs on your device. Camera images stay local. Location is used only to rank nearby results — never tracked or shared. No accounts, no analytics, no ads.

Brown Sign works on any iPhone running iOS 26. Apple Intelligence enhances the experience with smarter text cleanup and polished summaries, but the core pipeline works on every supported device.
```

## Keywords (100 characters max, comma-separated)
```
landmarks,brown signs,trails,travel,history,national parks,historic,road trip,sightseeing,directions
```

## What's New (Version 1.4.6)
```
Hiking trails, long-distance trails, and water trails now show up on the Nearby list and map when one's within range of you. Also fixed three landmark categories that had been quietly missing from Nearby because of stale identifiers in the curated landmark filter: National Wildlife Refuges, National Historic Landmarks, and memorials now appear like the rest.
```

### Previous versions

```
Version 1.4.5 — Sparse-data landmarks now show up on the History map. Some Wikipedia articles publish coordinates in their lead sentence but don't have a structured Wikidata coordinate — Drakes Bay Oyster Company is one example. Those landmarks used to save to History with no coordinates and drop off the map. Brown Sign now reads the article extract itself as a fallback, so the map matches what the article says.

Version 1.4.4 — Fixed an intermittent "No landmarks nearby" message that could appear in areas that actually contain landmarks. When the Wikidata service was slow or unreachable, the app was treating the failure the same as an empty area. Now you'll see a clear "Couldn't load landmarks" message with a Try again button instead, and the underlying timeout has been widened so transient slowdowns no longer trigger a false empty.

Version 1.4.3 — Whole-app design unification. Every card, list, textfield, and button across Scan, Nearby, and History now renders at a consistent 12pt corner radius. New custom List/Map switcher matches the search field height. Sentence-case button text. Brand brown extracted to a single asset color. Polished search field focus states, the Nearby empty state, and the History empty state.

Version 1.4.2 — Faster cold-start on the Nearby tab. Pins from your last session now appear instantly when you reopen the app, while a fresh search runs in the background — and the closest landmarks render before the rest of the list finishes loading. Pull-to-refresh is smoother: no more jump at the top of the list when results update. More landmarks show a thumbnail in the list and on map pins. Articles whose photos only appear inline in the body (like swing bridges) used to fall back to a placeholder; we now find those images too. Polish: list cards across Scan, Nearby, and History now end exactly with the last row instead of extending the parchment past the content; section headers are sized consistently across the three tabs; and Nearby's search field shows an explicit "No results" message when nothing matches.

Version 1.0 — Initial release.
```

## Support URL
https://github.com/seanmandable/brown-sign

## Marketing URL (optional)
https://github.com/seanmandable/brown-sign

## Copyright
© 2026 Sean Mandable
