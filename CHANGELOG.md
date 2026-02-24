# Changelog

All notable changes to this project will be documented in this file.

## [0.3.2] - 2026-02-24

### Fixed

- LaunchAgent now sets `EnvironmentVariables` with `PATH` including
  `/opt/homebrew/bin` so that `msmtp` and other Homebrew-installed tools
  (e.g. `bw`, `jq`) are found at runtime. Without this, `msmtp` was silently
  skipped and no summary email was sent when the job ran via launchd.

### Added

- `launchagent/com.homebrew.upgrade.plist`: LaunchAgent template with `__HOME__`
  placeholder and correct `EnvironmentVariables/PATH`.
- `make launchagent-install`: expands `__HOME__`, writes the plist to
  `~/Library/LaunchAgents/`, and bootstraps the agent. Safe to re-run.
- `make launchagent-uninstall`: unloads and removes the installed plist.

### Changed

- README LaunchAgent section rewritten: explains the PATH requirement, documents
  `make launchagent-install` / `make launchagent-uninstall`, and shows the
  template with `EnvironmentVariables`.

## [0.3.1] - 2026-02-19

### Added (CLI)

- `--version` flag to print the script version and exit.

### Verified

- `--help` usage output is available and up to date.

## [0.3.0] - 2026-02-19

### Added (Config)

- User configuration file support via `~/.brew-upgrade.conf`.
- New `--config <path>` option to load an alternate config file.
- Repository sample config: `.brew-upgrade.conf.example`.
- `make install` now seeds `~/.brew-upgrade.conf` from sample when missing.

### Changed (Config)

- Script constants can now be sourced from config (`HOMEBREW_LOG`, `BREW_PATH`,
  `EMAIL_TO`, `EMAIL_FROM_NAME`, `EMAIL_SUBJECT_PREFIX`, `EMAIL_CONFIG`).
- Defaults in repository are now generic (no personal values).
- Email recipient can be set in config and overridden on CLI (`--email-to`).

## [0.2.0] - 2026-02-18

### Added

- Optional email summary support via `msmtp`.
- New CLI flags for email workflow:
  `--email-summary`, `--email-to`, `--email-from-name`,
  `--email-subject-prefix`, `--email-config`, `--dry-run-email`, and `--help`.
- Human-readable run summary for email, including timestamp, host, status, upgraded
  formulae/casks, and log path.

### Changed

- Kept existing behavior (`brew update` + `brew upgrade`, log append, macOS
  notification) while adding argument parsing for script-level options.
- Unknown options are now passed through to `brew upgrade`.
- Both `stdout` and `stderr` from Homebrew operations are appended to the log.
- Upgrade parsing now extracts `==> Upgrading <name>` items and classifies casks
  heuristically using `Cask` context lines.
- If `msmtp` or its config is missing, the brew run still completes; warnings are
  written to stderr and the log.

## [0.1.0] - 2026-02-18

### Added (Initial Release)

- Initial project scaffold for `brew-upgrade`.
- Imported existing `brew-upgrade.sh` script from local machine setup.
- Added README with usage, requirements, and launchd notes.
- Added Makefile with install/uninstall targets.
- Added repository support files for publishing (`AGENTS.md`, `.markdownlint.json`,
  `.gitignore`).
