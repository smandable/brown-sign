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
