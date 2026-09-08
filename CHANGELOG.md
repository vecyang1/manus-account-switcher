# Changelog

All notable changes to `manus-account-switcher` will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.2.0] - 2026-04-12

### Fixed
- Fixed silent exit during interactive `add-account` command sequence.
- Resolved profile session switching persistence across native macOS Dock and Spotlight app relaunches.

### Changed
- Converted credit balance polling in menubar to asynchronous non-blocking thread for instant menu responsiveness.

## [1.1.0] - 2026-04-03

### Added
- Cross-account knowledge synchronization engine: export, import, and sync learned custom rules/preferences across multiple Manus profiles.
- Live credit balance inspector utilizing internal Manus gRPC-JSON API (`GetAvailableCredits`).
- Daily automated credit check-in scheduler.

## [1.0.0] - 2026-04-02

### Added
- Initial release of Manus Account Switcher for macOS.
- Multi-profile Electron isolation via distinct `--user-data-dir` containers.
- macOS Keychain integration for secure authentication token storage.
- Support for concurrent side-by-side account executions.
