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

## What CI and preflight block

- `ci.yml` (every PR and `main` push): Core tests (Linux),
  Web tests (WebKit — the production engine), and the full
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
- Verify uploads `readout-app-<version>.zip`; publish downloads that exact
  artifact, checks its SHA-256 against verify's output, and only then makes
  the DMG/ZIP/SHA256SUMS. Rebuilds are forbidden — **what ships is what was
  tested, byte for byte**. The release is created as a draft, the ZIP is
  re-downloaded and re-hashed, and only then is it undrafted.
- `workflow_dispatch` never creates tags: it only re-runs an existing tag,
  and `dry_run=true` runs preflight + verify without publishing.

## Branch and tag protection (owner: set once on GitHub)

- `main`: require PRs, require the Core / WebKit / Verify checks, no force
  pushes.
- Tags `v*`: restrict creation to the repository owner (Rulesets).
