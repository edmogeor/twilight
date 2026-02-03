#!/usr/bin/env bash
#
# plasma-daynight-sync.sh
# Manages the plasma-daynight-sync: a theme switcher for KDE day/night mode.
#   configure [options]  Scan themes, save config, generate watcher script, enable systemd service
#                        Options: -k|--kvantum -i|--icons -g|--gtk -o|--konsole -c|--color-scheme -s|--script -w|--wallpaper
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
            # Exclude cursor themes
            [[ -d "${theme_dir}cursors" ]] && continue
            themes+=("$(basename "$theme_dir")")
        done
    done
    # Deduplicate and sort
    printf '%s\n' "${themes[@]}" | sort -u
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
    local themes=()
    for dir in /usr/share/plasma/look-and-feel "${HOME}/.local/share/plasma/look-and-feel"; do
        [[ -d "$dir" ]] || continue
        for theme_dir in "$dir"/*/; do
            [[ -d "${theme_dir}contents/splash" ]] || continue
            themes+=("$(basename "$theme_dir")")
        done
    done
    # Deduplicate and sort
    printf '%s\n' "${themes[@]}" | sort -u
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
    LAF_LIGHT=$(kreadconfig6 --file kdeglobals --group KDE --key DefaultLightLookAndFeel)
    LAF_DARK=$(kreadconfig6 --file kdeglobals --group KDE --key DefaultDarkLookAndFeel)
    # Silent reload as per request
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
    if [[ -n "$SPLASH_OVERWRITE" ]]; then
        kwriteconfig6 --file ksplashrc --group KSplash --key Theme "$SPLASH_OVERWRITE"
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
        echo -e "  ${YELLOW}!${RESET} $laf is a system theme; creating local copy in ~/.local for overrides..."
        local laf_root="${HOME}/.local/share/plasma/look-and-feel/${laf}"
        local user_contents="${laf_root}/contents"
        mkdir -p "$user_contents"

        # Copy defaults
        cp "$defaults_file" "$user_contents/defaults"
        defaults_file="$user_contents/defaults"

        # Copy metadata (required for Plasma to recognize the theme)
        local system_laf_root="/usr/share/plasma/look-and-feel/${laf}"
        cp "${system_laf_root}/metadata."* "$laf_root/" 2>/dev/null || true

        # Add managed flag so we can safely delete this on removal
        touch "${laf_root}/.sync_managed"

        # Copy previews (so the theme looks correct in System Settings)
        if [[ -d "${system_laf_root}/contents/previews" ]]; then
            cp -r "${system_laf_root}/contents/previews" "$user_contents/"
        fi
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
    if [[ "$laf" == "$LAF_DARK" ]]; then
        if [[ -n "$KVANTUM_DARK" ]]; then
            kvantummanager --set "$KVANTUM_DARK"
            refresh_kvantum_style "kvantum-dark"
        fi
        [[ -n "$ICON_DARK" && -n "$PLASMA_CHANGEICONS" ]] && "$PLASMA_CHANGEICONS" "$ICON_DARK"
        [[ -n "$GTK_DARK" ]] && apply_gtk_theme "$GTK_DARK"
        [[ -n "$KONSOLE_DARK" ]] && apply_konsole_profile "$KONSOLE_DARK"
        apply_splash
        [[ -n "$SCRIPT_DARK" && -x "$SCRIPT_DARK" ]] && "$SCRIPT_DARK"
        dbus-send --session --type=signal /KGlobalSettings org.kde.KGlobalSettings.forceRefresh
        echo "[$(date)] Switched to 🌙 DARK mode"
    elif [[ "$laf" == "$LAF_LIGHT" ]]; then
        if [[ -n "$KVANTUM_LIGHT" ]]; then
            kvantummanager --set "$KVANTUM_LIGHT"
            refresh_kvantum_style "kvantum"
        fi
        [[ -n "$ICON_LIGHT" && -n "$PLASMA_CHANGEICONS" ]] && "$PLASMA_CHANGEICONS" "$ICON_LIGHT"
        [[ -n "$GTK_LIGHT" ]] && apply_gtk_theme "$GTK_LIGHT"
        [[ -n "$KONSOLE_LIGHT" ]] && apply_konsole_profile "$KONSOLE_LIGHT"
        apply_splash
        [[ -n "$SCRIPT_LIGHT" && -x "$SCRIPT_LIGHT" ]] && "$SCRIPT_LIGHT"
        dbus-send --session --type=signal /KGlobalSettings org.kde.KGlobalSettings.forceRefresh
        echo "[$(date)] Switched to ☀️ LIGHT mode"
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

do_light() {
    [[ -z "${LAF_LIGHT:-}" ]] && load_config_strict
    echo -e "Switching to ☀️ Light theme: ${BOLD}$LAF_LIGHT${RESET}"
    plasma-apply-lookandfeel -a "$LAF_LIGHT"

    # If watcher is not running, manually sync sub-themes
    if ! systemctl --user is-active --quiet "$SERVICE_NAME"; then
         apply_theme "$LAF_LIGHT"
    fi
}

do_dark() {
    [[ -z "${LAF_DARK:-}" ]] && load_config_strict
    echo -e "Switching to 🌙 Dark theme: ${BOLD}$LAF_DARK${RESET}"
    plasma-apply-lookandfeel -a "$LAF_DARK"

    # If watcher is not running, manually sync sub-themes
    if ! systemctl --user is-active --quiet "$SERVICE_NAME"; then
         apply_theme "$LAF_DARK"
    fi
}

do_toggle() {
    load_config_strict
    local current_laf
    current_laf=$(kreadconfig6 --file kdeglobals --group KDE --key LookAndFeelPackage)

    if [[ "$current_laf" == "$LAF_DARK" ]]; then
        do_light
    else
        do_dark
    fi
}

do_configure() {
    check_desktop_environment
    check_dependencies

    # Parse modifiers
    shift # Remove 'configure' from args
    local configure_all=true
    local configure_kvantum=false
    local configure_icons=false
    local configure_gtk=false
    local configure_konsole=false
    local configure_script=false
    local configure_splash=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -k|--kvantum)       configure_kvantum=true; configure_all=false ;;
            -i|--icons)         configure_icons=true; configure_all=false ;;
            -g|--gtk)           configure_gtk=true; configure_all=false ;;
            -o|--konsole)       configure_konsole=true; configure_all=false ;;
            -s|--script)        configure_script=true; configure_all=false ;;
            -S|--splash)        configure_splash=true; configure_all=false ;;
            *)
                echo "Unknown option: $1" >&2
                echo "Options: -k|--kvantum -i|--icons -g|--gtk -o|--konsole -s|--script -S|--splash" >&2
                exit 1
                ;;
        esac
        shift
    done

    # Load existing config if modifying specific options
    if [[ "$configure_all" == false && -f "$CONFIG_FILE" ]]; then
        # shellcheck source=/dev/null
        source "$CONFIG_FILE"
    else
        cleanup_stale
    fi

    # Read light/dark themes from KDE Quick Settings configuration
    echo -e "${BLUE}Reading theme configuration from KDE settings...${RESET}"
    local laf_light laf_dark
    laf_light=$(kreadconfig6 --file kdeglobals --group KDE --key DefaultLightLookAndFeel)
    laf_dark=$(kreadconfig6 --file kdeglobals --group KDE --key DefaultDarkLookAndFeel)
    echo -e "  ☀️ Light theme: ${BOLD}$laf_light${RESET}"
    echo -e "  🌙 Dark theme:  ${BOLD}$laf_dark${RESET}"

    if [[ "$laf_light" == "$laf_dark" ]]; then
        echo -e "${RED}Error: ☀️ Light and 🌙 Dark LookAndFeel are the same ($laf_light).${RESET}" >&2
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
            KVANTUM_LIGHT=""
            KVANTUM_DARK=""
        else
            echo ""
            echo -e "${BOLD}Available Kvantum themes:${RESET}"
            for i in "${!themes[@]}"; do
                printf "  ${BLUE}%3d)${RESET} %s\n" "$((i + 1))" "${themes[$i]}"
            done

            echo ""
            read -rp "Select ☀️ LIGHT mode Kvantum theme [1-${#themes[@]}]: " choice
            if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#themes[@]} )); then
                KVANTUM_LIGHT="${themes[$((choice - 1))]}"

                read -rp "Select 🌙 DARK mode Kvantum theme [1-${#themes[@]}]: " choice
                if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#themes[@]} )); then
                    KVANTUM_DARK="${themes[$((choice - 1))]}"
                else
                    KVANTUM_LIGHT=""
                    KVANTUM_DARK=""
                fi
            else
                KVANTUM_LIGHT=""
                KVANTUM_DARK=""
            fi
        fi
    else
        KVANTUM_LIGHT=""
        KVANTUM_DARK=""
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
            ICON_LIGHT=""
            ICON_DARK=""
        else
            echo ""
            echo -e "${BOLD}Available icon themes:${RESET}"
            for i in "${!icon_themes[@]}"; do
                printf "  ${BLUE}%3d)${RESET} %s\n" "$((i + 1))" "${icon_themes[$i]}"
            done

            echo ""
            read -rp "Select ☀️ LIGHT mode icon theme [1-${#icon_themes[@]}]: " choice
            if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#icon_themes[@]} )); then
                ICON_LIGHT="${icon_themes[$((choice - 1))]}"

                read -rp "Select 🌙 DARK mode icon theme [1-${#icon_themes[@]}]: " choice
                if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#icon_themes[@]} )); then
                    ICON_DARK="${icon_themes[$((choice - 1))]}"

                    # Offer to update look-and-feel defaults
                    echo ""
                    echo -e "${YELLOW}Note:${RESET} You can embed these icon themes directly into your look-and-feel themes."
                    echo "This means KDE will switch icons automatically, without needing this watcher."
                    echo -e "${YELLOW}Warning:${RESET} This change won't persist if you reinstall/update the themes."
                    read -rp "Update look-and-feel themes with these icon packs? [y/N]: " choice
                    if [[ "$choice" =~ ^[Yy]$ ]]; then
                        update_laf_icons "$laf_light" "$ICON_LIGHT" && \
                            echo -e "  ${GREEN}✓${RESET} Updated $laf_light with $ICON_LIGHT"
                        update_laf_icons "$laf_dark" "$ICON_DARK" && \
                            echo -e "  ${GREEN}✓${RESET} Updated $laf_dark with $ICON_DARK"
                        # Clear icon config since LAF will handle it
                        ICON_LIGHT=""
                        ICON_DARK=""
                        PLASMA_CHANGEICONS=""
                        echo "Icon switching will now be handled by the look-and-feel themes."
                    fi
                else
                    ICON_LIGHT=""
                    ICON_DARK=""
                fi
            else
                ICON_LIGHT=""
                ICON_DARK=""
            fi
        fi
    else
        ICON_LIGHT=""
        ICON_DARK=""
        PLASMA_CHANGEICONS=""
    fi
    fi

    # Select GTK themes
    if [[ "$configure_all" == true || "$configure_gtk" == true ]]; then
    echo ""
    read -rp "Configure GTK themes? [y/N]: " choice
    if [[ "$choice" =~ ^[Yy]$ ]]; then
        echo "Scanning for GTK themes..."
        mapfile -t gtk_themes < <(scan_gtk_themes)

        if [[ ${#gtk_themes[@]} -eq 0 ]]; then
            echo "No GTK themes found, skipping."
            GTK_LIGHT=""
            GTK_DARK=""
        else
            echo ""
            echo -e "${BOLD}Available GTK themes:${RESET}"
            for i in "${!gtk_themes[@]}"; do
                printf "  ${BLUE}%3d)${RESET} %s\n" "$((i + 1))" "${gtk_themes[$i]}"
            done

            echo ""
            read -rp "Select ☀️ LIGHT mode GTK theme [1-${#gtk_themes[@]}]: " choice
            if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#gtk_themes[@]} )); then
                GTK_LIGHT="${gtk_themes[$((choice - 1))]}"

                read -rp "Select 🌙 DARK mode GTK theme [1-${#gtk_themes[@]}]: " choice
                if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#gtk_themes[@]} )); then
                    GTK_DARK="${gtk_themes[$((choice - 1))]}"
                else
                    GTK_LIGHT=""
                    GTK_DARK=""
                fi
            else
                GTK_LIGHT=""
                GTK_DARK=""
            fi
        fi
    else
        GTK_LIGHT=""
        GTK_DARK=""
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
            KONSOLE_LIGHT=""
            KONSOLE_DARK=""
        else
            echo ""
            echo -e "${BOLD}Available Konsole profiles:${RESET}"
            for i in "${!konsole_profiles[@]}"; do
                printf "  ${BLUE}%3d)${RESET} %s\n" "$((i + 1))" "${konsole_profiles[$i]}"
            done

            echo ""
            read -rp "Select ☀️ LIGHT mode Konsole profile [1-${#konsole_profiles[@]}]: " choice
            if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#konsole_profiles[@]} )); then
                KONSOLE_LIGHT="${konsole_profiles[$((choice - 1))]}"

                read -rp "Select 🌙 DARK mode Konsole profile [1-${#konsole_profiles[@]}]: " choice
                if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#konsole_profiles[@]} )); then
                    KONSOLE_DARK="${konsole_profiles[$((choice - 1))]}"
                else
                    KONSOLE_LIGHT=""
                    KONSOLE_DARK=""
                fi
            else
                KONSOLE_LIGHT=""
                KONSOLE_DARK=""
            fi
        fi
    else
        KONSOLE_LIGHT=""
        KONSOLE_DARK=""
    fi
    fi

    # Select Splash Screens
    if [[ "$configure_all" == true || "$configure_splash" == true ]]; then
    echo ""
    read -rp "When the theme switches, so will the splashscreen - would you like to overwrite it? [y/N]: " choice
    if [[ "$choice" =~ ^[Yy]$ ]]; then
        echo "Scanning for splash themes..."
        mapfile -t splash_themes < <(scan_splash_themes)

        echo ""
        echo -e "${BOLD}Available splash themes:${RESET}"
        printf "  ${BLUE}%3d)${RESET} %s\n" "1" "None (Disable splash screen)"
        for i in "${!splash_themes[@]}"; do
            printf "  ${BLUE}%3d)${RESET} %s\n" "$((i + 2))" "${splash_themes[$i]}"
        done

        echo ""
        read -rp "Select splash theme to use for BOTH modes [1-$(( ${#splash_themes[@]} + 1 ))]: " choice
        if [[ "$choice" == "1" ]]; then
            SPLASH_OVERWRITE="None"
        elif [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 2 && choice <= ${#splash_themes[@]} + 1 )); then
            SPLASH_OVERWRITE="${splash_themes[$((choice - 2))]}"
        else
            SPLASH_OVERWRITE=""
        fi
    else
        SPLASH_OVERWRITE=""
    fi
    fi

    # Configure custom scripts
    if [[ "$configure_all" == true || "$configure_script" == true ]]; then
    echo ""
    read -rp "Configure custom scripts? [y/N]: " choice
    if [[ "$choice" =~ ^[Yy]$ ]]; then
        echo ""
        read -rp "Enter ☀️ LIGHT mode script path (leave empty to skip): " SCRIPT_LIGHT
        if [[ -n "$SCRIPT_LIGHT" && ! -x "$SCRIPT_LIGHT" ]]; then
            echo "Warning: $SCRIPT_LIGHT is not executable" >&2
        fi

        read -rp "Enter 🌙 DARK mode script path (leave empty to skip): " SCRIPT_DARK
        if [[ -n "$SCRIPT_DARK" && ! -x "$SCRIPT_DARK" ]]; then
            echo "Warning: $SCRIPT_DARK is not executable" >&2
        fi
    else
        SCRIPT_LIGHT=""
        SCRIPT_DARK=""
    fi
    fi

    # Check if anything was configured
    if [[ -z "$KVANTUM_LIGHT" && -z "$KVANTUM_DARK" && -z "$ICON_LIGHT" && -z "$ICON_DARK" && -z "$GTK_LIGHT" && -z "$GTK_DARK" && -z "$KONSOLE_LIGHT" && -z "$KONSOLE_DARK" && -z "$SCRIPT_LIGHT" && -z "$SCRIPT_DARK" && -z "$SPLASH_OVERWRITE" ]]; then
        echo ""
        echo "Nothing to configure. Exiting."
        exit 0
    fi

    echo ""
    echo "Configuration summary:"
    echo "   Splash overwrite: ${SPLASH_OVERWRITE:-disabled}"
    echo -e "☀️ Light theme: ${BOLD}$laf_light${RESET}"
    echo "    Kvantum: ${KVANTUM_LIGHT:-unchanged}"
    echo "    Icons: ${ICON_LIGHT:-unchanged}"
    echo "    GTK: ${GTK_LIGHT:-unchanged}"
    echo "    Konsole: ${KONSOLE_LIGHT:-unchanged}"
    echo "    Script: ${SCRIPT_LIGHT:-unchanged}"
    echo -e "🌙 Dark theme:  ${BOLD}$laf_dark${RESET}"
    echo "    Kvantum: ${KVANTUM_DARK:-unchanged}"
    echo "    Icons: ${ICON_DARK:-unchanged}"
    echo "    GTK: ${GTK_DARK:-unchanged}"
    echo "    Konsole: ${KONSOLE_DARK:-unchanged}"
    echo "    Script: ${SCRIPT_DARK:-unchanged}"

    cat > "$CONFIG_FILE" <<EOF
LAF_LIGHT=$laf_light
LAF_DARK=$laf_dark
KVANTUM_LIGHT=$KVANTUM_LIGHT
KVANTUM_DARK=$KVANTUM_DARK
ICON_LIGHT=$ICON_LIGHT
ICON_DARK=$ICON_DARK
PLASMA_CHANGEICONS=$PLASMA_CHANGEICONS
GTK_LIGHT=$GTK_LIGHT
GTK_DARK=$GTK_DARK
KONSOLE_LIGHT=$KONSOLE_LIGHT
KONSOLE_DARK=$KONSOLE_DARK
SPLASH_OVERWRITE=$SPLASH_OVERWRITE
SCRIPT_LIGHT=$SCRIPT_LIGHT
SCRIPT_DARK=$SCRIPT_DARK
EOF

    # Install globally?
    local executable_path
    echo ""
    read -rp "Do you want to install 'plasma-daynight-sync' globally to ~/.local/bin? [y/N]: " choice
    if [[ "$choice" =~ ^[Yy]$ ]]; then
        mkdir -p "$(dirname "$CLI_PATH")"
        cp "$0" "$CLI_PATH"
        chmod +x "$CLI_PATH"
        executable_path="$CLI_PATH"
        echo -e "${GREEN}Installed to $CLI_PATH${RESET}"
    else
        # Use absolute path of current script
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
    echo -e "${GREEN}Successfully configured and started $SERVICE_NAME.${RESET}"

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
            rm -rf "$theme_root"
            echo "Removed managed local theme: $(basename "$theme_root")"
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

    echo ""
    local current_laf
    current_laf=$(kreadconfig6 --file kdeglobals --group KDE --key LookAndFeelPackage 2>/dev/null)
    local laf_light laf_dark
    laf_light=$(kreadconfig6 --file kdeglobals --group KDE --key DefaultLightLookAndFeel 2>/dev/null)
    laf_dark=$(kreadconfig6 --file kdeglobals --group KDE --key DefaultDarkLookAndFeel 2>/dev/null)

    echo -e "${BOLD}Current mode:${RESET}"
    if [[ "$current_laf" == "$laf_light" ]]; then
        echo "  ☀️ Light ($current_laf)"
    elif [[ "$current_laf" == "$laf_dark" ]]; then
        echo "  🌙 Dark ($current_laf)"
    else
        echo "  Unknown ($current_laf)"
    fi

    echo ""
    if [[ -f "$CONFIG_FILE" ]]; then
        echo -e "${BOLD}Configuration ($CONFIG_FILE):${RESET}"
        # shellcheck source=/dev/null
        source "$CONFIG_FILE"
        echo "   Splash overwrite: ${SPLASH_OVERWRITE:-disabled}"
        echo -e "☀️ Light theme: ${BOLD}$LAF_LIGHT${RESET}"
        echo "    Kvantum: ${KVANTUM_LIGHT:-unchanged}"
        echo "    Icons: ${ICON_LIGHT:-unchanged}"
        echo "    GTK: ${GTK_LIGHT:-unchanged}"
        echo "    Konsole: ${KONSOLE_LIGHT:-unchanged}"
        echo "    Script: ${SCRIPT_LIGHT:-unchanged}"
        echo -e "🌙 Dark theme:  ${BOLD}$LAF_DARK${RESET}"
        echo "    Kvantum: ${KVANTUM_DARK:-unchanged}"
        echo "    Icons: ${ICON_DARK:-unchanged}"
        echo "    GTK: ${GTK_DARK:-unchanged}"
        echo "    Konsole: ${KONSOLE_DARK:-unchanged}"
        echo "    Script: ${SCRIPT_DARK:-unchanged}"
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
  light        Switch to Light mode (and sync sub-themes)
  dark         Switch to Dark mode (and sync sub-themes)
  toggle       Toggle between Light and Dark mode
  remove       Stop service, remove all installed files
  status       Show service status and current configuration
  help         Show this help message

Configure options:
  -k, --kvantum       Configure Kvantum themes only
  -i, --icons         Configure icon themes only
  -g, --gtk           Configure GTK themes only
  -o, --konsole       Configure Konsole profiles only
  -S, --splash        Configure splash screens only
  -s, --script        Configure custom scripts only

  With no options, configures all. With options, only reconfigures specified types.

Examples:
  $0 configure              Configure all theme options
  $0 configure -k -i        Configure only Kvantum and icon themes
  $0 configure --splash     Configure only splash screens
  $0 configure --script     Configure only custom scripts
  $0 status                 Show current configuration
  $0 remove                 Remove all installed files
EOF
}

case "${1:-}" in
    configure) do_configure "$@" ;;
    watch)     do_watch ;;
    light)     do_light ;;
    dark)      do_dark ;;
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
