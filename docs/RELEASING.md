# Releasing Readout

## Version policy (semver, strictly)

- **Patch (X.Y.Z → X.Y.Z+1):** fixes only. No new features, no behavior
  changes beyond the fix.
- **Minor (X.Y → X.Y+1.0):** backwards-compatible new features.
- **Major (X → X+1.0):** breaking changes only — persistent-format changes
  (baseline store), CLI argument changes, or settings-key incompatibilities.
- **No day-one bursts:** v1.0.1, v2.0.0 and v3.0.0 shipped within a day with
  no policy. From 3.0.1 on, each release goes through this document.
- **Never roll back a major:** the in-app update checker compares versions
  numerically, so users on 3.x treat any 1.x/2.x as older. Once a major is
  out, the next release keeps that major.
- The tag is always `vX.Y.Z` with no pre-release suffix.

## Release steps

1. Open a branch `release/X.Y.Z` from latest `main`:
   - Set `MARKETING_VERSION: "X.Y.Z"` in `project.yml`.
   - Add `docs/releases/X.Y.Z.md` (non-empty). See **Release notes** below.
   - Open a PR, wait for **all** CI checks to be green, merge.
2. On the merged `main` commit, create and push the tag:
   `git tag -a vX.Y.Z -m "Readout X.Y.Z" && git push origin vX.Y.Z`
   (Tags are owner-only; see the branch/tag protection note below.)
3. `release.yml` runs automatically: **preflight → verify → publish**.
4. Watch it succeed. On any failure: do NOT retry blindly and do NOT
   bypass a check — read the log, fix forward on `main`, re-tag only if
   preflight tells you the tag itself is wrong.

## Release notes

Release notes are for people who use Readout. Each entry describes something
a user can see, feel or rely on, in their words:

- **In:** new or changed behavior, fixed bugs as the user saw them
  ("Remote images over 20 MB are now refused before they download"),
  privacy and security changes, new system requirements, anything a user
  must do after updating.
- **Out:** refactors, file splits, test or CI changes, release-process
  changes, internal renames, PR and task numbers. Those belong in commit
  messages and PR descriptions.
- Group entries under `## New`, `## Improved`, `## Fixed`, `## Privacy` as
  applicable; leave out empty headings. If a release has no user-visible
  change, it should not be a release.
- Start with the summary sentence, not a `## X.Y.Z` heading: the file is the
  GitHub release body, which GitHub titles already, and the in-app update
  alert shows the release name right above the notes. (The alert drops such
  a heading and HTML tags such as `<kbd>`, so 3.5.0 and earlier read fine;
  new notes should not rely on it.)

## What CI and preflight block

- `ci.yml` (every `main` push, in full): Core tests (Linux),
  Web tests (WebKit — the production engine), Rendering baselines (WebKit:
  the real-agent corpus against its snapshots and screenshots), and the full
  Verify-signed-product run (Release and Smoke builds + ad-hoc sign + the
  smoke test on the signed Smoke build from /Applications +
  `tools/smoke-assert.py` + the signed Release app launched from there + Quick
  Look check; docs/TESTING.md).
  A red Core tests run blocks every release — this is what let v1.0.1 ship
  broken, and it can no longer happen.
  Pull requests run less to save macOS minutes (docs/TESTING.md, "What CI
  runs"): drafts run nothing, docs-only PRs skip the Linux jobs, and Verify
  runs only when the PR changes something outside docs, top-level Markdown,
  web tests and the speed budgets, or carries the `verify` label. The push to
  `main` never skips anything, and it is the run preflight requires, so the
  release gate is unchanged. A release PR (`project.yml` changes) runs
  everything.
- `release.yml` preflight fails with a clear message when:
  - the tag is not plain `vX.Y.Z`;
  - `X.Y.Z` is not strictly newer (semver) than the latest published Release
    (not checked on a `dry_run`, which publishes nothing);
  - `docs/releases/X.Y.Z.md` is missing or empty;
  - `project.yml` `MARKETING_VERSION` differs from `X.Y.Z`;
  - the tagged commit is not an ancestor of `main`;
  - CI on the tagged commit did not succeed. Preflight looks only at the
    `ci.yml` run triggered by the **push to `main`** for that exact commit
    (never a PR run or an older run of the same commit), waits up to
    60 minutes for it to finish if it is still running, and then requires
    the run and each of Core / WebKit / Rendering baselines / Verify to be `success`.
- Verify uploads `readout-app-<version>.zip` and `Readout-<version>.dmg`;
  publish downloads that exact artifact, checks both SHA-256s against
  verify's outputs, and only then writes SHA256SUMS. Rebuilds are forbidden —
  **what ships is what was tested, byte for byte**. The release is created as
  a draft, the ZIP is re-downloaded and re-hashed, and only then is it undrafted.
- The disk image is built in verify with [dmgbuild](https://github.com/dmgbuild/dmgbuild)
  (pinned with hashes in `tools/dmg/requirements.txt`; layout in
  `tools/dmg/settings.py`, background drawn by `tools/dmg/background.swift`
  at 1x and 2x): the tested app, an Applications link, an arrow and, while
  releases are not notarized, the line "First open: System Settings ▸ Privacy
  & Security ▸ Open Anyway". Verify then mounts it and requires the
  Applications link, the Finder layout, a 2x background and the tested app
  inside, file for file with the same signature; `dmg-window.png` in the smoke
  artifact shows the window. The layout files are read from the workflow's
  commit, so a dry run of an older tag builds today's disk image.
- `workflow_dispatch` never creates tags: it only re-runs an existing tag,
  and `dry_run=true` runs preflight + verify without publishing (any existing
  tag, the latest release included).

## Notarization (dormant until the secrets exist)

Releases are ad-hoc signed today. `release.yml` already asks `verify.yml` to
notarize (`notarize: true`, `secrets: inherit`); verify does so only when all
six repository secrets below are set, and otherwise signs ad hoc exactly as
before (the regular `ci.yml` runs pass no secrets, so PR and `main` runs are
always ad hoc). With the secrets, verify:

1. imports the certificate into a temporary keychain and signs with
   `tools/sign.sh dist/Readout.app "$DEVELOPER_ID_IDENTITY"` (hardened runtime,
   secure timestamp);
2. zips the app (`ditto`), submits it with `xcrun notarytool submit --key …
   --key-id … --issuer … --wait --timeout 30m`, prints Apple's log, fails unless
   the status is `Accepted`, then staples and validates the ticket;
3. runs the whole smoke test on the Smoke build of the same commit, signed
   with the same identity (not notarized: it never leaves the runner), then
   installs the notarized app in /Applications, launches it and runs the
   Quick Look check with it;
4. builds the DMG from the tested app (without the "Open Anyway" line), signs
   it, notarizes and staples it the same way (`tools/notarize.sh`), and uploads
   it in the verified artifact with its SHA-256;
5. requires Gatekeeper (`spctl -a -t exec -vv` on a quarantined copy) to
   accept the app; without notarization that check only prints its verdict
   (`rejected` today).

Publish then ships that DMG after checking its SHA-256 against verify's output.

### What the owner does (once)

1. Enrol in the Apple Developer Program (developer.apple.com/programs, $99 a
   year).
2. As the Account Holder, create a **Developer ID Application** certificate:
   - Keychain Access → Certificate Assistant → Request a Certificate From a
     Certificate Authority…: your email and name, "Saved to disk", save the
     CSR (`CertificateSigningRequest.certSigningRequest`);
   - developer.apple.com → Certificates, Identifiers & Profiles → Certificates
     → **+** → **Developer ID Application**, upload the CSR;
   - download the certificate and double-click it to install it in your login
     keychain (it lands next to the private key the CSR made).
3. Export the certificate with its private key as a password-protected
   `.p12`: Keychain Access → My Certificates → right-click "Developer ID
   Application: Your Name (TEAMID)" → Export… → Personal Information Exchange
   (.p12), e.g. `DeveloperID.p12`, with a password.
4. App Store Connect → Users and Access → Integrations → App Store Connect
   API → **Team Keys** → **+**: a name and the **Developer** role. Download
   the `.p8` (`AuthKey_<KEY_ID>.p8`; it downloads **only once**, keep it safe)
   and note its **Key ID** and the **Issuer ID** shown above the keys.
5. Add six repository secrets (GitHub → Settings → Secrets and variables →
   Actions → New repository secret):

   | Secret | Value | How to produce it |
   | --- | --- | --- |
   | `DEVELOPER_ID_P12_BASE64` | the `.p12`, base64 | `base64 -i DeveloperID.p12 \| pbcopy`, then paste |
   | `DEVELOPER_ID_P12_PASSWORD` | the `.p12` password | the password chosen in step 3 |
   | `DEVELOPER_ID_IDENTITY` | the identity's full name | `security find-identity -v -p codesigning`: the quoted name, e.g. `Developer ID Application: Your Name (TEAMID)` |
   | `NOTARY_API_KEY_P8_BASE64` | the `.p8`, base64 | `base64 -i AuthKey_<KEY_ID>.p8 \| pbcopy`, then paste |
   | `NOTARY_API_KEY_ID` | the key's Key ID | from step 4 (also in the file name) |
   | `NOTARY_API_ISSUER_ID` | the Issuer ID | from step 4 |

6. Try the lane before a release, publishing nothing. Either:
   - **Actions → CI → Run workflow**, branch `main`, tick **notarize**: the
     current `main` signed with the Developer ID, notarized, stapled, smoke
     tested and its DMG notarized (job "Notarization check"); or
   - **Actions → Release → Run workflow** with an existing tag (e.g. the
     latest) and `dry_run` = `true`: preflight and verify, no publish.

   Both are ad hoc (and say "asked for, but the signing secrets are not set")
   until all six secrets exist. Check the run log for `Accepted` twice (app,
   DMG) and `source=Notarized Developer ID` in the Gatekeeper step.
7. Tag the next release as usual (Release steps above): it is notarized.

If Apple rejects a submission, verify fails before anything is published.

### After the first notarized release

- Tell users, in that release's notes, that macOS asks once more for access
  to Documents, Desktop or Downloads and for Apple Events (Xcode as editor):
  the permissions now follow the Developer ID, and from then on persist
  across updates.
- Remove the "Open Anyway" paragraph from `README.md` (and `README.zh-CN.md`)
  and the per-release permission notes; the DMG's first-open line is already
  left out of notarized builds.
- If an older, ad-hoc Quick Look extension lingers (previews from the old
  build), run `qlmanage -r` once (and `qlmanage -r cache`).

## Branch and tag protection (owner: set once on GitHub)

- `main`: require PRs, require the Core tests (Linux), Web tests (WebKit)
  and Rendering baselines (WebKit) checks, no force pushes. (Skipped checks
  pass. Do not require "Verify signed product / Build, sign and smoke test":
  a PR that skips Verify never reports that name and would wait forever.
  Verify's gate is the push to `main` run that preflight requires.)
- Tags `v*`: restrict creation to the repository owner (Rulesets).
