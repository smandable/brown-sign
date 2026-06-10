# Brown Sign — repo conventions for Claude

## Version bumps must update the .md docs in the same commit

Any change to the app's version or build number — `MARKETING_VERSION`
or `CURRENT_PROJECT_VERSION` in `BrownSign/BrownSign.xcodeproj/project.pbxproj`
(which become `CFBundleShortVersionString` and `CFBundleVersion` in the
generated Info.plist) — MUST be accompanied, in the **same commit**, by
matching updates to every Markdown doc that references a version:

- `README.md` — any version-specific feature copy or changelog entry
- `docs/app-store-text.md` — the "What's New (Version X.Y.Z)" header
  and block, with the previous version's copy demoted into the
  "Previous versions" list
- Any per-release notes added under `docs/` (release notes, draft
  ASC copy, investigation logs)

The .md docs are the canonical user-facing record of what shipped; they
are expected to always reflect the **currently shipped** version and
build. If you find them lagging (e.g. project.pbxproj says 1.4.8 but
`app-store-text.md` still says "What's New (Version 1.4.7)"), bring
them current as part of the same commit that does the bump — don't
leave a "docs catch-up" follow-up commit behind.

Equally, never bump the version without writing the user-facing copy:
if there's nothing worth telling users about, the version probably
shouldn't be bumping.

## Which version digit to bump

The version is `major.minor.patch` and Apple does not enforce it, so the
digits are purely the signal sent to users. Use:

- **Patch** (`1.4.13`, `1.4.14`, …) — bug fixes, reliability, small
  tweaks, copy. (1.4.12 was correctly a patch: "reliability and polish.")
- **Minor** (`1.5.0`) — a new user-facing feature or capability, the kind
  of thing the "What's New" opens with as "New: …": a new thing the app
  *does* (offline / saved regions, sharing or collections of finds, a new
  discovery mode, route planning, widgets, an AR viewfinder), not a better
  version of something that already exists.
- **Major** (`2.0`) — a redesign, a paid tier, or a milestone worth
  marketing as a relaunch.

Two practical notes, both learned the hard way:

- Any `MARKETING_VERSION` increase is a **new-version** submission in App
  Store Connect (the create-new-version flow), whether it is `1.4.13` or
  `1.5.0` — the digit choice costs nothing technically, it only changes
  the story told to users.
- A marketing version that is live or approved ("Ready for Distribution")
  is a **closed train**: you cannot attach another build to it (ASC
  errors 90186 / 90062). The next build then needs a fresh
  `MARKETING_VERSION`. The build number (`CURRENT_PROJECT_VERSION`) may
  carry across that bump (1.4.8 → 1.4.9 kept build 24; 1.4.11 → 1.4.12
  kept build 29) — but **only if the old build was never uploaded to
  App Store Connect**. Once a build number has been uploaded — even if
  it was never submitted for review, even under a version that was
  later abandoned — that number is consumed for the app forever, and
  re-uploading it is rejected as a duplicate. Learned with the orphaned
  1.6.2 build 35: it was uploaded before the release was re-versioned
  to 1.7.0, so 1.7.0 had to ship as build 36. When re-versioning after
  an upload, always bump the build too.
