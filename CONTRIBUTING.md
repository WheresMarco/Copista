# Contributing to Copista

Thanks for helping. This page covers how to build and test Copista, and a few things that aren't
obvious from the code.

## Reporting a problem

Open an issue and describe what you added, what Copista did, and what you expected. If it's about
a particular PDF, say whether it's a scan or has text, and what the part names look like at the top
of the pages. Please don't attach sheet music you don't have the rights to share. A cropped
screenshot of a page's top is usually enough.

## Building and testing

Open `Copista.xcodeproj` in Xcode 27 or later and run the **Copista** scheme. Run the tests with ⌘U,
or from Terminal:

```sh
xcodebuild test -project Copista.xcodeproj -scheme Copista -destination 'platform=macOS'
```

If `xcode-select` points at the Command Line Tools rather than Xcode, put
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` in front of that command.

The tests generate their own PDFs, both scans and PDFs with text, so they don't depend on anyone's
library. They're written with Swift Testing.

The tests run inside the app. That means they use the same sandbox container as Copista itself,
including its settings.

### Testing against a real library

`RealLibraryVerificationTests` check detection against real sheet music. They're skipped unless that
music is in place. The test host is sandboxed, so copy the folders the tests name into the app's
container:

```
~/Library/Containers/co.wheresmar.Copista/Data/tmp/CopistaTestLibrary/
```

Keep the same relative paths, and delete the copy afterwards. The bundle identifier in that path
changes if you change the app's.

## Things to know

**Detection changes.** Fixtures can't show everything a real library will do. One rule that looked
right on generated PDFs moved dozens of real pages the wrong way. When changing anything in
`Copista/Detection`, compare the per-page results before and after on a few real multi-part PDFs.
Look at both scans and text PDFs.

When detection improves enough that saved results should be redone, bump `analyzerVersion` in
`SettingsStore`. Files a user has reviewed by hand keep their corrections either way.

**Built-in instruments** live in `Copista/Resources/DefaultInstruments.json`. Their names in each
language are in `Instruments.xcstrings`, keyed by the instrument's `key`.

- A key is permanent. An instrument's ID is derived from it, and saved corrections refer to that ID.
- When adding instruments, mark them `"since": N` and set `InstrumentCatalog.version` to `N`.
  Existing users then get the new instruments once, and ones they remove stay removed.
- Every alias must lead to its own instrument. A test checks this, and that no two instruments share
  an alias.

**Text in the app** is localized in English and Swedish with String Catalogs. Add a Swedish
translation for every new string in `Localizable.xcstrings`. Xcode adds the key when you build in the
IDE; a command-line build doesn't.

**The app icon** is drawn by `Design/make_icon.swift`. To change it, edit the script and run it from
the repository root:

```sh
xcrun swift Design/make_icon.swift
```

It writes both the Liquid Glass icon (`Copista/AppIcon.icon`) and the classic one for older macOS
(`Copista/Assets.xcassets/AppIcon.appiconset`). It uses no SF Symbols, which Apple doesn't license
for use in app icons.

## Releasing

Releases go on GitHub, and Copista updates itself from there with
[Sparkle](https://sparkle-project.org).

- **The feed:** each release carries an `appcast.xml`, and the app reads it from the latest release
  (`releases/latest/download/appcast.xml`). So whatever release is published last is the update everyone
  gets. Drafts and pre-releases don't count.
- **The key:** updates are signed with an EdDSA key. Its public half is `SPARKLE_PUBLIC_ED_KEY` in
  the Release build settings. Its private half is in the maintainer's login keychain, under Sparkle's
  `ed25519` account, made with Sparkle's `generate_keys`.
- **If the key is lost,** the apps people have installed can't verify updates any more. Back it up
  somewhere safe and keep it out of the repository:

  ```sh
  build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys -x copista-update-key.txt
  ```

  To release from another Mac, import that file there with `generate_keys -f`.

To make a release:

1. Add a `## 1.1.0` section to `CHANGELOG.md`, saying what's new for the people using Copista.
2. Commit and push.
3. Run `scripts/release.sh 1.1.0`. It builds the app and makes the disk image, the update zip and a
   signed `appcast.xml`, then uploads them as a draft release. `DRY_RUN=1` builds everything
   without uploading.
4. Check the draft on GitHub and publish it. From then on, Copista offers the update.

Each build is numbered by the number of commits, which Sparkle compares to tell newer from older.
The version in `MARKETING_VERSION` is only for Xcode's own builds; the script sets the real one.

Releases are signed to run locally rather than with a Developer ID, so they aren't notarized. People
approve the app once when they first open it (see the README); updates don't ask again. To notarize
later: join the Apple Developer Program, set the team, sign with Developer ID, turn on the Hardened
Runtime, and send the archive through `notarytool` before packaging. The Hardened Runtime stays off
until then, because it can stop an ad-hoc signed app from loading Sparkle.

## Pull requests

- Keep each pull request to one change, with a test where it can have one.
- Match the code around you: SwiftUI, Swift 6 with the main actor as the default, and comments that
  say why rather than what.
- Run the whole test suite before opening the pull request.

By contributing, you agree that your work is licensed under the [MIT License](LICENSE).
