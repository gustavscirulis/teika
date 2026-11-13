# Changes

Meaningful changes are recorded here in the same PR as their implementation.
IDs are permanent. Release manifests snapshot entries; do not delete entries after
submission. `./run.sh changes` distinguishes pending, prepared, submitted, and
distributed work. This is the complete audit trail. Public notes are authored
separately, combine related work, and focus on benefits customers care about.

This ledger starts after public **1.0.3 (5)**, whose source baseline is
`f420a77886a2a07e14a32298c83fae1787762c84`. Saved-note editing already shipped
in that version and is not an unreleased change. The initial backfill was checked
against `f420a77..d5344f9` (PR #9).

## Added

- [automatic-task-exports] Optionally turn each new voice note into a task in Things or Apple Reminders; existing notes and later edits are not exported.
- [task-export-settings] Choose Off, Things, or Apple Reminders in Notes Settings, with Things Inbox/Today and Reminders list and No date/Today controls.
- [obsidian-vault-export] Optionally save each new note into an Obsidian vault folder as its own Markdown file, named and filled from the vault's Unique note creator and template settings (with folder, file name and template overrides); edits in Teika update the file until it is changed in Obsidian.
- [persistent-task-delivery] Keep delivery progress for iPhone and Watch notes, with background Watch notes waiting until Teika is open and idle.

## Changed

- [concise-note-task-site-copy] Shorten the homepage's combined saved-note and task-export description.
- [current-release-site-copy] Describe submitted features in the present tense and combine clipboard, saved-note editing, and optional task exports into one homepage step; make this the default release copy policy.
- [reminders-first-release-presentation] Lead with Apple Reminders in release notes, store and website descriptions, and the first integration screenshot on iPhone and iPad.
- [task-export-privacy] Document optional note-text transfers to Things and Apple Reminders, their sync services, permissions, and local delivery tracking.
- [task-export-site-help] Explain task integrations, delivery recovery, and destination choices on the website and in support documentation.

## Fixed

- [store-description-and-screenshot-order] Explain saved-note editing and optional Apple Reminders or Things tasks in the main App Store description, and show Settings last in the iPhone and iPad screenshot sets.

- [task-delivery-recovery] Recover failed deliveries with Retry or Skip, and require confirmation before retrying an unconfirmed task to avoid duplicates.
- [task-description-content] Avoid repeating a complete task title in its description while preserving extra lines, truncated titles, and a marked excerpt for transcripts beyond Things' limit.

## Internal

- [reuse-upload-validation-for-site] Reuse the uploaded build's exact passed native validation before website publication, checking source, resolved dependencies, Xcode, and positive iOS/Watch counts without resolving packages again.
- [single-command-release-guidance] Recommend the combined publish command in CLI help, upload completion, timeout recovery, and the normal-Terminal fallback so releases do not require separate upload and submit commands.
- [submit-before-release-publication] Require verified App Store review submission before merging the release PR or deploying the website, while preserving resumable submission records if website publication fails.
- [app-store-screenshot-display-type] Use Apple's supported iPhone screenshot display identifier, including when resuming already-reviewed plans, without changing captured images or upload receipts.
- [opaque-store-screenshot-export] Export fully opaque simulator PNGs as RGB for App Store screenshots, verifying identical pixels and dimensions and rejecting real transparency.
- [compatible-screenshot-simulators] Fall back to a compatible simulator model and runtime when the newest runtime rejects an App Store screenshot device.
- [settings-navigation-ui-test] Locate the system back control by its identifier so Settings navigation validation also works when iOS places it in a separate toolbar.
- [export-regression-coverage] Add regression coverage and a macOS validation command for Things/Reminders exports, note persistence, and migration.
- [autonomous-release-workflow] Track changes and release assignments, author grouped customer-facing notes separately from the full ledger, preserve resumable release evidence, automate App Store metadata and review submission, capture screenshots, and publish website updates through the existing Git deployment.

## Releases

See `releases/<version>/release.json` for the exact selected changes and Apple
submission/distribution state. Website publication is recorded independently.
