# CarPlay and Listen

**Status (2026-09-30):** ships in 2.1.0 (build 43). Apple granted the
CarPlay **audio** entitlement on 2026-09-29 (requested 2026-09-28), and
it's switched on for Brown Sign's App ID.

## Why the audio category

CarPlay only shows an app Apple has granted a category entitlement for,
and the categories are exclusive in practice (WWDC26 allows audio plus
video, nothing else pairs). The roadmap ruled out the driving-task
category because it would close off an audio mode. So in the car Brown
Sign is a listening app: it reads landmark stories aloud.

## What's built

- **Listen engine** (`LandmarkNarrator`): on-device speech, a queue,
  Now Playing info and artwork, lock screen / steering wheel / CarPlay
  controls, and a `.spokenAudio` session that pauses for navigation
  prompts and calls and hands audio back when playback stops. A paused
  story ends itself after 20 minutes, so Play nearby doesn't hold
  location from a pocket.
- **Play nearby**: the closest landmark not yet heard, then the next
  closest from wherever the listener is by then (`NearbyStation`,
  10 mile rings widening to 25, re-fetched after about 2 miles).
- **Narrate as I drive**: quiet until the car is about 45 seconds from a
  landmark not heard in the last month, then its story, then quiet again.
  Turns itself off after 20 minutes parked or when CarPlay disconnects.
- **iPhone**: Listen button on the detail view, headphones menu on the
  Nearby tab.
- **CarPlay**: tab bar with Nearby (Play nearby, Narrate as I drive,
  closest landmarks) and History, Now Playing, Up Next.
- **Siri**: "Play nearby landmarks in Brown Sign", "Narrate landmarks as
  I drive in Brown Sign", "Stop narrating in Brown Sign".
- **Background modes**: `audio`, and `location` for Play nearby and
  Narrate as I drive with Maps in front (blue location indicator while on).

## Requesting the entitlement

Requested 2026-09-28 at [developer.apple.com/contact/carplay](https://developer.apple.com/contact/carplay/).
Pick the organization (Sean Mandable, 7VP76365KX, the team that signs
Brown Sign) and the app type (**Audio**). The form also has three
fields it doesn't require: "Tell us about your app", "What specific
CarPlay features do you plan to implement?" and an App Store URL. The
2026-09-28 request went in with them blank, so the details below went
to Apple the same day as a reply to its acknowledgment email.
Follow-ups go that way, keeping the email's Case-ID line. Bundle ID
`com.seanmandable.brownsign`, App Store ID 6762070205.

Description, for those fields or a follow-up:

> Brown Sign identifies the brown roadside signs that point to historic
> landmarks, and shows the landmarks around you. In CarPlay, Brown Sign
> is an audio app. It reads short stories about nearby landmarks aloud,
> using on-device speech built from each landmark's Wikipedia
> introduction. Drivers can tap Play nearby to hear the closest
> landmarks one after another, pick a landmark from the Nearby or
> History list, or turn on Narrate as I drive to hear about each
> landmark as they approach it. Playback uses the Now Playing template
> with play, pause, next and previous, and works with Siri ("Play nearby
> landmarks in Brown Sign"). Nothing plays until the driver asks. When
> playback stops, and after each Narrate as I drive story, the audio
> session is released so the driver's own audio resumes.

## After Apple approves

1. Done 2026-09-29: Certificates, Identifiers & Profiles → Identifiers →
   `com.seanmandable.brownsign` → Additional Capabilities → enable
   **CarPlay Audio App** → Save. This invalidates the App ID's existing
   profiles; automatic signing makes new ones on the next build.
2. Done 2026-09-29: `CODE_SIGN_ENTITLEMENTS` now applies to device
   builds too (Debug and Release, app target). Automatic signing needs
   an Apple account in Xcode (Settings > Accounts) to fetch a profile
   with `com.apple.developer.carplay-audio`. Without one, the build fails
   with "Entitlement com.apple.developer.carplay-audio not found and
   could not be included in profile". With the account signed in,
   automatic signing worked: the regenerated team profile and the signed
   app both carry the entitlement (checked 2026-09-29).
3. Done 2026-09-30: tried on the phone and in a car.
4. Done 2026-09-30: version 2.1.0, build 43, with What's New in
   `docs/app-store-text.md`.
5. Done 2026-09-30: `docs/privacy-policy.md` (effective September 30,
   2026) covers background location while Play nearby or Narrate as I
   drive is on, and the 30-day on-device narration log.
6. Done 2026-09-30: App Review notes are in `docs/app-store-text.md`
   (background `location` and `audio`, and how to try Listen).

## Testing

- **CarPlay simulator:** Xcode 27's Device Hub, which replaced
  Simulator.app, doesn't expose the CarPlay window on public macOS
  (FB24785359: the plugin needs Apple-internal entitlements). The options
  are Xcode 26.x's Simulator.app installed side by side (I/O > External
  Displays > CarPlay, iOS 26 runtime), or the entitlement plus CarPlay
  Simulator with a real phone.
- **Verified in the iOS 27 simulator (2026-09-28), via a temporary debug
  hook since removed:** Play nearby start, pool fetch (35 landmarks in
  Hartford), auto-advance, pause / resume / next / previous, History
  playback, Narrate as I drive on a simulated drive (three automatic
  narrations with the cooldown between them), the heard log surviving a
  relaunch, disambiguation suffixes dropped from spoken titles.
- **On a phone and in a car (2026-09-30):** tried by Sean on his
  iPhone 18 Pro and in his car before the 2.1.0 bump.
