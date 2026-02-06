<div align="center">
  <h1>gloam</h1>
  <p><b>Syncs Kvantum, GTK, and custom scripts with Plasma 6's native light/dark (day/night) theme switching - and more.</b></p>
  <img src="screenshots/example.gif" width="800" />
</div>

**gloam** solves a common problem in KDE Plasma: **external themes don't switch automatically.**

While Plasma handles its own styling well, components like **Kvantum**, **GTK apps**, **Flatpaks**, and **Konsole** often get left behind when switching between day and night modes.

**gloam** bridges this gap. It hooks into KDE's native day/night transition to instantly synchronize *everything* on your desktop, ensuring a consistent look across all applications.

It can bundle your preferences into custom Plasma Global Themes (for native integration), or simply run alongside your existing setup to handle the external tools that Plasma misses.

## Features

- **Custom Theme Generation:** Bundles your overrides into proper Plasma Global Themes for native switching.
- **Kvantum Integration:** Automatically switches Kvantum themes for application styling.
- **Application Style Sync:** Switches Qt widget styles (Breeze, Fusion, etc.) for light/dark modes.
- **Plasma Style Sync:** Switches Plasma desktop themes (panel, widgets appearance).
- **Window Decorations:** Changes window title bar styles for light/dark modes.
- **Color Scheme Sync:** Switches Plasma color schemes for light/dark modes.
- **Cursor Theme Sync:** Changes cursor themes for light/dark modes.
- **Icon Theme Sync:** Changes icon packs for light/dark modes.
- **GTK Theme Sync:** Updates GTK 3/4 themes to match your Plasma preference.
- **Flatpak Support:** Automatically applies GTK, Kvantum, and icon themes to Flatpak apps.
- **Konsole Profiles:** Switches Konsole profiles live for running instances and new windows.
- **Splash Screen:** Optionally overrides or disables the splash screen.
- **Login Screen (SDDM):** Switches SDDM login screen themes for light/dark modes.
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
git clone https://github.com/edmogeor/gloam.git
cd gloam && ./gloam.sh configure
```

The `configure` command will:
- Scan your system for available themes (Kvantum, application styles, Plasma styles, window decorations, color schemes, cursors, icons, GTK, etc.).
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
gloam configure --kvantum      # Kvantum themes
gloam configure --appstyle     # Application style (Qt widget style)
gloam configure --style        # Plasma styles
gloam configure --decorations  # Window decorations
gloam configure --colors       # Color schemes
gloam configure --cursors      # Cursor themes
gloam configure --icons        # Icon themes
gloam configure --gtk          # GTK themes
gloam configure --konsole      # Konsole profiles
gloam configure --splash       # Splash screen
gloam configure --login        # Login screen (SDDM) themes
gloam configure --script       # Custom scripts
gloam configure --widget       # Panel widget
gloam configure --shortcut     # Keyboard shortcut
```

## Usage

Once configured, the service runs in the background. You usually don't need to touch it. However, you can use the CLI to manually switch modes or check status.

### Commands

| Command | Description |
| :--- | :--- |
| `gloam configure` | Run the setup wizard. |
| `gloam status` | Show the service status and current theme configuration. |
| `gloam light` | Switch to light mode (and sync all sub-themes). |
| `gloam dark` | Switch to dark mode (and sync all sub-themes). |
| `gloam toggle` | Toggle between light and dark modes (also via Meta+Shift+L). |
| `gloam remove` | Stop the service and remove all installed files. |
| `gloam watch` | Run the monitor in the foreground (used by the service). |

## How It Works

1.  **Native Integration (Optional):** If you choose, `gloam` can generate custom Plasma Global Themes containing your choices. These are set as your KDE defaults so Plasma handles the main switch natively.
2.  **Bridging the Gap:** A lightweight background service monitors Plasma's state. When it detects a switch, it instantly applies the "external" settings that Plasma can't touch: changing Kvantum themes, updating GTK configs, reloading Konsole profiles, and running your custom scripts.

## Uninstallation

To remove the service, configuration, and all installed files:

```bash
gloam remove
```

## Day/Night Wallpapers

**Note:** gloam does not manage wallpapers, as KDE Plasma 6 handles day/night wallpaper switching natively through dynamic wallpapers.

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
