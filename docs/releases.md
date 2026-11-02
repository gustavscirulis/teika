# Teika releases

## Between releases

`changes.md` is the canonical change ledger. Add a permanent unique ID and a short
description under Added, Changed, Fixed, or Internal in the same PR as each meaningful
change. Keep shipped entries: manifests freeze their text and release assignment.
Public notes are authored separately: combine related changes into one customer
benefit and leave out implementation details, tests, tooling, and routine documentation
work. A detailed ledger entry does not automatically deserve a release-note bullet.
PR validation requires a ledger edit for meaningful changes. A PR with no release
impact can instead include `No release impact: <explanation>` in its description.
Release-record/version-only PRs do not need a new product-change entry.

```sh
./run.sh changes
./run.sh changes --json
./run.sh changes --sync-site
./run.sh changes --check
```

The website's upcoming notes come only from `releases/upcoming.json`. Each authored
summary references one or more related non-Internal ledger IDs; their detailed text
is never copied to public pages. For example, task export settings, delivery tracking,
retries, transcript formatting and integration documentation all support the single
customer-facing feature of sending new notes to Things or Reminders. Only summaries
whose IDs are all pending appear in development. A partial release needs wording
that accurately describes its selected changes.

The site projection is checked in so Vercel's `site/` root never needs to read files
outside its build directory. After changing the ledger, summaries, release selections,
or authored notes, run `changes --sync-site` and commit the resulting JSON with the change.
The initial ledger covers changes after public 1.0.3 (5), checked against
`f420a77..d5344f9`. Its baseline notes are copied from Apple's public What's New;
earlier releases are not reconstructed.

## One-time local setup

Use the Mac's existing signing identities and Xcode account. Set
`TEIKA_DEVELOPMENT_TEAM` to the developer team ID. API credentials come from
`~/.appstoreconnect/teika.json`, falling back to the existing private
`~/.appstoreconnect/snapwell.json` team-key reference. A complete `ASC_KEY_PATH` /
`ASC_KEY_ID` environment configuration overrides local files; team keys also need
`ASC_ISSUER_ID`. Individual keys omit the issuer. Never copy private keys or config
into this repository, `.context`, PR messages, or CI.

```sh
./run.sh release doctor
```

Doctor checks tool availability and reads Teika from Apple. It compiles the helper
once so subsequent dry runs do not write even build artifacts. It reports read access
separately from write permissions: metadata/review requires an App Manager/Admin key,
and successful reads do not prove that role. Xcode enforces signing access; Apple
enforces metadata/review permissions. Existing reviewer contacts are copied directly
between Apple's records, never emitted in helper output or stored in Git.

## An agent-owned release

An explicit request to release Teika authorizes preparing a release PR, uploading,
submitting for review with automatic publication after approval, then merging the
validated PR and publishing the site after successful submission. Installing or
testing this tooling does not authorize a live release. The agent performs these steps without recurring
confirmation requests:

1. Read `changes`, Apple state, and durable receipts. Resume an existing release
   before choosing another version/build.
2. Preview `./run.sh release prepare --dry-run`, then `./run.sh release prepare`.
   Apple determines the latest public version and next build. Default to the next
   patch, or use `--version 1.2.3`. Select all pending entries by default; use
   `--changes id-one,id-two` for a deliberate partial release.
3. Author 1–4 concise `•` bullets in the release's `en-US.txt`, grouping related work
   by customer benefit, and cross-check the source diff. Prepare seeds this file only
   from authored upcoming summaries fully covered by the selection; otherwise it
   stays empty for the agent to write. Do not copy the ledger or enumerate its
   supporting implementation, maintenance and documentation details. Edit
   `metadata.json` (name, subtitle, description, keywords, public URLs,
   copyright and review instructions) to reflect actual behavior. Integrate the current
   release features into the opening description and how-it-works steps; review the
   full description rather than relying on an appended feature paragraph. Set `notes_reviewed` and
   `metadata_reviewed` to true in the manifest after review.
4. Review the existing store images against the source diff. If any are inaccurate,
   run `./run.sh release screenshots --version 1.2.3`; use `--family iphone|ipad|watch`
   to replace only affected families. This creates dedicated disposable simulators,
   uses debug-only fixture scenes, and saves dimension-checked PNGs and hashes in the
   release folder. Lead with the main recording or transcription experience on iPhone and iPad,
   followed by saved notes; Settings belongs last. Inspect every PNG and the final
   ordered list before setting `screenshots.json`'s `reviewed`
   to true. If current assets remain accurate, use `mode: "reuse"`, an explanatory
   `reason`, `reviewed: true`, and `sets: []`. This decision is required on every
   release. Original screenshot sets remain in Apple until replacements process.
5. Run `changes --sync-site`. Update homepage/support/privacy prose as needed, then
   validate and commit all release content. Push and open a PR targeting `main`.
6. Run `./run.sh release publish --version 1.2.3 --dry-run`. It reads Apple and prints
   the exact notes, metadata, build, screenshot policy, and publication policy without
   writing local or remote state. An unreviewed/inconsistent plan fails here.
7. Run the same publish command without `--dry-run`. It runs/reuses native evidence,
   creates a unique signed archive, checks all phone/Watch/widget bundle
   versions and signatures, uploads symbols and the app without changing build
   numbers, waits for processing, updates metadata, uploads reviewed assets, attaches
   the exact build, and submits for App Review with `AFTER_APPROVAL`.
8. Only after read-back confirms successful App Review submission, the command
   validates the prepared revision, checks PR status, merges that exact PR, and
   verifies Vercel's Production deployment and public home/support/privacy/updates
   pages. No Vercel CLI token is required. The site publishes immediately after
   submission; do not wait for Apple approval. Describe the release's features in
   the present tense across the homepage, support and release notes. Do not add
   "coming next" labels or Apple approval/availability disclaimers. An upload,
   screenshot, metadata, or submission failure must leave the release PR unmerged.
9. Read-back verifies the build, notes, listing, review membership/state, and release
   policy. Routine release publication finishes after successful submission and
   website verification; no approval monitoring or follow-up copy change is needed.
   Keep Apple's actual state in the manifest and private evidence. Commit the
   sanitized updated release manifest on the release branch and
   update its PR/public record as appropriate. Keep Conductor on the release branch;
   do not rename it or switch to another workspace's checkout.

The app ID `6796609245` and bundle `com.gustavscirulis.teika` are checked before API
operations. Metadata starts with the existing `en-US` listing. Other locales,
pricing, category, privacy/compliance declarations, and account/legal agreements
are preserved; unknown factual answers and required account-holder actions are
reported as blockers, never guessed.

## Resume, inspect, or abandon

Use one command for a prepared release, including when continuing an interrupted
attempt:

```sh
./run.sh release publish --version 1.2.3
```

It uploads if needed, waits for processing, applies the reviewed listing and
screenshots, submits for review, then merges the release PR and verifies the
website. A confirmed upload is reused. `upload` and `submit` are optional commands
for deliberately running only part of that workflow.

```sh
./run.sh release status --version 1.2.3 --dry-run  # read-only
./run.sh release website --version 1.2.3          # retry Git/Vercel publication
./run.sh release upload --version 1.2.3           # archive/upload only
./run.sh release submit --version 1.2.3           # processing/metadata/review only
./run.sh release status --version 1.2.3           # verified distribution read-back
./run.sh release abandon --version 1.2.3          # unuploaded, unsubmitted plans only
```

Website and Apple checkpoints are independent. A processing timeout or metadata
failure retains the upload; rerun `publish` to continue without creating another
build. After separate `upload` and `submit` commands, commit the sanitized submission
record and run `publish` (or `website`) to merge and deploy; both verify submission
before any merge. A Git/Vercel failure preserves the successful Apple submission.
Commit its sanitized record before resuming publication from a clean working tree.
The submitted state is not a distribution claim. Apple-confirmed distribution
updates the manifest to `distributed`. Abandoned plans release their selected IDs
back to pending. Uploaded plans cannot be abandoned by throwing away evidence.

Artifacts and receipts live at `~/.appstoreconnect/teika/releases/<version>/`;
native evidence lives beside them under `validation/`. `TEIKA_RELEASE_STATE_DIR`
may select another private directory outside the repository. A per-app lock prevents
concurrent releases across workspaces. Preserve archives, symbols and receipts.
Changed source/content, an unreceipted existing build, or an ambiguous interrupted
upload stops rather than silently attaching/re-uploading. Reconcile the saved upload
log and exact Apple identity before proceeding; never delete receipts to force a retry.

## Validation

```sh
python3 -m unittest discover -s tests -p 'test_*.py'
swift test --disable-sandbox --package-path tools/ReleaseTools
bash tests/test_things_exports.sh
./run.sh changes --check
./run.sh site build
./run.sh release validate
```

Native validation runs the Teika iOS unit/UI suites and TeikaWatch tests and inspects
xcresult summaries: positive passed counts, zero failures, zero skips. The optional
live 0.5 GB model-download test is explicitly excluded and recorded. Validation is
reused only for matching app/test/shared sources, resolved dependency versions,
build configuration and Xcode version; marketing/build fields are normalized.
`release validate --fresh` records a fresh run. A failed/incomplete fresh run blocks
reuse of an older pass for those inputs. Release archives use the resolved packages
from validation and fail if native inputs change during archiving.

Before merging the release PR, website publication verifies that the current native
fingerprint (including resolved dependencies and Xcode) matches the uploaded build's
receipt and its passed iOS/Watch evidence. It reuses those positive test counts without
resolving packages again. Missing, changed, failed, or incomplete evidence blocks
publication.

If Conductor cannot access CoreSimulator or native signing, report the service error
and preserve all progress. Use one command from a normal Terminal:
`./run.sh release publish --version 1.2.3`. This continues through submission and
website publication without a separate `submit` command. The agent then inspects
the durable logs and Apple read-back; blocked or zero-test runs never count as
passing evidence.

Screenshot PNGs must be opaque and use a consistent size within each display set.
The Watch capture uses Series 9 (45mm) for Teika's existing Series 7 display class.
Screenshot launch arguments and sample content are debug-only. Capture builds use
an in-memory phone note store and isolated preferences, disable transfers and task
dispatch, and never request the microphone or download a model. Release archive
verification also checks the main binary for leaked screenshot launch hooks.
