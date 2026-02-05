# twilight

<div align="center">
  <img src="screenshots/example.gif" width="800" />
</div>

**twilight** is a dark/light mode theme switcher for KDE Plasma's day/night cycle. It hooks into KDE's built-in day/night mode to automatically synchronize theme components that otherwise wouldn't get switched, or that you want to override with different options than the global theme provides.

It generates custom Plasma Global Themes from your selections so KDE applies most overrides natively, and runs a lightweight background service to handle the rest (Kvantum, GTK, Konsole, Flatpak, browser color scheme, custom scripts).

## Features

- **Custom Theme Generation:** Bundles your overrides into proper Plasma Global Themes for native switching.
- **Kvantum Integration:** Automatically switches Kvantum themes for application styling.
- **Plasma Style Sync:** Switches Plasma desktop themes (panel, widgets appearance).
- **Window Decorations:** Changes window title bar styles for light/dark modes.
- **Color Scheme Sync:** Switches Plasma color schemes for light/dark modes.
- **Cursor Theme Sync:** Changes cursor themes for light/dark modes.
- **Icon Theme Sync:** Changes icon packs for light/dark modes.
- **GTK Theme Sync:** Updates GTK 3/4 themes to match your Plasma preference.
- **Browser Color Scheme:** Syncs the XDG portal color scheme preference for browsers.
- **Flatpak Support:** Automatically applies GTK, Kvantum, and icon themes to Flatpak apps.
- **Konsole Profiles:** Switches Konsole profiles live for running instances and new windows.
- **Splash Screen:** Optionally overrides or disables the splash screen.
- **Custom Scripts:** Run arbitrary scripts when switching to light or dark mode.
- **Systemd Service:** User-level systemd service watches for changes automatically.
- **Panel Widget:** Optional Light/Dark Mode Toggle widget for your panel.
- **Keyboard Shortcut:** Toggle with Meta+Shift+L (customizable in System Settings > Shortcuts).
- **Global Installation:** Optionally install system-wide for all users, push config to existing users, and set defaults for new users.

## Requirements

- **KDE Plasma 6** (uses `kreadconfig6`/`kwriteconfig6`)
- `inotify-tools`: Required for monitoring configuration changes.
- `kvantum`: If you want to manage Kvantum themes.
- `flatpak`: Optional. If installed, GTK/Kvantum themes and icons are automatically applied to Flatpak apps.

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

Clone the repository and run the configuration wizard:

```bash
git clone https://github.com/edmogeor/twilight.git
cd twilight && ./twilight.sh configure
```

The `configure` command will:
- Scan your system for available themes (Kvantum, Plasma styles, window decorations, color schemes, cursors, icons, GTK, etc.).
- Ask you to select which ones to use for **light** and **dark** mode.
- Detect your current Plasma day/night global themes.
- Generate custom Plasma Global Themes from your selections.
- Install the CLI to `~/.local/bin/` (or `/usr/local/bin/` for global installs).
- Install the Light/Dark Mode Toggle panel widget (optional).
- Add a keyboard shortcut (Meta+Shift+L) for quick toggling (optional).
- Create and enable a systemd user service (`twilight.service`).

### Partial Re-configuration

You can re-configure specific components without going through the whole wizard:

```bash
twilight configure --kvantum      # Kvantum themes
twilight configure --style        # Plasma styles
twilight configure --decorations  # Window decorations
twilight configure --colors       # Color schemes
twilight configure --cursors      # Cursor themes
twilight configure --icons        # Icon themes
twilight configure --gtk          # GTK themes
twilight configure --konsole      # Konsole profiles
twilight configure --splash       # Splash screen
twilight configure --script       # Custom scripts
twilight configure --widget       # Panel widget
twilight configure --shortcut     # Keyboard shortcut
```

## Usage

Once configured, the service runs in the background. You usually don't need to touch it. However, you can use the CLI to manually switch modes or check status.

### Commands

| Command | Description |
| :--- | :--- |
| `twilight configure` | Run the setup wizard. |
| `twilight status` | Show the service status and current theme configuration. |
| `twilight light` | Switch to light mode (and sync all sub-themes). |
| `twilight dark` | Switch to dark mode (and sync all sub-themes). |
| `twilight toggle` | Toggle between light and dark modes (also via Meta+Shift+L). |
| `twilight remove` | Stop the service and remove all installed files. |
| `twilight watch` | Run the monitor in the foreground (used by the service). |

## How It Works

1. During `configure`, twilight generates custom Plasma Global Themes that bundle your selected color scheme, icons, cursors, Plasma style, window decorations, and splash screen.
2. These custom themes are set as your KDE day/night defaults, so Plasma applies most overrides natively when switching.
3. A systemd service uses `inotifywait` to monitor `~/.config/kdeglobals` for changes.
4. When a theme switch is detected, the service applies the remaining overrides that can't be bundled: Kvantum, GTK, browser color scheme, Konsole profiles, Flatpak themes, and custom scripts.

## Uninstallation

To remove the service, configuration, and all installed files:

```bash
twilight remove
```

## Day/Night Wallpapers

**Note:** twilight does not manage wallpapers, as KDE Plasma 6 handles day/night wallpaper switching natively through dynamic wallpapers.

To set up automatic day/night wallpaper switching:

1. **Create a wallpaper folder** in `~/.local/share/wallpapers/` with the following structure (Replace `WALLPAPER_NAME` with the name you want):

```
~/.local/share/wallpapers/WALLPAPER_NAME/
├── metadata.json
└── contents/
    ├── images/          # Day wallpapers
    │   ├── 1440x2960.png
    │   ├── 5120x2880.png
    │   └── 7680x2160.png
    └── images_dark/     # Night wallpapers
        ├── 1440x2960.png
        ├── 5120x2880.png
        └── 7680x2160.png
```

2. **Create the `metadata.json` file** (Make sure the Id field is one word with no spaces):

```json
{
    "KPlugin": {
        "Authors": [
            {
            }
        ],
        "Id": "WALLPAPER_NAME",
        "License": "CC-BY-SA-4.0",
        "Name": "WALLPAPER_NAME"
    }
}
```

3. **Add your wallpaper images:**
   - Place day wallpapers in `contents/images/`
   - Place night wallpapers in `contents/images_dark/`
   - Name each file by its resolution (e.g., `1440x2960.png`)
   - KDE will automatically select the appropriate resolution for each display

4. **Select the wallpaper:**
   - Open System Settings > Wallpaper
   - Your new wallpaper should appear in the list
   - Select it to enable automatic day/night switching
   - Ensure **Switch dynamic wallpapers:** is set to **Based on whether Plasma style is light or dark**

KDE will automatically switch between day and night wallpapers based on your day/night mode settings.
