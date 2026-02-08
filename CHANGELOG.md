# Changelog

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
