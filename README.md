<div align="center">
  <h1>gloam</h1>
  <p><b>Syncs Kvantum, GTK, and custom scripts with Plasma 6's native light/dark (day/night) theme switching - and more.</b></p>
  <img src="screenshots/example.gif" width="800" />
</div>

### Quick Start

```bash
curl -fsS https://api.github.com/repos/edmogeor/gloam/releases/latest \
  | grep -o '"tarball_url": "[^"]*"' | cut -d'"' -f4 \
  | xargs curl -fsSL | tar xz
cd gloam-* && ./gloam.sh configure
```

## Releases

**Latest:** [v1.1.2](https://github.com/edmogeor/gloam/releases/tag/v1.1.2)

See the full [changelog](CHANGELOG.md) for details.

To update an existing installation:

```bash
gloam update
```

---

**gloam** solves a common problem in KDE Plasma: **external themes don't switch automatically.**

While Plasma handles its own styling well, components like **Kvantum**, **GTK apps**, **Flatpaks**, and **Konsole** often get left behind when switching between day and night modes.

**gloam** bridges this gap. It hooks into KDE's native day/night transition to instantly synchronize *everything* on your desktop, ensuring a consistent look across all applications.

It can bundle your preferences into custom Plasma Global Themes (for native integration), or simply run alongside your existing setup to handle the external tools that Plasma misses.

## Features

- **Custom Theme Generation:** Bundles your overrides into proper Plasma Global Themes for native switching.
- **Color Scheme Sync:** Switches Plasma color schemes for light/dark modes.
- **Kvantum Integration:** Automatically switches Kvantum themes for application styling.
- **Application Style Sync:** Switches Qt widget styles (Breeze, Fusion, etc.) for light/dark modes.
- **GTK Theme Sync:** Updates GTK 3/4 themes to match your Plasma preference.
- **Flatpak Support:** Automatically applies GTK, Kvantum, and icon themes to Flatpak apps.
- **Plasma Style Sync:** Switches Plasma desktop themes (panel, widgets appearance).
- **Window Decorations:** Changes window title bar styles for light/dark modes.
- **Icon Theme Sync:** Changes icon packs for light/dark modes.
- **Cursor Theme Sync:** Changes cursor themes for light/dark modes.
- **Splash Screen:** Optionally overrides or disables the splash screen.
- **Login Screen (SDDM):** Switches SDDM login screen themes for light/dark modes.
- **Wallpaper Generation:** Creates dynamic wallpaper packs from your images and applies them to desktop, lock screen, and SDDM.
- **Konsole Profiles:** Switches Konsole profiles live for running instances and new windows.
- **Custom Scripts:** Run arbitrary scripts when switching to light or dark mode.
- **Systemd Service:** User-level systemd service watches for changes automatically.
- **Panel Widget:** Optional Light/Dark Mode Toggle widget for your panel.
- **Keyboard Shortcut:** Toggle with Meta+Shift+L (customizable in System Settings > Shortcuts).
- **Global Installation:** Optionally install system-wide for all users, push config to existing users, and set defaults for new users.

## Requirements

- **KDE Plasma 6** (uses `kreadconfig6`/`kwriteconfig6`)
- [`gum`](https://github.com/charmbracelet/gum): Required for styled terminal UI (prompts, spinners, menus).
- `inotify-tools`: Required for monitoring configuration changes.


### Optional: Seamless Qt App Refresh

By default, some Qt applications may not refresh their styles until restarted. To enable seamless live refreshing of all Qt apps when switching themes, install the [plasma-qt-forcerefresh](https://github.com/edmogeor/plasma-qt-forcerefresh) patch:

```bash
git clone https://github.com/edmogeor/plasma-qt-forcerefresh.git
cd plasma-qt-forcerefresh && ./plasma-integration-patch-manager.sh install
```

This patches `plasma-integration` to add a DBus signal that forces Qt apps to reload their styles without restarting.

### Flatpak Notes

When you configure GTK or Kvantum themes, the script automatically sets up Flatpak permissions to access theme directories. Themes and icons are applied via environment variable overrides (`GTK_THEME`, `GTK_ICON_THEME`, `QT_STYLE_OVERRIDE`).

**Note:** Flatpak apps need to be closed and reopened for theme changes to take effect.

For Kvantum-styled Flatpak Qt apps, you may also need to install the Kvantum runtime:

```bash
flatpak install org.kde.KStyle.Kvantum
```

## Installation & Configuration

Download the latest release and run the configuration wizard:

```bash
curl -fsS https://api.github.com/repos/edmogeor/gloam/releases/latest \
  | grep -o '"tarball_url": "[^"]*"' | cut -d'"' -f4 \
  | xargs curl -fsSL | tar xz
cd gloam-* && ./gloam.sh configure
```

The `configure` command will:
- Scan your system for available themes (color schemes, Kvantum, application styles, GTK, Plasma styles, window decorations, icons, cursors, etc.).
- Ask you to select which ones to use for **light** and **dark** mode.
- Detect your current Plasma day/night global themes.
- Generate custom Plasma Global Themes from your selections.
- Install the CLI to `~/.local/bin/` (or `/usr/local/bin/` for global installs).
- Install the Light/Dark Mode Toggle panel widget (optional).
- Add a keyboard shortcut (Meta+Shift+L) for quick toggling (optional).
- Create and enable a systemd user service (`gloam.service`).

### Partial Re-configuration

You can re-configure specific components without going through the whole wizard:

```bash
gloam configure --colors       # Color schemes
gloam configure --kvantum      # Kvantum themes
gloam configure --appstyle     # Application style (Qt widget style)
gloam configure --gtk          # GTK themes
gloam configure --style        # Plasma styles
gloam configure --decorations  # Window decorations
gloam configure --icons        # Icon themes
gloam configure --cursors      # Cursor themes
gloam configure --splash       # Splash screen
gloam configure --login        # Login screen (SDDM) themes
gloam configure --wallpaper    # Day/night wallpapers
gloam configure --konsole      # Konsole profiles
gloam configure --script       # Custom scripts
gloam configure --widget       # Panel widget
gloam configure --shortcut     # Keyboard shortcut
```

### Config Export & Import

You can export your current configuration to a directory for use on another machine or user:

```bash
gloam configure --export /path/to/dir
```

Then import it to skip the interactive setup wizard:

```bash
gloam configure --import /path/to/dir/gloam.conf
```

Import sources the config file and proceeds directly to custom theme generation, CLI installation, and service setup.

## Usage

Once configured, the service runs in the background. You usually don't need to touch it. However, you can use the CLI to manually switch modes or check status.

### Commands

| Command | Description |
| :--- | :--- |
| `gloam configure` | Run the setup wizard. |
| `gloam configure -e <dir>` | Export current `gloam.conf` to a directory. |
| `gloam configure -I <file>` | Import an existing `gloam.conf` and skip interactive setup. |
| `gloam status` | Show the service status and current theme configuration. |
| `gloam light` | Switch to light mode (and sync all sub-themes). |
| `gloam dark` | Switch to dark mode (and sync all sub-themes). |
| `gloam toggle` | Toggle between light and dark modes (also via Meta+Shift+L). |
| `gloam remove` | Stop the service and remove all installed files. |
| `gloam update` | Check for and install the latest version. |
| `gloam version` | Show the installed version. |
| `gloam watch` | Run the monitor in the foreground (used by the service). |

## How It Works

1.  **Native Integration (Optional):** If you choose, `gloam` can generate custom Plasma Global Themes containing your choices. These are set as your KDE defaults so Plasma handles the main switch natively.
2.  **Bridging the Gap:** A lightweight background service monitors Plasma's state. When it detects a switch, it instantly applies the "external" settings that Plasma can't touch: changing Kvantum themes, updating GTK configs, reloading Konsole profiles, and running your custom scripts.

## Uninstallation

To remove the service, configuration, and all installed files:

```bash
gloam remove        # if installed globally
./gloam.sh remove   # if running from source
```

## License

This project is licensed under the GPLv3 License - see the [LICENSE](LICENSE) file for details.


