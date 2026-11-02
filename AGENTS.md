# Teika agent workflow

- Read `docs/releases.md` before release, versioning, metadata, or screenshot work.
- Update `changes.md` in the same PR as every meaningful feature, fix, website,
  documentation, or maintenance change. Use a permanent unique kebab-case ID and
  the Added, Changed, Fixed, or Internal heading. For changes with no meaningful
  release impact, say so in the PR description. Never invent historical changes.
- Run `./run.sh changes` to see pending and assigned entries. Do not delete shipped
  entries or silently reuse an ID for a different change.
- On an explicit release request, own version/build selection, authored notes,
  metadata, screenshots, validation, release PR merge, website verification,
  upload, review submission, and read-back. Default to a patch update and automatic
  publication after approval. Merge the release PR only after App Store Connect
  confirms successful review submission. Then publish the site immediately through
  the existing Vercel Git integration; do not wait for Apple approval.
- Write 1–4 concise customer-facing bullets from the selected non-Internal entries,
  combining related work into a single customer benefit and cross-checking the source
  diff. The ledger is an audit trail, not public copy: omit implementation details,
  tests, tooling and routine documentation work. Maintain authored upcoming summaries
  in `releases/upcoming.json`; never copy raw ledger entries to the website or App
  Store. Review and commit all prepared content before publishing. At successful
  review submission, describe the release's features in the present tense across
  the website and public release copy. Do not add "coming next" labels or Apple
  approval/availability disclaimers. Routine releases need no approval monitoring
  or follow-up website copy change; keep Apple's actual state in private evidence
  and the release manifest.
- App Store Connect is authoritative for builds and release state. Keep keys,
  reviewer contacts, tokens, archives, and native evidence outside Git. Preserve
  receipts on failure; never erase them to force another upload.
- Release implementation/testing does not authorize a live upload or submission.
- Follow `site/AGENTS.md` for site edits. Reuse matching native validation rather
  than repeating it. A blocked or zero-test run is not a pass.
