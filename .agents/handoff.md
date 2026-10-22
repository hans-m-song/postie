# Handoff

## Latest checkpoint — 2026-10-22

User requested separate commits. Completed locally: 9fb17f6 formatting/Linux CI, 5973276 ordering/MCP/CLI foundation, 85fa94c MCP request discovery. Documentation is reconciled in the accompanying documentation commit; all36 staged README/docs files have valid relative links. No push. Index-only staging preserved all working source; deferred OTA integration remains uncommitted in Package/Makefile/PostieApp/HTTPSettingsEditor and separate updater/infra/scripts/release files. Private .codex/.vscode untouched.

The staged foundation was exported to /Volumes/Data/tmp/postie-split-validation and independently reviewed for staging boundaries. All279 tests passed without warnings, including the automation Settings entry and excluding Sparkle: /Volumes/Data/tmp/postie-checkin-foundation-tests.log. Discovery then passed27 focused tests and strict formatting in the same isolated snapshot: /Volumes/Data/tmp/postie-checkin-discovery-tests.log. Final release app/CLI snapshot builds and strict signatures passed without warnings: /Volumes/Data/tmp/postie-checkin-build.log. These artifacts are in the temporary snapshot, preserving the user's existing dist app. Earlier records below retain the sequence; this checkpoint supersedes their uncommitted/schema-cache/user-acceptance status.

T-103 user-accepted: after restarting the Codex session, tool metadata exposes collectionName across all eight collection-taking tools and optional query on requests.list. A live buildsight query `bcc sta` returned only get qbcc stats; no send. User replied “Sounds like it worked.” Schema-cache and acceptance gates are resolved. T-104–T-110 remain queued; no review fixes implemented. Next proposed correctness task is T-104 snapshot credential-header masking, requiring synthetic reproduction first.

User replied “Sounds good” to the proposed plan. T-103 implemented: optional requests.list query matches saved name/path, MCP schemas advertise collectionName, dispatcher retains legacy collectionID and rejects both selectors. Duplicate accessible names yield ambiguity error, no uniqueness migration. New pure RequestDiscovery helper has no vault/network dependency. Paths exclude origin templates/authority/query/fragment and keep percent escapes literal. No other review fixes applied.

All 27 focused AppAutomationTests/AutomationContractTests/MCPTransportTests passed without warnings; make lint passed. Log /Volumes/Data/tmp/postie-discovery-tests-final.log. Independent source review clear after correcting template-origin hostname/port suffix extraction; blind test audit clear after adding interior substring assertions. App/CLI release builds and strict signatures passed; artifacts refreshed in dist, log /Volumes/Data/tmp/postie-discovery-build.log. User acceptance/check-in pending; reopen rebuilt Postie and refresh MCP schemas before testing. No real HTTP sends, runtime configuration/Keychain reads, commit or push.

User requested every review finding be recorded as an immediate follow-up, then selected MCP partial request discovery first and collection names rather than UUID selectors. Added docs/immediate-follow-ups.md T-103–T-110 and linked roadmap. Approved requests.list optional query matches request name or saved URL path case-insensitively, without variable/secret resolution; collectionName used for MCP selectors, IDs retained internally and CLI compatibility preserved. Window ownership remains a separate unconfirmed product choice. Older cleanup/source-review state below remains applicable.

Live discovery checks after user restarted Postie, 2026-10-22: MCP collectionName with mixed case/whitespace plus interior name substring returned only get qbcc stats; path-only interior substring returned three matching requests. No-match and origin-variable-name queries returned none. Blank query and legacy collectionID returned identical five-item ordering. Both selectors returned invalidArguments; nonexistent collection returned notFound. Read-only calls only, no sends or workspace mutation. Codex session still advertises old collectionID-only tool metadata, although new arguments reach current app successfully; schema refresh remains unverified. Duplicate-name and exclusion behavior for this slice remain synthetic-tested only. User acceptance/check-in still pending.

Updated 2026-10-21. This is the current resumption state. Durable decisions and older evidence remain in [log.md](log.md); product status is [roadmap](../docs/roadmap.md).

## Active work

User approved documentation cleanup, README logo, normalized Swift formatting, and Linux CI. User then requested a swiftui-pro review delegated by module plus independent unit-test reviews without implementation context. Implementation/review is complete locally; user review/check-in remains.

- README uses existing packaging/Postie.png; no image regeneration.
- Current guides and historical status banners reconciled. Roadmap opening is canonical; dated task records remain historical.
- .swift-format sets4 spaces/120 columns; structural rewrite rules were disabled. Sources, Tests and Package.swift were normalized with official Swift6.4.1 Linux formatter.
- Linux workflow .github/workflows/ci.yml checks strict formatting, per-file syntax, actionlint and event-range whitespace. Tools scripts and Make lint/format/syntax targets added. Image/checkout/actionlint pinned; no credentials, build, deployment or macOS runner required.
- No hosted GitHub run observed, no push/deployment performed.
- Review findings recorded in [review-2026-10-21.md](../docs/review-2026-10-21.md). No functional review fixes applied.

## Verification

All279 existing package tests passed (Core138, Control19, Automation26, App96), no warnings/failures: /Volumes/Data/tmp/postie-cleanup-tests.log. App/CLI release rebuild and strict signatures passed: postie-cleanup-release.log. Artifacts dist/Postie.app and dist/postie refreshed.

Pinned Linux formatter+parser passed in source-only copy /Volumes/Data/tmp/postie-linux-ci-verification, with no runtime/agent config mounted. Intentionally invalid Swift file made parser fail; removed afterward. Local make lint/make syntax, actionlint, Bash syntax and normal/zero/missing-base whitespace checks passed. Relative Markdown links verified. See docs/ci.md for evidence paths.

## Review findings awaiting a new fix plan

Module reviewers used current source; no fixed diff attribution and no runtime reproduction claimed.

1. Snapshot request-template projection can lose inherited custom API-key header sensitivity.
2. CLI arguments/envelope frame budgets differ; oversized replies close IPC without a bounded correlated error.
3. Case-sensitive move recovery reconstructs lowercase paths for otherwise supported mixed-case directories.
4. WindowGroup shares singleton navigation/search across windows; decide single-window versus scene-local state.
5. Custom variable autocomplete lacks accessibility elements/selection announcements.
6. Global published clock invalidates unrelated views while idle; performance impact unmeasured.

Two blind reviewers read only all11 Core test files and all21 App/Automation/Control test files. Most tests are meaningful; targeted weaknesses include a snapshot failure test reaching the wrong error, ungated concurrency/stale-cancel scenarios, unbounded fixture/continuation waits, and vacuous plaintext/source-variable assertions. Strengthen existing cases instead of adding comprehensive coverage.

## Product work and commits

- b066227: layout/snapshots and resolved JSON export.
- 661e149: manual workspace key transfer.
- 983c27d: snapshot navigation regression.
- 2234b28: snapshot collapsing/counts.
- 3cca2f1: frozen unused-secret capture, encrypted snapshot support and actual-send opt-in.

Ordering/MCP/CLI foundations, sanitizer/policy UI, CLI diagnostic, CI and formatting are now checked in by the separate commits above. User standing rule: commit only user-verified scope locally; no push. Partial staging keeps deferred distribution changes separate. Recheck index/status before future staging.

## Live acceptance already established

User confirmed basic drag ordering and cross-collection moves. Intermittent wrong insertion became unreproducible; user deferred investigation.

Real Codex MCP list/start/get, Block, Unredacted, inherited/explicit redacted mode routing and cached-ID request exclusion were exercised. After fix, freshness became {{test}} under inherited redaction; user accepted. No request edits/policy changes made by agent in these checks.

Real CLI list/read/start/result, ongoing listing, cancellation and temporary snapshot create/read/rename/delete passed. Temporary snapshot deleted. Rebuilt CLI with app closed gave correct Open Postie guidance. Live operations explicitly authorized.

Remaining live gates: new snapshot redaction, collection exclusion across children, ordering/MCP-enabled restart persistence, MCP-specific create/edit/snapshot mutations, final settings/drag-feedback acceptance. These do not replace fixing the newly reviewed correctness issues.

## Operational boundaries

- Preserve unrelated distribution work: infra/, scripts/, Tests/ReleaseTests/, AppUpdater/Sparkle changes and packaging/Postie-512.png. OTA/deployment deferred; no release suite.
- Never inspect/stage .vscode/ or .codex/; preserve local user/editor/agent configuration.
- No runtime config, actual Keychain contents, env vars or credentials read. Use explicit synthetic workspaces and fake keys for tests.
- No Python/Ruby tooling. Swift/Bash/Make.
- No active subagent edits or separate worktree; all review workers read-only/completed.
- Memory updates not requested; do not write memory.

## Local build commands

Use existing .build/automation-check cache. Parent owns compiler/build lock. SwiftPM test options are documented in Makefile; sandbox execution may require the existing narrow cache/build escalation. Run make app cli BUILD_DIR=.build/automation-check CONFIGURATION=release and strict codesign checks when source changes warrant them. Do not confuse local/synthetic checks with native/user/deployment verification.
