# CI and local verification

Updated 2026-10-21. Repository checks are configured in [Linux CI](../.github/workflows/ci.yml) for pushes and pull requests. This workflow has not yet been observed running on GitHub; local checks are not a hosted-CI success claim.

## Linux checks

The job uses an official Swift 6.4.1 Ubuntu image pinned by digest. It does not build Postie, resolve its dependencies, access credentials or deploy infrastructure.

| Check | Purpose | Boundary |
|---|---|---|
| `swift format lint --strict --recursive Sources Tests Package.swift` | Enforce the repository's four-space/120-column formatting configuration | Syntax/style checks, not type checking |
| `bash tools/check-swift-syntax.sh` | Parse each Swift source/test and the package manifest separately | Does not require SwiftUI/AppKit SDKs or establish macOS compatibility |
| actionlint 1.7.12 | Validate GitHub Actions YAML, expressions and job structure | Release binary is checksum-verified; this is not a hosted job execution |
| `bash tools/check-whitespace.sh BASE HEAD` | Check whitespace introduced by a push/PR range | New/missing base falls back to checking the current tree, not historical commits |

Checkout is pinned to a full commit, repository permissions are read-only, persisted credentials are disabled, jobs have a timeout, and superseded runs are cancelled. The workflow does not require repository secrets or a macOS runner.

Swift formatting covers `Sources`, `Tests`, and `Package.swift`. Deployment scripts, Terraform and local editor/agent configuration are outside this formatting pass. The formatter configuration disables several rewriting rules so normalization does not introduce unrelated structural refactors.

## Local commands

With the corresponding Swift toolchain installed:

```sh
make format
make lint
make syntax
```

`make format` rewrites the scoped Swift files. `make lint` checks them and the current tracked diff's whitespace. `make syntax` parses them; its compiler can be overridden with `SWIFTC` on the Make command line. Linux users can override `SWIFT=swift SWIFTC=swiftc`, because the macOS build defaults use `/usr/bin`.

CI's pinned Swift 6.4.1 formatter is authoritative. Different formatter versions can disagree; use the same toolchain when updating the formatting baseline. Swift 6 includes the formatter. [Official formatter documentation](https://github.com/swiftlang/swift-format), [official Linux toolchains](https://www.swift.org/install/linux/).

## macOS verification

```sh
make test
make app cli
codesign --verify --deep --strict dist/Postie.app
codesign --verify --strict dist/postie
```

These checks require macOS. The existing functional suite uses synthetic fixtures and temporary workspaces; no new comprehensive test suite is part of CI setup. Native UI behavior, Keychain continuity, real network operations and user acceptance are separate gates. Release/deployment tests remain deferred.

## Cleanup verification

The normalized Swift files passed the pinned Linux formatter and syntax checks in an isolated source-only copy, plus local `make lint` and `make syntax`. An intentionally invalid Swift file made the Linux syntax gate fail as expected; it was removed from the isolated copy afterward. Actionlint, Bash syntax and normal/new/missing-base whitespace checks passed locally.

All 279 existing macOS package tests passed (Core138, Control19, Automation26, App96), with no failures or warnings. App/CLI release rebuilds and strict signatures passed. Logs: `/Volumes/Data/tmp/postie-cleanup-tests.log`, `postie-cleanup-release.log`, `postie-linux-ci-verification.log`, `postie-linux-syntax-negative.log`, and `postie-linux-ci-final/verification.log`.

No GitHub job or deployment has been triggered by this local work. Module and blind test reviews are tracked separately in [the review report](review-2026-10-21.md); their findings are not disproved by the passing suite.
