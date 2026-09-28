# CarPlay and Listen

**Status (2026-09-28):** built on the `carplay-listen` branch, not shipped.
The iPhone half (Listen, Play nearby, Narrate as I drive, Siri) works now.
The CarPlay half waits on Apple granting the CarPlay **audio** entitlement
(requested 2026-09-28).

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
  prompts and calls and hands audio back when playback stops.
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
The form only asks for the organization (use Sean Mandable,
7VP76365KX, the team that signs Brown Sign) and the app type
(**Audio**). Bundle ID `com.seanmandable.brownsign`, App Store ID
6762070205.

Description, in case Apple asks for more detail:

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

1. Certificates, Identifiers & Profiles → Identifiers →
   `com.seanmandable.brownsign` → Additional Capabilities → enable
   **CarPlay Audio** → Save.
2. In the project, change `CODE_SIGN_ENTITLEMENTS[sdk=iphonesimulator*]`
   to plain `CODE_SIGN_ENTITLEMENTS` (Debug and Release, app target), so
   device builds carry `BrownSign.entitlements` too. Try automatic
   signing first; if Xcode says the profile lacks
   `com.apple.developer.carplay-audio`, follow Apple's manual-profile
   steps in "Requesting CarPlay Entitlements".
3. Test on the phone: CarPlay Simulator (Additional Tools for Xcode) with
   the iPhone over USB, then a real car. Check with the phone locked.
4. Ship it as a new minor version with a new build number (see
   CLAUDE.md), with What's New copy in `docs/app-store-text.md`.
5. Update `docs/privacy-policy.md` (new effective date) before
   submitting: location is also used, in the background, while Play
   nearby or Narrate as I drive is on; and a 30-day list of narrated
   landmarks is kept on the device.
6. App Review notes: background `location` runs only while Play nearby
   or Narrate as I drive is on, to choose which landmark to narrate as
   the car moves. Background `audio` plays the narration.

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
- **Not verified yet:** the CarPlay templates on a car screen, lock
  screen and steering wheel controls on a device, Siri phrases, real GPS
  course ("on your left"), pausing for a navigation prompt, voice
  quality on a device (the simulator only has the lowest-quality voice).
