# Changelog

All notable changes to **MacExpert** — a native macOS controller for SPE Expert amplifiers
(serial / WebSocket RCU) that also ships as an
[Amateur Radio Suite](https://github.com/VU3ESV/AmateurRadioSuite) plugin. Format follows
[Keep a Changelog](https://keepachangelog.com/). Releases are cut locally with `release.sh`
(tags `vX.Y.Z`); a push to `main` only runs CI — the automatic release on every merge was
removed on 2026-06-28. v2.0.4 – v2.0.9 are not itemised here; see the
[GitHub releases](https://github.com/vu2cpl/macexpert-spe/releases).

## [Unreleased]

## [2.0.11] — 2026-10-09
Released 2026-10-09 as [v2.0.11](https://github.com/vu2cpl/macexpert-spe/releases/tag/v2.0.11):
`MacExpert-2.0.11-macOS.{zip,dmg}` (universal, notarized + stapled, `sdk 27.0`),
`MacExpert-2.0.11.radioplugin` and `SHA256SUMS`.

### Fixed
- **v2.0.10 shipped a stale binary** — the June 2026 build, without the update check its
  notes describe. `build-app.sh` lipo'd `.build/{arm64,x86_64}-apple-macosx/release/MacExpert`,
  which Swift 6.4's build system no longer writes (it writes `.build/out/Products/Release`), so
  the June binaries still lying there were packaged. 2.0.11 is the first release that really
  contains the update check. `build-app.sh` now builds both architectures in one SwiftPM
  invocation, asks SwiftPM for the product path (`--show-bin-path`) after deleting the old
  product, passes the real macOS SDK to the linker (Swift 6.4 otherwise records the deployment
  target, 14.0, as the SDK), and stops unless the fresh binary has both architectures,
  `minos 14.0`, `sdk` = the build SDK, no `@rpath` dylibs, the update checker, and is copied
  byte-identically into a freshly assembled `.app` with the right `Info.plist` version. The test
  target's resource bundle is no longer copied into the app. `release.sh` also checks the
  published zip has no AppleDouble entries.

### Changed
- **Update dialog: no focus, no default button for the automatic check** (Manoj, 2026-10-09).
  The window an automatic check puts up (at launch or from the hourly timer) appears in front
  without activating MacExpert or taking the keyboard, and none of its buttons is the default:
  Return never opens the browser, **Download** needs a click, Esc / the close box is **Remind
  Me Later**. **Check for Updates…** still brings it forward with the keyboard, also with no
  default button. It was an app-modal `NSAlert` that became the key window mid-typing, where
  Return pressed Download; it is now a non-modal panel (shared `UpdateChecker.swift`, still
  byte-identical across VU2CPL's Swift apps).

## [2.0.10] — 2026-10-09
*Its release files contain a stale binary (the June 2026 build, without the update check) —
use 2.0.11.*

### Added
- **Update check against GitHub releases** (standalone app only — the Suite plugin excludes
  it): about 10 s after launch, at most once a day, one anonymous `GET` of
  `api.github.com/repos/vu2cpl/macexpert-spe/releases/latest`; if the tag is newer than
  `CFBundleShortVersionString`, a dialog with the release notes and **Download** (opens the
  release page) / **Skip This Version** / **Remind Me Later**. **MacExpert → Check for
  Updates…** always reports; **Check for updates automatically** (default on) sits beside it.
  `MacExpert/UpdateChecker.swift` is byte-identical across VU2CPL's Swift apps. Nothing is
  downloaded or installed automatically. Refined 2026-10-09: only a successful check (HTTP 200
  with a `tag_name`) stores the time — a failed one (offline, timeout, any HTTP error including
  the 403 rate limit, bad JSON) stores nothing and is retried at the next launch, or after 1 h
  while running; an hourly timer repeats the daily check for as long as the app runs (never
  while one of its dialogs is open); and a development build (version containing "dev", e.g.
  `build-app.sh`'s `0.0.0-dev`) never checks on its own — Check for Updates… still works.

### Changed
- **Releases are cut locally** with `release.sh` (build, embed + sign the ExtensionKit plugin,
  notarize + staple the `.app` and `.dmg`, package the `.radioplugin`, `SHA256SUMS`); the CI
  auto-release workflow was deleted 2026-06-28, so a push to `main` only runs CI (build + test
  + extension smoke build). `release.sh` now stamps the tag's version into `Info.plist` (it
  used to run after `build-app.sh`, which left `0.0.0-dev` in some 2.0.x bundles) and zips the
  app with `ditto --norsrc`, so the `.zip` carries no AppleDouble `._*` entries.

## [2.0.3] — 2026-06-03
### Added
- **CI + Release pipelines** (previously none): CI builds + tests the app and the plugin
  `.appex` on every PR and push to `main`. *(At the time a GitHub Release was also cut
  automatically on every merge to `main`; that was removed 2026-06-28 — see 2.0.10.)*
- **Out-of-process plugin** ([CONVERTING-A-PLUGIN.md](https://github.com/VU3ESV/AmateurRadioSuite/blob/main/docs/CONVERTING-A-PLUGIN.md)):
  an ExtensionKit `.appex` (`Xcode/`) + `scripts/make-radioplugin.sh` packaging
  `MacExpert.radioplugin`, so the suite can browse/install MacExpert and host it sandboxed via
  `EXHostViewController`. To avoid restructuring the package, the `.appex` recompiles the app's
  own sources (excluding the standalone `@main` + resources); **the standalone app and
  `Package.swift` are unchanged**.
  - *Deferred:* an in-process `RadioPlugin` adapter (would need a library/exe package split);
    the shipping suite hosts plugins out-of-process, so it isn't needed yet.

## [2.0.1] — 2026-04-30
### Changed
- Move all serial I/O off the main thread to a dedicated `ioQueue`.
### Added
- "Amp Powered Off" banner with a traffic watchdog; allow RCU capture in WebSocket mode.

## [2.0.0] — 2026-04-26
### Added
- Live two-way mirroring of the amplifier display via RCU LCD-frame parsing (serial +
  WebSocket parity), info screens, and a standby banner.
- Fixture-based regression tests for the RCU frame parser (7 screens, 18 tests) and a
  reverse-engineering write-up (`docs/REVERSE_ENGINEERING.md`).
- Universal (arm64 + x86_64) build via `lipo`; full-area alert banner, UI toggles, MID power
  scale; refreshed README.
