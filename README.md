# Plasma Day/Night Sync

<div align="center">
  <img src="screenshots/example.gif" width="800" />
</div>

**Plasma Day/Night Sync** is a robust theme switcher for the KDE Plasma desktop environment. It hooks into KDE's built-in Day/Night mode switcher to automatically synchronize theme components that otherwise wouldn't get switched, or that you want to override with different options than the theme provides. Supports Kvantum themes, Plasma styles, window decorations, color schemes, cursor themes, GTK themes, icon sets, Konsole profiles, and custom scripts.

It runs as a background service (systemd user unit) to ensure your desktop experience is consistent whenever you toggle the global theme via Quick Settings or when KDE switches the theme automatically.

## Features

-   **Kvantum Integration:** Automatically switches Kvantum themes (useful for application styling).
-   **Plasma Style Sync:** Switches Plasma desktop themes (panel, widgets appearance).
-   **Window Decorations:** Changes window title bar styles for Day/Night modes.
-   **Color Scheme Sync:** Switches Plasma color schemes for Day/Night modes.
-   **Cursor Theme Sync:** Changes cursor themes for Day/Night modes.
-   **Icon Theme Sync:** Changes icon packs for Day/Night modes.
-   **GTK Theme Sync:** Updates GTK 3/4 themes to match your Plasma preference.
-   **Flatpak Support:** Automatically applies GTK and Kvantum themes to Flatpak apps, with icon support.
-   **Konsole Profiles:** Switches Konsole profiles live for running instances and new windows.
-   **Splash Screen:** Optionally overrides or changes the splash screen.
-   **Custom Scripts:** Run arbitrary scripts when switching to Day or Night mode.
-   **Systemd Service:** Installs a user-level systemd service to watch for changes automatically.
-   **Panel Widget:** Optional Day/Night Toggle widget for your panel.
-   **Keyboard Shortcut:** Toggle themes with Meta+Shift+L (customizable in System Settings > Shortcuts). **Note:** You may need to log out and back in for the shortcut to take effect.

## Requirements

-   **KDE Plasma 6** (uses `kreadconfig6`/`kwriteconfig6`)
-   `inotify-tools`: Required for monitoring configuration changes.
-   `kvantum`: If you want to manage Kvantum themes.
-   `flatpak`: Optional. If installed, GTK/Kvantum themes and icons are automatically applied to Flatpak apps.

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
git clone https://github.com/edmogeor/plasma-daynight-sync.git
cd plasma-daynight-sync && ./plasma-daynight-sync.sh configure
```

The `configure` command will:
-   Scan your system for available themes (Kvantum, Plasma styles, window decorations, color schemes, cursors, icons, GTK, etc.).
-   Ask you to select which ones to use for **Day Mode** and **Night Mode**.
-   Detect your current Plasma Day/Night global themes.
-   Install the script to `~/.local/bin/` (optional).
-   Install the Day/Night Toggle panel widget (optional).
-   Add a keyboard shortcut (Meta+Shift+L) for quick toggling (optional). **Note:** You may need to log out and back in for the shortcut to take effect.
-   Create and enable a systemd user service (`plasma-daynight-sync.service`).

### Partial Re-configuration

You can re-configure specific components without going through the whole wizard:

```bash
./plasma-daynight-sync.sh configure --kvantum      # Only re-configure Kvantum
./plasma-daynight-sync.sh configure --style        # Only re-configure Plasma Style
./plasma-daynight-sync.sh configure --decorations  # Only re-configure Window Decorations
./plasma-daynight-sync.sh configure --colors       # Only re-configure Color Schemes
./plasma-daynight-sync.sh configure --cursors      # Only re-configure Cursors
./plasma-daynight-sync.sh configure --icons        # Only re-configure Icons
./plasma-daynight-sync.sh configure --gtk          # Only re-configure GTK
./plasma-daynight-sync.sh configure --konsole      # Only re-configure Konsole
./plasma-daynight-sync.sh configure --splash       # Only re-configure Splash Screen
./plasma-daynight-sync.sh configure --script       # Only re-configure Custom Scripts
./plasma-daynight-sync.sh configure --widget       # Install/reinstall panel widget
./plasma-daynight-sync.sh configure --shortcut     # Install/reinstall keyboard shortcut
```

## Usage

Once configured and installed, the service runs in the background. You usually don't need to touch it. However, you can use the CLI to manually switch modes or check status.

### Commands

| Command | Description |
| :--- | :--- |
| `plasma-daynight-sync configure` | Run the setup wizard. |
| `plasma-daynight-sync status` | Show the service status and current theme configuration. |
| `plasma-daynight-sync day` | Manually force **Day Mode** (and sync all sub-themes). |
| `plasma-daynight-sync night` | Manually force **Night Mode** (and sync all sub-themes). |
| `plasma-daynight-sync toggle` | Toggle between Day and Night modes (also via Meta+Shift+L). |
| `plasma-daynight-sync remove` | Stop the service and remove all configuration/installed files. |
| `plasma-daynight-sync watch` | Run the monitor in the foreground (used by the service). |

## How it works

1.  The script reads your KDE global configuration to determine your preferred "Day" and "Night" Global Themes (Look and Feel packages).
2.  It uses `inotifywait` to monitor `~/.config/kdeglobals` for changes.
3.  When you switch your Global Theme in System Settings (or via the Quick Settings widget), the script detects the change.
4.  It immediately applies the corresponding Kvantum theme, GTK theme, Icons, etc., that you selected during `configure`.

## Uninstallation

To remove the service and configuration:

```bash
plasma-daynight-sync remove
```

## Day/Night Wallpapers

**Note:** This tool does not manage wallpapers, as KDE Plasma 6 handles day/night wallpaper switching natively through dynamic wallpapers.

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

KDE will automatically switch between day and night wallpapers based on your Day/Night mode settings.
