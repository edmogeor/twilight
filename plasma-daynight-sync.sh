#!/usr/bin/env bash
#
# plasma-daynight-sync.sh
# Manages the plasma-daynight-sync: a theme switcher for KDE day/night mode.
#   configure [options]  Scan themes, save config, generate watcher script, enable systemd service
#                        Options: -k|--kvantum -i|--icons -g|--gtk -o|--konsole -s|--script -S|--splash -w|--widget -K|--shortcut
#                        With no options, configures all. With options, only reconfigures specified types.
#   uninstall            Stop service, remove all installed files
#   status               Show service status and current configuration

set -euo pipefail

# ANSI Colors
BOLD='\033[1m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
RESET='\033[0m'

KVANTUM_DIR="${HOME}/.config/Kvantum"
CONFIG_FILE="${HOME}/.config/plasma-daynight-sync.conf"
SERVICE_NAME="plasma-daynight-sync"
SERVICE_DIR="${HOME}/.config/systemd/user"
SERVICE_FILE="${SERVICE_DIR}/${SERVICE_NAME}.service"
CLI_PATH="${HOME}/.local/bin/plasma-daynight-sync"
PLASMOID_ID="org.kde.plasma.daynighttoggle"
PLASMOID_INSTALL_DIR="${HOME}/.local/share/plasma/plasmoids/${PLASMOID_ID}"
DESKTOP_FILE="${HOME}/.local/share/applications/plasma-daynight-toggle.desktop"
SHORTCUT_ID="plasma-daynight-toggle.desktop"

get_friendly_name() {
    local type="$1"
    local id="$2"
    [[ -z "$id" ]] && return 0

    case "$type" in
        laf)
            for dir in /usr/share/plasma/look-and-feel "${HOME}/.local/share/plasma/look-and-feel"; do
                if [[ -f "${dir}/${id}/metadata.json" ]] && command -v jq &>/dev/null; then
                    jq -r '.KPlugin.Name // empty' "${dir}/${id}/metadata.json" 2>/dev/null && return 0
                elif [[ -f "${dir}/${id}/metadata.desktop" ]]; then
                    grep -m1 "^Name=" "${dir}/${id}/metadata.desktop" 2>/dev/null | cut -d= -f2 && return 0
                fi
            done
            ;;
        decoration)
            if [[ "$id" == "__aurorae__svg__"* ]]; then
                local theme_name="${id#__aurorae__svg__}"
                for dir in /usr/share/aurorae/themes "${HOME}/.local/share/aurorae/themes"; do
                    if [[ -f "${dir}/${theme_name}/metadata.desktop" ]]; then
                        grep -m1 "^Name=" "${dir}/${theme_name}/metadata.desktop" 2>/dev/null | cut -d= -f2 && return 0
                    fi
                done
                echo "$theme_name" && return 0
            elif [[ "$id" == "org.kde.breeze" ]]; then echo "Breeze" && return 0
            elif [[ "$id" == "org.kde.oxygen" ]]; then echo "Oxygen" && return 0
            elif [[ "$id" == "org.kde.plastik" ]]; then echo "Plastik" && return 0
            elif [[ "$id" == "org.kde.kwin.aurorae" ]]; then echo "Aurorae" && return 0
            fi
            ;;
        splash)
            [[ "$id" == "None" ]] && echo "None" && return 0
            for dir in /usr/share/plasma/look-and-feel "${HOME}/.local/share/plasma/look-and-feel"; do
                if [[ -f "${dir}/${id}/metadata.json" ]] && command -v jq &>/dev/null; then
                    jq -r '.KPlugin.Name // empty' "${dir}/${id}/metadata.json" 2>/dev/null && return 0
                elif [[ -f "${dir}/${id}/metadata.desktop" ]]; then
                    grep -m1 "^Name=" "${dir}/${id}/metadata.desktop" 2>/dev/null | cut -d= -f2 && return 0
                fi
            done
            ;;
    esac
    echo "$id"
}

show_laf_reminder() {
    echo -e "${YELLOW}Reminder:${RESET} Make sure your Day and Night themes are set to your preferred themes."
    echo "You can set them in: System Settings > Quick Settings"
    echo ""
}

scan_kvantum_themes() {
    local themes=()
    for dir in /usr/share/Kvantum "$KVANTUM_DIR"; do
        for kvconfig in "$dir"/*/*.kvconfig; do
            [[ -f "$kvconfig" ]] || continue
            themes+=("$(basename "$kvconfig" .kvconfig)")
        done
    done
    # Deduplicate and sort
    printf '%s\n' "${themes[@]}" | sort -u
}

scan_icon_themes() {
    local themes=()
    for dir in /usr/share/icons "${HOME}/.local/share/icons" "${HOME}/.icons"; do
        [[ -d "$dir" ]] || continue
        for theme_dir in "$dir"/*/; do
            [[ -f "${theme_dir}index.theme" ]] || continue
            # Exclude cursor-only themes
            [[ -d "${theme_dir}cursors" && ! -d "${theme_dir}actions" && ! -d "${theme_dir}apps" ]] && continue
            themes+=("$(basename "$theme_dir")")
        done
    done
    # Deduplicate and sort
    printf '%s\n' "${themes[@]}" | sort -u
}

scan_cursor_themes() {
    local themes=()
    for dir in /usr/share/icons "${HOME}/.local/share/icons" "${HOME}/.icons"; do
        [[ -d "$dir" ]] || continue
        for theme_dir in "$dir"/*/; do
            [[ -d "${theme_dir}cursors" ]] || continue
            themes+=("$(basename "$theme_dir")")
        done
    done
    # Deduplicate and sort
    printf '%s\n' "${themes[@]}" | sort -u
}

scan_window_decorations() {
    local seen_ids=""
    # Aurorae themes
    for dir in /usr/share/aurorae/themes "${HOME}/.local/share/aurorae/themes"; do
        [[ -d "$dir" ]] || continue
        for theme_dir in "$dir"/*/; do
            [[ -f "${theme_dir}metadata.desktop" || -f "${theme_dir}aurorae.theme" ]] || continue
            local id name
            id="__aurorae__svg__$(basename "$theme_dir")"
            [[ "$seen_ids" == *"|$id|"* ]] && continue
            seen_ids+="|$id|"
            
            # Use centralized function for name
            name=$(get_friendly_name decoration "$id")
            printf '%s|%s\n' "$id" "$name"
        done
    done
    # Built-in decorations (check if plugin exists)
    for plugin_dir in /usr/lib/qt6/plugins/org.kde.kdecoration2 /usr/lib64/qt6/plugins/org.kde.kdecoration2 /usr/lib/x86_64-linux-gnu/qt6/plugins/org.kde.kdecoration2; do
        [[ -d "$plugin_dir" ]] || continue
        [[ -f "$plugin_dir/org.kde.breeze.so" || -f "$plugin_dir/breeze.so" ]] && printf '%s|%s\n' "org.kde.breeze" "$(get_friendly_name decoration "org.kde.breeze")"
        [[ -f "$plugin_dir/org.kde.oxygen.so" || -f "$plugin_dir/oxygen.so" ]] && printf '%s|%s\n' "org.kde.oxygen" "$(get_friendly_name decoration "org.kde.oxygen")"
        [[ -f "$plugin_dir/org.kde.plastik.so" || -f "$plugin_dir/plastik.so" ]] && printf '%s|%s\n' "org.kde.plastik" "$(get_friendly_name decoration "org.kde.plastik")"
        [[ -f "$plugin_dir/org.kde.kwin.aurorae.so" || -f "$plugin_dir/kwin_aurorae.so" ]] && printf '%s|%s\n' "org.kde.kwin.aurorae" "$(get_friendly_name decoration "org.kde.kwin.aurorae")"
        break
    done
}


scan_gtk_themes() {
    local themes=()
    for dir in /usr/share/themes "${HOME}/.themes" "${HOME}/.local/share/themes"; do
        [[ -d "$dir" ]] || continue
        for theme_dir in "$dir"/*/; do
            # Check for gtk-3.0 or gtk-4.0 directory
            if [[ -d "${theme_dir}gtk-3.0" || -d "${theme_dir}gtk-4.0" ]]; then
                themes+=("$(basename "$theme_dir")")
            fi
        done
    done
    # Deduplicate and sort
    printf '%s\n' "${themes[@]}" | sort -u
}

scan_konsole_profiles() {
    local profiles=()
    for dir in /usr/share/konsole "${HOME}/.local/share/konsole"; do
        [[ -d "$dir" ]] || continue
        for profile in "$dir"/*.profile; do
            [[ -f "$profile" ]] || continue
            profiles+=("$(basename "$profile" .profile)")
        done
    done
    # Deduplicate and sort
    printf '%s\n' "${profiles[@]}" | sort -u
}

scan_splash_themes() {
    local seen_ids=""
    for dir in /usr/share/plasma/look-and-feel "${HOME}/.local/share/plasma/look-and-feel"; do
        [[ -d "$dir" ]] || continue
        for theme_dir in "$dir"/*/; do
            [[ -d "${theme_dir}contents/splash" ]] || continue
            local id name
            id="$(basename "$theme_dir")"
            # Skip if already seen (user themes override system)
            [[ "$seen_ids" == *"|$id|"* ]] && continue
            seen_ids+="|$id|"
            
            # Use centralized function for name
            name=$(get_friendly_name splash "$id")
            printf '%s|%s\n' "$id" "$name"
        done
    done | sort -t'|' -k2
}

scan_color_schemes() {
    local schemes=()
    for dir in /usr/share/color-schemes "${HOME}/.local/share/color-schemes" /run/current-system/profile/share/color-schemes; do
        [[ -d "$dir" ]] || continue
        for scheme in "$dir"/*.colors; do
            [[ -f "$scheme" ]] || continue
            schemes+=("$(basename "$scheme" .colors)")
        done
    done
    # Deduplicate and sort
    printf '%s\n' "${schemes[@]}" | sort -u
}

scan_plasma_styles() {
    local styles=()
    for dir in /usr/share/plasma/desktoptheme "${HOME}/.local/share/plasma/desktoptheme"; do
        [[ -d "$dir" ]] || continue
        for style_dir in "$dir"/*/; do
            [[ -f "${style_dir}metadata.json" || -f "${style_dir}metadata.desktop" ]] || continue
            styles+=("$(basename "$style_dir")")
        done
    done
    # Deduplicate and sort
    printf '%s\n' "${styles[@]}" | sort -u
}

install_plasmoid() {
    local script_dir
    script_dir="$(dirname "$(readlink -f "$0")")"
    local plasmoid_src="${script_dir}/plasmoid"

    if [[ ! -d "$plasmoid_src" ]]; then
        echo -e "${RED}Error: Plasmoid source not found at $plasmoid_src${RESET}" >&2
        return 1
    fi

    mkdir -p "$PLASMOID_INSTALL_DIR"
    cp -r "$plasmoid_src"/* "$PLASMOID_INSTALL_DIR/"
    echo -e "${GREEN}Installed Day/Night Toggle widget to $PLASMOID_INSTALL_DIR${RESET}"
    echo "You can add it to your panel by right-clicking the panel > Add Widgets > Day/Night Toggle"
}

remove_plasmoid() {
    if [[ -d "$PLASMOID_INSTALL_DIR" ]]; then
        rm -rf "$PLASMOID_INSTALL_DIR"
        echo "Removed Day/Night Toggle widget"
    fi
}

install_shortcut() {
    # Create .desktop file for the toggle command (appears in Commands section of System Settings > Shortcuts)
    mkdir -p "$(dirname "$DESKTOP_FILE")"
    cat > "$DESKTOP_FILE" <<EOF
[Desktop Entry]
Type=Application
Name=Toggle Day/Night Theme
Exec=plasma-daynight-sync toggle
NoDisplay=true
StartupNotify=false
X-KDE-GlobalAccel-CommandShortcut=true
EOF

    # Register the shortcut with KDE (Meta+Shift+L)
    kwriteconfig6 --file kglobalshortcutsrc --group "services" --group "$SHORTCUT_ID" --key "_launch" "Meta+Shift+L"

    echo -e "${GREEN}Keyboard shortcut installed: Meta+Shift+L${RESET}"
    echo "You can change it in System Settings > Shortcuts > Commands"
}

remove_shortcut() {
    if [[ -f "$DESKTOP_FILE" ]]; then
        rm -f "$DESKTOP_FILE"
        echo "Removed shortcut desktop file"
    fi
    # Remove from kglobalshortcutsrc
    if grep -q "$SHORTCUT_ID" "${HOME}/.config/kglobalshortcutsrc" 2>/dev/null; then
        kwriteconfig6 --file kglobalshortcutsrc --group "services" --group "$SHORTCUT_ID" --key "_launch" --delete
        echo "Removed keyboard shortcut"
    fi
}

cleanup_stale() {
    local dirty=0
    if systemctl --user is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        systemctl --user stop "$SERVICE_NAME"
        dirty=1
    fi
    if systemctl --user is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then
        systemctl --user disable "$SERVICE_NAME"
        dirty=1
    fi
    [[ -f "$SERVICE_FILE" ]] && rm "$SERVICE_FILE" && dirty=1
    [[ -f "$CONFIG_FILE" ]] && rm "$CONFIG_FILE" && dirty=1
    if [[ "$dirty" -eq 1 ]]; then
        systemctl --user daemon-reload
        echo -e "${GREEN}Cleaned up previous installation.${RESET}"
        echo ""
    fi
}

check_desktop_environment() {
    if [[ "$XDG_CURRENT_DESKTOP" != *"KDE"* ]]; then
        echo -e "${RED}Error: This script requires KDE Plasma desktop environment.${RESET}" >&2
        exit 1
    fi
}

check_dependencies() {
    local missing=()
    command -v inotifywait &>/dev/null || missing+=("inotify-tools")

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo -e "${RED}Error: Missing dependencies:${RESET}" >&2
        printf '  - %s\n' "${missing[@]}" >&2
        exit 1
    fi
}

get_laf() {
    kreadconfig6 --file kdeglobals --group KDE --key LookAndFeelPackage
}

reload_laf_config() {
    LAF_DAY=$(kreadconfig6 --file kdeglobals --group KDE --key DefaultLightLookAndFeel)
    LAF_NIGHT=$(kreadconfig6 --file kdeglobals --group KDE --key DefaultDarkLookAndFeel)
    # Silent reload as per request
}

apply_browser_color_scheme() {
    local mode="$1"  # 'day' or 'night'
    local color_scheme portal_value

    if [[ "$mode" == "night" ]]; then
        color_scheme="prefer-dark"
        portal_value=1
    else
        color_scheme="prefer-light"
        portal_value=0
    fi

    # Set gsettings color-scheme (browsers poll this)
    if command -v gsettings &>/dev/null; then
        gsettings set org.gnome.desktop.interface color-scheme "$color_scheme" 2>/dev/null || true
    fi

    # Emit XDG Desktop Portal signal for instant browser notification
    dbus-send --session --type=signal \
        /org/freedesktop/portal/desktop \
        org.freedesktop.portal.Settings.SettingChanged \
        string:'org.freedesktop.appearance' \
        string:'color-scheme' \
        "variant:uint32:$portal_value" 2>/dev/null || true
}

apply_flatpak_theme() {
    local theme="$1"
    command -v flatpak &>/dev/null || return 0
    flatpak override --user --env=GTK_THEME="$theme" 2>/dev/null || true
}

apply_flatpak_icons() {
    local icons="$1"
    command -v flatpak &>/dev/null || return 0
    flatpak override --user --env=GTK_ICON_THEME="$icons" 2>/dev/null || true
}

get_current_icon_theme() {
    kreadconfig6 --file kdeglobals --group Icons --key Theme 2>/dev/null
}

setup_flatpak_permissions() {
    command -v flatpak &>/dev/null || return 0
    flatpak override --user \
        --filesystem=~/.themes:ro \
        --filesystem=~/.local/share/themes:ro \
        --filesystem=~/.icons:ro \
        --filesystem=~/.local/share/icons:ro \
        --filesystem=xdg-config/Kvantum:ro \
        2>/dev/null || true
}

setup_flatpak_kvantum() {
    command -v flatpak &>/dev/null || return 0
    flatpak override --user --env=QT_STYLE_OVERRIDE=kvantum 2>/dev/null || true
}


apply_gtk_theme() {
    local theme="$1"

    # Update GTK 3 settings
    mkdir -p "${HOME}/.config/gtk-3.0"
    sed -i "s/^gtk-theme-name=.*/gtk-theme-name=$theme/" "${HOME}/.config/gtk-3.0/settings.ini" 2>/dev/null || \
        echo -e "[Settings]\ngtk-theme-name=$theme" >> "${HOME}/.config/gtk-3.0/settings.ini"
    # Update GTK 4 settings
    mkdir -p "${HOME}/.config/gtk-4.0"
    sed -i "s/^gtk-theme-name=.*/gtk-theme-name=$theme/" "${HOME}/.config/gtk-4.0/settings.ini" 2>/dev/null || \
        echo -e "[Settings]\ngtk-theme-name=$theme" >> "${HOME}/.config/gtk-4.0/settings.ini"
    # Update via gsettings if available
    command -v gsettings &>/dev/null && gsettings set org.gnome.desktop.interface gtk-theme "$theme" 2>/dev/null || true

    # Update xsettingsd if present (X11 fallback)
    if [[ -f "${HOME}/.config/xsettingsd/xsettingsd.conf" ]]; then
        sed -i "s/Net\/ThemeName \".*\"/Net\/ThemeName \"$theme\"/" "${HOME}/.config/xsettingsd/xsettingsd.conf" 2>/dev/null || true
        pkill -HUP xsettingsd 2>/dev/null || true
    fi

    # Update Flatpak GTK theme
    apply_flatpak_theme "$theme"
}

apply_konsole_profile() {
    local profile="$1"
    # 1. Set default for new windows (requires filename with extension)
    kwriteconfig6 --file konsolerc --group "Desktop Entry" --key DefaultProfile "$profile.profile"

    # 2. Live update running instances (requires profile name without extension)
    local qdbus_cmd
    if command -v qdbus6 &>/dev/null; then
        qdbus_cmd="qdbus6"
    elif command -v qdbus &>/dev/null; then
        qdbus_cmd="qdbus"
    else
        return 0
    fi

    for instance in $($qdbus_cmd | grep -E 'org\.kde\.konsole|org\.kde\.yakuake'); do
        # Update each session
        for session in $($qdbus_cmd "$instance" | grep -E '^/Sessions/'); do
            $qdbus_cmd "$instance" "$session" org.kde.konsole.Session.setProfile "$profile" >/dev/null 2>&1 || true
        done

        # Update each window's default profile
        for window in $($qdbus_cmd "$instance" | grep -E '^/Windows/'); do
            $qdbus_cmd "$instance" "$window" org.kde.konsole.Window.setDefaultProfile "$profile" >/dev/null 2>&1 || true
        done
    done
}

apply_splash() {
    local splash="$1"
    if [[ -n "$splash" ]]; then
        # Delay to let KDE finish applying LookAndFeel (which overwrites ksplashrc)
        sleep 1.5
        # When "None" is selected, set Engine to "none" first to disable splash screen
        # (otherwise KDE uses KSplashQML which still shows a splash)
        if [[ "$splash" == "None" ]]; then
            kwriteconfig6 --file ksplashrc --group KSplash --key Engine "none"
            kwriteconfig6 --file ksplashrc --group KSplash --key Theme "None"
        else
            kwriteconfig6 --file ksplashrc --group KSplash --key Theme "$splash"
            kwriteconfig6 --file ksplashrc --group KSplash --key Engine "KSplashQML"
        fi
    fi
}

apply_color_scheme() {
    local scheme="$1"
    plasma-apply-colorscheme "$scheme" >/dev/null 2>&1 || true
}

apply_plasma_style() {
    local style="$1"
    plasma-apply-desktoptheme "$style" >/dev/null 2>&1 || true
}

apply_cursor_theme() {
    local theme="$1"
    plasma-apply-cursortheme "$theme" >/dev/null 2>&1 || true
}

apply_window_decoration() {
    local decoration="$1"
    kwriteconfig6 --file kwinrc --group org.kde.kdecoration2 --key theme "$decoration"
    # Reconfigure KWin to apply the change
    if command -v qdbus6 &>/dev/null; then
        qdbus6 org.kde.KWin /KWin reconfigure >/dev/null 2>&1 || true
    elif command -v qdbus &>/dev/null; then
        qdbus org.kde.KWin /KWin reconfigure >/dev/null 2>&1 || true
    fi
}


update_laf_icons() {
    local laf="$1"
    local icon_theme="$2"
    local defaults_file=""

    # Find the defaults file for this look-and-feel
    for dir in "${HOME}/.local/share/plasma/look-and-feel" "/usr/share/plasma/look-and-feel"; do
        if [[ -f "${dir}/${laf}/contents/defaults" ]]; then
            defaults_file="${dir}/${laf}/contents/defaults"
            break
        fi
    done

    if [[ -z "$defaults_file" ]]; then
        echo "Warning: Could not find defaults file for $laf" >&2
        return 1
    fi

    # Check if we need to copy to user directory (if it's a system file)
    if [[ "$defaults_file" == /usr/* ]]; then
        local friendly_name
        friendly_name=$(get_friendly_name laf "$laf")
        echo -e "  ${YELLOW}!${RESET} ${BOLD}$friendly_name${RESET} ($laf) is a system theme; creating local copy in ~/.local for overrides..."
        local system_laf_root="/usr/share/plasma/look-and-feel/${laf}"
        local laf_root="${HOME}/.local/share/plasma/look-and-feel/${laf}"

        # Copy entire theme directory
        mkdir -p "$(dirname "$laf_root")"
        cp -r "$system_laf_root" "$laf_root"

        # Add managed flag so we can safely delete this on removal
        touch "${laf_root}/.sync_managed"

        defaults_file="${laf_root}/contents/defaults"
    fi

    # Backup the defaults file if not already backed up
    if [[ ! -f "${defaults_file}.bak" ]]; then
        cp "$defaults_file" "${defaults_file}.bak"
    fi

    # Update the icon theme
    kwriteconfig6 --file "$defaults_file" --group kdeglobals --group Icons --key Theme "$icon_theme"
}

refresh_kvantum_style() {
    local style="$1"
    kwriteconfig6 --file kdeglobals --group KDE --key widgetStyle "$style"
}

apply_theme() {
    local laf="$1"
    if [[ "$laf" == "$LAF_NIGHT" ]]; then
        if [[ -n "$KVANTUM_NIGHT" ]]; then
            kvantummanager --set "$KVANTUM_NIGHT"
            refresh_kvantum_style "kvantum-dark"
        fi
        [[ -n "$ICON_NIGHT" && -n "$PLASMA_CHANGEICONS" ]] && "$PLASMA_CHANGEICONS" "$ICON_NIGHT"
        [[ -n "$GTK_NIGHT" ]] && apply_gtk_theme "$GTK_NIGHT"
        # Apply Flatpak icons (use configured icons, or fall back to theme default)
        if [[ -n "$GTK_NIGHT" ]]; then
            if [[ -n "$ICON_NIGHT" ]]; then
                apply_flatpak_icons "$ICON_NIGHT"
            else
                apply_flatpak_icons "$(get_current_icon_theme)"
            fi
        fi
        [[ -n "$COLOR_NIGHT" ]] && apply_color_scheme "$COLOR_NIGHT"
        [[ -n "$STYLE_NIGHT" ]] && apply_plasma_style "$STYLE_NIGHT"
        [[ -n "$DECORATION_NIGHT" ]] && apply_window_decoration "$DECORATION_NIGHT"
        [[ -n "$CURSOR_NIGHT" ]] && apply_cursor_theme "$CURSOR_NIGHT"
        [[ -n "$KONSOLE_NIGHT" ]] && apply_konsole_profile "$KONSOLE_NIGHT"
        apply_splash "$SPLASH_NIGHT"
        apply_browser_color_scheme "night"
        [[ -n "$SCRIPT_NIGHT" && -x "$SCRIPT_NIGHT" ]] && "$SCRIPT_NIGHT"
        dbus-send --session --type=signal /KGlobalSettings org.kde.KGlobalSettings.forceRefresh
        echo "night" > "${XDG_RUNTIME_DIR}/plasma-daynight-mode"
        echo "[$(date)] Switched to 🌙 NIGHT mode"
    elif [[ "$laf" == "$LAF_DAY" ]]; then
        if [[ -n "$KVANTUM_DAY" ]]; then
            kvantummanager --set "$KVANTUM_DAY"
            refresh_kvantum_style "kvantum"
        fi
        [[ -n "$ICON_DAY" && -n "$PLASMA_CHANGEICONS" ]] && "$PLASMA_CHANGEICONS" "$ICON_DAY"
        [[ -n "$GTK_DAY" ]] && apply_gtk_theme "$GTK_DAY"
        # Apply Flatpak icons (use configured icons, or fall back to theme default)
        if [[ -n "$GTK_DAY" ]]; then
            if [[ -n "$ICON_DAY" ]]; then
                apply_flatpak_icons "$ICON_DAY"
            else
                apply_flatpak_icons "$(get_current_icon_theme)"
            fi
        fi
        [[ -n "$COLOR_DAY" ]] && apply_color_scheme "$COLOR_DAY"
        [[ -n "$STYLE_DAY" ]] && apply_plasma_style "$STYLE_DAY"
        [[ -n "$DECORATION_DAY" ]] && apply_window_decoration "$DECORATION_DAY"
        [[ -n "$CURSOR_DAY" ]] && apply_cursor_theme "$CURSOR_DAY"
        [[ -n "$KONSOLE_DAY" ]] && apply_konsole_profile "$KONSOLE_DAY"
        apply_splash "$SPLASH_DAY"
        apply_browser_color_scheme "day"
        [[ -n "$SCRIPT_DAY" && -x "$SCRIPT_DAY" ]] && "$SCRIPT_DAY"
        dbus-send --session --type=signal /KGlobalSettings org.kde.KGlobalSettings.forceRefresh
        echo "day" > "${XDG_RUNTIME_DIR}/plasma-daynight-mode"
        echo "[$(date)] Switched to ☀️ DAY mode"
    else
        echo "[$(date)] Unknown LookAndFeel: $laf — skipping"
    fi
}

do_watch() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo "Error: No config found at $CONFIG_FILE. Run configure first." >&2
        exit 1
    fi
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"

    if ! command -v inotifywait &>/dev/null; then
        echo "Error: inotifywait not found. Install inotify-tools." >&2
        exit 1
    fi

    PREV_LAF=$(get_laf)
    apply_theme "$PREV_LAF"

    inotifywait -m -e moved_to "${HOME}/.config" --include 'kdeglobals' |
    while read -r; do
        reload_laf_config
        laf=$(get_laf)
        if [[ "$laf" != "$PREV_LAF" ]]; then
            apply_theme "$laf"
            PREV_LAF="$laf"
        fi
    done
}

load_config_strict() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo -e "${RED}Error: No config found at $CONFIG_FILE. Run configure first.${RESET}" >&2
        exit 1
    fi
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
}

do_day() {
    [[ -z "${LAF_DAY:-}" ]] && load_config_strict
    # Save auto mode state before plasma-apply-lookandfeel disables it
    local auto_mode
    auto_mode=$(kreadconfig6 --file kdeglobals --group KDE --key AutomaticLookAndFeel)

    local friendly_name
    friendly_name=$(get_friendly_name laf "$LAF_DAY")
    echo -e "Switching to ☀️ Day theme: ${BOLD}$friendly_name${RESET} ($LAF_DAY)"
    plasma-apply-lookandfeel -a "$LAF_DAY"

    # Restore auto mode if it was enabled
    if [[ "$auto_mode" == "true" ]]; then
        kwriteconfig6 --file kdeglobals --group KDE --key AutomaticLookAndFeel true
    fi

    # If watcher is not running, manually sync sub-themes
    if ! systemctl --user is-active --quiet "$SERVICE_NAME"; then
         apply_theme "$LAF_DAY"
    fi
}

do_night() {
    [[ -z "${LAF_NIGHT:-}" ]] && load_config_strict
    # Save auto mode state before plasma-apply-lookandfeel disables it
    local auto_mode
    auto_mode=$(kreadconfig6 --file kdeglobals --group KDE --key AutomaticLookAndFeel)

    local friendly_name
    friendly_name=$(get_friendly_name laf "$LAF_NIGHT")
    echo -e "Switching to 🌙 Night theme: ${BOLD}$friendly_name${RESET} ($LAF_NIGHT)"
    plasma-apply-lookandfeel -a "$LAF_NIGHT"

    # Restore auto mode if it was enabled
    if [[ "$auto_mode" == "true" ]]; then
        kwriteconfig6 --file kdeglobals --group KDE --key AutomaticLookAndFeel true
    fi

    # If watcher is not running, manually sync sub-themes
    if ! systemctl --user is-active --quiet "$SERVICE_NAME"; then
         apply_theme "$LAF_NIGHT"
    fi
}

do_toggle() {
    load_config_strict
    local current_laf
    current_laf=$(kreadconfig6 --file kdeglobals --group KDE --key LookAndFeelPackage)

    if [[ "$current_laf" == "$LAF_NIGHT" ]]; then
        do_day
    else
        do_night
    fi
}

clean_app_overrides() {
    # Silently remove app-specific theme overrides so they follow the global theme
    # Keys: ColorScheme (Dolphin/Gwenview), Color Theme (Kate/KWrite)
    while read -r file; do
        [[ -f "$file" ]] || continue
        local filename=$(basename "$file")
        [[ "$filename" == "kdeglobals" || "$filename" == "plasma-daynight-sync.conf" ]] && continue
        if grep -qE "^(ColorScheme|Color Theme)=" "$file" 2>/dev/null; then
            sed -i -E '/^(ColorScheme|Color Theme)=/d' "$file"
        fi
    done < <(find "${HOME}/.config" -maxdepth 1 -type f)
}

get_other_users() {
    # Get list of regular users (UID >= 1000, excluding current user and nobody)
    while IFS=: read -r username _ uid _ _ home _; do
        [[ "$uid" -ge 1000 && "$uid" -lt 65534 && "$username" != "$USER" && -d "$home" ]] || continue
        echo "$username:$home"
    done < /etc/passwd
}

apply_to_other_users() {
    local users
    mapfile -t users < <(get_other_users)

    if [[ ${#users[@]} -eq 0 ]]; then
        echo "No other users found on the system."
        return 0
    fi

    # Check if we have sudo access
    if ! sudo -n true 2>/dev/null; then
        # Try to get sudo access
        if ! sudo true 2>/dev/null; then
            echo ""
            echo -e "${YELLOW}Could not obtain sudo access.${RESET}"
            echo "To apply settings to all users, run:"
            echo -e "  ${BOLD}sudo plasma-daynight-sync configure --all-users${RESET}"
            return 1
        fi
    fi

    echo ""
    echo -e "${BLUE}Applying settings to all users...${RESET}"

    for user_entry in "${users[@]}"; do
        local username="${user_entry%%:*}"
        local user_home="${user_entry#*:}"

        echo -e "  Configuring ${BOLD}$username${RESET}..."

        # Copy local themes if needed
        if [[ -n "$KVANTUM_DAY" || -n "$KVANTUM_NIGHT" ]]; then
            for theme in "$KVANTUM_DAY" "$KVANTUM_NIGHT"; do
                [[ -z "$theme" ]] && continue
                if [[ -d "${HOME}/.config/Kvantum/$theme" ]]; then
                    sudo mkdir -p "$user_home/.config/Kvantum" 2>/dev/null
                    sudo cp -r "${HOME}/.config/Kvantum/$theme" "$user_home/.config/Kvantum/" 2>/dev/null
                    sudo chown -R "$username:$username" "$user_home/.config/Kvantum/$theme" 2>/dev/null
                fi
            done
        fi

        # Copy local icon themes if needed
        for theme in "$ICON_DAY" "$ICON_NIGHT" "$CURSOR_DAY" "$CURSOR_NIGHT"; do
            [[ -z "$theme" ]] && continue
            for src_dir in "${HOME}/.local/share/icons" "${HOME}/.icons"; do
                if [[ -d "$src_dir/$theme" ]]; then
                    sudo mkdir -p "$user_home/.local/share/icons" 2>/dev/null
                    sudo cp -r "$src_dir/$theme" "$user_home/.local/share/icons/" 2>/dev/null
                    sudo chown -R "$username:$username" "$user_home/.local/share/icons/$theme" 2>/dev/null
                    break
                fi
            done
        done

        # Copy local GTK themes if needed
        for theme in "$GTK_DAY" "$GTK_NIGHT"; do
            [[ -z "$theme" ]] && continue
            for src_dir in "${HOME}/.themes" "${HOME}/.local/share/themes"; do
                if [[ -d "$src_dir/$theme" ]]; then
                    sudo mkdir -p "$user_home/.local/share/themes" 2>/dev/null
                    sudo cp -r "$src_dir/$theme" "$user_home/.local/share/themes/" 2>/dev/null
                    sudo chown -R "$username:$username" "$user_home/.local/share/themes/$theme" 2>/dev/null
                    break
                fi
            done
        done

        # Copy the config file
        sudo cp "$CONFIG_FILE" "$user_home/.config/plasma-daynight-sync.conf" 2>/dev/null
        sudo chown "$username:$username" "$user_home/.config/plasma-daynight-sync.conf" 2>/dev/null

        # Set the Day/Night themes in KDE settings
        local laf_day laf_night
        laf_day=$(kreadconfig6 --file kdeglobals --group KDE --key DefaultLightLookAndFeel)
        laf_night=$(kreadconfig6 --file kdeglobals --group KDE --key DefaultDarkLookAndFeel)
        if [[ -n "$laf_day" ]]; then
            sudo -u "$username" kwriteconfig6 --file kdeglobals --group KDE --key DefaultLightLookAndFeel "$laf_day" 2>/dev/null || true
        fi
        if [[ -n "$laf_night" ]]; then
            sudo -u "$username" kwriteconfig6 --file kdeglobals --group KDE --key DefaultDarkLookAndFeel "$laf_night" 2>/dev/null || true
        fi
        # Enable automatic theme switching
        sudo -u "$username" kwriteconfig6 --file kdeglobals --group KDE --key AutomaticLookAndFeel true 2>/dev/null || true

        # Copy the script if installed globally
        if [[ -f "$CLI_PATH" ]]; then
            sudo mkdir -p "$user_home/.local/bin" 2>/dev/null
            sudo cp "$CLI_PATH" "$user_home/.local/bin/plasma-daynight-sync" 2>/dev/null
            sudo chown "$username:$username" "$user_home/.local/bin/plasma-daynight-sync" 2>/dev/null
        fi

        # Install and enable systemd service for the user
        sudo mkdir -p "$user_home/.config/systemd/user" 2>/dev/null
        sudo mkdir -p "$user_home/.config/systemd/user/default.target.wants" 2>/dev/null

        # Update service file to use the user's path
        local user_service="$user_home/.config/systemd/user/plasma-daynight-sync.service"
        sudo bash -c "cat > '$user_service'" <<EOF
[Unit]
Description=Plasma auto theme watcher (Kvantum switcher)

[Service]
ExecStart=$user_home/.local/bin/plasma-daynight-sync watch
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF
        sudo chown "$username:$username" "$user_service" 2>/dev/null

        # Enable the service by creating symlink
        sudo ln -sf ../plasma-daynight-sync.service "$user_home/.config/systemd/user/default.target.wants/plasma-daynight-sync.service" 2>/dev/null
        sudo chown -h "$username:$username" "$user_home/.config/systemd/user/default.target.wants/plasma-daynight-sync.service" 2>/dev/null

        echo -e "    ${GREEN}✓${RESET} Done"
    done

    echo ""
    echo -e "${GREEN}Settings applied to all users.${RESET}"
}

do_configure() {
    check_desktop_environment
    check_dependencies

    show_laf_reminder

    # Remove app-specific overrides so they follow the global theme
    clean_app_overrides
    echo ""

    # Parse modifiers
    shift # Remove 'configure' from args
    local configure_all=true
    local configure_kvantum=false
    local configure_icons=false
    local configure_gtk=false
    local configure_konsole=false
    local configure_script=false
    local configure_splash=false
    local configure_colors=false
    local configure_style=false
    local configure_decorations=false
    local configure_cursors=false
    local configure_widget=false
    local configure_shortcut=false
    local configure_allusers=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -k|--kvantum)       configure_kvantum=true; configure_all=false ;;
            -i|--icons)         configure_icons=true; configure_all=false ;;
            -g|--gtk)           configure_gtk=true; configure_all=false ;;
            -o|--konsole)       configure_konsole=true; configure_all=false ;;
            -s|--script)        configure_script=true; configure_all=false ;;
            -S|--splash)        configure_splash=true; configure_all=false ;;
            -c|--colors)        configure_colors=true; configure_all=false ;;
            -p|--style)         configure_style=true; configure_all=false ;;
            -d|--decorations)   configure_decorations=true; configure_all=false ;;
            -C|--cursors)       configure_cursors=true; configure_all=false ;;
            -w|--widget)        configure_widget=true; configure_all=false ;;
            -K|--shortcut)      configure_shortcut=true; configure_all=false ;;
            -a|--all-users)     configure_allusers=true ;;
            *)
                echo "Unknown option: $1" >&2
                echo "Options: -k|--kvantum -p|--style -d|--decorations -c|--colors -i|--icons -C|--cursors -g|--gtk -o|--konsole -s|--script -S|--splash -w|--widget -K|--shortcut -a|--all-users" >&2
                exit 1
                ;;
        esac
        shift
    done

    # Load existing config if modifying specific options
    if [[ "$configure_all" == false && -f "$CONFIG_FILE" ]]; then
        # shellcheck source=/dev/null
        source "$CONFIG_FILE"
    elif [[ "$configure_all" == true && -f "$CONFIG_FILE" ]]; then
        echo -e "${YELLOW}Existing configuration found.${RESET}"
        read -rp "Do you want to overwrite it? [y/N]: " choice
        if [[ "$choice" =~ ^[Yy]$ ]]; then
            cleanup_stale
        else
            echo "Use configure options to modify specific settings (e.g. --kvantum, --gtk)."
            echo "Run 'plasma-daynight-sync help' for available options."
            exit 0
        fi
    else
        cleanup_stale
    fi

    # Read day/night themes from KDE Quick Settings configuration
    echo -e "${BLUE}Reading theme configuration from KDE settings...${RESET}"
    local laf_day laf_night
    laf_day=$(kreadconfig6 --file kdeglobals --group KDE --key DefaultLightLookAndFeel)
    laf_night=$(kreadconfig6 --file kdeglobals --group KDE --key DefaultDarkLookAndFeel)
    echo -e "  ☀️ Day theme: ${BOLD}$(get_friendly_name laf "$laf_day")${RESET} ($laf_day)"
    echo -e "  🌙 Night theme:  ${BOLD}$(get_friendly_name laf "$laf_night")${RESET} ($laf_night)"

    if [[ "$laf_day" == "$laf_night" ]]; then
        echo -e "${RED}Error: ☀️ Day and 🌙 Night LookAndFeel are the same ($laf_day).${RESET}" >&2
        echo "Configure different themes in System Settings > Colors & Themes > Global Theme." >&2
        exit 1
    fi

    # Select Kvantum themes
    if [[ "$configure_all" == true || "$configure_kvantum" == true ]]; then
    echo ""
    local choice
    read -rp "Configure Kvantum themes? [y/N]: " choice
    if [[ "$choice" =~ ^[Yy]$ ]]; then
        echo "Scanning for Kvantum themes..."
        mapfile -t themes < <(scan_kvantum_themes)

        if [[ ${#themes[@]} -eq 0 ]]; then
            echo "No Kvantum themes found, skipping."
            KVANTUM_DAY=""
            KVANTUM_NIGHT=""
        else
            echo ""
            echo -e "${BOLD}Available Kvantum themes:${RESET}"
            for i in "${!themes[@]}"; do
                printf "  ${BLUE}%3d)${RESET} %s\n" "$((i + 1))" "${themes[$i]}"
            done

            echo ""
            read -rp "Select ☀️ DAY mode Kvantum theme [1-${#themes[@]}]: " choice
            if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#themes[@]} )); then
                KVANTUM_DAY="${themes[$((choice - 1))]}"

                read -rp "Select 🌙 NIGHT mode Kvantum theme [1-${#themes[@]}]: " choice
                if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#themes[@]} )); then
                    KVANTUM_NIGHT="${themes[$((choice - 1))]}"
                    if command -v flatpak &>/dev/null; then
                        setup_flatpak_permissions
                        setup_flatpak_kvantum
                        echo -e "${YELLOW}Note:${RESET} Flatpak apps may need to be closed and reopened to update theme."
                    fi
                else
                    KVANTUM_DAY=""
                    KVANTUM_NIGHT=""
                fi
            else
                KVANTUM_DAY=""
                KVANTUM_NIGHT=""
            fi
        fi
    else
        KVANTUM_DAY=""
        KVANTUM_NIGHT=""
    fi
    fi

    # Select Plasma Styles
    if [[ "$configure_all" == true || "$configure_style" == true ]]; then
    echo ""
    read -rp "Configure Plasma styles? [y/N]: " choice
    if [[ "$choice" =~ ^[Yy]$ ]]; then
        echo "Scanning for Plasma styles..."
        mapfile -t plasma_styles < <(scan_plasma_styles)

        if [[ ${#plasma_styles[@]} -eq 0 ]]; then
            echo "No Plasma styles found, skipping."
            STYLE_DAY=""
            STYLE_NIGHT=""
        else
            echo ""
            echo -e "${BOLD}Available Plasma styles:${RESET}"
            for i in "${!plasma_styles[@]}"; do
                printf "  ${BLUE}%3d)${RESET} %s\n" "$((i + 1))" "${plasma_styles[$i]}"
            done

            echo ""
            read -rp "Select ☀️ DAY mode Plasma style [1-${#plasma_styles[@]}]: " choice
            if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#plasma_styles[@]} )); then
                STYLE_DAY="${plasma_styles[$((choice - 1))]}"

                read -rp "Select 🌙 NIGHT mode Plasma style [1-${#plasma_styles[@]}]: " choice
                if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#plasma_styles[@]} )); then
                    STYLE_NIGHT="${plasma_styles[$((choice - 1))]}"
                else
                    STYLE_DAY=""
                    STYLE_NIGHT=""
                fi
            else
                STYLE_DAY=""
                STYLE_NIGHT=""
            fi
        fi
    else
        STYLE_DAY=""
        STYLE_NIGHT=""
    fi
    fi

    # Select Window Decorations
    if [[ "$configure_all" == true || "$configure_decorations" == true ]]; then
    echo ""
    read -rp "Configure window decorations? [y/N]: " choice
    if [[ "$choice" =~ ^[Yy]$ ]]; then
        echo "Scanning for window decorations..."
        local decoration_ids=() decoration_names=()
        while IFS='|' read -r id name; do
            decoration_ids+=("$id")
            decoration_names+=("$name")
        done < <(scan_window_decorations)

        if [[ ${#decoration_ids[@]} -eq 0 ]]; then
            echo "No window decorations found, skipping."
            DECORATION_DAY=""
            DECORATION_NIGHT=""
        else
            echo ""
            echo -e "${BOLD}Available window decorations:${RESET}"
            for i in "${!decoration_names[@]}"; do
                printf "  ${BLUE}%3d)${RESET} %s\n" "$((i + 1))" "${decoration_names[$i]}"
            done

            echo ""
            read -rp "Select ☀️ DAY mode window decoration [1-${#decoration_ids[@]}]: " choice
            if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#decoration_ids[@]} )); then
                DECORATION_DAY="${decoration_ids[$((choice - 1))]}"

                read -rp "Select 🌙 NIGHT mode window decoration [1-${#decoration_ids[@]}]: " choice
                if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#decoration_ids[@]} )); then
                    DECORATION_NIGHT="${decoration_ids[$((choice - 1))]}"
                else
                    DECORATION_DAY=""
                    DECORATION_NIGHT=""
                fi
            else
                DECORATION_DAY=""
                DECORATION_NIGHT=""
            fi
        fi
    else
        DECORATION_DAY=""
        DECORATION_NIGHT=""
    fi
    fi

    # Select Color Schemes
    if [[ "$configure_all" == true || "$configure_colors" == true ]]; then
    echo ""
    read -rp "Configure color schemes? [y/N]: " choice
    if [[ "$choice" =~ ^[Yy]$ ]]; then
        echo "Scanning for color schemes..."
        mapfile -t color_schemes < <(scan_color_schemes)

        if [[ ${#color_schemes[@]} -eq 0 ]]; then
            echo "No color schemes found, skipping."
            COLOR_DAY=""
            COLOR_NIGHT=""
        else
            echo ""
            echo -e "${BOLD}Available color schemes:${RESET}"
            for i in "${!color_schemes[@]}"; do
                printf "  ${BLUE}%3d)${RESET} %s\n" "$((i + 1))" "${color_schemes[$i]}"
            done

            echo ""
            read -rp "Select ☀️ DAY mode color scheme [1-${#color_schemes[@]}]: " choice
            if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#color_schemes[@]} )); then
                COLOR_DAY="${color_schemes[$((choice - 1))]}"

                read -rp "Select 🌙 NIGHT mode color scheme [1-${#color_schemes[@]}]: " choice
                if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#color_schemes[@]} )); then
                    COLOR_NIGHT="${color_schemes[$((choice - 1))]}"
                else
                    COLOR_DAY=""
                    COLOR_NIGHT=""
                fi
            else
                COLOR_DAY=""
                COLOR_NIGHT=""
            fi
        fi
    else
        COLOR_DAY=""
        COLOR_NIGHT=""
    fi
    fi

    # Select icon themes
    if [[ "$configure_all" == true || "$configure_icons" == true ]]; then
    echo ""
    read -rp "Configure icon themes? [y/N]: " choice
    if [[ "$choice" =~ ^[Yy]$ ]]; then
        # Check common locations first
        for path in /usr/lib/plasma-changeicons /usr/libexec/plasma-changeicons /usr/lib64/plasma-changeicons; do
            if [[ -x "$path" ]]; then
                PLASMA_CHANGEICONS="$path"
                break
            fi
        done
        # Fallback to find if not found
        if [[ -z "${PLASMA_CHANGEICONS:-}" ]]; then
            PLASMA_CHANGEICONS=$(find /usr/lib /usr/libexec /usr/lib64 -name "plasma-changeicons" -print -quit 2>/dev/null || true)
        fi

        if [[ -z "$PLASMA_CHANGEICONS" ]]; then
            echo "Error: plasma-changeicons not found." >&2
            exit 1
        fi
        echo "Scanning for icon themes..."
        mapfile -t icon_themes < <(scan_icon_themes)

        if [[ ${#icon_themes[@]} -eq 0 ]]; then
            echo "No icon themes found, skipping."
            ICON_DAY=""
            ICON_NIGHT=""
        else
            echo ""
            echo -e "${BOLD}Available icon themes:${RESET}"
            for i in "${!icon_themes[@]}"; do
                printf "  ${BLUE}%3d)${RESET} %s\n" "$((i + 1))" "${icon_themes[$i]}"
            done

            echo ""
            read -rp "Select ☀️ DAY mode icon theme [1-${#icon_themes[@]}]: " choice
            if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#icon_themes[@]} )); then
                ICON_DAY="${icon_themes[$((choice - 1))]}"

                read -rp "Select 🌙 NIGHT mode icon theme [1-${#icon_themes[@]}]: " choice
                if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#icon_themes[@]} )); then
                    ICON_NIGHT="${icon_themes[$((choice - 1))]}"

                    # Offer to update look-and-feel defaults
                    echo ""
                    echo -e "${YELLOW}Note:${RESET} You can embed these icon themes directly into your look-and-feel themes."
                    echo "This means KDE will switch icons automatically, without needing this watcher."
                    echo -e "${YELLOW}Warning:${RESET} This change won't persist if you reinstall/update the themes."
                    read -rp "Update look-and-feel themes with these icon packs? [y/N]: " choice
                    if [[ "$choice" =~ ^[Yy]$ ]]; then
                        update_laf_icons "$laf_day" "$ICON_DAY" && \
                            echo -e "  ${GREEN}✓${RESET} Updated ${BOLD}$(get_friendly_name laf "$laf_day")${RESET} ($laf_day) with $ICON_DAY"
                        update_laf_icons "$laf_night" "$ICON_NIGHT" && \
                            echo -e "  ${GREEN}✓${RESET} Updated ${BOLD}$(get_friendly_name laf "$laf_night")${RESET} ($laf_night) with $ICON_NIGHT"
                        # Clear icon config since LAF will handle it
                        ICON_DAY=""
                        ICON_NIGHT=""
                        PLASMA_CHANGEICONS=""
                        echo "Icon switching will now be handled by the look-and-feel themes."
                    fi
                else
                    ICON_DAY=""
                    ICON_NIGHT=""
                fi
            else
                ICON_DAY=""
                ICON_NIGHT=""
            fi
        fi
    else
        ICON_DAY=""
        ICON_NIGHT=""
        PLASMA_CHANGEICONS=""
    fi
    fi

    # Select Cursor themes
    if [[ "$configure_all" == true || "$configure_cursors" == true ]]; then
    echo ""
    read -rp "Configure cursor themes? [y/N]: " choice
    if [[ "$choice" =~ ^[Yy]$ ]]; then
        echo "Scanning for cursor themes..."
        mapfile -t cursor_themes < <(scan_cursor_themes)

        if [[ ${#cursor_themes[@]} -eq 0 ]]; then
            echo "No cursor themes found, skipping."
            CURSOR_DAY=""
            CURSOR_NIGHT=""
        else
            echo ""
            echo -e "${BOLD}Available cursor themes:${RESET}"
            for i in "${!cursor_themes[@]}"; do
                printf "  ${BLUE}%3d)${RESET} %s\n" "$((i + 1))" "${cursor_themes[$i]}"
            done

            echo ""
            read -rp "Select ☀️ DAY mode cursor theme [1-${#cursor_themes[@]}]: " choice
            if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#cursor_themes[@]} )); then
                CURSOR_DAY="${cursor_themes[$((choice - 1))]}"

                read -rp "Select 🌙 NIGHT mode cursor theme [1-${#cursor_themes[@]}]: " choice
                if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#cursor_themes[@]} )); then
                    CURSOR_NIGHT="${cursor_themes[$((choice - 1))]}"
                else
                    CURSOR_DAY=""
                    CURSOR_NIGHT=""
                fi
            else
                CURSOR_DAY=""
                CURSOR_NIGHT=""
            fi
        fi
    else
        CURSOR_DAY=""
        CURSOR_NIGHT=""
    fi
    fi

    # Select GTK/Flatpak themes
    if [[ "$configure_all" == true || "$configure_gtk" == true ]]; then
    echo ""
    read -rp "Configure GTK/Flatpak themes? [y/N]: " choice
    if [[ "$choice" =~ ^[Yy]$ ]]; then
        echo "Scanning for GTK themes..."
        mapfile -t gtk_themes < <(scan_gtk_themes)

        if [[ ${#gtk_themes[@]} -eq 0 ]]; then
            echo "No GTK themes found, skipping."
            GTK_DAY=""
            GTK_NIGHT=""
        else
            echo ""
            echo -e "${BOLD}Available GTK themes:${RESET}"
            for i in "${!gtk_themes[@]}"; do
                printf "  ${BLUE}%3d)${RESET} %s\n" "$((i + 1))" "${gtk_themes[$i]}"
            done

            echo ""
            read -rp "Select ☀️ DAY mode GTK theme [1-${#gtk_themes[@]}]: " choice
            if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#gtk_themes[@]} )); then
                GTK_DAY="${gtk_themes[$((choice - 1))]}"

                read -rp "Select 🌙 NIGHT mode GTK theme [1-${#gtk_themes[@]}]: " choice
                if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#gtk_themes[@]} )); then
                    GTK_NIGHT="${gtk_themes[$((choice - 1))]}"
                    if command -v flatpak &>/dev/null; then
                        setup_flatpak_permissions
                        echo -e "${YELLOW}Note:${RESET} Flatpak apps may need to be closed and reopened to update theme."
                    fi
                else
                    GTK_DAY=""
                    GTK_NIGHT=""
                fi
            else
                GTK_DAY=""
                GTK_NIGHT=""
            fi
        fi
    else
        GTK_DAY=""
        GTK_NIGHT=""
    fi
    fi

    # Select Konsole profiles
    if [[ "$configure_all" == true || "$configure_konsole" == true ]]; then
    echo ""
    read -rp "Configure Konsole profiles? [y/N]: " choice
    if [[ "$choice" =~ ^[Yy]$ ]]; then
        echo "Scanning for Konsole profiles..."
        mapfile -t konsole_profiles < <(scan_konsole_profiles)

        if [[ ${#konsole_profiles[@]} -eq 0 ]]; then
            echo "No Konsole profiles found, skipping."
            KONSOLE_DAY=""
            KONSOLE_NIGHT=""
        else
            echo ""
            echo -e "${BOLD}Available Konsole profiles:${RESET}"
            for i in "${!konsole_profiles[@]}"; do
                printf "  ${BLUE}%3d)${RESET} %s\n" "$((i + 1))" "${konsole_profiles[$i]}"
            done

            echo ""
            read -rp "Select ☀️ DAY mode Konsole profile [1-${#konsole_profiles[@]}]: " choice
            if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#konsole_profiles[@]} )); then
                KONSOLE_DAY="${konsole_profiles[$((choice - 1))]}"

                read -rp "Select 🌙 NIGHT mode Konsole profile [1-${#konsole_profiles[@]}]: " choice
                if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#konsole_profiles[@]} )); then
                    KONSOLE_NIGHT="${konsole_profiles[$((choice - 1))]}"
                else
                    KONSOLE_DAY=""
                    KONSOLE_NIGHT=""
                fi
            else
                KONSOLE_DAY=""
                KONSOLE_NIGHT=""
            fi
        fi
    else
        KONSOLE_DAY=""
        KONSOLE_NIGHT=""
    fi
    fi

    # Select Splash Screens
    if [[ "$configure_all" == true || "$configure_splash" == true ]]; then
    echo ""
    read -rp "Configure splash screen override? [y/N]: " choice
    if [[ "$choice" =~ ^[Yy]$ ]]; then
        echo "Scanning for splash themes..."
        local splash_ids=() splash_names=()
        while IFS='|' read -r id name; do
            splash_ids+=("$id")
            splash_names+=("$name")
        done < <(scan_splash_themes)

        echo ""
        echo -e "${BOLD}Available splash themes:${RESET}"
        printf "  ${BLUE}%3d)${RESET} %s\n" "0" "None (Disable splash screen)"
        for i in "${!splash_names[@]}"; do
            printf "  ${BLUE}%3d)${RESET} %s\n" "$((i + 1))" "${splash_names[$i]}"
        done

        echo ""
        read -rp "Select ☀️ DAY mode splash theme [0-${#splash_ids[@]}]: " choice
        if [[ "$choice" == "0" ]]; then
            SPLASH_DAY="None"
        elif [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#splash_ids[@]} )); then
            SPLASH_DAY="${splash_ids[$((choice - 1))]}"
        else
            SPLASH_DAY=""
        fi

        read -rp "Select 🌙 NIGHT mode splash theme [0-${#splash_ids[@]}]: " choice
        if [[ "$choice" == "0" ]]; then
            SPLASH_NIGHT="None"
        elif [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#splash_ids[@]} )); then
            SPLASH_NIGHT="${splash_ids[$((choice - 1))]}"
        else
            SPLASH_NIGHT=""
        fi
    else
        SPLASH_DAY=""
        SPLASH_NIGHT=""
    fi
    fi

    # Configure custom scripts
    if [[ "$configure_all" == true || "$configure_script" == true ]]; then
    echo ""
    read -rp "Configure custom scripts? [y/N]: " choice
    if [[ "$choice" =~ ^[Yy]$ ]]; then
        echo ""
        read -rp "Enter ☀️ DAY mode script path (leave empty to skip): " SCRIPT_DAY
        if [[ -n "$SCRIPT_DAY" && ! -x "$SCRIPT_DAY" ]]; then
            echo "Warning: $SCRIPT_DAY is not executable" >&2
        fi

        read -rp "Enter 🌙 NIGHT mode script path (leave empty to skip): " SCRIPT_NIGHT
        if [[ -n "$SCRIPT_NIGHT" && ! -x "$SCRIPT_NIGHT" ]]; then
            echo "Warning: $SCRIPT_NIGHT is not executable" >&2
        fi
    else
        SCRIPT_DAY=""
        SCRIPT_NIGHT=""
    fi
    fi

    # Check if anything was configured
    if [[ -z "$KVANTUM_DAY" && -z "$KVANTUM_NIGHT" && -z "$STYLE_DAY" && -z "$STYLE_NIGHT" && -z "$DECORATION_DAY" && -z "$DECORATION_NIGHT" && -z "$COLOR_DAY" && -z "$COLOR_NIGHT" && -z "$ICON_DAY" && -z "$ICON_NIGHT" && -z "$CURSOR_DAY" && -z "$CURSOR_NIGHT" && -z "$GTK_DAY" && -z "$GTK_NIGHT" && -z "$KONSOLE_DAY" && -z "$KONSOLE_NIGHT" && -z "$SPLASH_DAY" && -z "$SPLASH_NIGHT" && -z "$SCRIPT_DAY" && -z "$SCRIPT_NIGHT" ]]; then
        echo ""
        echo "Nothing to configure. Exiting."
        exit 0
    fi

    echo ""
    echo "Configuration summary:"
    echo -e "☀️ Day theme: ${BOLD}$(get_friendly_name laf "$laf_day")${RESET} ($laf_day)"
    echo "    Kvantum: ${KVANTUM_DAY:-unchanged}"
    echo "    Style: ${STYLE_DAY:-unchanged}"
    echo "    Decorations: $(get_friendly_name decoration "${DECORATION_DAY:-}")"
    echo "    Colors: ${COLOR_DAY:-unchanged}"
    echo "    Icons: ${ICON_DAY:-unchanged}"
    echo "    Cursors: ${CURSOR_DAY:-unchanged}"
    echo "    GTK: ${GTK_DAY:-unchanged}"
    echo "    Konsole: ${KONSOLE_DAY:-unchanged}"
    echo "    Splash: $(get_friendly_name splash "${SPLASH_DAY:-}")"
    echo "    Script: ${SCRIPT_DAY:-unchanged}"
    echo -e "🌙 Night theme:  ${BOLD}$(get_friendly_name laf "$laf_night")${RESET} ($laf_night)"
    echo "    Kvantum: ${KVANTUM_NIGHT:-unchanged}"
    echo "    Style: ${STYLE_NIGHT:-unchanged}"
    echo "    Decorations: $(get_friendly_name decoration "${DECORATION_NIGHT:-}")"
    echo "    Colors: ${COLOR_NIGHT:-unchanged}"
    echo "    Icons: ${ICON_NIGHT:-unchanged}"
    echo "    Cursors: ${CURSOR_NIGHT:-unchanged}"
    echo "    GTK: ${GTK_NIGHT:-unchanged}"
    echo "    Konsole: ${KONSOLE_NIGHT:-unchanged}"
    echo "    Splash: $(get_friendly_name splash "${SPLASH_NIGHT:-}")"
    echo "    Script: ${SCRIPT_NIGHT:-unchanged}"

    cat > "$CONFIG_FILE" <<EOF
LAF_DAY=$laf_day
LAF_NIGHT=$laf_night
KVANTUM_DAY=$KVANTUM_DAY
KVANTUM_NIGHT=$KVANTUM_NIGHT
ICON_DAY=$ICON_DAY
ICON_NIGHT=$ICON_NIGHT
PLASMA_CHANGEICONS=$PLASMA_CHANGEICONS
GTK_DAY=$GTK_DAY
GTK_NIGHT=$GTK_NIGHT
COLOR_DAY=$COLOR_DAY
COLOR_NIGHT=$COLOR_NIGHT
STYLE_DAY=$STYLE_DAY
STYLE_NIGHT=$STYLE_NIGHT
DECORATION_DAY=$DECORATION_DAY
DECORATION_NIGHT=$DECORATION_NIGHT
CURSOR_DAY=$CURSOR_DAY
CURSOR_NIGHT=$CURSOR_NIGHT
KONSOLE_DAY=$KONSOLE_DAY
KONSOLE_NIGHT=$KONSOLE_NIGHT
SPLASH_DAY=$SPLASH_DAY
SPLASH_NIGHT=$SPLASH_NIGHT
SCRIPT_DAY=$SCRIPT_DAY
SCRIPT_NIGHT=$SCRIPT_NIGHT
EOF

    # Install globally?
    local executable_path
    local installed_globally=false

    # Check if already installed globally
    if [[ -x "$CLI_PATH" ]]; then
        installed_globally=true
        executable_path="$CLI_PATH"
    fi

    # Handle widget-only or shortcut-only configuration
    if [[ "$configure_widget" == true || "$configure_shortcut" == true ]] && [[ "$configure_all" == false ]]; then
        if [[ "$installed_globally" == false ]]; then
            echo -e "${RED}Error: Widget and shortcut require global installation.${RESET}" >&2
            echo "Run 'plasma-daynight-sync configure' first to install globally." >&2
            exit 1
        fi
        # Update the script
        cp "$0" "$CLI_PATH"
        chmod +x "$CLI_PATH"

        if [[ "$configure_widget" == true ]]; then
            install_plasmoid
        fi
        if [[ "$configure_shortcut" == true ]]; then
            install_shortcut
        fi
        return 0
    fi

    # Skip install prompts if partial reconfigure and already installed
    if [[ "$configure_all" == false && "$installed_globally" == true ]]; then
        cp "$0" "$CLI_PATH"
        chmod +x "$CLI_PATH"
        executable_path="$CLI_PATH"
    elif [[ "$configure_all" == true ]]; then
        echo ""
        read -rp "Do you want to install 'plasma-daynight-sync' globally to ~/.local/bin? [y/N]: " choice
        if [[ "$choice" =~ ^[Yy]$ ]]; then
            mkdir -p "$(dirname "$CLI_PATH")"
            cp "$0" "$CLI_PATH"
            chmod +x "$CLI_PATH"
            executable_path="$CLI_PATH"
            installed_globally=true
            echo -e "${GREEN}Installed to $CLI_PATH${RESET}"

            # Offer to install the panel widget
            echo ""
            read -rp "Do you want to install the Day/Night Toggle panel widget? [y/N]: " choice
            if [[ "$choice" =~ ^[Yy]$ ]]; then
                install_plasmoid
            fi

            # Offer to install keyboard shortcut
            echo ""
            read -rp "Do you want to add a keyboard shortcut (Meta+Shift+L) to toggle themes? [y/N]: " choice
            if [[ "$choice" =~ ^[Yy]$ ]]; then
                install_shortcut
            fi
        else
            # Use absolute path of current script
            executable_path=$(readlink -f "$0")
            echo ""
            echo -e "${YELLOW}Note:${RESET} The panel widget and keyboard shortcut require the command to be installed globally."
            echo "Run configure again and choose 'yes' for global installation to enable these features."
        fi
    else
        executable_path=$(readlink -f "$0")
    fi

    # Install systemd service
    mkdir -p "$SERVICE_DIR"
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Plasma auto theme watcher (Kvantum switcher)

[Service]
ExecStart=$executable_path watch
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF

    systemctl --user daemon-reload
    systemctl --user enable --now "$SERVICE_NAME"

    # Enable automatic theme switching in KDE Quick Settings
    kwriteconfig6 --file kdeglobals --group KDE --key AutomaticLookAndFeel true

    echo -e "${GREEN}Successfully configured and started $SERVICE_NAME.${RESET}"

    # Apply settings to other users if requested via flag
    if [[ "$configure_allusers" == true ]]; then
        apply_to_other_users
    # Offer to apply settings to other users (only if other users exist)
    elif [[ "$configure_all" == true ]]; then
        local other_users
        mapfile -t other_users < <(get_other_users)
        if [[ ${#other_users[@]} -gt 0 ]]; then
            echo ""
            read -rp "Apply these settings to all users on this system? [y/N]: " choice
            if [[ "$choice" =~ ^[Yy]$ ]]; then
                apply_to_other_users
            fi
        fi
    fi

    # Check if plasma-qt-forcerefresh patch is installed
    local is_patched=""
    is_patched=$(nm -C /usr/lib/qt6/plugins/platformthemes/KDEPlasmaPlatformTheme6.so 2>/dev/null | grep "forceStyleRefresh" || true)

    if [[ -z "$is_patched" ]]; then
        # Check secondary path just in case
        is_patched=$(nm -C /usr/lib64/qt6/plugins/platformthemes/KDEPlasmaPlatformTheme6.so 2>/dev/null | grep "forceStyleRefresh" || true)
    fi

    if [[ -z "$is_patched" ]] && command -v nm &>/dev/null; then
        echo -e "\n${YELLOW}Note:${RESET} Standard Qt apps (Dolphin, Kate, etc.) require a patch to refresh themes without restarting."
        echo "If you want seamless live-switching, install the forcerefresh patch:"
        echo "  git clone https://github.com/edmogeor/plasma-qt-forcerefresh.git"
        echo "  cd plasma-qt-forcerefresh && ./plasma-integration-patch-manager.sh install"
    fi
}

do_remove() {
    if systemctl --user is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        systemctl --user stop "$SERVICE_NAME"
    fi
    if systemctl --user is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then
        systemctl --user disable "$SERVICE_NAME"
    fi

    # Restore or remove look-and-feel overrides
    local laf_dir="${HOME}/.local/share/plasma/look-and-feel"
    if [[ -d "$laf_dir" ]]; then
        find "$laf_dir" -maxdepth 2 -name ".sync_managed" | while read -r flag; do
            theme_root=$(dirname "$flag")
            local theme_id
            theme_id=$(basename "$theme_root")
            local friendly_name
            friendly_name=$(get_friendly_name laf "$theme_id")
            rm -rf "$theme_root"
            echo "Removed managed local theme: ${BOLD}$friendly_name${RESET} ($theme_id)"
        done
        
        # Fallback for themes that were modified but not fully copied (restore .bak files)
        find "$laf_dir" -name "defaults.bak" | while read -r bak; do
            defaults="${bak%.bak}"
            mv "$bak" "$defaults"
            echo "Restored $defaults from backup"
        done
    fi

    local removed=0
    for f in "$SERVICE_FILE" "$CONFIG_FILE" "$CLI_PATH"; do
        if [[ -f "$f" ]]; then
            rm "$f"
            echo "Removed $f"
            removed=1
        fi
    done

    # Remove plasmoid if installed
    remove_plasmoid

    # Remove keyboard shortcut if installed
    remove_shortcut

    # Reset Flatpak overrides we set
    if command -v flatpak &>/dev/null; then
        flatpak override --user --unset-env=GTK_THEME 2>/dev/null || true
        flatpak override --user --unset-env=GTK_ICON_THEME 2>/dev/null || true
        flatpak override --user --unset-env=QT_STYLE_OVERRIDE 2>/dev/null || true
        echo "Reset Flatpak theme overrides"
    fi

    if [[ "$removed" -eq 1 ]]; then
        systemctl --user daemon-reload
    fi

    echo "Remove complete."
}

do_status() {
    echo -e "${BOLD}Service status:${RESET}"
    if systemctl --user is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        echo -e "    Running: ${GREEN}yes${RESET}"
    else
        echo -e "    Running: ${RED}no${RESET}"
    fi
    if systemctl --user is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then
        echo -e "    Enabled: ${GREEN}yes${RESET}"
    else
        echo -e "    Enabled: ${RED}no${RESET}"
    fi
    if [[ -d "$PLASMOID_INSTALL_DIR" ]]; then
        echo -e "    Panel widget: ${GREEN}installed${RESET}"
    else
        echo -e "    Panel widget: ${YELLOW}not installed${RESET}"
    fi
    if [[ -f "$DESKTOP_FILE" ]]; then
        echo -e "    Keyboard shortcut: ${GREEN}installed${RESET} (Meta+Shift+L)"
    else
        echo -e "    Keyboard shortcut: ${YELLOW}not installed${RESET}"
    fi

    echo ""
    local current_laf
    current_laf=$(kreadconfig6 --file kdeglobals --group KDE --key LookAndFeelPackage 2>/dev/null)
    local laf_day laf_night
    laf_day=$(kreadconfig6 --file kdeglobals --group KDE --key DefaultLightLookAndFeel 2>/dev/null)
    laf_night=$(kreadconfig6 --file kdeglobals --group KDE --key DefaultDarkLookAndFeel 2>/dev/null)

    echo -e "${BOLD}Current mode:${RESET}"
    if [[ "$current_laf" == "$laf_day" ]]; then
        echo "  ☀️ Day ($(get_friendly_name laf "$current_laf") - $current_laf)"
    elif [[ "$current_laf" == "$laf_night" ]]; then
        echo "  🌙 Night ($(get_friendly_name laf "$current_laf") - $current_laf)"
    else
        echo "  Unknown ($current_laf)"
    fi

    echo ""
    if [[ -f "$CONFIG_FILE" ]]; then
        echo -e "${BOLD}Configuration ($CONFIG_FILE):${RESET}"
        # shellcheck source=/dev/null
        source "$CONFIG_FILE"
        echo -e "☀️ Day theme: ${BOLD}$(get_friendly_name laf "$LAF_DAY")${RESET} ($LAF_DAY)"
        echo "    Kvantum: ${KVANTUM_DAY:-unchanged}"
        echo "    Style: ${STYLE_DAY:-unchanged}"
        echo "    Decorations: $(get_friendly_name decoration "${DECORATION_DAY:-}")"
        echo "    Colors: ${COLOR_DAY:-unchanged}"
        echo "    Icons: ${ICON_DAY:-unchanged}"
        echo "    Cursors: ${CURSOR_DAY:-unchanged}"
        echo "    GTK: ${GTK_DAY:-unchanged}"
        echo "    Konsole: ${KONSOLE_DAY:-unchanged}"
        echo "    Splash: $(get_friendly_name splash "${SPLASH_DAY:-}")"
        echo "    Script: ${SCRIPT_DAY:-unchanged}"
        echo -e "🌙 Night theme:  ${BOLD}$(get_friendly_name laf "$LAF_NIGHT")${RESET} ($LAF_NIGHT)"
        echo "    Kvantum: ${KVANTUM_NIGHT:-unchanged}"
        echo "    Style: ${STYLE_NIGHT:-unchanged}"
        echo "    Decorations: $(get_friendly_name decoration "${DECORATION_NIGHT:-}")"
        echo "    Colors: ${COLOR_NIGHT:-unchanged}"
        echo "    Icons: ${ICON_NIGHT:-unchanged}"
        echo "    Cursors: ${CURSOR_NIGHT:-unchanged}"
        echo "    GTK: ${GTK_NIGHT:-unchanged}"
        echo "    Konsole: ${KONSOLE_NIGHT:-unchanged}"
        echo "    Splash: $(get_friendly_name splash "${SPLASH_NIGHT:-}")"
        echo "    Script: ${SCRIPT_NIGHT:-unchanged}"
    else
        echo "Configuration: not installed"
    fi
}

show_help() {
    cat <<EOF
plasma-daynight-sync - A theme switcher for KDE day/night mode

Usage: $0 <command> [options]

Commands:
  configure    Scan themes, save config, enable systemd service
  watch        Start the theme monitoring loop (foreground)
  day          Switch to Day mode (and sync sub-themes)
  night        Switch to Night mode (and sync sub-themes)
  toggle       Toggle between Day and Night mode
  remove       Stop service, remove all installed files and widget
  status       Show service status and current configuration
  help         Show this help message

Configure options:
  -k, --kvantum       Configure Kvantum themes only
  -i, --icons         Configure icon themes only
  -g, --gtk           Configure GTK themes only
  -o, --konsole       Configure Konsole profiles only
  -S, --splash        Configure splash screens only
  -c, --colors        Configure color schemes only
  -p, --style         Configure Plasma styles only
  -d, --decorations   Configure window decorations only
  -C, --cursors       Configure cursor themes only
  -s, --script        Configure custom scripts only
  -w, --widget        Install/reinstall panel widget
  -K, --shortcut      Install/reinstall keyboard shortcut (Meta+Shift+L)

  With no options, configures all. With options, only reconfigures specified types.

Panel Widget:
  During configuration, if you install the command globally (~/.local/bin),
  you'll be offered to install a Day/Night Toggle panel widget. This adds
  a sun/moon button to your panel for quick theme switching.

Examples:
  $0 configure              Configure all theme options
  $0 configure -k -i        Configure only Kvantum and icon themes
  $0 configure --splash     Configure only splash screens
  $0 configure --script     Configure only custom scripts
  $0 configure --all-users  Apply settings to all users on the system
  $0 status                 Show current configuration
  $0 remove                 Remove all installed files
EOF
}

case "${1:-}" in
    configure) do_configure "$@" ;;
    watch)     do_watch ;;
    day)       do_day ;;
    night)     do_night ;;
    toggle)    do_toggle ;;
    remove)    do_remove ;;
    status)    do_status ;;
    help|-h|--help) show_help ;;
    *)
        echo "Usage: $0 <command> [options]"
        echo "Try '$0 help' for more information."
        exit 1
        ;;
esac
