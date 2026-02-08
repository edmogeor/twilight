# Changelog

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
