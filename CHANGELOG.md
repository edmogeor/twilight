# Changelog

## [1.3.2] - 2026-03-01

### Fixed
- **Look and feel not applied on first boot:** `dbus-monitor` would exit immediately if the KDE session bus wasn't fully initialised yet (the service starts `Before=plasma-core.target`), causing the watcher to exit with status 1 before Plasma was ready to handle it. The service would restart after 5 seconds but the initial theme application was skipped in the failed first attempt. The `dbus-monitor` call is now wrapped in a retry loop so startup proceeds correctly on the first attempt
- **Duplicate theme applies after GeoClue correction:** when the GeoClue background subshell corrected the theme post-startup, `plasma-apply-lookandfeel` emitted a `notifyChange` DBus signal that the main monitor loop also acted on, applying the theme a second time. The subshell now writes a timestamp to `$XDG_RUNTIME_DIR/gloam-last-apply` which the main loop includes in its debounce check

## [1.3.0] - 2026-02-27

### Fixed
- **KDE crash on patch reinstall:** replacing the plasma-integration `.so` while KDE is running caused crashes. The patched library is now staged to `~/.cache/gloam/` and installed on next login by the gloam service (before KDE loads the plugin)
- Passwordless sudo helper (`/usr/local/lib/gloam/install-staged-patch`) allows the systemd user service to install staged patches without a TTY, following the same pattern as the existing SDDM helpers

## [1.2.2] - 2026-02-21

### Fixed
- Patches directory not found when running `gloam configure --patches` from a global installation
- Patches are now deployed to `/usr/local/share/gloam/patches` during global CLI installation
- Automatic fallback to fetch patches from GitHub when not available locally

## [1.2.1] - 2026-02-16

### Added
- **Auto Mode:** new `gloam auto` command switches to automatic day/night theme scheduling via KDE's KNightTime service
- **OSD overlay:** on-screen display shows the current mode (Light, Dark, Auto) when switching via the panel widget, keyboard shortcut, or CLI commands
- **Plasmoid auto state:** panel widget now cycles through Light, Dark, and Auto modes on click with a dedicated contrast icon for auto mode
- **Right-click Auto Mode:** plasmoid context menu includes an "Auto Mode" option alongside Light Mode and Dark Mode

### Changed
- `gloam toggle` now cycles through Light → Dark → Auto instead of just toggling between Light and Dark
- Keyboard shortcut (Meta+Shift+L) follows the same three-state cycle
- Explicit `gloam light` / `gloam dark` commands now disable automatic mode (previously auto mode was silently preserved)

## [1.2.0] - 2026-02-11

### Added
- Plasma patch build/install/remove infrastructure (`gloam configure --patches`)
  - **plasma-integration**: adds a DBus `forceRefresh` signal handler so Qt apps reload styles without restarting
  - Patch is built from source, detected via `nm` symbol check, and cleanly removed by `gloam remove`

### Removed
- **plasma-workspace** autoswitcher override patch
- Logout prompt after installing patches, widget, or shortcut

### Fixed
- Systemd service crash loop: `Type=notify` with a silently failing `systemd-notify` caused systemd to kill gloam every 90 seconds, re-applying the schedule theme on each restart and overriding manual toggles (now uses `Type=simple`)
- Patch builds use proper `.patch` files instead of fragile sed-based inline patching
- Patch install uses atomic `cp` + `mv` to avoid partial writes
- Patch removal correctly detects installed patches for sudo elevation
- Patch source pinned to installed Plasma version tag to avoid ABI mismatches
- Backup `.gloam-orig` files refreshed when Plasma updates overwrite patched files
- `deploy_patches_dir` returns clean exit codes and only runs for global installs

## [1.1.2] - 2026-02-10

### Changed
- Replace inotifywait file watcher with DBus monitor for theme change detection (removes inotify-tools dependency)

### Fixed
- Theme now applies before session restore so windows start with correct theme
- Service runs immediately after KWin starts using `After=plasma-kwin_wayland.service`
- Uses `Type=notify` with `systemd-notify --ready` to block session restore until theme is applied (reverted in v1.2.0)
- Respect auto mode setting on login — only switch themes based on day/night cycle if auto mode is enabled

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
- Wait for kded6 (KDE daemon) at login before applying themes so QT apps pick up changes

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
- Suppress inotifywait noise in watch mode (`-q` flag) (removed in v1.1.2)
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
