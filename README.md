# Spike Jam

An arcade indoor volleyball game for iPhone, Apple TV, iPad and Mac. It's fast and loud, with real rotations and real play calls, players who catch fire, and live multiplayer with friends. Pick a men's or a women's game.

Made by Conley Chaos LLC. Open source under the MIT license.

- Design: [docs/superpowers/specs/2026-11-26-spike-jam-design.md](docs/superpowers/specs/2026-11-26-spike-jam-design.md)
- Plans: [docs/superpowers/plans/](docs/superpowers/plans/)
- `SpikeJam/` is the throwaway feel spike from the first playtests. It will be replaced.
- `Packages/SpikeCore` (coming) is the shared game core: rules, rotation, AI and the fixed-step simulation. It builds for Apple platforms and Linux.

## Building

```sh
scripts/bootstrap.sh    # generates SpikeJam.xcodeproj from project.yml (installs XcodeGen if needed)
```

The app is `com.conleychaos.spikejam`, team `B222J9J7B8`, automatic signing. `scripts/make-icon.swift`
redraws the placeholder app icon.

## TestFlight

```sh
scripts/testflight.sh --dry-run    # print the commands, run nothing
scripts/testflight.sh              # bootstrap, archive (Release), export and upload
```

The build number is the current time as `YYYYMMDDHHMM`, passed to `xcodebuild` (project files are not
edited). By default Xcode's signed-in account does the signing and upload. To use an App Store Connect
API key instead, export `ASC_KEY_ID`, `ASC_ISSUER_ID` and `ASC_KEY_PATH` (path to the `.p8`, kept
outside the repo). `ExportOptions.plist` selects `app-store-connect`, destination `upload`, team
`B222J9J7B8`, automatic signing. The Info.plist sets `ITSAppUsesNonExemptEncryption` to false, so
TestFlight asks no export compliance question.

CI does this for you. `.github/workflows/ios.yml` builds the app unsigned on every pull request and
push to `main` and, once `Packages/SpikeCore` exists, runs its tests on macOS and in the official
`swift` Docker image on Linux. On each push to `main` it runs `scripts/testflight.sh` with an App Store
Connect API key (Admin role, so Xcode can manage signing and distribute builds). It needs the
repository secrets `ASC_KEY_ID`, `ASC_ISSUER_ID` and `ASC_KEY_P8` (the `.p8` file's contents); until
they exist the upload is skipped with a notice:

```sh
gh secret set ASC_KEY_ID --body "<key ID>"
gh secret set ASC_ISSUER_ID --body "<issuer ID from Users and Access, Integrations>"
gh secret set ASC_KEY_P8 < ~/.appstoreconnect/private_keys/AuthKey_<key ID>.p8
```

### Sending a build to testers

A push to `main` that changes the app (`SpikeJam`, `Packages` or `project.yml`) uploads a build and
sends it to **Family and Friends** (the external group) as well as the internal testers. A push that
changes only scripts, docs or CI uploads for the internal testers only. Later builds of an approved
version usually clear beta app review in minutes. To pick another group or resend a build, run the
workflow by hand: Actions → iOS → Run workflow on `main` (or `gh workflow run ios.yml --ref main`).
Its inputs:

- `distribute` (default on): after the upload, run `scripts/distribute.swift` for that build. Off
  means upload only.
- `group` (default `Family and Friends`): the beta group, looked up by name.
- `build` (default empty): distribute this already-uploaded build number and skip the archive, e.g.
  a build uploaded from a Mac with `scripts/testflight.sh`
  (`gh workflow run ios.yml --ref main -f build=202611260600`).
- `revoke_ci_certs` (default off): before archiving, revoke every development certificate CI ever
  created (`scripts/certs.swift --revoke-api-created`). Each fresh runner's archive mints one, and the
  job revokes its own when it finishes. Certificates a Mac made through Xcode are named after its
  user and are left alone.

`scripts/distribute.swift` talks to the App Store Connect API with the same key (an ES256 JWT signed
with CryptoKit; neither the key nor the token is ever printed). It waits up to 30 minutes for the
build to finish processing, answers export compliance if it is still pending, sets "What to Test"
from the commit subjects since the group's previous build (CI, docs and chore commits are left out;
with no previous build, a short default), adds the build to the group and, for an external group,
submits it for beta app review when App Store Connect says the build is ready for one. The run's
summary shows the notes that went out.

Run it locally with the same three `ASC_*` variables as `testflight.sh`:

```sh
scripts/distribute.swift --dry-run                         # read only: notes and planned changes
scripts/distribute.swift --build 202611260600              # distribute that build to Family and Friends
scripts/distribute.swift --build 202611260600 --group "Family and Friends" --since 2026-11-20
```

External testing also needs the app's Test Information in App Store Connect (feedback email, beta app
description, review contact); if it's missing, the review submission fails with Apple's message in
the log.
