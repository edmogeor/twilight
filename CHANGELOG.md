# Changelog

## [1.1.1] - 2026-02-10

### Added
- Show user's selection after Installation Mode, Apply to Other Users, and Copy Desktop Settings prompts
- Spinners for import config validation and setting system defaults

### Changed
- "Both existing and new users" is now the first option in the user apply menu

### Fixed
- Unbound variable crash in `select_themes` when light and dark choices are identical
- Silent exit in `apply_sddm_for_current_mode` when no wallpaper background found (`set -e`)
- Missing spacing before Konsole profiles prompt

## [1.1.0] - 2026-02-09

### Added
- Full TUI overhaul using [gum](https://github.com/charmbracelet/gum) — styled prompts, confirmations, spinners, and coloured output throughout
- ASCII art banner displayed on all subcommands
- Automatic dependency installation with package manager detection (pacman, apt, dnf, zypper)
- `error()` log level for non-fatal errors (logged + displayed, without exiting)
- `debug()` log level gated behind `GLOAM_DEBUG=true`
- Version and update check shown in `gloam status` output
- SDDM themes, push targets, and last switch time shown in `gloam status`
- Watch mode (`gloam watch`) uses timestamped log-style output for consistency

### Changed
- Unified logging: all `warn`, `error`, and `die` calls now write to both the log file and the terminal consistently
- Verbose error messages with actionable guidance (e.g. which package to install, how to recover)
- Folded follow-up hints into error/warn messages so they are captured in the log file
- Capitalized all removal status messages for consistency
- Replaced jq dependency with pure bash JSON parsing
- Suppress inotifywait noise in watch mode (`-q` flag)
- Standardized capitalization across all status and removal messages
- Import/export now prompts for paths when not provided as arguments

### Fixed
- Warnings and errors during configure/watch were displayed but not written to the log file
- `log "WARNING: ..."` embedded level in message text instead of using `warn()`

## [1.0.4] - 2026-02-09

### Changed
- Consolidate three wallpaper packs (Custom Dynamic/Light/Dark) into a single "Custom" pack
- Rename wallpaper pack directory from `gloam-dynamic` to `gloam`
- SDDM and lockscreen now source wallpapers from the single pack's `images/` and `images_dark/` directories

### Fixed
- Ctrl+C now properly exits the script during interactive prompts
- Reconfigure correctly resolves custom themes back to base themes
- Custom theme prompt only appears when configuring bundleable options

## [1.0.3] - 2026-02-08

### Added
- Validate config file against expected variables on load; warn if outdated or incompatible after an update

### Fixed
- CLI binary installed with `chmod 755` instead of `chmod +x` so non-root users can read and execute it

## [1.0.2] - 2026-02-08

### Fixed
- Self-update no longer corrupts the running script (buffer entire script before executing, use atomic mv)
- Suppress spurious `KPackageStructure` warnings from unrelated plasmoids during kpackagetool6 operations

## [1.0.1] - 2026-02-08

### Added
- Copy font settings (font families, sizes, and rendering) across users in "Copy Desktop Settings"
- Track keys added to `/etc/xdg/kdeglobals` for clean removal

### Fixed
- Removal no longer deletes pre-existing system defaults from `/etc/xdg/kdeglobals`

## [1.0.0] - 2026-02-08

### Added
- Version tracking (`gloam version`, `gloam --version`)
- Self-update mechanism (`gloam update`)
- Automatic update check on `gloam configure`
- GitHub Actions release workflow
- Changelog
