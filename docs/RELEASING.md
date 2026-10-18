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

- `ci.yml` (every PR and `main` push): Core tests (Linux),
  Web tests (WebKit — the production engine), Rendering baselines (WebKit:
  the real-agent corpus against its snapshots and screenshots), and the full
  Verify-signed-product run (Release build + ad-hoc sign + boot the signed
  app from /Applications + `tools/smoke-assert.py` + Quick Look check).
  A red Core tests run blocks every release — this is what let v1.0.1 ship
  broken, and it can no longer happen.
- `release.yml` preflight fails with a clear message when:
  - the tag is not plain `vX.Y.Z`;
  - `X.Y.Z` is not strictly newer (semver) than the latest published Release;
  - `docs/releases/X.Y.Z.md` is missing or empty;
  - `project.yml` `MARKETING_VERSION` differs from `X.Y.Z`;
  - the tagged commit is not an ancestor of `main`;
  - CI on the tagged commit did not succeed. Preflight looks only at the
    `ci.yml` run triggered by the **push to `main`** for that exact commit
    (never a PR run or an older run of the same commit), waits up to
    60 minutes for it to finish if it is still running, and then requires
    the run and each of Core / WebKit / Rendering baselines / Verify to be `success`.
- Verify uploads `readout-app-<version>.zip` (and, when it notarized, the
  DMG); publish downloads that exact artifact, checks its SHA-256 against
  verify's output, and only then makes the DMG (unless verify made it)/ZIP/SHA256SUMS. Rebuilds are forbidden — **what ships is what was
  tested, byte for byte**. The release is created as a draft, the ZIP is
  re-downloaded and re-hashed, and only then is it undrafted.
- `workflow_dispatch` never creates tags: it only re-runs an existing tag,
  and `dry_run=true` runs preflight + verify without publishing.

## Notarization (dormant until the secrets exist)

Releases are ad-hoc signed today. `release.yml` already asks `verify.yml` to
notarize (`notarize: true`, `secrets: inherit`); verify does so only when all
six repository secrets below are set, and otherwise signs ad hoc exactly as
before (`ci.yml` passes no secrets, so PR and `main` runs are always ad hoc).
With the secrets, verify:

1. imports the certificate into a temporary keychain and signs with
   `tools/sign.sh dist/Readout.app "$DEVELOPER_ID_IDENTITY"` (hardened runtime,
   secure timestamp);
2. zips the app (`ditto`), submits it with `xcrun notarytool submit --key …
   --key-id … --issuer … --wait --timeout 30m`, prints Apple's log, fails unless
   the status is `Accepted`, then staples and validates the ticket;
3. runs the whole smoke test on that notarized app from /Applications;
4. builds the DMG from the tested app, signs it, notarizes and staples it the
   same way (`tools/notarize.sh`), and uploads it in the verified artifact with
   its SHA-256;
5. requires Gatekeeper (`spctl -a -t exec -vv` on a quarantined copy) to
   accept the app; without notarization that check only prints its verdict
   (`rejected` today).

Publish then ships that DMG after checking its SHA-256 against verify's
output, instead of building one; without it, publish builds the DMG as today.

What the owner needs (once):

- A **Developer ID Application** certificate (Apple Developer Program,
  Certificates → +, "Developer ID Application"), exported from Keychain Access
  with its private key as a `.p12` with a password.
- An **App Store Connect API key** with the **Developer** role (App Store
  Connect → Users and Access → Integrations → App Store Connect API → Team
  Keys): the `.p8` file (downloadable once), its Key ID and the Issuer ID.
- These repository secrets (Settings → Secrets and variables → Actions):

  | Secret | Value |
  | --- | --- |
  | `DEVELOPER_ID_P12_BASE64` | `base64 -i DeveloperID.p12` |
  | `DEVELOPER_ID_P12_PASSWORD` | the `.p12` export password |
  | `DEVELOPER_ID_IDENTITY` | the identity's full name, e.g. `Developer ID Application: Name (TEAMID)` (`security find-identity -v -p codesigning`) |
  | `NOTARY_API_KEY_P8_BASE64` | `base64 -i AuthKey_XXXXXXXXXX.p8` |
  | `NOTARY_API_KEY_ID` | the key's Key ID |
  | `NOTARY_API_ISSUER_ID` | the Issuer ID shown above the keys |

Nothing else changes: the next tag pushed is released notarized. If Apple
rejects it, verify fails before anything is published. Once releases are
notarized, README's "Open Anyway" and per-release permission notes can go.

## Branch and tag protection (owner: set once on GitHub)

- `main`: require PRs, require the Core tests (Linux), Web tests (WebKit),
  Rendering baselines (WebKit) and Verify signed product checks, no force
  pushes.
- Tags `v*`: restrict creation to the repository owner (Rulesets).
