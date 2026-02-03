# Plasma Day/Night Sync

<div align="center">
  <img src="screenshots/example.gif" width="800" />
</div>

**Plasma Day/Night Sync** is a robust theme switcher for the KDE Plasma desktop environment. It hooks into KDE's built-in Day/Night mode switcher to automatically synchronize theme components that otherwise wouldn't get switched, such as Kvantum themes, GTK themes, Icon sets, Konsole profiles, and even custom scripts.

It runs as a background service (systemd user unit) to ensure your desktop experience is consistent whenever you toggle the global theme via Quick Settings or when KDE switches the theme automatically.

## Features

-   **Kvantum Integration:** Automatically switches Kvantum themes (useful for application styling).
-   **GTK Theme Sync:** Updates GTK 3/4 themes to match your Plasma preference.
-   **Icon Theme Sync:** Changes icon packs for Day/Night modes.
-   **Konsole Profiles:** Switches Konsole profiles live for running instances and new windows.
-   **Splash Screen:** Optionally overrides or changes the splash screen.
-   **Custom Scripts:** Run arbitrary scripts when switching to Day or Night mode.
-   **Systemd Service:** Installs a user-level systemd service to watch for changes automatically.
-   **Panel Widget:** Optional Day/Night Toggle widget for your panel.
-   **Keyboard Shortcut:** Toggle themes with Meta+Shift+L (customizable in System Settings > Shortcuts).

## Requirements

-   **KDE Plasma 6** (uses `kreadconfig6`/`kwriteconfig6`)
-   `inotify-tools`: Required for monitoring configuration changes.
-   `kvantum`: If you want to manage Kvantum themes.

### Optional: Seamless Qt App Refresh

By default, some Qt applications may not refresh their styles until restarted. To enable seamless live refreshing of all Qt apps when switching themes, install the [plasma-qt-forcerefresh](https://github.com/edmogeor/plasma-qt-forcerefresh) patch:

```bash
git clone https://github.com/edmogeor/plasma-qt-forcerefresh.git
cd plasma-qt-forcerefresh && ./plasma-integration-patch-manager.sh install
```

This patches `plasma-integration` to add a DBus signal that forces Qt apps to reload their styles without restarting.

## Installation & Configuration

1.  **Clone or Download** this repository.
2.  **Make the script executable** (optional, the script handles installation):
    ```bash
    chmod +x plasma-daynight-sync.sh
    ```
3.  **Run the configuration wizard**:
    ```bash
    ./plasma-daynight-sync.sh configure
    ```

The `configure` command will:
-   Scan your system for available Kvantum themes, GTK themes, Icons, etc.
-   Ask you to select which ones to use for **Day Mode** and **Night Mode**.
-   Detect your current Plasma Day/Night global themes.
-   Install the script to `~/.local/bin/` (optional).
-   Install the Day/Night Toggle panel widget (optional).
-   Add a keyboard shortcut (Meta+Shift+L) for quick toggling (optional).
-   Create and enable a systemd user service (`plasma-daynight-sync.service`).

### Partial Re-configuration

You can re-configure specific components without going through the whole wizard:

```bash
./plasma-daynight-sync.sh configure --kvantum    # Only re-configure Kvantum
./plasma-daynight-sync.sh configure --icons      # Only re-configure Icons
./plasma-daynight-sync.sh configure --gtk        # Only re-configure GTK
./plasma-daynight-sync.sh configure --konsole    # Only re-configure Konsole
./plasma-daynight-sync.sh configure --script     # Only re-configure Custom Scripts
./plasma-daynight-sync.sh configure --widget     # Install/reinstall panel widget
./plasma-daynight-sync.sh configure --shortcut   # Install/reinstall keyboard shortcut
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
