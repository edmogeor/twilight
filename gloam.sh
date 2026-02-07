#!/usr/bin/env bash
#
# gloam.sh
# gloam: Syncs Kvantum, GTK, and custom scripts with Plasma 6's native light/dark (day/night) theme switching - and more.
#   configure [options]  Scan themes, save config, generate watcher script, enable systemd service
#                        Options: -c|--colors -k|--kvantum -a|--appstyle -g|--gtk -p|--style -d|--decorations -i|--icons -C|--cursors -S|--splash -l|--login -W|--wallpaper -o|--konsole -s|--script -w|--widget -K|--shortcut
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

# Global installation mode flags
INSTALL_GLOBAL=false
PUSH_TO_USERS=false
SET_SYSTEM_DEFAULTS=false
SELECTED_USERS=()

# Global installation marker file
GLOBAL_INSTALL_MARKER="/etc/gloam.admin"

# Global scripts directory
GLOBAL_SCRIPTS_DIR="/usr/local/share/gloam"

# Log file
LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}"
LOG_FILE="${LOG_DIR}/gloam.log"
LOG_MAX_SIZE=102400  # 100KB

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "$msg"
    mkdir -p "$LOG_DIR"
    # Truncate if too large
    if [[ -f "$LOG_FILE" ]] && (( $(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0) > LOG_MAX_SIZE )); then
        tail -n 100 "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
    fi
    echo "$msg" >> "$LOG_FILE"
}

warn() {
    local msg="$*"
    echo -e "${YELLOW}Warning: ${msg}${RESET}" >&2
    log "WARN: $msg"
}

die() {
    local msg="$*"
    echo -e "${RED}Error: ${msg}${RESET}" >&2
    log "ERROR: $msg"
    exit 1
}

# Temp file tracking and cleanup
GLOAM_TMPFILES=()

gloam_mktemp() {
    local f
    f=$(mktemp /tmp/gloam-XXXXXXXX)
    GLOAM_TMPFILES+=("$f")
    echo "$f"
}

cleanup() {
    for f in "${GLOAM_TMPFILES[@]}"; do
        [[ -f "$f" ]] && rm -f "$f"
    done
}
trap cleanup EXIT INT TERM

# Base paths (may be overridden by global install)
KVANTUM_DIR="${HOME}/.config/Kvantum"
CONFIG_FILE="${HOME}/.config/gloam.conf"
SERVICE_NAME="gloam"
PLASMOID_ID="org.kde.plasma.lightdarktoggle"
SHORTCUT_ID="gloam-toggle.desktop"

# Path helper functions
get_cli_path() {
    if [[ "$INSTALL_GLOBAL" == true ]]; then
        echo "/usr/local/bin/gloam"
    else
        echo "${HOME}/.local/bin/gloam"
    fi
}

get_plasmoid_path() {
    if [[ "$INSTALL_GLOBAL" == true ]]; then
        echo "/usr/share/plasma/plasmoids/${PLASMOID_ID}"
    else
        echo "${HOME}/.local/share/plasma/plasmoids/${PLASMOID_ID}"
    fi
}

get_desktop_file_path() {
    if [[ "$INSTALL_GLOBAL" == true ]]; then
        echo "/usr/share/applications/gloam-toggle.desktop"
    else
        echo "${HOME}/.local/share/applications/gloam-toggle.desktop"
    fi
}

get_theme_install_dir() {
    if [[ "$INSTALL_GLOBAL" == true ]]; then
        echo "/usr/share/plasma/look-and-feel"
    else
        echo "${HOME}/.local/share/plasma/look-and-feel"
    fi
}

get_service_dir() {
    if [[ "$INSTALL_GLOBAL" == true ]]; then
        echo "/etc/systemd/user"
    else
        echo "${HOME}/.config/systemd/user"
    fi
}

get_service_file() {
    echo "$(get_service_dir)/${SERVICE_NAME}.service"
}

# Check for existing global installation
check_existing_global_install() {
    [[ ! -f "$GLOBAL_INSTALL_MARKER" ]] && return 0

    local admin_user admin_date
    admin_user=$(grep "^user=" "$GLOBAL_INSTALL_MARKER" 2>/dev/null | cut -d= -f2)
    admin_date=$(grep "^date=" "$GLOBAL_INSTALL_MARKER" 2>/dev/null | cut -d= -f2)

    echo ""
    echo -e "${YELLOW}Warning: Global installation already exists.${RESET}"
    echo "  Configured by: ${admin_user:-unknown}"
    echo "  Date: ${admin_date:-unknown}"
    echo ""
    echo "Continuing will overwrite the existing global configuration."
    read -rp "Continue anyway? [y/N]: " choice
    [[ "$choice" =~ ^[Yy]$ ]] && return 0
    return 1
}

# Write global installation marker
write_global_install_marker() {
    [[ "$INSTALL_GLOBAL" != true ]] && return
    sudo tee "$GLOBAL_INSTALL_MARKER" > /dev/null <<EOF
user=$USER
date=$(date '+%Y-%m-%d %H:%M')
EOF
}

# Global installation prompts
ask_global_install() {
    echo ""
    echo -e "${BOLD}Installation Mode${RESET}"
    echo "Local install: Components in your home directory only"
    echo "Global install: Components available to all users (requires sudo)"
    echo ""

    read -rp "Install globally? [y/N]: " choice
    if [[ "$choice" =~ ^[Yy]$ ]]; then
        echo "Authenticating sudo..."
        if ! sudo -v; then
            echo -e "${RED}Sudo authentication failed.${RESET}"
            read -rp "Continue with local installation? [Y/n]: " fallback
            [[ "$fallback" =~ ^[Nn]$ ]] && exit 1
            return
        fi
        echo -e "${GREEN}Sudo authenticated.${RESET}"

        # Check for existing global installation
        if ! check_existing_global_install; then
            echo "Falling back to local installation."
            return
        fi

        INSTALL_GLOBAL=true

        # Ask about pushing to other users
        ask_push_to_users

        # Ask about system defaults for new users
        ask_system_defaults

        # Ask about copying desktop settings if either push or defaults was selected
        if [[ "${PUSH_TO_USERS:-}" == true || "${SET_SYSTEM_DEFAULTS:-}" == true ]]; then
            echo ""
            echo -e "${BOLD}Copy Desktop Settings${RESET}"
            echo "Copy the following settings to new/existing users:"
            echo "  - Panel layout, positions and widgets (plasmoids)"
            echo "  - Mouse and touchpad settings"
            echo "  - Window manager effects and tiling"
            echo "  - Keyboard shortcuts"
            echo "  - Desktop and lock screen wallpapers"
            echo "  - App settings (Dolphin, Konsole profiles, KRunner)"
            echo ""
            read -rp "Copy desktop settings? [y/N]: " desktop_choice
            [[ "$desktop_choice" =~ ^[Yy]$ ]] && COPY_DESKTOP_LAYOUT=true
        fi
    fi
}

ask_push_to_users() {
    # Find real users (UID 1000-60000, has home dir under /home, not current user)
    local users=()
    while IFS=: read -r username _ uid _ _ home _; do
        [[ "$uid" -ge 1000 && "$uid" -lt 60000 && "$home" == /home/* && -d "$home" && "$username" != "$USER" ]] && users+=("$username:$home")
    done < /etc/passwd

    if [[ ${#users[@]} -eq 0 ]]; then
        return
    fi

    echo ""
    echo -e "${BOLD}Push to Existing Users${RESET}"
    echo "Copy your theme configuration to all other users on this system."
    echo ""

    read -rp "Push settings to all other users? [y/N]: " choice
    if [[ "$choice" =~ ^[Yy]$ ]]; then
        SELECTED_USERS=("${users[@]}")
        PUSH_TO_USERS=true
    fi
}

ask_system_defaults() {
    echo ""
    echo -e "${BOLD}System Defaults${RESET}"
    echo "Set these themes as defaults for NEW users created on this system."
    echo "Existing users are not affected by this option."
    echo ""

    read -rp "Set system defaults for new users? [y/N]: " choice
    [[ "$choice" =~ ^[Yy]$ ]] && SET_SYSTEM_DEFAULTS=true
}

install_icons_system_wide() {
    # Install configured icon/cursor themes to /usr/share/icons/ if only available locally
    local theme_names=("${ICON_LIGHT:-}" "${ICON_DARK:-}" "${CURSOR_LIGHT:-}" "${CURSOR_DARK:-}")
    for theme_name in "${theme_names[@]}"; do
        [[ -z "$theme_name" ]] && continue
        [[ -d "/usr/share/icons/${theme_name}" ]] && continue
        # Find theme in local dirs
        local src=""
        for dir in "${HOME}/.local/share/icons" "${HOME}/.icons"; do
            if [[ -d "${dir}/${theme_name}" ]]; then
                src="${dir}/${theme_name}"
                break
            fi
        done
        [[ -z "$src" ]] && continue
        sudo cp -r "$src" "/usr/share/icons/${theme_name}"
        # Also install any sibling themes referenced by symlinks (e.g. WhiteSur base for WhiteSur-light)
        local link_target
        while IFS= read -r link_target; do
            local dep_name
            dep_name=$(echo "$link_target" | sed -n 's|^\.\./\([^/]*\)/.*|\1|p')
            [[ -z "$dep_name" ]] && continue
            [[ -d "/usr/share/icons/${dep_name}" ]] && continue
            local dep_src="$(dirname "$src")/${dep_name}"
            [[ -d "$dep_src" ]] && sudo cp -r "$dep_src" "/usr/share/icons/${dep_name}"
        done < <(find -L "$src" -maxdepth 1 -type l -printf '%l\n' 2>/dev/null || find "$src" -maxdepth 1 -type l -exec readlink {} \; 2>/dev/null)
    done
}

push_config_to_users() {
    [[ "$PUSH_TO_USERS" != true ]] && return
    [[ ${#SELECTED_USERS[@]} -eq 0 ]] && return

    echo ""
    echo "Pushing configuration to selected users..."

    local service_file
    service_file="$(get_service_file)"

    for entry in "${SELECTED_USERS[@]}"; do
        local username="${entry%%:*}"
        local homedir="${entry#*:}"
        local target_config="${homedir}/.config/gloam.conf"
        local target_service_dir="${homedir}/.config/systemd/user"
        local target_service="${target_service_dir}/${SERVICE_NAME}.service"

        echo "  Configuring $username..."

        # Ensure .config directory exists
        sudo mkdir -p "${homedir}/.config"
        sudo chown "$username:" "${homedir}/.config"

        # Copy config file
        sudo cp "$CONFIG_FILE" "$target_config"
        sudo chown "$username:" "$target_config"

        # Set KDE theme defaults for this user
        sudo -u "$username" kwriteconfig6 --file "${homedir}/.config/kdeglobals" \
            --group KDE --key DefaultLightLookAndFeel "${LAF_LIGHT:-}" 2>/dev/null || true
        sudo -u "$username" kwriteconfig6 --file "${homedir}/.config/kdeglobals" \
            --group KDE --key DefaultDarkLookAndFeel "${LAF_DARK:-}" 2>/dev/null || true
        sudo -u "$username" kwriteconfig6 --file "${homedir}/.config/kdeglobals" \
            --group KDE --key AutomaticLookAndFeel true 2>/dev/null || true

        # Copy desktop settings if requested
        if [[ "${COPY_DESKTOP_LAYOUT:-}" == true ]]; then
            # Panel applet layout (with wallpaper path rewrite)
            local panel_config="${HOME}/.config/plasma-org.kde.plasma.desktop-appletsrc"
            if [[ -f "$panel_config" ]]; then
                sudo cp "$panel_config" "${homedir}/.config/plasma-org.kde.plasma.desktop-appletsrc"
                sudo sed -i 's|Image=file://.*/wallpapers/gloam-|Image=file:///usr/share/wallpapers/gloam-|g' \
                    "${homedir}/.config/plasma-org.kde.plasma.desktop-appletsrc"
                sudo chown "$username:" "${homedir}/.config/plasma-org.kde.plasma.desktop-appletsrc"
            fi

            # UX config files (panels, input, window manager, shortcuts, apps)
            local ux_configs=(
                plasmashellrc
                kcminputrc
                kwinrc
                kglobalshortcutsrc
                kscreenlockerrc
                krunnerrc
                dolphinrc
                konsolerc
                breezerc
            )
            for cfg in "${ux_configs[@]}"; do
                [[ -f "${HOME}/.config/${cfg}" ]] || continue
                sudo cp "${HOME}/.config/${cfg}" "${homedir}/.config/${cfg}"
                sudo chown "$username:" "${homedir}/.config/${cfg}"
            done

            # Rewrite gloam wallpaper paths in lock screen config
            if [[ -f "${homedir}/.config/kscreenlockerrc" ]]; then
                sudo sed -i 's|Image=file://.*/wallpapers/gloam-|Image=file:///usr/share/wallpapers/gloam-|g' \
                    "${homedir}/.config/kscreenlockerrc"
            fi

            # Set lockscreen wallpaper if not already a gloam wallpaper
            if [[ "${WALLPAPER:-}" == true ]] && ! grep -q 'wallpapers/gloam-' "${homedir}/.config/kscreenlockerrc" 2>/dev/null; then
                sudo -u "$username" kwriteconfig6 --file "${homedir}/.config/kscreenlockerrc" \
                    --group Greeter --group Wallpaper --group org.kde.image --group General \
                    --key Image "file:///usr/share/wallpapers/gloam-dynamic" 2>/dev/null || true
            fi

            # Konsole profiles (color schemes and profiles)
            local konsole_dir="${HOME}/.local/share/konsole"
            if [[ -d "$konsole_dir" ]] && [[ -n "$(ls -A "$konsole_dir" 2>/dev/null)" ]]; then
                sudo mkdir -p "${homedir}/.local/share/konsole"
                sudo cp -r "$konsole_dir"/* "${homedir}/.local/share/konsole/"
                sudo chown -R "$username:" "${homedir}/.local/share/konsole"
            fi

            # Custom plasmoids so panel widgets work
            local plasmoids_dir="${HOME}/.local/share/plasma/plasmoids"
            if [[ -d "$plasmoids_dir" ]] && [[ -n "$(ls -A "$plasmoids_dir" 2>/dev/null)" ]]; then
                sudo mkdir -p "${homedir}/.local/share/plasma/plasmoids"
                sudo cp -r "$plasmoids_dir"/* "${homedir}/.local/share/plasma/plasmoids/"
                sudo chown -R "$username:" "${homedir}/.local/share/plasma"
            fi
        fi

        # Apply wallpapers to user even without full desktop layout copy
        if [[ "${WALLPAPER:-}" == true && "${COPY_DESKTOP_LAYOUT:-}" != true ]]; then
            # Set lockscreen wallpaper
            if ! sudo grep -q 'wallpapers/gloam-' "${homedir}/.config/kscreenlockerrc" 2>/dev/null; then
                sudo -u "$username" kwriteconfig6 --file "${homedir}/.config/kscreenlockerrc" \
                    --group Greeter --group Wallpaper --group org.kde.image --group General \
                    --key Image "file:///usr/share/wallpapers/gloam-dynamic" 2>/dev/null || true
            fi
        fi

        # Install systemd service for this user (if not using global service dir)
        if [[ "$INSTALL_GLOBAL" != true ]]; then
            sudo mkdir -p "$target_service_dir"
            sudo cp "$service_file" "$target_service"
            sudo chown -R "$username:" "$target_service_dir"
        fi

        # Enable service for user (will take effect on their next login)
        sudo -u "$username" systemctl --user daemon-reload 2>/dev/null || log "WARN: Failed to daemon-reload for user: $username (not logged in?)"
        sudo -u "$username" systemctl --user enable "$SERVICE_NAME" 2>/dev/null || log "WARN: Failed to enable service for user: $username (not logged in?)"

        echo -e "    ${GREEN}Done${RESET}"
    done

    # Install bundled assets to system-wide locations
    local theme_dir_light="${THEME_INSTALL_DIR:-}/org.kde.custom.light"

    # Install bundled icons and cursors to /usr/share/icons/
    for asset_type in icons cursors; do
        for theme_dir in "$theme_dir_light" "${THEME_INSTALL_DIR:-}/org.kde.custom.dark"; do
            [[ -d "${theme_dir}/contents/${asset_type}" ]] || continue
            for asset_dir in "${theme_dir}/contents/${asset_type}"/*/; do
                [[ -d "$asset_dir" ]] || continue
                local asset_name
                asset_name="$(basename "$asset_dir")"
                if [[ ! -d "/usr/share/icons/${asset_name}" ]]; then
                    sudo cp -r "$asset_dir" "/usr/share/icons/${asset_name}"
                fi
            done
        done
    done

    # Install bundled wallpapers to /usr/share/wallpapers/
    if [[ -d "${theme_dir_light}/contents/wallpapers" ]]; then
        for pack_dir in "${theme_dir_light}/contents/wallpapers"/gloam-*/; do
            [[ -d "$pack_dir" ]] || continue
            local pack_name
            pack_name="$(basename "$pack_dir")"
            if [[ ! -d "/usr/share/wallpapers/${pack_name}" ]]; then
                sudo cp -r "$pack_dir" "/usr/share/wallpapers/${pack_name}"
            fi
        done
    fi

    # Set system-wide default desktop wallpaper via Plasma plugin config
    if [[ "${WALLPAPER:-}" == true && -d "/usr/share/wallpapers/gloam-dynamic" ]]; then
        local wp_main_xml="/usr/share/plasma/wallpapers/org.kde.image/contents/config/main.xml"
        if [[ -f "$wp_main_xml" ]]; then
            sudo sed -i '/<entry name="Image"/,/<\/entry>/ s|<default>[^<]*</default>|<default>file:///usr/share/wallpapers/gloam-dynamic</default>|' "$wp_main_xml" 2>/dev/null || true
        fi
    fi

    # Fallback: install icon/cursor themes directly from local dirs (no custom theme)
    install_icons_system_wide

    # Install SDDM backgrounds from theme dir to system location
    for variant in light dark; do
        local theme_dir_variant="${THEME_INSTALL_DIR:-}/org.kde.custom.${variant}"
        local sddm_src
        sddm_src=$({ compgen -G "${theme_dir_variant}/contents/sddm/sddm-bg-${variant}.*" 2>/dev/null || true; } | head -1)
        if [[ -n "$sddm_src" && -f "$sddm_src" ]]; then
            sudo mkdir -p /usr/local/lib/gloam
            sudo cp "$sddm_src" "/usr/local/lib/gloam/"
        fi
    done

    # Apply SDDM wallpaper for current mode after restoring files
    if [[ -x /usr/local/lib/gloam/set-sddm-background ]]; then
        local current_laf_push
        current_laf_push=$(kreadconfig6 --file kdeglobals --group KDE --key LookAndFeelPackage 2>/dev/null)
        local push_sddm_variant="light"
        if [[ "$current_laf_push" == "${LAF_DARK:-}" ]]; then
            push_sddm_variant="dark"
        fi
        local push_sddm_bg
        push_sddm_bg=$({ compgen -G "/usr/local/lib/gloam/sddm-bg-${push_sddm_variant}.*" || true; } | head -1)
        [[ -n "$push_sddm_bg" ]] && apply_sddm_wallpaper "$push_sddm_bg"
    fi
}

set_system_defaults() {
    [[ "$SET_SYSTEM_DEFAULTS" != true ]] && return

    echo ""
    echo "Setting system defaults for new users..."

    # Set default light/dark themes in /etc/xdg/kdeglobals
    local xdg_globals="/etc/xdg/kdeglobals"
    sudo mkdir -p /etc/xdg
    sudo kwriteconfig6 --file "$xdg_globals" --group KDE --key DefaultLightLookAndFeel "${LAF_LIGHT:-}"
    sudo kwriteconfig6 --file "$xdg_globals" --group KDE --key DefaultDarkLookAndFeel "${LAF_DARK:-}"
    sudo kwriteconfig6 --file "$xdg_globals" --group KDE --key AutomaticLookAndFeel true

    # Copy gloam config to /etc/skel so new users get it
    sudo mkdir -p /etc/skel/.config
    sudo cp "$CONFIG_FILE" /etc/skel/.config/gloam.conf

    # Copy desktop settings if requested
    if [[ "${COPY_DESKTOP_LAYOUT:-}" == true ]]; then
        # Panel applet layout (with wallpaper path rewrite)
        local panel_config="${HOME}/.config/plasma-org.kde.plasma.desktop-appletsrc"
        if [[ -f "$panel_config" ]]; then
            sudo cp "$panel_config" /etc/skel/.config/plasma-org.kde.plasma.desktop-appletsrc
            sudo sed -i 's|Image=file://.*/wallpapers/gloam-|Image=file:///usr/share/wallpapers/gloam-|g' \
                /etc/skel/.config/plasma-org.kde.plasma.desktop-appletsrc
        fi

        # UX config files (panels, input, window manager, shortcuts, apps)
        local ux_configs=(
            plasmashellrc
            kcminputrc
            kwinrc
            kglobalshortcutsrc
            kscreenlockerrc
            krunnerrc
            dolphinrc
            konsolerc
            breezerc
        )
        for cfg in "${ux_configs[@]}"; do
            [[ -f "${HOME}/.config/${cfg}" ]] || continue
            sudo cp "${HOME}/.config/${cfg}" "/etc/skel/.config/${cfg}"
        done

        # Rewrite gloam wallpaper paths in lock screen config
        if [[ -f /etc/skel/.config/kscreenlockerrc ]]; then
            sudo sed -i 's|Image=file://.*/wallpapers/gloam-|Image=file:///usr/share/wallpapers/gloam-|g' \
                /etc/skel/.config/kscreenlockerrc
        fi

        # Set lockscreen wallpaper if not already a gloam wallpaper
        if [[ "${WALLPAPER:-}" == true ]] && ! grep -q 'wallpapers/gloam-' /etc/skel/.config/kscreenlockerrc 2>/dev/null; then
            sudo kwriteconfig6 --file /etc/skel/.config/kscreenlockerrc \
                --group Greeter --group Wallpaper --group org.kde.image --group General \
                --key Image "file:///usr/share/wallpapers/gloam-dynamic"
        fi

        # Konsole profiles (color schemes and profiles)
        local konsole_dir="${HOME}/.local/share/konsole"
        if [[ -d "$konsole_dir" ]] && [[ -n "$(ls -A "$konsole_dir" 2>/dev/null)" ]]; then
            sudo mkdir -p /etc/skel/.local/share/konsole
            sudo cp -r "$konsole_dir"/* /etc/skel/.local/share/konsole/
        fi

        # Custom plasmoids so panel widgets work
        local plasmoids_dir="${HOME}/.local/share/plasma/plasmoids"
        if [[ -d "$plasmoids_dir" ]] && [[ -n "$(ls -A "$plasmoids_dir" 2>/dev/null)" ]]; then
            sudo mkdir -p /etc/skel/.local/share/plasma/plasmoids
            sudo cp -r "$plasmoids_dir"/* /etc/skel/.local/share/plasma/plasmoids/
        fi
    fi

    # Auto-enable service for all users via default.target.wants symlink
    local service_file="/etc/systemd/user/${SERVICE_NAME}.service"
    if [[ -f "$service_file" ]]; then
        sudo mkdir -p /etc/systemd/user/default.target.wants
        sudo ln -sf "$service_file" /etc/systemd/user/default.target.wants/
    fi

    # Install bundled icons and cursors to /usr/share/icons/
    local theme_dir_light="${THEME_INSTALL_DIR:-}/org.kde.custom.light"
    for asset_type in icons cursors; do
        for theme_dir in "$theme_dir_light" "${THEME_INSTALL_DIR:-}/org.kde.custom.dark"; do
            [[ -d "${theme_dir}/contents/${asset_type}" ]] || continue
            for asset_dir in "${theme_dir}/contents/${asset_type}"/*/; do
                [[ -d "$asset_dir" ]] || continue
                local asset_name
                asset_name="$(basename "$asset_dir")"
                if [[ ! -d "/usr/share/icons/${asset_name}" ]]; then
                    sudo cp -r "$asset_dir" "/usr/share/icons/${asset_name}"
                fi
            done
        done
    done

    # Install bundled wallpapers to /usr/share/wallpapers/
    if [[ -d "${theme_dir_light}/contents/wallpapers" ]]; then
        for pack_dir in "${theme_dir_light}/contents/wallpapers"/gloam-*/; do
            [[ -d "$pack_dir" ]] || continue
            local pack_name
            pack_name="$(basename "$pack_dir")"
            if [[ ! -d "/usr/share/wallpapers/${pack_name}" ]]; then
                sudo cp -r "$pack_dir" "/usr/share/wallpapers/${pack_name}"
            fi
        done
    fi

    # Fallback: install icon/cursor themes directly from local dirs (no custom theme)
    install_icons_system_wide

    # Set system-wide default desktop wallpaper via Plasma plugin config
    if [[ "${WALLPAPER:-}" == true && -d "/usr/share/wallpapers/gloam-dynamic" ]]; then
        local wp_main_xml="/usr/share/plasma/wallpapers/org.kde.image/contents/config/main.xml"
        if [[ -f "$wp_main_xml" ]]; then
            sudo sed -i '/<entry name="Image"/,/<\/entry>/ s|<default>[^<]*</default>|<default>file:///usr/share/wallpapers/gloam-dynamic</default>|' "$wp_main_xml" 2>/dev/null || true
        fi
    fi

    # Set keyboard shortcut in /etc/xdg/kglobalshortcutsrc
    sudo kwriteconfig6 --file /etc/xdg/kglobalshortcutsrc --group "services" --group "$SHORTCUT_ID" --key "_launch" "Meta+Shift+L"

    echo -e "${GREEN}System defaults configured for new users.${RESET}"
}

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
                # Aurorae themes - strip prefix
                echo "${id#__aurorae__svg__}" && return 0
            elif [[ "$id" == "kwin4_decoration_qml_"* ]]; then
                # KPackage/QML decorations - look up name or strip prefix
                for dir in /usr/share/kwin/decorations "${HOME}/.local/share/kwin/decorations"; do
                    if [[ -f "${dir}/${id}/metadata.json" ]] && command -v jq &>/dev/null; then
                        jq -r '.KPlugin.Name // empty' "${dir}/${id}/metadata.json" 2>/dev/null && return 0
                    fi
                done
                echo "${id#kwin4_decoration_qml_}" && return 0
            fi
            # Simple names like "Breeze", "Oxygen" - return as-is
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
        sddm)
            local conf="/usr/share/sddm/themes/${id}/theme.conf"
            if [[ -f "$conf" ]]; then
                grep -m1 "^Name=" "$conf" 2>/dev/null | cut -d= -f2 && return 0
            fi
            ;;
    esac
    echo "$id"
}

show_laf_reminder() {
    echo -e "${YELLOW}Reminder:${RESET} Make sure your Light and Dark themes are set to your preferred themes."
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
            local name
            name="$(basename "$theme_dir")"
            # Skip the "default" stub
            [[ "$name" == "default" ]] && continue
            # Skip themes marked as hidden
            grep -qi '^Hidden=true' "${theme_dir}index.theme" 2>/dev/null && continue
            # Must have actions or apps dirs (excludes cursor-only themes)
            local has_icons
            has_icons=$(find -L "$theme_dir" -maxdepth 2 -type d \( -name actions -o -name apps \) -print -quit 2>/dev/null)
            [[ -z "$has_icons" ]] && continue
            themes+=("$name")
        done
    done
    # Deduplicate and sort
    printf '%s\n' "${themes[@]}" | sort -u
}

scan_cursor_themes() {
    # Use KDE's tool to list cursor themes
    # Parse output like: " * Breeze Light [Breeze_Light]"
    plasma-apply-cursortheme --list-themes 2>/dev/null | \
        sed -n 's/.*\* \(.*\) \[\(.*\)\].*/\2|\1/p'
}

scan_window_decorations() {
    # Use KDE's tool to list all available window decorations
    # Parse output like: " * Plastik (theme name: kwin4_decoration_qml_plastik)"
    /usr/lib/kwin-applywindowdecoration --list-themes 2>/dev/null | \
        sed -n 's/.*\* \(.*\) (theme name: \([^)]*\)).*/\2|\1/p' | \
        sed 's/ - current theme for this Plasma session//'
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

scan_sddm_themes() {
    local sddm_dir="/usr/share/sddm/themes"
    [[ -d "$sddm_dir" ]] || return 0
    for theme_dir in "$sddm_dir"/*/; do
        [[ -f "${theme_dir}theme.conf" || -f "${theme_dir}metadata.desktop" ]] || continue
        local id name
        id="$(basename "$theme_dir")"
        name=$(get_friendly_name sddm "$id")
        printf '%s|%s\n' "$id" "$name"
    done | sort -t'|' -k2
}

scan_app_styles() {
    python3 -c "from PyQt6.QtWidgets import QStyleFactory; print('\n'.join(sorted(set(QStyleFactory.keys()))))"
}

get_image_dimensions() {
    local path="$1"
    python3 -c "
from PyQt6.QtGui import QImage
img = QImage('${path//\'/\\\'}')
if not img.isNull():
    print(f'{img.width()}x{img.height()}')
"
}

resolve_image_paths() {
    local input="$1"
    local images=()
    for path in $input; do
        # Expand tilde
        path="${path/#\~/$HOME}"
        if [[ -d "$path" ]]; then
            for ext in png jpg jpeg webp bmp; do
                for img in "$path"/*."$ext"; do
                    [[ -f "$img" ]] && images+=("$img")
                done
            done
        elif [[ -f "$path" ]]; then
            images+=("$path")
        fi
    done
    printf '%s\n' "${images[@]}"
}

generate_wallpaper_pack() {
    local pack_name="$1"
    local display_name="$2"
    local -n _light_imgs=$3
    local -n _dark_imgs=$4
    local wallpaper_dir
    local _global="${THEME_INSTALL_GLOBAL:-${INSTALL_GLOBAL:-false}}"

    if [[ "$_global" == true ]]; then
        wallpaper_dir="/usr/share/wallpapers/${pack_name}"
    else
        wallpaper_dir="${HOME}/.local/share/wallpapers/${pack_name}"
    fi

    # Clean and create directory structure
    if [[ "$_global" == true ]]; then
        sudo rm -rf "$wallpaper_dir"
        sudo mkdir -p "${wallpaper_dir}/contents/images"
    else
        rm -rf "$wallpaper_dir"
        mkdir -p "${wallpaper_dir}/contents/images"
    fi

    # Copy light images
    for img in "${_light_imgs[@]}"; do
        [[ -f "$img" ]] || continue
        local dims ext
        dims=$(get_image_dimensions "$img")
        [[ -z "$dims" ]] && continue
        ext="${img##*.}"
        if [[ "$_global" == true ]]; then
            sudo cp "$img" "${wallpaper_dir}/contents/images/${dims}.${ext,,}"
        else
            cp "$img" "${wallpaper_dir}/contents/images/${dims}.${ext,,}"
        fi
    done

    # Copy dark images (if any)
    if [[ ${#_dark_imgs[@]} -gt 0 ]]; then
        if [[ "$_global" == true ]]; then
            sudo mkdir -p "${wallpaper_dir}/contents/images_dark"
        else
            mkdir -p "${wallpaper_dir}/contents/images_dark"
        fi
        for img in "${_dark_imgs[@]}"; do
            [[ -f "$img" ]] || continue
            local dims ext
            dims=$(get_image_dimensions "$img")
            [[ -z "$dims" ]] && continue
            ext="${img##*.}"
            if [[ "$_global" == true ]]; then
                sudo cp "$img" "${wallpaper_dir}/contents/images_dark/${dims}.${ext,,}"
            else
                cp "$img" "${wallpaper_dir}/contents/images_dark/${dims}.${ext,,}"
            fi
        done
    fi

    # Generate metadata.json
    if [[ "$_global" == true ]]; then
        sudo tee "${wallpaper_dir}/metadata.json" > /dev/null <<METADATA
{
    "KPlugin": {
        "Authors": [
            {
                "Name": "gloam"
            }
        ],
        "Id": "${pack_name}",
        "License": "CC-BY-SA-4.0",
        "Name": "${display_name}"
    }
}
METADATA
    else
        cat > "${wallpaper_dir}/metadata.json" <<METADATA
{
    "KPlugin": {
        "Authors": [
            {
                "Name": "gloam"
            }
        ],
        "Id": "${pack_name}",
        "License": "CC-BY-SA-4.0",
        "Name": "${display_name}"
    }
}
METADATA
    fi

    echo -e "  ${GREEN}Created:${RESET} ${display_name} — ${wallpaper_dir}/"
}

scan_color_schemes() {
    local schemes=()
    for dir in /usr/share/color-schemes "${HOME}/.local/share/color-schemes"; do
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
    local seen_ids=""
    for dir in /usr/share/plasma/desktoptheme "${HOME}/.local/share/plasma/desktoptheme"; do
        [[ -d "$dir" ]] || continue
        for style_dir in "$dir"/*/; do
            [[ -f "${style_dir}metadata.json" || -f "${style_dir}metadata.desktop" ]] || continue
            local id
            id="$(basename "$style_dir")"
            [[ "$id" == "default" ]] && continue
            [[ "$seen_ids" == *"|$id|"* ]] && continue
            seen_ids+="|$id|"
            printf '%s\n' "$id"
        done
    done | sort
}

install_plasmoid() {
    local script_dir install_dir
    script_dir="$(dirname "$(readlink -f "$0")")"
    local plasmoid_src="${script_dir}/plasmoid"
    install_dir="$(get_plasmoid_path)"

    if [[ ! -d "$plasmoid_src" ]]; then
        echo -e "${RED}Error: Plasmoid source not found at $plasmoid_src${RESET}" >&2
        return 1
    fi

    if [[ "$INSTALL_GLOBAL" == true ]]; then
        sudo mkdir -p "$install_dir"
        sudo cp -r "$plasmoid_src"/* "$install_dir/"
    else
        mkdir -p "$install_dir"
        cp -r "$plasmoid_src"/* "$install_dir/"
    fi

    echo -e "${GREEN}Installed Light/Dark Mode Toggle widget to $install_dir${RESET}"
    echo "You can add it to your panel by right-clicking the panel > Add Widgets > Light/Dark Mode Toggle"
}

remove_plasmoid() {
    local local_path="${HOME}/.local/share/plasma/plasmoids/${PLASMOID_ID}"
    local global_path="/usr/share/plasma/plasmoids/${PLASMOID_ID}"

    [[ -d "$local_path" ]] && rm -rf "$local_path" && echo "Removed $local_path"
    [[ -d "$global_path" ]] && sudo rm -rf "$global_path" && echo "Removed $global_path"
    return 0
}

install_shortcut() {
    local desktop_file
    desktop_file="$(get_desktop_file_path)"

    local desktop_content="[Desktop Entry]
Type=Application
Name=Light/Dark Mode Toggle
Exec=gloam toggle
NoDisplay=true
StartupNotify=false
X-KDE-GlobalAccel-CommandShortcut=true"

    if [[ "$INSTALL_GLOBAL" == true ]]; then
        echo "$desktop_content" | sudo tee "$desktop_file" > /dev/null
    else
        mkdir -p "$(dirname "$desktop_file")"
        echo "$desktop_content" > "$desktop_file"
    fi

    # Register the shortcut with KDE (Meta+Shift+L) - always per-user
    kwriteconfig6 --file kglobalshortcutsrc --group "services" --group "$SHORTCUT_ID" --key "_launch" "Meta+Shift+L"

    echo -e "${GREEN}Keyboard shortcut installed: Meta+Shift+L${RESET}"
    echo "You can change it in System Settings > Shortcuts > Commands"
    echo -e "${YELLOW}Note:${RESET} You may need to log out and back in for the shortcut to take effect."
}

remove_shortcut() {
    local local_file="${HOME}/.local/share/applications/gloam-toggle.desktop"
    local global_file="/usr/share/applications/gloam-toggle.desktop"
    local had_shortcut=false

    [[ -f "$local_file" ]] && rm -f "$local_file" && echo "Removed $local_file" && had_shortcut=true
    [[ -f "$global_file" ]] && sudo rm -f "$global_file" && echo "Removed $global_file" && had_shortcut=true

    # Remove from kglobalshortcutsrc (per-user) only if we actually had the shortcut installed
    if [[ "$had_shortcut" == true ]] && grep -q "$SHORTCUT_ID" "${HOME}/.config/kglobalshortcutsrc" 2>/dev/null; then
        kwriteconfig6 --file kglobalshortcutsrc --group "services" --group "$SHORTCUT_ID" --key "_launch" --delete
        echo "Removed keyboard shortcut binding"
    fi
    return 0
}

cleanup_stale() {
    local dirty=0
    local local_service="${HOME}/.config/systemd/user/${SERVICE_NAME}.service"

    if systemctl --user is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        systemctl --user stop "$SERVICE_NAME"
        dirty=1
    fi
    if systemctl --user is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then
        systemctl --user disable "$SERVICE_NAME"
        dirty=1
    fi
    [[ -f "$local_service" ]] && rm "$local_service" && dirty=1
    [[ -f "$CONFIG_FILE" ]] && rm "$CONFIG_FILE" && dirty=1
    if [[ "$dirty" -eq 1 ]]; then
        systemctl --user daemon-reload
        echo -e "${GREEN}Cleaned up previous installation.${RESET}"
        echo ""
    fi
}

check_desktop_environment() {
    if [[ "$XDG_CURRENT_DESKTOP" != *"KDE"* ]]; then
        die "This script requires KDE Plasma desktop environment."
    fi
}

check_dependencies() {
    local missing=()
    command -v inotifywait &>/dev/null || missing+=("inotify-tools")
    command -v kreadconfig6 &>/dev/null || missing+=("kreadconfig6")
    command -v kwriteconfig6 &>/dev/null || missing+=("kwriteconfig6")

    if [[ ${#missing[@]} -gt 0 ]]; then
        die "Missing dependencies:\n$(printf '  - %s\n' "${missing[@]}")"
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

apply_browser_color_scheme() {
    local mode="$1"  # 'light' or 'dark'
    local color_scheme portal_value

    if [[ "$mode" == "dark" ]]; then
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
            # Also mask the splash service to completely prevent it from running at login
            systemctl --user mask plasma-ksplash.service 2>/dev/null || true
        else
            kwriteconfig6 --file ksplashrc --group KSplash --key Theme "$splash"
            kwriteconfig6 --file ksplashrc --group KSplash --key Engine "KSplashQML"
            # Unmask the splash service so it can run at login
            systemctl --user unmask plasma-ksplash.service 2>/dev/null || true
        fi
    fi
}

apply_sddm_theme() {
    local theme="$1"
    if [[ -n "$theme" ]]; then
        # Delay to let KDE finish applying LookAndFeel
        sleep 1.5
        if [[ -x /usr/local/lib/gloam/set-sddm-theme ]]; then
            sudo /usr/local/lib/gloam/set-sddm-theme "$theme" 2>/dev/null || warn "Failed to apply SDDM theme: $theme"
        else
            sudo kwriteconfig6 --file /etc/sddm.conf.d/kde_settings.conf \
                --group Theme --key Current "$theme" 2>/dev/null || warn "Failed to apply SDDM theme: $theme"
        fi
    fi
}

apply_desktop_wallpaper() {
    local wallpaper_dir="$1"
    plasma-apply-wallpaperimage "$wallpaper_dir" >/dev/null 2>&1 || warn "Failed to apply desktop wallpaper: $wallpaper_dir"
}

apply_lockscreen_wallpaper() {
    local wallpaper_dir="$1"
    kwriteconfig6 --file kscreenlockerrc \
        --group Greeter --group Wallpaper --group org.kde.image --group General \
        --key Image "file://${wallpaper_dir}"
}

is_gloam_wallpaper() {
    local surface="$1"  # "desktop", "lockscreen", or "sddm"
    case "$surface" in
        desktop)
            local rc="${HOME}/.config/plasma-org.kde.plasma.desktop-appletsrc"
            [[ -f "$rc" ]] || return 1
            local wp
            wp=$(awk '/\[Wallpaper\]\[org\.kde\.image\]\[General\]/ { found=1; next }
                 /^\[/ { found=0 }
                 found && /^Image=/ { print substr($0, 7); exit }' "$rc")
            [[ "$wp" == *"/wallpapers/gloam-"* ]]
            ;;
        lockscreen)
            local wp
            wp=$(kreadconfig6 --file kscreenlockerrc \
                --group Greeter --group Wallpaper --group org.kde.image --group General \
                --key Image 2>/dev/null)
            [[ "$wp" == *"/wallpapers/gloam-"* ]]
            ;;
        sddm)
            local theme bg
            theme=$(kreadconfig6 --file /etc/sddm.conf.d/kde_settings.conf \
                --group Theme --key Current 2>/dev/null)
            [[ -z "$theme" ]] && theme="breeze"
            bg=$(kreadconfig6 --file "/usr/share/sddm/themes/${theme}/theme.conf.user" \
                --group General --key background 2>/dev/null)
            [[ "$bg" == "/usr/local/lib/gloam/"* ]]
            ;;
    esac
}

apply_sddm_wallpaper() {
    local image="$1"
    if [[ -n "$image" && -f "$image" ]]; then
        if [[ -x /usr/local/lib/gloam/set-sddm-background ]]; then
            sudo /usr/local/lib/gloam/set-sddm-background "$image" 2>/dev/null || warn "Failed to apply SDDM background: $image"
        fi
    fi
}

setup_sddm_sudoers() {
    # Create wrapper script
    sudo mkdir -p /usr/local/lib/gloam
    sudo tee /usr/local/lib/gloam/set-sddm-theme > /dev/null <<'SCRIPT'
#!/bin/bash
[[ -z "$1" ]] && exit 1
kwriteconfig6 --file /etc/sddm.conf.d/kde_settings.conf --group Theme --key Current "$1"
SCRIPT
    sudo chmod 755 /usr/local/lib/gloam/set-sddm-theme

    # Create sudoers rule
    echo "ALL ALL=(ALL) NOPASSWD: /usr/local/lib/gloam/set-sddm-theme" | \
        sudo tee /etc/sudoers.d/gloam-sddm > /dev/null
    sudo chmod 440 /etc/sudoers.d/gloam-sddm
}

setup_sddm_wallpaper() {
    sudo mkdir -p /usr/local/lib/gloam

    # Find the wallpaper pack base directory
    local wp_base
    if [[ -n "${WALLPAPER_BASE:-}" ]]; then
        wp_base="$WALLPAPER_BASE"
    elif [[ "${THEME_INSTALL_GLOBAL:-false}" == true ]]; then
        wp_base="/usr/share/wallpapers"
    else
        wp_base="${HOME}/.local/share/wallpapers"
    fi

    # Pick the largest image from each pack for SDDM
    local best_light="" best_dark="" best_pixels=0
    for img in "${wp_base}/gloam-light/contents/images/"*; do
        [[ -f "$img" ]] || continue
        local dims
        dims=$(get_image_dimensions "$img")
        [[ -z "$dims" ]] && continue
        local w h
        w="${dims%x*}"; h="${dims#*x}"
        if (( w * h > best_pixels )); then
            best_pixels=$(( w * h ))
            best_light="$img"
        fi
    done

    best_pixels=0
    for img in "${wp_base}/gloam-dark/contents/images/"*; do
        [[ -f "$img" ]] || continue
        local dims
        dims=$(get_image_dimensions "$img")
        [[ -z "$dims" ]] && continue
        local w h
        w="${dims%x*}"; h="${dims#*x}"
        if (( w * h > best_pixels )); then
            best_pixels=$(( w * h ))
            best_dark="$img"
        fi
    done

    # Copy images to system-accessible location
    if [[ -n "$best_light" ]]; then
        local ext="${best_light##*.}"
        sudo cp "$best_light" "/usr/local/lib/gloam/sddm-bg-light.${ext,,}"
    fi
    if [[ -n "$best_dark" ]]; then
        local ext="${best_dark##*.}"
        sudo cp "$best_dark" "/usr/local/lib/gloam/sddm-bg-dark.${ext,,}"
    fi

    # Create wrapper script
    sudo tee /usr/local/lib/gloam/set-sddm-background > /dev/null <<'SCRIPT'
#!/bin/bash
[[ -z "$1" || ! -f "$1" ]] && exit 1
THEME=$(kreadconfig6 --file /etc/sddm.conf.d/kde_settings.conf --group Theme --key Current 2>/dev/null)
[[ -z "$THEME" ]] && THEME="breeze"
THEME_DIR="/usr/share/sddm/themes/$THEME"
[[ -d "$THEME_DIR" ]] || exit 1
kwriteconfig6 --file "$THEME_DIR/theme.conf.user" --group General --key background "$1"
SCRIPT
    sudo chmod 755 /usr/local/lib/gloam/set-sddm-background

    # Create sudoers rule
    echo "ALL ALL=(ALL) NOPASSWD: /usr/local/lib/gloam/set-sddm-background" | \
        sudo tee /etc/sudoers.d/gloam-sddm-bg > /dev/null
    sudo chmod 440 /etc/sudoers.d/gloam-sddm-bg
}

apply_color_scheme() {
    local scheme="$1"
    plasma-apply-colorscheme "$scheme" >/dev/null 2>&1 || warn "Failed to apply color scheme: $scheme"
}

apply_plasma_style() {
    local style="$1"
    plasma-apply-desktoptheme "$style" >/dev/null 2>&1 || warn "Failed to apply plasma style: $style"
}

apply_cursor_theme() {
    local theme="$1"
    plasma-apply-cursortheme "$theme" >/dev/null 2>&1 || warn "Failed to apply cursor theme: $theme"
}

apply_window_decoration() {
    local decoration="$1"
    /usr/lib/kwin-applywindowdecoration "$decoration" >/dev/null 2>&1 || warn "Failed to apply window decoration: $decoration"
}


refresh_kvantum_style() {
    local style="$1"
    kwriteconfig6 --file kdeglobals --group KDE --key widgetStyle "$style"
}

apply_app_style() {
    local style="$1"
    if [[ -n "$style" ]]; then
        kwriteconfig6 --file kdeglobals --group KDE --key widgetStyle "$style"
    fi
}

# Check if user configured any options that can be bundled into a custom theme
has_bundleable_options() {
    [[ -n "${COLOR_LIGHT:-}" || -n "${COLOR_DARK:-}" || \
       -n "${ICON_LIGHT:-}" || -n "${ICON_DARK:-}" || \
       -n "${CURSOR_LIGHT:-}" || -n "${CURSOR_DARK:-}" || \
       -n "${STYLE_LIGHT:-}" || -n "${STYLE_DARK:-}" || \
       -n "${DECORATION_LIGHT:-}" || -n "${DECORATION_DARK:-}" || \
       -n "${SPLASH_LIGHT:-}" || -n "${SPLASH_DARK:-}" || \
       -n "${SDDM_LIGHT:-}" || -n "${SDDM_DARK:-}" || \
       -n "${APPSTYLE_LIGHT:-}" || -n "${APPSTYLE_DARK:-}" ]]
}

# Prompt user for global vs local theme install, authenticate sudo if needed
request_sudo_for_global_install() {
    # If already in global install mode, use global paths automatically
    if [[ "$INSTALL_GLOBAL" == true ]]; then
        THEME_INSTALL_DIR="$(get_theme_install_dir)"
        THEME_INSTALL_GLOBAL=true
        echo "Custom themes will be installed globally (matching your installation mode)."
        return 0
    fi

    echo ""
    echo -e "${BOLD}Custom Theme Installation${RESET}"
    echo "Your theme overrides can be saved as custom Plasma themes."
    echo ""
    echo "Installation options:"
    echo "  Global: /usr/share/plasma/look-and-feel/ (requires sudo)"
    echo "  Local:  ~/.local/share/plasma/look-and-feel/ (user only)"
    echo ""

    read -rp "Install themes globally? [y/N]: " choice
    if [[ "$choice" =~ ^[Yy]$ ]]; then
        echo "Requesting sudo access..."
        if sudo -v; then
            THEME_INSTALL_DIR="/usr/share/plasma/look-and-feel"
            THEME_INSTALL_GLOBAL=true
            echo -e "${GREEN}Sudo authenticated. Themes will be installed globally.${RESET}"
            return 0
        else
            echo -e "${YELLOW}Sudo authentication failed.${RESET}"
            read -rp "Install locally instead? [Y/n]: " fallback
            if [[ "$fallback" =~ ^[Nn]$ ]]; then
                echo "Skipping custom theme generation."
                return 1
            fi
        fi
    fi

    THEME_INSTALL_DIR="${HOME}/.local/share/plasma/look-and-feel"
    THEME_INSTALL_GLOBAL=false
    echo "Themes will be installed locally."
    return 0
}

# Generate a custom look-and-feel theme package
generate_custom_theme() {
    local mode="$1"  # "light" or "dark"
    local base_theme="$2"  # Original LAF theme to fork
    local theme_id="org.kde.custom.${mode}"
    local theme_name="Custom (${mode^})"  # Capitalize first letter
    local theme_dir="${THEME_INSTALL_DIR}/${theme_id}"

    # Find base theme directory
    local base_theme_dir=""
    for dir in /usr/share/plasma/look-and-feel "${HOME}/.local/share/plasma/look-and-feel"; do
        if [[ -d "${dir}/${base_theme}" ]]; then
            base_theme_dir="${dir}/${base_theme}"
            break
        fi
    done

    if [[ -z "$base_theme_dir" ]]; then
        echo -e "  ${RED}Error: Base theme not found: ${base_theme}${RESET}" >&2
        return 1
    fi

    # Remove existing custom theme if present
    if [[ "$THEME_INSTALL_GLOBAL" == true ]]; then
        sudo rm -rf "$theme_dir"
        sudo cp -r "$base_theme_dir" "$theme_dir"
    else
        rm -rf "$theme_dir"
        cp -r "$base_theme_dir" "$theme_dir"
    fi

    # Select user overrides based on mode
    local color_scheme icon_theme cursor_theme plasma_style decoration splash_theme sddm_theme app_style
    if [[ "$mode" == "light" ]]; then
        color_scheme="${COLOR_LIGHT:-}"
        icon_theme="${ICON_LIGHT:-}"
        cursor_theme="${CURSOR_LIGHT:-}"
        plasma_style="${STYLE_LIGHT:-}"
        decoration="${DECORATION_LIGHT:-}"
        splash_theme="${SPLASH_LIGHT:-}"
        sddm_theme="${SDDM_LIGHT:-}"
        app_style="${APPSTYLE_LIGHT:-}"
    else
        color_scheme="${COLOR_DARK:-}"
        icon_theme="${ICON_DARK:-}"
        cursor_theme="${CURSOR_DARK:-}"
        plasma_style="${STYLE_DARK:-}"
        decoration="${DECORATION_DARK:-}"
        splash_theme="${SPLASH_DARK:-}"
        sddm_theme="${SDDM_DARK:-}"
        app_style="${APPSTYLE_DARK:-}"
    fi

    # Update metadata.json with new ID and name, preserving original authors
    local author_block author_name author_email original_authors
    author_block=$(awk '/"Authors"/,/\]/' "${base_theme_dir}/metadata.json" 2>/dev/null) || log "WARN: Could not extract author block from ${base_theme_dir}/metadata.json"
    author_name=$(echo "$author_block" | grep -m1 '"Name"[[:space:]]*:' | sed 's/.*"Name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/') || true
    author_email=$(echo "$author_block" | grep -m1 '"Email"[[:space:]]*:' | sed 's/.*"Email"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/') || true
    [[ -z "$author_name" ]] && author_name="Unknown"
    local original_credit
    if [[ -n "$author_email" ]]; then
        original_credit='{ "Email": "'"$author_email"'", "Name": "'"$author_name"'" }'
    else
        original_credit='{ "Name": "'"$author_name"'" }'
    fi

    local metadata
    metadata=$(cat <<METADATA
{
    "KPlugin": {
        "Authors": [{ "Name": "gloam" }, ${original_credit}],
        "Description": "Custom ${mode} theme based on $(basename "$base_theme_dir")",
        "Id": "${theme_id}",
        "Name": "${theme_name}",
        "Version": "1.0"
    },
    "KPackageStructure": "Plasma/LookAndFeel",
    "X-Plasma-APIVersion": "2"
}
METADATA
)

    if [[ "$THEME_INSTALL_GLOBAL" == true ]]; then
        echo "$metadata" | sudo tee "${theme_dir}/metadata.json" > /dev/null
    else
        echo "$metadata" > "${theme_dir}/metadata.json"
    fi

    # Modify defaults file - only override what user explicitly configured
    local defaults_file="${theme_dir}/contents/defaults"

    # Helper to update a key in defaults file
    update_defaults_key() {
        local section="$1" key="$2" value="$3"
        local tmpfile
        tmpfile=$(gloam_mktemp)

        local awk_script='
        BEGIN { in_section=0; key_done=0; section_found=0 }
        /^\[/ {
            if (in_section && !key_done) { print key "=" value; key_done=1 }
            in_section = ($0 == section)
            if (in_section) section_found=1
        }
        in_section && $0 ~ "^" key "=" { print key "=" value; key_done=1; next }
        { print }
        END {
            if (in_section && !key_done) print key "=" value
            if (!section_found) print "\n" section "\n" key "=" value
        }'

        if [[ "$THEME_INSTALL_GLOBAL" == true ]]; then
            sudo awk -v section="$section" -v key="$key" -v value="$value" "$awk_script" "$defaults_file" > "$tmpfile"
            sudo mv "$tmpfile" "$defaults_file"
            sudo chmod 644 "$defaults_file"
            sudo chown root:root "$defaults_file"
        else
            awk -v section="$section" -v key="$key" -v value="$value" "$awk_script" "$defaults_file" > "$tmpfile"
            mv "$tmpfile" "$defaults_file"
        fi
    }

    # Apply user overrides to defaults
    [[ -n "$color_scheme" ]] && update_defaults_key "[kdeglobals][General]" "ColorScheme" "$color_scheme"
    [[ -n "$icon_theme" ]] && update_defaults_key "[kdeglobals][Icons]" "Theme" "$icon_theme"
    [[ -n "$cursor_theme" ]] && update_defaults_key "[kcminputrc][Mouse]" "cursorTheme" "$cursor_theme"
    [[ -n "$plasma_style" ]] && update_defaults_key "[plasmarc][Theme]" "name" "$plasma_style"

    # Window decoration
    if [[ -n "$decoration" ]]; then
        local dec_library dec_theme
        if [[ "$decoration" == "__aurorae__svg__"* ]]; then
            dec_library="org.kde.kwin.aurorae"
            dec_theme="${decoration}"
        elif [[ "$decoration" == "kwin4_decoration_qml_"* ]]; then
            dec_library="${decoration}"
            dec_theme=""
        else
            dec_library="org.kde.${decoration,,}"
            dec_theme="${decoration}"
        fi
        update_defaults_key "[kwinrc][org.kde.kdecoration2]" "library" "$dec_library"
        update_defaults_key "[kwinrc][org.kde.kdecoration2]" "theme" "$dec_theme"
    fi

    # Splash screen
    if [[ -n "$splash_theme" ]]; then
        if [[ "$splash_theme" == "None" ]]; then
            update_defaults_key "[KSplash]" "Engine" "none"
            update_defaults_key "[KSplash]" "Theme" "None"
            # Remove splash assets since we're disabling it
            if [[ "$THEME_INSTALL_GLOBAL" == true ]]; then
                sudo rm -rf "${theme_dir}/contents/splash"
            else
                rm -rf "${theme_dir}/contents/splash"
            fi
        else
            update_defaults_key "[KSplash]" "Engine" "KSplashQML"
            update_defaults_key "[KSplash]" "Theme" "$splash_theme"
        fi
    fi

    # SDDM theme
    [[ -n "$sddm_theme" ]] && update_defaults_key "[sddm][Theme]" "Current" "$sddm_theme"

    # Application style (Qt widget style)
    [[ -n "$app_style" ]] && update_defaults_key "[kdeglobals][KDE]" "widgetStyle" "$app_style"

    # Bundle color scheme into theme (native LAF support)
    if [[ -n "$color_scheme" ]]; then
        local color_src=""
        for dir in /usr/share/color-schemes "${HOME}/.local/share/color-schemes"; do
            if [[ -f "${dir}/${color_scheme}.colors" ]]; then
                color_src="${dir}/${color_scheme}.colors"
                break
            fi
        done
        if [[ -n "$color_src" ]]; then
            if [[ "$THEME_INSTALL_GLOBAL" == true ]]; then
                sudo mkdir -p "${theme_dir}/contents/colors"
                sudo cp "$color_src" "${theme_dir}/contents/colors/${color_scheme}.colors"
            else
                mkdir -p "${theme_dir}/contents/colors"
                cp "$color_src" "${theme_dir}/contents/colors/${color_scheme}.colors"
            fi
        fi
    fi

    # Bundle icon theme (and any sibling themes it symlinks to) into theme directory
    if [[ -n "$icon_theme" ]]; then
        local icon_src="" icon_src_dir=""
        for dir in /usr/share/icons "${HOME}/.local/share/icons" "${HOME}/.icons"; do
            if [[ -d "${dir}/${icon_theme}" ]]; then
                icon_src="${dir}/${icon_theme}"
                icon_src_dir="$dir"
                break
            fi
        done
        if [[ -n "$icon_src" ]]; then
            # Collect the theme and any sibling themes it symlinks to (e.g. WhiteSur-light -> ../WhiteSur/)
            local icon_themes_to_bundle=("$icon_theme")
            local link_target
            while IFS= read -r link_target; do
                # Resolve relative symlink targets like ../WhiteSur/actions to extract theme name
                local dep_name
                dep_name=$(echo "$link_target" | sed -n 's|^\.\./\([^/]*\)/.*|\1|p')
                [[ -z "$dep_name" ]] && continue
                # Skip if already in the list or same as main theme
                local already=false
                for existing in "${icon_themes_to_bundle[@]}"; do
                    [[ "$existing" == "$dep_name" ]] && already=true && break
                done
                [[ "$already" == true ]] && continue
                # Only add if the dependency exists in the same parent directory
                [[ -d "${icon_src_dir}/${dep_name}" ]] && icon_themes_to_bundle+=("$dep_name")
            done < <(find -L "$icon_src" -maxdepth 1 -type l -printf '%l\n' 2>/dev/null || find "$icon_src" -maxdepth 1 -type l -exec readlink {} \; 2>/dev/null)

            for icon_name in "${icon_themes_to_bundle[@]}"; do
                local src_path="${icon_src_dir}/${icon_name}"
                [[ -d "$src_path" ]] || continue
                if [[ "$THEME_INSTALL_GLOBAL" == true ]]; then
                    sudo mkdir -p "${theme_dir}/contents/icons"
                    sudo cp -r "$src_path" "${theme_dir}/contents/icons/${icon_name}"
                else
                    mkdir -p "${theme_dir}/contents/icons"
                    cp -r "$src_path" "${theme_dir}/contents/icons/${icon_name}"
                fi
                # Global install: ensure icons are in /usr/share/icons for system-wide access
                if [[ "$THEME_INSTALL_GLOBAL" == true && "$src_path" != /usr/share/icons/* ]]; then
                    sudo cp -r "$src_path" "/usr/share/icons/${icon_name}"
                    rm -rf "$src_path"
                    # Record original location for restore on uninstall (main theme only)
                    if [[ "$icon_name" == "$icon_theme" ]]; then
                        if [[ "$mode" == "light" ]]; then
                            ICON_LIGHT_MOVED_FROM="$(dirname "$src_path")"
                        else
                            ICON_DARK_MOVED_FROM="$(dirname "$src_path")"
                        fi
                    fi
                fi
            done
            [[ "$THEME_INSTALL_GLOBAL" == true && "$icon_src" != /usr/share/icons/* ]] && \
                "$PLASMA_CHANGEICONS" "$icon_theme" >/dev/null 2>&1 || log "WARN: Failed to re-apply icon theme: $icon_theme"
        fi
    fi

    # Bundle cursor theme (and any sibling themes it symlinks to) into theme directory
    if [[ -n "$cursor_theme" ]]; then
        local cursor_src="" cursor_src_dir=""
        for dir in /usr/share/icons "${HOME}/.local/share/icons" "${HOME}/.icons"; do
            if [[ -d "${dir}/${cursor_theme}/cursors" ]]; then
                cursor_src="${dir}/${cursor_theme}"
                cursor_src_dir="$dir"
                break
            fi
        done
        if [[ -n "$cursor_src" ]]; then
            # Collect the theme and any sibling themes it symlinks to
            local cursor_themes_to_bundle=("$cursor_theme")
            local link_target
            while IFS= read -r link_target; do
                local dep_name
                dep_name=$(echo "$link_target" | sed -n 's|^\.\./\([^/]*\)/.*|\1|p')
                [[ -z "$dep_name" ]] && continue
                local already=false
                for existing in "${cursor_themes_to_bundle[@]}"; do
                    [[ "$existing" == "$dep_name" ]] && already=true && break
                done
                [[ "$already" == true ]] && continue
                [[ -d "${cursor_src_dir}/${dep_name}" ]] && cursor_themes_to_bundle+=("$dep_name")
            done < <(find -L "$cursor_src" -maxdepth 1 -type l -printf '%l\n' 2>/dev/null || find "$cursor_src" -maxdepth 1 -type l -exec readlink {} \; 2>/dev/null)

            for cursor_name in "${cursor_themes_to_bundle[@]}"; do
                local src_path="${cursor_src_dir}/${cursor_name}"
                [[ -d "$src_path" ]] || continue
                if [[ "$THEME_INSTALL_GLOBAL" == true ]]; then
                    sudo mkdir -p "${theme_dir}/contents/cursors"
                    sudo cp -r "$src_path" "${theme_dir}/contents/cursors/${cursor_name}"
                else
                    mkdir -p "${theme_dir}/contents/cursors"
                    cp -r "$src_path" "${theme_dir}/contents/cursors/${cursor_name}"
                fi
                # Global install: ensure cursors are in /usr/share/icons for system-wide access
                if [[ "$THEME_INSTALL_GLOBAL" == true && "$src_path" != /usr/share/icons/* ]]; then
                    sudo cp -r "$src_path" "/usr/share/icons/${cursor_name}"
                    rm -rf "$src_path"
                    # Record original location for restore on uninstall (main theme only)
                    if [[ "$cursor_name" == "$cursor_theme" ]]; then
                        if [[ "$mode" == "light" ]]; then
                            CURSOR_LIGHT_MOVED_FROM="$(dirname "$src_path")"
                        else
                            CURSOR_DARK_MOVED_FROM="$(dirname "$src_path")"
                        fi
                    fi
                fi
            done
            [[ "$THEME_INSTALL_GLOBAL" == true && "$cursor_src" != /usr/share/icons/* ]] && \
                plasma-apply-cursortheme "$cursor_theme" >/dev/null 2>&1 || log "WARN: Failed to re-apply cursor theme: $cursor_theme"
        fi
    fi

    # Bundle plasma style / desktop theme into theme directory (native LAF support)
    if [[ -n "$plasma_style" ]]; then
        local style_src=""
        for dir in /usr/share/plasma/desktoptheme "${HOME}/.local/share/plasma/desktoptheme"; do
            if [[ -d "${dir}/${plasma_style}" ]]; then
                style_src="${dir}/${plasma_style}"
                break
            fi
        done
        if [[ -n "$style_src" ]]; then
            if [[ "$THEME_INSTALL_GLOBAL" == true ]]; then
                sudo mkdir -p "${theme_dir}/contents/desktoptheme"
                sudo cp -r "$style_src"/* "${theme_dir}/contents/desktoptheme/"
            else
                mkdir -p "${theme_dir}/contents/desktoptheme"
                cp -r "$style_src"/* "${theme_dir}/contents/desktoptheme/"
            fi
        fi
    fi

    # Wallpaper - do NOT set Image in defaults; wallpapers are applied explicitly at runtime
    if [[ "${WALLPAPER:-}" == true ]]; then
        true  # wallpapers bundled separately after both themes are generated
    fi

    # Export current panel layout via Plasma's serialization API
    local layout_js layout_dir="${theme_dir}/contents/layouts"
    layout_js=$(qdbus6 org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell.dumpCurrentLayoutJS 2>/dev/null) || true
    if [[ -n "$layout_js" ]]; then
        if [[ "$THEME_INSTALL_GLOBAL" == true ]]; then
            sudo mkdir -p "$layout_dir"
            echo "$layout_js" | sudo tee "${layout_dir}/org.kde.plasma.desktop-layout.js" > /dev/null
        else
            mkdir -p "$layout_dir"
            echo "$layout_js" > "${layout_dir}/org.kde.plasma.desktop-layout.js"
        fi
    fi

    echo -e "  ${GREEN}Created:${RESET} ${theme_name} (based on $(basename "$base_theme_dir"))"
}

# Bundle wallpapers and SDDM backgrounds into the custom theme directory
bundle_wallpapers_and_sddm() {
    local theme_dir_light="${THEME_INSTALL_DIR}/org.kde.custom.light"

    [[ -d "$theme_dir_light" ]] || return 0

    # Bundle wallpaper packs into light theme dir (canonical location)
    if [[ "${WALLPAPER:-}" == true ]]; then
        # Check both global and local dirs — wallpapers may have been generated
        # locally before the global install decision was made
        local wp_src=""
        for candidate in "/usr/share/wallpapers" "${HOME}/.local/share/wallpapers"; do
            for pack in gloam-dynamic gloam-light gloam-dark; do
                if [[ -d "${candidate}/${pack}" ]]; then
                    wp_src="$candidate"
                    break 2
                fi
            done
        done

        local has_packs=false
        [[ -n "$wp_src" ]] && has_packs=true

        if [[ "$has_packs" == true ]]; then
            if [[ "$THEME_INSTALL_GLOBAL" == true ]]; then
                sudo mkdir -p "${theme_dir_light}/contents/wallpapers"
                for pack in gloam-dynamic gloam-light gloam-dark; do
                    [[ -d "${wp_src}/${pack}" ]] || continue
                    sudo cp -r "${wp_src}/${pack}" "${theme_dir_light}/contents/wallpapers/${pack}"
                    sudo rm -rf "${wp_src}/${pack}"
                done
            else
                mkdir -p "${theme_dir_light}/contents/wallpapers"
                for pack in gloam-dynamic gloam-light gloam-dark; do
                    [[ -d "${wp_src}/${pack}" ]] || continue
                    cp -r "${wp_src}/${pack}" "${theme_dir_light}/contents/wallpapers/${pack}"
                    rm -rf "${wp_src}/${pack}"
                done
            fi

            # Set WALLPAPER_BASE to point to the bundled location
            WALLPAPER_BASE="${theme_dir_light}/contents/wallpapers"
        fi
    fi

    # Bundle SDDM backgrounds into each theme dir
    # Create SDDM images from wallpaper packs if they don't already exist
    local theme_dir_dark="${THEME_INSTALL_DIR}/org.kde.custom.dark"
    local sddm_wp_base="${WALLPAPER_BASE:-}"
    [[ -z "$sddm_wp_base" ]] && sddm_wp_base="${wp_src:-}"
    for variant in light dark; do
        local sddm_bg
        sddm_bg=$({ compgen -G "/usr/local/lib/gloam/sddm-bg-${variant}.*" 2>/dev/null || true; } | head -1)

        # If SDDM image doesn't exist, create it from the wallpaper pack
        if [[ -z "$sddm_bg" || ! -f "$sddm_bg" ]] && [[ -n "$sddm_wp_base" ]]; then
            local best_img="" best_px=0
            for img in "${sddm_wp_base}/gloam-${variant}/contents/images/"*; do
                [[ -f "$img" ]] || continue
                local dims
                dims=$(get_image_dimensions "$img")
                [[ -z "$dims" ]] && continue
                local w h
                w="${dims%x*}"; h="${dims#*x}"
                if (( w * h > best_px )); then
                    best_px=$(( w * h ))
                    best_img="$img"
                fi
            done
            if [[ -n "$best_img" ]]; then
                local ext="${best_img##*.}"
                sudo mkdir -p /usr/local/lib/gloam
                sudo cp "$best_img" "/usr/local/lib/gloam/sddm-bg-${variant}.${ext,,}"
                sddm_bg="/usr/local/lib/gloam/sddm-bg-${variant}.${ext,,}"
            fi
        fi

        [[ -n "$sddm_bg" && -f "$sddm_bg" ]] || continue

        local target_theme_dir
        if [[ "$variant" == "light" ]]; then
            target_theme_dir="$theme_dir_light"
        else
            target_theme_dir="$theme_dir_dark"
        fi
        [[ -d "$target_theme_dir" ]] || continue

        if [[ "$THEME_INSTALL_GLOBAL" == true ]]; then
            sudo mkdir -p "${target_theme_dir}/contents/sddm"
            sudo cp "$sddm_bg" "${target_theme_dir}/contents/sddm/"
        else
            mkdir -p "${target_theme_dir}/contents/sddm"
            cp "$sddm_bg" "${target_theme_dir}/contents/sddm/"
        fi
    done
}

# Remove custom themes on uninstall
remove_custom_themes() {
    for theme in org.kde.custom.light org.kde.custom.dark; do
        local local_path="${HOME}/.local/share/plasma/look-and-feel/${theme}"
        local global_path="/usr/share/plasma/look-and-feel/${theme}"

        [[ -d "$local_path" ]] && rm -rf "$local_path" && echo "Removed $local_path"
        [[ -d "$global_path" ]] && sudo rm -rf "$global_path" && echo "Removed $global_path"
    done
    return 0
}

remove_wallpaper_packs() {
    for pack in gloam-dynamic gloam-light gloam-dark; do
        local local_path="${HOME}/.local/share/wallpapers/${pack}"
        local global_path="/usr/share/wallpapers/${pack}"
        [[ -d "$local_path" ]] && rm -rf "$local_path" && echo "Removed $local_path"
        [[ -d "$global_path" ]] && sudo rm -rf "$global_path" && echo "Removed $global_path"
    done
    return 0
}

apply_theme() {
    local laf="$1"
    local initial="${2:-false}"  # true on startup, skips browser signal to avoid feedback loop
    if [[ "$initial" == true ]]; then
        log "Applying theme: $laf (initial)"
    else
        log "Applying theme: $laf"
    fi
    # Wait for LookAndFeel to finish applying before overriding settings
    sleep 0.5

    # Check if we're using custom themes (bundled options handled by theme itself)
    local using_custom_themes=false
    [[ -n "${CUSTOM_THEME_LIGHT:-}" || -n "${CUSTOM_THEME_DARK:-}" ]] && using_custom_themes=true

    if [[ "$laf" == "$LAF_DARK" ]]; then
        # Kvantum - always apply (not bundleable)
        if [[ -n "$KVANTUM_DARK" ]]; then
            mkdir -p "${HOME}/.config/Kvantum"
            kwriteconfig6 --file "${HOME}/.config/Kvantum/kvantum.kvconfig" --group General --key theme "$KVANTUM_DARK"
            refresh_kvantum_style "kvantum-dark"
        fi

        # GTK theme - always apply (not bundleable)
        [[ -n "$GTK_DARK" ]] && apply_gtk_theme "$GTK_DARK"

        # Flatpak icons - always apply (not bundleable)
        if [[ -n "$GTK_DARK" ]]; then
            apply_flatpak_icons "${ICON_DARK:-$(get_current_icon_theme)}"
        fi

        # These are only applied if NOT using custom themes (they're bundled in custom themes)
        if [[ "$using_custom_themes" == false ]]; then
            [[ -n "$ICON_DARK" && -n "$PLASMA_CHANGEICONS" ]] && "$PLASMA_CHANGEICONS" "$ICON_DARK"
            [[ -n "$COLOR_DARK" ]] && apply_color_scheme "$COLOR_DARK"
            [[ -n "$STYLE_DARK" ]] && apply_plasma_style "$STYLE_DARK"
            [[ -n "$DECORATION_DARK" ]] && apply_window_decoration "$DECORATION_DARK"
            [[ -n "$CURSOR_DARK" ]] && apply_cursor_theme "$CURSOR_DARK"
            apply_splash "$SPLASH_DARK"
            if [[ -n "$APPSTYLE_DARK" && -z "$KVANTUM_DARK" ]]; then
                apply_app_style "$APPSTYLE_DARK"
            fi
        else
            # Still ensure splash "None" stays disabled (theme sets it, but LookAndFeel may override)
            [[ "$SPLASH_DARK" == "None" ]] && apply_splash "None"
        fi

        # Konsole - always apply (not bundleable)
        [[ -n "$KONSOLE_DARK" ]] && apply_konsole_profile "$KONSOLE_DARK"

        # Login screen (SDDM) - always apply (system-level, not applied by plasma-apply-lookandfeel)
        [[ -n "$SDDM_DARK" ]] && apply_sddm_theme "$SDDM_DARK"

        # Wallpapers - switch each surface unless the user has overridden it
        if [[ "${WALLPAPER:-}" == true ]]; then
            local wp_base="${WALLPAPER_BASE:-${HOME}/.local/share/wallpapers}"
            is_gloam_wallpaper desktop && apply_desktop_wallpaper "${wp_base}/gloam-dark"
            is_gloam_wallpaper lockscreen && apply_lockscreen_wallpaper "${wp_base}/gloam-dark"
            # SDDM background - check if gloam images exist on disk (user opted in during configure)
            # Note: can't use is_gloam_wallpaper sddm here because the LookAndFeel's defaults
            # may have switched the SDDM theme, and the new theme won't have a gloam background yet
            local sddm_bg_dark
            sddm_bg_dark=$({ compgen -G "/usr/local/lib/gloam/sddm-bg-dark.*" || true; } | head -1)
            [[ -n "$sddm_bg_dark" ]] && apply_sddm_wallpaper "$sddm_bg_dark"
        fi

        # Browser color scheme - skip on initial startup to avoid feedback loop
        # with Plasma's AutomaticLookAndFeel (Plasma sets this via the portal itself)
        [[ "$initial" != true ]] && apply_browser_color_scheme "dark"

        # Custom script - always apply
        if [[ -n "$SCRIPT_DARK" && -x "$SCRIPT_DARK" ]]; then
            log "Running dark script: $SCRIPT_DARK"
            if "$SCRIPT_DARK" >> "$LOG_FILE" 2>&1; then
                log "Dark script completed successfully"
            else
                log "Dark script failed with exit code $?"
            fi
        elif [[ -n "$SCRIPT_DARK" && ! -x "$SCRIPT_DARK" ]]; then
            log "Dark script not executable: $SCRIPT_DARK"
        fi

        dbus-send --session --type=signal /KGlobalSettings org.kde.KGlobalSettings.forceRefresh 2>/dev/null || log "WARN: dbus forceRefresh signal failed"
        echo "dark" > "${XDG_RUNTIME_DIR}/gloam-runtime"
        log "Switched to DARK mode"

    elif [[ "$laf" == "$LAF_LIGHT" ]]; then
        # Kvantum - always apply (not bundleable)
        if [[ -n "$KVANTUM_LIGHT" ]]; then
            mkdir -p "${HOME}/.config/Kvantum"
            kwriteconfig6 --file "${HOME}/.config/Kvantum/kvantum.kvconfig" --group General --key theme "$KVANTUM_LIGHT"
            refresh_kvantum_style "kvantum"
        fi

        # GTK theme - always apply (not bundleable)
        [[ -n "$GTK_LIGHT" ]] && apply_gtk_theme "$GTK_LIGHT"

        # Flatpak icons - always apply (not bundleable)
        if [[ -n "$GTK_LIGHT" ]]; then
            apply_flatpak_icons "${ICON_LIGHT:-$(get_current_icon_theme)}"
        fi

        # These are only applied if NOT using custom themes (they're bundled in custom themes)
        if [[ "$using_custom_themes" == false ]]; then
            [[ -n "$ICON_LIGHT" && -n "$PLASMA_CHANGEICONS" ]] && "$PLASMA_CHANGEICONS" "$ICON_LIGHT"
            [[ -n "$COLOR_LIGHT" ]] && apply_color_scheme "$COLOR_LIGHT"
            [[ -n "$STYLE_LIGHT" ]] && apply_plasma_style "$STYLE_LIGHT"
            [[ -n "$DECORATION_LIGHT" ]] && apply_window_decoration "$DECORATION_LIGHT"
            [[ -n "$CURSOR_LIGHT" ]] && apply_cursor_theme "$CURSOR_LIGHT"
            apply_splash "$SPLASH_LIGHT"
            if [[ -n "$APPSTYLE_LIGHT" && -z "$KVANTUM_LIGHT" ]]; then
                apply_app_style "$APPSTYLE_LIGHT"
            fi
        else
            # Still ensure splash "None" stays disabled (theme sets it, but LookAndFeel may override)
            [[ "$SPLASH_LIGHT" == "None" ]] && apply_splash "None"
        fi

        # Konsole - always apply (not bundleable)
        [[ -n "$KONSOLE_LIGHT" ]] && apply_konsole_profile "$KONSOLE_LIGHT"

        # Login screen (SDDM) - always apply (system-level, not applied by plasma-apply-lookandfeel)
        [[ -n "$SDDM_LIGHT" ]] && apply_sddm_theme "$SDDM_LIGHT"

        # Wallpapers - switch each surface unless the user has overridden it
        if [[ "${WALLPAPER:-}" == true ]]; then
            local wp_base="${WALLPAPER_BASE:-${HOME}/.local/share/wallpapers}"
            is_gloam_wallpaper desktop && apply_desktop_wallpaper "${wp_base}/gloam-light"
            is_gloam_wallpaper lockscreen && apply_lockscreen_wallpaper "${wp_base}/gloam-light"
            # SDDM background - check if gloam images exist on disk (user opted in during configure)
            # Note: can't use is_gloam_wallpaper sddm here because the LookAndFeel's defaults
            # may have switched the SDDM theme, and the new theme won't have a gloam background yet
            local sddm_bg_light
            sddm_bg_light=$({ compgen -G "/usr/local/lib/gloam/sddm-bg-light.*" || true; } | head -1)
            [[ -n "$sddm_bg_light" ]] && apply_sddm_wallpaper "$sddm_bg_light"
        fi

        # Browser color scheme - skip on initial startup to avoid feedback loop
        # with Plasma's AutomaticLookAndFeel (Plasma sets this via the portal itself)
        [[ "$initial" != true ]] && apply_browser_color_scheme "light"

        # Custom script - always apply
        if [[ -n "$SCRIPT_LIGHT" && -x "$SCRIPT_LIGHT" ]]; then
            log "Running light script: $SCRIPT_LIGHT"
            if "$SCRIPT_LIGHT" >> "$LOG_FILE" 2>&1; then
                log "Light script completed successfully"
            else
                log "Light script failed with exit code $?"
            fi
        elif [[ -n "$SCRIPT_LIGHT" && ! -x "$SCRIPT_LIGHT" ]]; then
            log "Light script not executable: $SCRIPT_LIGHT"
        fi

        dbus-send --session --type=signal /KGlobalSettings org.kde.KGlobalSettings.forceRefresh 2>/dev/null || log "WARN: dbus forceRefresh signal failed"
        echo "light" > "${XDG_RUNTIME_DIR}/gloam-runtime"
        log "Switched to LIGHT mode"
    else
        log "Unknown LookAndFeel: $laf — skipping"
    fi
}

do_watch() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        die "No config found at $CONFIG_FILE. Run configure first."
    fi
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"

    if ! command -v inotifywait &>/dev/null; then
        die "inotifywait not found. Install inotify-tools."
    fi

    log "Watcher started"

    # Wait for Plasma to fully initialize before applying theme
    sleep 1

    PREV_LAF=$(get_laf)
    log "Initial theme: $PREV_LAF"
    apply_theme "$PREV_LAF" true

    local last_apply=0
    inotifywait -m -e moved_to "${HOME}/.config" --include 'kdeglobals' |
    while read -r; do
        # Debounce: ignore events within 3 seconds of last apply to prevent
        # feedback loop with Plasma's AutomaticLookAndFeel
        local now
        now=$(date +%s)
        if (( now - last_apply < 3 )); then
            continue
        fi
        reload_laf_config
        laf=$(get_laf)
        if [[ "$laf" != "$PREV_LAF" ]]; then
            apply_theme "$laf"
            PREV_LAF="$laf"
            last_apply=$(date +%s)
        fi
    done
}

load_config_strict() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        die "No config found at $CONFIG_FILE. Run configure first."
    fi
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
}

do_light() {
    load_config_strict
    # Save auto mode state before plasma-apply-lookandfeel disables it
    local auto_mode
    auto_mode=$(kreadconfig6 --file kdeglobals --group KDE --key AutomaticLookAndFeel)

    local friendly_name
    friendly_name=$(get_friendly_name laf "$LAF_LIGHT")
    echo -e "Switching to ☀️ Light theme: ${BOLD}$friendly_name${RESET}"
    plasma-apply-lookandfeel -a "$LAF_LIGHT"

    # Restore auto mode if it was enabled
    if [[ "$auto_mode" == "true" ]]; then
        kwriteconfig6 --file kdeglobals --group KDE --key AutomaticLookAndFeel true
    fi

    apply_theme "$LAF_LIGHT"
}

do_dark() {
    load_config_strict
    # Save auto mode state before plasma-apply-lookandfeel disables it
    local auto_mode
    auto_mode=$(kreadconfig6 --file kdeglobals --group KDE --key AutomaticLookAndFeel)

    local friendly_name
    friendly_name=$(get_friendly_name laf "$LAF_DARK")
    echo -e "Switching to 🌙 Dark theme: ${BOLD}$friendly_name${RESET}"
    plasma-apply-lookandfeel -a "$LAF_DARK"

    # Restore auto mode if it was enabled
    if [[ "$auto_mode" == "true" ]]; then
        kwriteconfig6 --file kdeglobals --group KDE --key AutomaticLookAndFeel true
    fi

    apply_theme "$LAF_DARK"
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

clean_app_overrides() {
    # Silently remove app-specific theme overrides so they follow the global theme
    # Keys: ColorScheme (Dolphin/Gwenview), Color Theme (Kate/KWrite)
    while read -r file; do
        [[ -f "$file" ]] || continue
        local filename=$(basename "$file")
        [[ "$filename" == "kdeglobals" || "$filename" == "gloam.conf" ]] && continue
        if grep -qE "^(ColorScheme|Color Theme)=" "$file" 2>/dev/null; then
            sed -i -E '/^(ColorScheme|Color Theme)=/d' "$file"
        fi
    done < <(find "${HOME}/.config" -maxdepth 1 -type f)
}

do_configure() {
    check_desktop_environment
    check_dependencies

    # Parse modifiers first to know if this is a full or partial configure
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
    local configure_login=false
    local configure_widget=false
    local configure_shortcut=false
    local configure_appstyle=false
    local configure_wallpaper=false
    local IMPORT_CONFIG=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -k|--kvantum)       configure_kvantum=true; configure_all=false ;;
            -i|--icons)         configure_icons=true; configure_all=false ;;
            -g|--gtk)           configure_gtk=true; configure_all=false ;;
            -o|--konsole)       configure_konsole=true; configure_all=false ;;
            -s|--script)        configure_script=true; configure_all=false ;;
            -S|--splash)        configure_splash=true; configure_all=false ;;
            -l|--login)         configure_login=true; configure_all=false ;;
            -a|--appstyle)      configure_appstyle=true; configure_all=false ;;
            -W|--wallpaper)     configure_wallpaper=true; configure_all=false ;;
            -c|--colors)        configure_colors=true; configure_all=false ;;
            -p|--style)         configure_style=true; configure_all=false ;;
            -d|--decorations)   configure_decorations=true; configure_all=false ;;
            -C|--cursors)       configure_cursors=true; configure_all=false ;;
            -w|--widget)        configure_widget=true; configure_all=false ;;
            -K|--shortcut)      configure_shortcut=true; configure_all=false ;;
            -I|--import)        shift; IMPORT_CONFIG="$1" ;;
            help|-h|--help)     show_configure_help; exit 0 ;;
            *)
                echo "Unknown option: $1" >&2
                echo "Options: -c|--colors -k|--kvantum -a|--appstyle -g|--gtk -p|--style -d|--decorations -i|--icons -C|--cursors -S|--splash -l|--login -W|--wallpaper -o|--konsole -s|--script -w|--widget -K|--shortcut -I|--import <file>" >&2
                exit 1
                ;;
        esac
        shift
    done

    # Show disclaimer
    echo ""
    echo -e "${YELLOW}${BOLD}Disclaimer${RESET}"
    echo "gloam modifies Plasma theme settings, system configs, and user files."
    echo "It is recommended to back up your system before proceeding."
    echo "The authors are not responsible for any system issues."
    echo ""
    read -rp "Continue? [y/N]: " disclaimer_choice
    [[ ! "$disclaimer_choice" =~ ^[Yy]$ ]] && { echo "Aborted."; exit 0; }

    # Handle config import - source the file and skip all interactive questions
    if [[ -n "${IMPORT_CONFIG}" ]]; then
        if [[ ! -f "$IMPORT_CONFIG" ]]; then
            echo -e "${RED}Error: Config file not found: $IMPORT_CONFIG${RESET}"
            exit 1
        fi
        echo -e "${BLUE}Importing configuration from ${IMPORT_CONFIG}...${RESET}"
        # shellcheck source=/dev/null
        source "$IMPORT_CONFIG"

        # Validate that all referenced assets exist before making any changes
        local import_errors=()

        # Base themes (required for custom theme generation)
        if [[ -n "${BASE_THEME_LIGHT:-}" ]]; then
            local _found=false
            for dir in /usr/share/plasma/look-and-feel "${HOME}/.local/share/plasma/look-and-feel"; do
                [[ -d "${dir}/${BASE_THEME_LIGHT}" ]] && _found=true && break
            done
            [[ "$_found" == false ]] && import_errors+=("Light base theme not installed: $BASE_THEME_LIGHT")
        fi
        if [[ -n "${BASE_THEME_DARK:-}" ]]; then
            local _found=false
            for dir in /usr/share/plasma/look-and-feel "${HOME}/.local/share/plasma/look-and-feel"; do
                [[ -d "${dir}/${BASE_THEME_DARK}" ]] && _found=true && break
            done
            [[ "$_found" == false ]] && import_errors+=("Dark base theme not installed: $BASE_THEME_DARK")
        fi

        # Icon themes
        for _label_icon in "ICON_LIGHT:Light icon theme" "ICON_DARK:Dark icon theme"; do
            local _var="${_label_icon%%:*}" _desc="${_label_icon#*:}"
            local _val="${!_var:-}"
            if [[ -n "$_val" ]]; then
                local _found=false
                for dir in /usr/share/icons "${HOME}/.local/share/icons" "${HOME}/.icons"; do
                    [[ -d "${dir}/${_val}" ]] && _found=true && break
                done
                [[ "$_found" == false ]] && import_errors+=("${_desc} not installed: $_val")
            fi
        done

        # Cursor themes
        for _label_cur in "CURSOR_LIGHT:Light cursor theme" "CURSOR_DARK:Dark cursor theme"; do
            local _var="${_label_cur%%:*}" _desc="${_label_cur#*:}"
            local _val="${!_var:-}"
            if [[ -n "$_val" ]]; then
                local _found=false
                for dir in /usr/share/icons "${HOME}/.local/share/icons" "${HOME}/.icons"; do
                    [[ -d "${dir}/${_val}" ]] && _found=true && break
                done
                [[ "$_found" == false ]] && import_errors+=("${_desc} not installed: $_val")
            fi
        done

        # Kvantum themes (theme name comes from .kvconfig filename, not parent dir)
        for _label_kv in "KVANTUM_LIGHT:Light Kvantum theme" "KVANTUM_DARK:Dark Kvantum theme"; do
            local _var="${_label_kv%%:*}" _desc="${_label_kv#*:}"
            local _val="${!_var:-}"
            if [[ -n "$_val" ]]; then
                local _found=false
                for dir in /usr/share/Kvantum "${HOME}/.config/Kvantum"; do
                    compgen -G "${dir}/*/${_val}.kvconfig" > /dev/null 2>&1 && _found=true && break
                done
                [[ "$_found" == false ]] && import_errors+=("${_desc} not installed: $_val")
            fi
        done

        # GTK themes
        for _label_gtk in "GTK_LIGHT:Light GTK theme" "GTK_DARK:Dark GTK theme"; do
            local _var="${_label_gtk%%:*}" _desc="${_label_gtk#*:}"
            local _val="${!_var:-}"
            if [[ -n "$_val" ]]; then
                local _found=false
                for dir in /usr/share/themes "${HOME}/.themes" "${HOME}/.local/share/themes"; do
                    [[ -d "${dir}/${_val}" ]] && _found=true && break
                done
                [[ "$_found" == false ]] && import_errors+=("${_desc} not installed: $_val")
            fi
        done

        # Wallpaper source images
        if [[ "${WALLPAPER:-}" == true ]]; then
            if [[ -z "${WP_SOURCE_LIGHT:-}" ]]; then
                import_errors+=("WALLPAPER=true but WP_SOURCE_LIGHT is not set")
            else
                for img in ${WP_SOURCE_LIGHT}; do
                    [[ -f "$img" ]] || import_errors+=("Light wallpaper not found: $img")
                done
            fi
            if [[ -z "${WP_SOURCE_DARK:-}" ]]; then
                import_errors+=("WALLPAPER=true but WP_SOURCE_DARK is not set")
            else
                for img in ${WP_SOURCE_DARK}; do
                    [[ -f "$img" ]] || import_errors+=("Dark wallpaper not found: $img")
                done
            fi
        fi

        # Custom scripts
        [[ -n "${SCRIPT_LIGHT:-}" && ! -f "${SCRIPT_LIGHT}" ]] && import_errors+=("Light script not found: $SCRIPT_LIGHT")
        [[ -n "${SCRIPT_DARK:-}" && ! -f "${SCRIPT_DARK}" ]] && import_errors+=("Dark script not found: $SCRIPT_DARK")

        if [[ ${#import_errors[@]} -gt 0 ]]; then
            echo -e "${RED}Import failed — missing assets:${RESET}"
            for err in "${import_errors[@]}"; do
                echo -e "  ${RED}- ${err}${RESET}"
            done
            exit 1
        fi

        # Authenticate sudo if config requires global installation
        if [[ "${INSTALL_GLOBAL:-false}" == true ]]; then
            echo "Config requires global installation, requesting sudo..."
            sudo -v || { echo -e "${RED}Sudo required for global installation.${RESET}"; exit 1; }
        fi
        # Auto-discover push targets if push was enabled
        if [[ "${PUSH_TO_USERS:-false}" == true ]]; then
            SELECTED_USERS=()
            while IFS=: read -r username _ uid _ _ home _; do
                [[ "$uid" -ge 1000 && "$uid" -lt 60000 && "$home" == /home/* && -d "$home" && "$username" != "$USER" ]] && SELECTED_USERS+=("$username:$home")
            done < /etc/passwd
        fi
        # Resolve LAF to base themes (custom themes won't exist on a fresh machine)
        local laf_light laf_dark
        if [[ -n "${BASE_THEME_LIGHT:-}" && -n "${BASE_THEME_DARK:-}" ]]; then
            laf_light="$BASE_THEME_LIGHT"
            laf_dark="$BASE_THEME_DARK"
        else
            laf_light="${LAF_LIGHT:-}"
            laf_dark="${LAF_DARK:-}"
        fi
        if [[ -z "$laf_light" || -z "$laf_dark" ]]; then
            echo -e "${RED}Error: Imported config is missing theme definitions.${RESET}"
            exit 1
        fi
        echo -e "  ☀️ Light theme: ${BOLD}$(get_friendly_name laf "$laf_light")${RESET}"
        echo -e "  🌙 Dark theme:  ${BOLD}$(get_friendly_name laf "$laf_dark")${RESET}"
        cleanup_stale
        # Remove app-specific overrides so they follow the global theme
        clean_app_overrides
    # Load existing config if modifying specific options (includes INSTALL_GLOBAL)
    elif [[ "$configure_all" == false && -f "$CONFIG_FILE" ]]; then
        # shellcheck source=/dev/null
        source "$CONFIG_FILE"
        # Authenticate sudo if this is a global installation
        if [[ "$INSTALL_GLOBAL" == true ]]; then
            echo "Global installation detected, requesting sudo..."
            sudo -v || { echo -e "${RED}Sudo required for global installation.${RESET}"; exit 1; }
        fi
    elif [[ "$configure_all" == true ]]; then
        # Full configuration - ask about global installation first
        ask_global_install

        if [[ -f "$CONFIG_FILE" ]]; then
            echo -e "${YELLOW}Existing configuration found.${RESET}"
            read -rp "Do you want to overwrite it? [y/N]: " choice
            if [[ "$choice" =~ ^[Yy]$ ]]; then
                cleanup_stale
            else
                echo "Use configure options to modify specific settings (e.g. --kvantum, --gtk)."
                echo "Run 'gloam help' for available options."
                exit 0
            fi
        else
            cleanup_stale
        fi
    fi

    if [[ -z "${IMPORT_CONFIG}" ]]; then

    show_laf_reminder

    # Remove app-specific overrides so they follow the global theme
    clean_app_overrides
    echo ""

    # Read light/dark themes from KDE Quick Settings configuration
    echo -e "${BLUE}Reading theme configuration from KDE settings...${RESET}"
    local laf_light laf_dark
    laf_light=$(kreadconfig6 --file kdeglobals --group KDE --key DefaultLightLookAndFeel)
    laf_dark=$(kreadconfig6 --file kdeglobals --group KDE --key DefaultDarkLookAndFeel)

    # If KDE still points to our custom themes, resolve back to the base themes
    if [[ "$laf_light" == "org.kde.custom.light" ]]; then
        if [[ -n "${BASE_THEME_LIGHT:-}" ]]; then
            laf_light="$BASE_THEME_LIGHT"
        else
            echo -e "${RED}Error: KDE is set to use Custom (Light) but the base theme is unknown.${RESET}" >&2
            echo "Please make sure light and dark themes are set in System Settings > Quick Settings" >&2
            exit 1
        fi
    fi
    if [[ "$laf_dark" == "org.kde.custom.dark" ]]; then
        if [[ -n "${BASE_THEME_DARK:-}" ]]; then
            laf_dark="$BASE_THEME_DARK"
        else
            echo -e "${RED}Error: KDE is set to use Custom (Dark) but the base theme is unknown.${RESET}" >&2
            echo "Please make sure light and dark themes are set in System Settings > Quick Settings" >&2
            exit 1
        fi
    fi
    echo -e "  ☀️ Light theme: ${BOLD}$(get_friendly_name laf "$laf_light")${RESET}"
    echo -e "  🌙 Dark theme:  ${BOLD}$(get_friendly_name laf "$laf_dark")${RESET}"

    if [[ "$laf_light" == "$laf_dark" ]]; then
        echo -e "${RED}Error: ☀️ Light and 🌙 Dark LookAndFeel are the same ($laf_light).${RESET}" >&2
        echo "Configure different themes in System Settings > Colors & Themes > Global Theme." >&2
        exit 1
    fi

    # Select Color Schemes
    if [[ "$configure_all" == true || "$configure_colors" == true ]]; then
    echo ""
    local choice
    read -rp "Configure color schemes? (normally automatically set by global theme) [y/N]: " choice
    if [[ "$choice" =~ ^[Yy]$ ]]; then
        echo "Scanning for color schemes..."
        mapfile -t color_schemes < <(scan_color_schemes)

        if [[ ${#color_schemes[@]} -eq 0 ]]; then
            echo "No color schemes found, skipping."
            COLOR_LIGHT=""
            COLOR_DARK=""
        else
            echo ""
            echo -e "${BOLD}Available color schemes:${RESET}"
            for i in "${!color_schemes[@]}"; do
                printf "  ${BLUE}%3d)${RESET} %s\n" "$((i + 1))" "${color_schemes[$i]}"
            done

            echo ""
            read -rp "Select ☀️ LIGHT mode color scheme [1-${#color_schemes[@]}]: " choice
            if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#color_schemes[@]} )); then
                COLOR_LIGHT="${color_schemes[$((choice - 1))]}"

                read -rp "Select 🌙 DARK mode color scheme [1-${#color_schemes[@]}]: " choice
                if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#color_schemes[@]} )); then
                    COLOR_DARK="${color_schemes[$((choice - 1))]}"
                else
                    COLOR_LIGHT=""
                    COLOR_DARK=""
                fi
            else
                COLOR_LIGHT=""
                COLOR_DARK=""
            fi
        fi
    else
        COLOR_LIGHT=""
        COLOR_DARK=""
    fi
    fi

    # Select Kvantum themes
    if [[ "$configure_all" == true || "$configure_kvantum" == true ]]; then
    echo ""
    read -rp "Configure Kvantum themes? (not automatically set by global theme) [y/N]: " choice
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
                    if command -v flatpak &>/dev/null; then
                        setup_flatpak_permissions
                        setup_flatpak_kvantum
                        echo -e "${YELLOW}Note:${RESET} Flatpak apps may need to be closed and reopened to update theme."
                    fi
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

    # Select Application Style (Qt widget style)
    if [[ "$configure_all" == true || "$configure_appstyle" == true ]]; then
    echo ""
    read -rp "Configure application style? (normally automatically set by global theme) [y/N]: " choice
    if [[ "$choice" =~ ^[Yy]$ ]]; then
        echo "Scanning for application styles..."
        local app_style_names=()
        while IFS= read -r name; do
            app_style_names+=("$name")
        done < <(scan_app_styles)

        if [[ ${#app_style_names[@]} -eq 0 ]]; then
            echo -e "${YELLOW}No application styles found.${RESET}"
            APPSTYLE_LIGHT=""
            APPSTYLE_DARK=""
        else
            echo ""
            echo -e "${BOLD}Available application styles:${RESET}"
            for i in "${!app_style_names[@]}"; do
                printf "  ${BLUE}%3d)${RESET} %s\n" "$((i + 1))" "${app_style_names[$i]}"
            done

            echo ""
            read -rp "Select ☀️ LIGHT mode application style [1-${#app_style_names[@]}]: " choice
            if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#app_style_names[@]} )); then
                APPSTYLE_LIGHT="${app_style_names[$((choice - 1))]}"
            else
                APPSTYLE_LIGHT=""
            fi

            read -rp "Select 🌙 DARK mode application style [1-${#app_style_names[@]}]: " choice
            if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#app_style_names[@]} )); then
                APPSTYLE_DARK="${app_style_names[$((choice - 1))]}"
            else
                APPSTYLE_DARK=""
            fi
        fi
    else
        APPSTYLE_LIGHT=""
        APPSTYLE_DARK=""
    fi
    fi

    # Select GTK/Flatpak themes
    if [[ "$configure_all" == true || "$configure_gtk" == true ]]; then
    echo ""
    read -rp "Configure GTK/Flatpak themes? (not automatically set by global theme) [y/N]: " choice
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
                    if command -v flatpak &>/dev/null; then
                        setup_flatpak_permissions
                        echo -e "${YELLOW}Note:${RESET} Flatpak apps may need to be closed and reopened to update theme."
                    fi
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

    # Select Plasma Styles
    if [[ "$configure_all" == true || "$configure_style" == true ]]; then
    echo ""
    read -rp "Configure Plasma styles? (normally automatically set by global theme) [y/N]: " choice
    if [[ "$choice" =~ ^[Yy]$ ]]; then
        echo "Scanning for Plasma styles..."
        local style_ids=()
        mapfile -t style_ids < <(scan_plasma_styles)

        if [[ ${#style_ids[@]} -eq 0 ]]; then
            echo "No Plasma styles found, skipping."
            STYLE_LIGHT=""
            STYLE_DARK=""
        else
            echo ""
            echo -e "${BOLD}Available Plasma styles:${RESET}"
            for i in "${!style_ids[@]}"; do
                printf "  ${BLUE}%3d)${RESET} %s\n" "$((i + 1))" "${style_ids[$i]}"
            done

            echo ""
            read -rp "Select ☀️ LIGHT mode Plasma style [1-${#style_ids[@]}]: " choice
            if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#style_ids[@]} )); then
                STYLE_LIGHT="${style_ids[$((choice - 1))]}"

                read -rp "Select 🌙 DARK mode Plasma style [1-${#style_ids[@]}]: " choice
                if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#style_ids[@]} )); then
                    STYLE_DARK="${style_ids[$((choice - 1))]}"
                else
                    STYLE_LIGHT=""
                    STYLE_DARK=""
                fi
            else
                STYLE_LIGHT=""
                STYLE_DARK=""
            fi
        fi
    else
        STYLE_LIGHT=""
        STYLE_DARK=""
    fi
    fi

    # Select Window Decorations
    if [[ "$configure_all" == true || "$configure_decorations" == true ]]; then
    echo ""
    read -rp "Configure window decorations? (normally automatically set by global theme) [y/N]: " choice
    if [[ "$choice" =~ ^[Yy]$ ]]; then
        echo "Scanning for window decorations..."
        local decoration_ids=() decoration_names=()
        while IFS='|' read -r id name; do
            decoration_ids+=("$id")
            decoration_names+=("$name")
        done < <(scan_window_decorations)

        if [[ ${#decoration_ids[@]} -eq 0 ]]; then
            echo "No window decorations found, skipping."
            DECORATION_LIGHT=""
            DECORATION_DARK=""
        else
            echo ""
            echo -e "${BOLD}Available window decorations:${RESET}"
            for i in "${!decoration_names[@]}"; do
                printf "  ${BLUE}%3d)${RESET} %s\n" "$((i + 1))" "${decoration_names[$i]}"
            done

            echo ""
            read -rp "Select ☀️ LIGHT mode window decoration [1-${#decoration_ids[@]}]: " choice
            if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#decoration_ids[@]} )); then
                DECORATION_LIGHT="${decoration_ids[$((choice - 1))]}"

                read -rp "Select 🌙 DARK mode window decoration [1-${#decoration_ids[@]}]: " choice
                if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#decoration_ids[@]} )); then
                    DECORATION_DARK="${decoration_ids[$((choice - 1))]}"
                else
                    DECORATION_LIGHT=""
                    DECORATION_DARK=""
                fi
            else
                DECORATION_LIGHT=""
                DECORATION_DARK=""
            fi
        fi
    else
        DECORATION_LIGHT=""
        DECORATION_DARK=""
    fi
    fi

    # Select icon themes
    if [[ "$configure_all" == true || "$configure_icons" == true ]]; then
    echo ""
    read -rp "Configure icon themes? (normally automatically set by global theme) [y/N]: " choice
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

    # Select Cursor themes
    if [[ "$configure_all" == true || "$configure_cursors" == true ]]; then
    echo ""
    read -rp "Configure cursor themes? (normally automatically set by global theme) [y/N]: " choice
    if [[ "$choice" =~ ^[Yy]$ ]]; then
        echo "Scanning for cursor themes..."
        local cursor_ids=() cursor_names=()
        while IFS='|' read -r id name; do
            cursor_ids+=("$id")
            cursor_names+=("$name")
        done < <(scan_cursor_themes)

        if [[ ${#cursor_ids[@]} -eq 0 ]]; then
            echo "No cursor themes found, skipping."
            CURSOR_LIGHT=""
            CURSOR_DARK=""
        else
            echo ""
            echo -e "${BOLD}Available cursor themes:${RESET}"
            for i in "${!cursor_names[@]}"; do
                printf "  ${BLUE}%3d)${RESET} %s\n" "$((i + 1))" "${cursor_names[$i]}"
            done

            echo ""
            read -rp "Select ☀️ LIGHT mode cursor theme [1-${#cursor_ids[@]}]: " choice
            if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#cursor_ids[@]} )); then
                CURSOR_LIGHT="${cursor_ids[$((choice - 1))]}"

                read -rp "Select 🌙 DARK mode cursor theme [1-${#cursor_ids[@]}]: " choice
                if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#cursor_ids[@]} )); then
                    CURSOR_DARK="${cursor_ids[$((choice - 1))]}"
                else
                    CURSOR_LIGHT=""
                    CURSOR_DARK=""
                fi
            else
                CURSOR_LIGHT=""
                CURSOR_DARK=""
            fi
        fi
    else
        CURSOR_LIGHT=""
        CURSOR_DARK=""
    fi
    fi

    # Select Splash Screens
    if [[ "$configure_all" == true || "$configure_splash" == true ]]; then
    echo ""
    read -rp "Configure splash screen override? (normally automatically set by global theme) [y/N]: " choice
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
        read -rp "Select ☀️ LIGHT mode splash theme [0-${#splash_ids[@]}]: " choice
        if [[ "$choice" == "0" ]]; then
            SPLASH_LIGHT="None"
        elif [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#splash_ids[@]} )); then
            SPLASH_LIGHT="${splash_ids[$((choice - 1))]}"
        else
            SPLASH_LIGHT=""
        fi

        read -rp "Select 🌙 DARK mode splash theme [0-${#splash_ids[@]}]: " choice
        if [[ "$choice" == "0" ]]; then
            SPLASH_DARK="None"
        elif [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#splash_ids[@]} )); then
            SPLASH_DARK="${splash_ids[$((choice - 1))]}"
        else
            SPLASH_DARK=""
        fi
    else
        SPLASH_LIGHT=""
        SPLASH_DARK=""
    fi
    fi

    # Select Login Screen (SDDM) Themes
    if [[ "$configure_all" == true || "$configure_login" == true ]]; then
    echo ""
    read -rp "Configure login screen (SDDM) themes? (requires sudo) [y/N]: " choice
    if [[ "$choice" =~ ^[Yy]$ ]]; then
        echo "Scanning for SDDM themes..."
        local sddm_ids=() sddm_names=()
        while IFS='|' read -r id name; do
            sddm_ids+=("$id")
            sddm_names+=("$name")
        done < <(scan_sddm_themes)

        if [[ ${#sddm_ids[@]} -eq 0 ]]; then
            echo -e "${YELLOW}No SDDM themes found in /usr/share/sddm/themes/${RESET}"
            SDDM_LIGHT=""
            SDDM_DARK=""
        else
            echo ""
            echo -e "${BOLD}Available SDDM themes:${RESET}"
            for i in "${!sddm_names[@]}"; do
                printf "  ${BLUE}%3d)${RESET} %s\n" "$((i + 1))" "${sddm_names[$i]}"
            done

            echo ""
            read -rp "Select ☀️ LIGHT mode login theme [1-${#sddm_ids[@]}]: " choice
            if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#sddm_ids[@]} )); then
                SDDM_LIGHT="${sddm_ids[$((choice - 1))]}"
            else
                SDDM_LIGHT=""
            fi

            read -rp "Select 🌙 DARK mode login theme [1-${#sddm_ids[@]}]: " choice
            if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#sddm_ids[@]} )); then
                SDDM_DARK="${sddm_ids[$((choice - 1))]}"
            else
                SDDM_DARK=""
            fi

            # Set up sudoers rule for non-interactive SDDM switching
            if [[ -n "${SDDM_LIGHT:-}" || -n "${SDDM_DARK:-}" ]]; then
                echo ""
                echo "Setting up passwordless sudo for SDDM theme switching..."
                sudo -v || { echo -e "${RED}Sudo required for SDDM theme switching.${RESET}"; SDDM_LIGHT=""; SDDM_DARK=""; }
                if [[ -n "${SDDM_LIGHT:-}" || -n "${SDDM_DARK:-}" ]]; then
                    setup_sddm_sudoers
                    echo -e "${GREEN}SDDM sudoers rule installed.${RESET}"
                fi
            fi
        fi
    else
        SDDM_LIGHT=""
        SDDM_DARK=""
    fi
    fi

    # Configure day/night wallpapers
    if [[ "$configure_all" == true || "$configure_wallpaper" == true ]]; then
    echo ""
    read -rp "Configure wallpapers? (normally automatically set by global theme) [y/N]: " choice
    if [[ "$choice" =~ ^[Yy]$ ]]; then
        echo ""
        read -rp "Enter ☀️ LIGHT wallpaper path(s) (space-separated files, or a folder): " wp_light_input
        local wp_light_paths=()
        while IFS= read -r img; do
            wp_light_paths+=("$img")
        done < <(resolve_image_paths "$wp_light_input")

        if [[ ${#wp_light_paths[@]} -eq 0 ]]; then
            echo -e "${YELLOW}No valid images found for light mode.${RESET}"
        fi

        read -rp "Enter 🌙 DARK wallpaper path(s) (space-separated files, or a folder): " wp_dark_input
        local wp_dark_paths=()
        while IFS= read -r img; do
            wp_dark_paths+=("$img")
        done < <(resolve_image_paths "$wp_dark_input")

        if [[ ${#wp_dark_paths[@]} -eq 0 ]]; then
            echo -e "${YELLOW}No valid images found for dark mode.${RESET}"
        fi

        if [[ ${#wp_light_paths[@]} -gt 0 && ${#wp_dark_paths[@]} -gt 0 ]]; then
            # Store original source paths for import/re-generation
            WP_SOURCE_LIGHT="${wp_light_paths[*]}"
            WP_SOURCE_DARK="${wp_dark_paths[*]}"

            echo ""
            echo "Creating wallpaper packs..."
            local wp_empty=()
            generate_wallpaper_pack "gloam-dynamic" "Custom (Dynamic)" wp_light_paths wp_dark_paths
            generate_wallpaper_pack "gloam-light" "Custom (Light)" wp_light_paths wp_empty
            generate_wallpaper_pack "gloam-dark" "Custom (Dark)" wp_dark_paths wp_empty

            echo ""
            local wallpaper_dir
            if [[ "${THEME_INSTALL_GLOBAL:-${INSTALL_GLOBAL:-false}}" == true ]]; then
                wallpaper_dir="/usr/share/wallpapers/gloam-dynamic"
            else
                wallpaper_dir="${HOME}/.local/share/wallpapers/gloam-dynamic"
            fi
            echo -n "Applying to desktop... "
            apply_desktop_wallpaper "$wallpaper_dir"
            echo -e "${GREEN}done${RESET}"

            echo -n "Applying to lock screen... "
            apply_lockscreen_wallpaper "$wallpaper_dir"
            echo -e "${GREEN}done${RESET}"

            echo ""
            read -rp "Set SDDM login background? (requires sudo) [y/N]: " sddm_wp_choice
            if [[ "$sddm_wp_choice" =~ ^[Yy]$ ]]; then
                sudo -v || { echo -e "${RED}Sudo required for SDDM wallpaper.${RESET}"; sddm_wp_choice="n"; }
                if [[ "$sddm_wp_choice" =~ ^[Yy]$ ]]; then
                    setup_sddm_wallpaper
                    echo -e "  ${GREEN}SDDM backgrounds installed.${RESET}"
                    # Apply SDDM wallpaper for current mode
                    local current_laf_sddm
                    current_laf_sddm=$(kreadconfig6 --file kdeglobals --group KDE --key LookAndFeelPackage 2>/dev/null)
                    local sddm_variant="light"
                    if [[ "$current_laf_sddm" == "$laf_dark" || "$current_laf_sddm" == "${BASE_THEME_DARK:-}" || "$current_laf_sddm" == "org.kde.custom.dark" ]]; then
                        sddm_variant="dark"
                    fi
                    local initial_sddm_bg
                    initial_sddm_bg=$({ compgen -G "/usr/local/lib/gloam/sddm-bg-${sddm_variant}.*" || true; } | head -1)
                    [[ -n "$initial_sddm_bg" ]] && apply_sddm_wallpaper "$initial_sddm_bg"
                fi
            fi

            WALLPAPER=true
        else
            echo -e "${YELLOW}Need at least one image for each mode. Skipping wallpaper.${RESET}"
            WALLPAPER=""
        fi
    else
        WALLPAPER=""
    fi
    fi

    # Select Konsole profiles
    if [[ "$configure_all" == true || "$configure_konsole" == true ]]; then
    echo ""
    read -rp "Configure Konsole profiles? (not automatically set by global theme) [y/N]: " choice
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

        # Copy scripts globally if global install and script is in user's home
        if [[ "$INSTALL_GLOBAL" == true ]]; then
            if [[ -n "$SCRIPT_LIGHT" && -f "$SCRIPT_LIGHT" && "$SCRIPT_LIGHT" == "$HOME"* ]]; then
                sudo mkdir -p "$GLOBAL_SCRIPTS_DIR"
                sudo cp "$SCRIPT_LIGHT" "$GLOBAL_SCRIPTS_DIR/$(basename "$SCRIPT_LIGHT")"
                sudo chmod +x "$GLOBAL_SCRIPTS_DIR/$(basename "$SCRIPT_LIGHT")"
                SCRIPT_LIGHT="$GLOBAL_SCRIPTS_DIR/$(basename "$SCRIPT_LIGHT")"
                echo "Installed light script globally"
            fi
            if [[ -n "$SCRIPT_DARK" && -f "$SCRIPT_DARK" && "$SCRIPT_DARK" == "$HOME"* ]]; then
                sudo mkdir -p "$GLOBAL_SCRIPTS_DIR"
                sudo cp "$SCRIPT_DARK" "$GLOBAL_SCRIPTS_DIR/$(basename "$SCRIPT_DARK")"
                sudo chmod +x "$GLOBAL_SCRIPTS_DIR/$(basename "$SCRIPT_DARK")"
                SCRIPT_DARK="$GLOBAL_SCRIPTS_DIR/$(basename "$SCRIPT_DARK")"
                echo "Installed dark script globally"
            fi
        fi
    else
        SCRIPT_LIGHT=""
        SCRIPT_DARK=""
    fi
    fi

    # Check if anything was configured
    if [[ -z "${KVANTUM_LIGHT:-}" && -z "${KVANTUM_DARK:-}" && -z "${STYLE_LIGHT:-}" && -z "${STYLE_DARK:-}" && -z "${DECORATION_LIGHT:-}" && -z "${DECORATION_DARK:-}" && -z "${COLOR_LIGHT:-}" && -z "${COLOR_DARK:-}" && -z "${ICON_LIGHT:-}" && -z "${ICON_DARK:-}" && -z "${CURSOR_LIGHT:-}" && -z "${CURSOR_DARK:-}" && -z "${GTK_LIGHT:-}" && -z "${GTK_DARK:-}" && -z "${KONSOLE_LIGHT:-}" && -z "${KONSOLE_DARK:-}" && -z "${SPLASH_LIGHT:-}" && -z "${SPLASH_DARK:-}" && -z "${SDDM_LIGHT:-}" && -z "${SDDM_DARK:-}" && -z "${APPSTYLE_LIGHT:-}" && -z "${APPSTYLE_DARK:-}" && -z "${WALLPAPER:-}" && -z "${SCRIPT_LIGHT:-}" && -z "${SCRIPT_DARK:-}" ]]; then
        echo ""
        echo "Nothing to configure. Exiting."
        exit 0
    fi

    echo ""
    echo "Configuration summary:"
    echo -e "☀️ Light theme: ${BOLD}$(get_friendly_name laf "$laf_light")${RESET}"
    echo "    Colors: ${COLOR_LIGHT:-unset}"
    echo "    Kvantum: ${KVANTUM_LIGHT:-unset}"
    echo "    App style: ${APPSTYLE_LIGHT:-unset}"
    echo "    GTK: ${GTK_LIGHT:-unset}"
    echo "    Style: ${STYLE_LIGHT:-unset}"
    echo "    Decorations: $([[ -n "${DECORATION_LIGHT:-}" ]] && get_friendly_name decoration "$DECORATION_LIGHT" || echo "unchanged")"
    echo "    Icons: ${ICON_LIGHT:-unset}"
    echo "    Cursors: ${CURSOR_LIGHT:-unset}"
    echo "    Splash: $(get_friendly_name splash "${SPLASH_LIGHT:-}")"
    echo "    Login: $(get_friendly_name sddm "${SDDM_LIGHT:-}")"
    echo "    Wallpaper: ${WALLPAPER:+Custom (Dynamic, Light, Dark)}"
    echo "    Konsole: ${KONSOLE_LIGHT:-unset}"
    echo "    Script: ${SCRIPT_LIGHT:-unset}"
    echo -e "🌙 Dark theme:  ${BOLD}$(get_friendly_name laf "$laf_dark")${RESET}"
    echo "    Colors: ${COLOR_DARK:-unset}"
    echo "    Kvantum: ${KVANTUM_DARK:-unset}"
    echo "    App style: ${APPSTYLE_DARK:-unset}"
    echo "    GTK: ${GTK_DARK:-unset}"
    echo "    Style: ${STYLE_DARK:-unset}"
    echo "    Decorations: $([[ -n "${DECORATION_DARK:-}" ]] && get_friendly_name decoration "$DECORATION_DARK" || echo "unchanged")"
    echo "    Icons: ${ICON_DARK:-unset}"
    echo "    Cursors: ${CURSOR_DARK:-unset}"
    echo "    Splash: $(get_friendly_name splash "${SPLASH_DARK:-}")"
    echo "    Login: $(get_friendly_name sddm "${SDDM_DARK:-}")"
    echo "    Wallpaper: ${WALLPAPER:+Custom (Dynamic, Light, Dark)}"
    echo "    Konsole: ${KONSOLE_DARK:-unset}"
    echo "    Script: ${SCRIPT_DARK:-unset}"

    # Preserve values from config if doing partial reconfigure
    local CUSTOM_THEME_LIGHT="${CUSTOM_THEME_LIGHT:-}"
    local CUSTOM_THEME_DARK="${CUSTOM_THEME_DARK:-}"
    local BASE_THEME_LIGHT="${BASE_THEME_LIGHT:-}"
    local BASE_THEME_DARK="${BASE_THEME_DARK:-}"
    local THEME_INSTALL_GLOBAL="${THEME_INSTALL_GLOBAL:-false}"
    local THEME_INSTALL_DIR="${THEME_INSTALL_DIR:-}"
    local WALLPAPER_BASE="${WALLPAPER_BASE:-}"
    local ICON_LIGHT_MOVED_FROM="${ICON_LIGHT_MOVED_FROM:-}"
    local ICON_DARK_MOVED_FROM="${ICON_DARK_MOVED_FROM:-}"
    local CURSOR_LIGHT_MOVED_FROM="${CURSOR_LIGHT_MOVED_FROM:-}"
    local CURSOR_DARK_MOVED_FROM="${CURSOR_DARK_MOVED_FROM:-}"

    # Check if custom themes already exist (regenerate automatically)
    local custom_themes_exist=false
    if [[ -n "$CUSTOM_THEME_LIGHT" ]]; then
        if [[ -n "$BASE_THEME_LIGHT" ]]; then
            custom_themes_exist=true
        else
            # Old config without base themes - need full reconfigure
            echo -e "${YELLOW}Warning: Custom themes exist but base themes are not recorded.${RESET}"
            echo "Please run a full reconfigure to regenerate custom themes."
            CUSTOM_THEME_LIGHT=""
            CUSTOM_THEME_DARK=""
        fi
    fi

    # Helper to check if base theme exists
    check_base_theme_exists() {
        local theme="$1"
        for dir in /usr/share/plasma/look-and-feel "${HOME}/.local/share/plasma/look-and-feel"; do
            [[ -d "${dir}/${theme}" ]] && return 0
        done
        return 1
    }

    if [[ "$custom_themes_exist" == true ]]; then
        # Custom themes exist - regenerate automatically
        echo ""
        echo "Regenerating custom themes..."

        # Verify base themes still exist
        if ! check_base_theme_exists "$BASE_THEME_LIGHT"; then
            echo -e "${RED}Error: Base theme '$BASE_THEME_LIGHT' is no longer installed.${RESET}"
            echo "Please reinstall the theme or run a full reconfigure to select a new base theme."
            exit 1
        fi
        if ! check_base_theme_exists "$BASE_THEME_DARK"; then
            echo -e "${RED}Error: Base theme '$BASE_THEME_DARK' is no longer installed.${RESET}"
            echo "Please reinstall the theme or run a full reconfigure to select a new base theme."
            exit 1
        fi

        # Set up theme install directory
        if [[ "$THEME_INSTALL_GLOBAL" == true ]]; then
            THEME_INSTALL_DIR="/usr/share/plasma/look-and-feel"
        else
            THEME_INSTALL_DIR="${HOME}/.local/share/plasma/look-and-feel"
        fi

        generate_custom_theme "light" "$BASE_THEME_LIGHT"
        generate_custom_theme "dark" "$BASE_THEME_DARK"
        bundle_wallpapers_and_sddm

        laf_light="$CUSTOM_THEME_LIGHT"
        laf_dark="$CUSTOM_THEME_DARK"

        # Apply the appropriate custom theme to match the user's current mode
        local current_laf
        current_laf=$(kreadconfig6 --file kdeglobals --group KDE --key LookAndFeelPackage 2>/dev/null)
        LAF_LIGHT="$laf_light"
        LAF_DARK="$laf_dark"
        if [[ "$current_laf" == "$CUSTOM_THEME_DARK" || "$current_laf" == "$BASE_THEME_DARK" ]]; then
            echo -e "Switching to 🌙 Dark theme: ${BOLD}$(get_friendly_name laf "$LAF_DARK")${RESET}"
            plasma-apply-lookandfeel -a "$LAF_DARK"
        else
            echo -e "Switching to ☀️ Light theme: ${BOLD}$(get_friendly_name laf "$LAF_LIGHT")${RESET}"
            plasma-apply-lookandfeel -a "$LAF_LIGHT"
        fi

        # Re-apply wallpapers from bundled location
        if [[ "${WALLPAPER:-}" == true && -n "${WALLPAPER_BASE:-}" ]]; then
            local wp_mode="gloam-dynamic"
            apply_desktop_wallpaper "${WALLPAPER_BASE}/${wp_mode}"
            apply_lockscreen_wallpaper "${WALLPAPER_BASE}/${wp_mode}"
        fi

        # Apply SDDM wallpaper for current mode
        if [[ -x /usr/local/lib/gloam/set-sddm-background ]]; then
            local regen_sddm_variant="light"
            if [[ "$current_laf" == "$CUSTOM_THEME_DARK" || "$current_laf" == "$BASE_THEME_DARK" ]]; then
                regen_sddm_variant="dark"
            fi
            local regen_sddm_bg
            regen_sddm_bg=$({ compgen -G "/usr/local/lib/gloam/sddm-bg-${regen_sddm_variant}.*" || true; } | head -1)
            [[ -n "$regen_sddm_bg" ]] && apply_sddm_wallpaper "$regen_sddm_bg"
        fi

        echo -e "${GREEN}Custom themes updated.${RESET}"

    elif has_bundleable_options; then
        # First time - ask user if they want custom themes
        echo ""
        read -rp "Generate custom themes from your selections? [Y/n]: " gen_choice
        if [[ ! "$gen_choice" =~ ^[Nn]$ ]]; then
            if request_sudo_for_global_install; then
                echo ""
                echo "Generating custom themes..."

                # Store base themes for future regeneration
                BASE_THEME_LIGHT="$laf_light"
                BASE_THEME_DARK="$laf_dark"

                generate_custom_theme "light" "$BASE_THEME_LIGHT"
                generate_custom_theme "dark" "$BASE_THEME_DARK"
                bundle_wallpapers_and_sddm

                CUSTOM_THEME_LIGHT="org.kde.custom.light"
                CUSTOM_THEME_DARK="org.kde.custom.dark"

                # Update KDE Quick Settings to use our custom themes
                kwriteconfig6 --file kdeglobals --group KDE --key DefaultLightLookAndFeel "$CUSTOM_THEME_LIGHT"
                kwriteconfig6 --file kdeglobals --group KDE --key DefaultDarkLookAndFeel "$CUSTOM_THEME_DARK"

                # Update local variables to use custom themes
                laf_light="$CUSTOM_THEME_LIGHT"
                laf_dark="$CUSTOM_THEME_DARK"

                # Apply the appropriate custom theme to match the user's current mode
                local current_laf
                current_laf=$(kreadconfig6 --file kdeglobals --group KDE --key LookAndFeelPackage 2>/dev/null)
                LAF_LIGHT="$laf_light"
                LAF_DARK="$laf_dark"
                if [[ "$current_laf" == "$BASE_THEME_DARK" ]]; then
                    echo -e "Switching to 🌙 Dark theme: ${BOLD}$(get_friendly_name laf "$LAF_DARK")${RESET}"
                    plasma-apply-lookandfeel -a "$LAF_DARK"
                else
                    echo -e "Switching to ☀️ Light theme: ${BOLD}$(get_friendly_name laf "$LAF_LIGHT")${RESET}"
                    plasma-apply-lookandfeel -a "$LAF_LIGHT"
                fi

                # Re-apply wallpapers from bundled location
                if [[ "${WALLPAPER:-}" == true && -n "${WALLPAPER_BASE:-}" ]]; then
                    local wp_mode="gloam-dynamic"
                    apply_desktop_wallpaper "${WALLPAPER_BASE}/${wp_mode}"
                    apply_lockscreen_wallpaper "${WALLPAPER_BASE}/${wp_mode}"
                fi

                # Apply SDDM wallpaper for current mode
                if [[ -x /usr/local/lib/gloam/set-sddm-background ]]; then
                    local first_sddm_variant="light"
                    if [[ "$current_laf" == "$BASE_THEME_DARK" ]]; then
                        first_sddm_variant="dark"
                    fi
                    local first_sddm_bg
                    first_sddm_bg=$({ compgen -G "/usr/local/lib/gloam/sddm-bg-${first_sddm_variant}.*" || true; } | head -1)
                    [[ -n "$first_sddm_bg" ]] && apply_sddm_wallpaper "$first_sddm_bg"
                fi

                echo -e "${GREEN}Custom themes installed and set as defaults.${RESET}"
            fi
        fi
    fi

    fi # end of interactive block (skipped during --import)

    # Import: generate custom themes and apply settings
    if [[ -n "${IMPORT_CONFIG}" && -n "${BASE_THEME_LIGHT:-}" && -n "${BASE_THEME_DARK:-}" ]]; then
        echo ""
        echo "Generating custom themes..."

        if [[ "${THEME_INSTALL_GLOBAL:-false}" == true ]]; then
            THEME_INSTALL_DIR="/usr/share/plasma/look-and-feel"
        else
            THEME_INSTALL_DIR="${HOME}/.local/share/plasma/look-and-feel"
        fi

        CUSTOM_THEME_LIGHT="org.kde.custom.light"
        CUSTOM_THEME_DARK="org.kde.custom.dark"

        generate_custom_theme "light" "$BASE_THEME_LIGHT"
        generate_custom_theme "dark" "$BASE_THEME_DARK"

        # Regenerate wallpaper packs from original source images
        if [[ "${WALLPAPER:-}" == true && -n "${WP_SOURCE_LIGHT:-}" && -n "${WP_SOURCE_DARK:-}" ]]; then
            echo "Creating wallpaper packs..."
            local wp_light_paths=() wp_dark_paths=()
            local img
            for img in ${WP_SOURCE_LIGHT}; do
                [[ -f "$img" ]] && wp_light_paths+=("$img")
            done
            for img in ${WP_SOURCE_DARK}; do
                [[ -f "$img" ]] && wp_dark_paths+=("$img")
            done
            if [[ ${#wp_light_paths[@]} -gt 0 && ${#wp_dark_paths[@]} -gt 0 ]]; then
                local wp_empty=()
                generate_wallpaper_pack "gloam-dynamic" "Custom (Dynamic)" wp_light_paths wp_dark_paths
                generate_wallpaper_pack "gloam-light" "Custom (Light)" wp_light_paths wp_empty
                generate_wallpaper_pack "gloam-dark" "Custom (Dark)" wp_dark_paths wp_empty
            fi
        fi

        bundle_wallpapers_and_sddm

        # Set up SDDM sudoers rules (skipped during import since interactive prompts are bypassed)
        if [[ -n "${SDDM_LIGHT:-}" || -n "${SDDM_DARK:-}" ]]; then
            setup_sddm_sudoers
        fi

        # Set up SDDM wallpaper helper script if backgrounds were bundled
        if [[ -n "$({ compgen -G '/usr/local/lib/gloam/sddm-bg-*' 2>/dev/null || true; })" ]]; then
            sudo mkdir -p /usr/local/lib/gloam
            sudo tee /usr/local/lib/gloam/set-sddm-background > /dev/null <<'SCRIPT'
#!/bin/bash
[[ -z "$1" || ! -f "$1" ]] && exit 1
THEME=$(kreadconfig6 --file /etc/sddm.conf.d/kde_settings.conf --group Theme --key Current 2>/dev/null)
[[ -z "$THEME" ]] && THEME="breeze"
THEME_DIR="/usr/share/sddm/themes/$THEME"
[[ -d "$THEME_DIR" ]] || exit 1
kwriteconfig6 --file "$THEME_DIR/theme.conf.user" --group General --key background "$1"
SCRIPT
            sudo chmod 755 /usr/local/lib/gloam/set-sddm-background
            echo "ALL ALL=(ALL) NOPASSWD: /usr/local/lib/gloam/set-sddm-background" | \
                sudo tee /etc/sudoers.d/gloam-sddm-bg > /dev/null
            sudo chmod 440 /etc/sudoers.d/gloam-sddm-bg
        fi

        laf_light="$CUSTOM_THEME_LIGHT"
        laf_dark="$CUSTOM_THEME_DARK"

        # Update KDE Quick Settings to use our custom themes
        kwriteconfig6 --file kdeglobals --group KDE --key DefaultLightLookAndFeel "$CUSTOM_THEME_LIGHT"
        kwriteconfig6 --file kdeglobals --group KDE --key DefaultDarkLookAndFeel "$CUSTOM_THEME_DARK"

        # Apply the appropriate custom theme
        local current_laf
        current_laf=$(kreadconfig6 --file kdeglobals --group KDE --key LookAndFeelPackage 2>/dev/null)
        LAF_LIGHT="$laf_light"
        LAF_DARK="$laf_dark"
        if [[ "$current_laf" == "$CUSTOM_THEME_DARK" || "$current_laf" == "$BASE_THEME_DARK" ]]; then
            plasma-apply-lookandfeel -a "$LAF_DARK"
        else
            plasma-apply-lookandfeel -a "$LAF_LIGHT"
        fi

        # Apply wallpapers from bundled location
        if [[ "${WALLPAPER:-}" == true && -n "${WALLPAPER_BASE:-}" ]]; then
            local wp_mode="gloam-dynamic"
            apply_desktop_wallpaper "${WALLPAPER_BASE}/${wp_mode}"
            apply_lockscreen_wallpaper "${WALLPAPER_BASE}/${wp_mode}"
        fi

        # Apply SDDM wallpaper
        if [[ -x /usr/local/lib/gloam/set-sddm-background ]]; then
            local import_sddm_variant="light"
            if [[ "$current_laf" == "$CUSTOM_THEME_DARK" || "$current_laf" == "$BASE_THEME_DARK" ]]; then
                import_sddm_variant="dark"
            fi
            local import_sddm_bg
            import_sddm_bg=$({ compgen -G "/usr/local/lib/gloam/sddm-bg-${import_sddm_variant}.*" || true; } | head -1)
            [[ -n "$import_sddm_bg" ]] && apply_sddm_wallpaper "$import_sddm_bg"
        fi

        echo -e "${GREEN}Custom themes installed.${RESET}"
    fi

    # Store LAF values for push_config_to_users and set_system_defaults
    LAF_LIGHT="$laf_light"
    LAF_DARK="$laf_dark"

    cat > "$CONFIG_FILE" <<EOF
LAF_LIGHT=$laf_light
LAF_DARK=$laf_dark
KVANTUM_LIGHT=${KVANTUM_LIGHT:-}
KVANTUM_DARK=${KVANTUM_DARK:-}
ICON_LIGHT=${ICON_LIGHT:-}
ICON_DARK=${ICON_DARK:-}
PLASMA_CHANGEICONS=${PLASMA_CHANGEICONS:-}
GTK_LIGHT=${GTK_LIGHT:-}
GTK_DARK=${GTK_DARK:-}
COLOR_LIGHT=${COLOR_LIGHT:-}
COLOR_DARK=${COLOR_DARK:-}
STYLE_LIGHT=${STYLE_LIGHT:-}
STYLE_DARK=${STYLE_DARK:-}
DECORATION_LIGHT=${DECORATION_LIGHT:-}
DECORATION_DARK=${DECORATION_DARK:-}
CURSOR_LIGHT=${CURSOR_LIGHT:-}
CURSOR_DARK=${CURSOR_DARK:-}
KONSOLE_LIGHT=${KONSOLE_LIGHT:-}
KONSOLE_DARK=${KONSOLE_DARK:-}
SPLASH_LIGHT=${SPLASH_LIGHT:-}
SPLASH_DARK=${SPLASH_DARK:-}
SDDM_LIGHT=${SDDM_LIGHT:-}
SDDM_DARK=${SDDM_DARK:-}
APPSTYLE_LIGHT=${APPSTYLE_LIGHT:-}
APPSTYLE_DARK=${APPSTYLE_DARK:-}
WALLPAPER=${WALLPAPER:-}
WP_SOURCE_LIGHT=${WP_SOURCE_LIGHT:-}
WP_SOURCE_DARK=${WP_SOURCE_DARK:-}
SCRIPT_LIGHT=${SCRIPT_LIGHT:-}
SCRIPT_DARK=${SCRIPT_DARK:-}
CUSTOM_THEME_LIGHT=${CUSTOM_THEME_LIGHT:-}
CUSTOM_THEME_DARK=${CUSTOM_THEME_DARK:-}
BASE_THEME_LIGHT=${BASE_THEME_LIGHT:-}
BASE_THEME_DARK=${BASE_THEME_DARK:-}
THEME_INSTALL_GLOBAL=${THEME_INSTALL_GLOBAL:-false}
WALLPAPER_BASE=${WALLPAPER_BASE:-}
ICON_LIGHT_MOVED_FROM=${ICON_LIGHT_MOVED_FROM:-}
ICON_DARK_MOVED_FROM=${ICON_DARK_MOVED_FROM:-}
CURSOR_LIGHT_MOVED_FROM=${CURSOR_LIGHT_MOVED_FROM:-}
CURSOR_DARK_MOVED_FROM=${CURSOR_DARK_MOVED_FROM:-}
INSTALL_GLOBAL=${INSTALL_GLOBAL:-false}
PUSH_TO_USERS=${PUSH_TO_USERS:-false}
SET_SYSTEM_DEFAULTS=${SET_SYSTEM_DEFAULTS:-false}
COPY_DESKTOP_LAYOUT=${COPY_DESKTOP_LAYOUT:-false}
INSTALL_CLI=${INSTALL_CLI:-false}
INSTALL_WIDGET=${INSTALL_WIDGET:-false}
INSTALL_SHORTCUT=${INSTALL_SHORTCUT:-false}
EOF

    # Get paths based on install mode
    local cli_path service_dir service_file executable_path
    cli_path="$(get_cli_path)"
    service_dir="$(get_service_dir)"
    service_file="$(get_service_file)"

    # Check if already installed
    local installed_previously=false
    if [[ -x "$cli_path" ]] || [[ -x "${HOME}/.local/bin/gloam" ]] || [[ -x "/usr/local/bin/gloam" ]]; then
        installed_previously=true
    fi

    # Handle widget-only or shortcut-only configuration
    if [[ "$configure_widget" == true || "$configure_shortcut" == true ]] && [[ "$configure_all" == false ]]; then
        if [[ "$installed_previously" == false ]]; then
            echo -e "${RED}Error: Widget and shortcut require the CLI to be installed first.${RESET}" >&2
            echo "Run 'gloam configure' first." >&2
            exit 1
        fi
        # Update the script
        if [[ "$INSTALL_GLOBAL" == true ]]; then
            [[ "$(realpath "$0")" != "$(realpath "$cli_path" 2>/dev/null)" ]] && sudo cp "$0" "$cli_path"
            sudo chmod +x "$cli_path"
        else
            [[ "$(realpath "$0")" != "$(realpath "$cli_path" 2>/dev/null)" ]] && cp "$0" "$cli_path"
            chmod +x "$cli_path"
        fi

        [[ "$configure_widget" == true ]] && install_plasmoid
        [[ "$configure_shortcut" == true ]] && install_shortcut
        return 0
    fi

    # Skip install prompts if partial reconfigure
    if [[ "$configure_all" == false && "$installed_previously" == true ]]; then
        if [[ "$INSTALL_GLOBAL" == true ]]; then
            [[ "$(realpath "$0")" != "$(realpath "$cli_path" 2>/dev/null)" ]] && sudo cp "$0" "$cli_path"
            sudo chmod +x "$cli_path"
        else
            [[ "$(realpath "$0")" != "$(realpath "$cli_path" 2>/dev/null)" ]] && cp "$0" "$cli_path"
            chmod +x "$cli_path"
        fi
        executable_path="$cli_path"
    elif [[ -n "${IMPORT_CONFIG}" ]]; then
        # Import mode - install based on config flags
        if [[ "${INSTALL_CLI:-false}" == true ]]; then
            if [[ "$INSTALL_GLOBAL" == true ]]; then
                sudo mkdir -p "$(dirname "$cli_path")"
                [[ "$(realpath "$0")" != "$(realpath "$cli_path" 2>/dev/null)" ]] && sudo cp "$0" "$cli_path"
                sudo chmod +x "$cli_path"
            else
                mkdir -p "$(dirname "$cli_path")"
                [[ "$(realpath "$0")" != "$(realpath "$cli_path" 2>/dev/null)" ]] && cp "$0" "$cli_path"
                chmod +x "$cli_path"
            fi
            executable_path="$cli_path"
            echo -e "${GREEN}Installed to $cli_path${RESET}"
            [[ "${INSTALL_WIDGET:-false}" == true ]] && install_plasmoid
            [[ "${INSTALL_SHORTCUT:-false}" == true ]] && install_shortcut
        else
            executable_path=$(readlink -f "$0")
        fi
    elif [[ "$configure_all" == true ]]; then
        # Install the CLI
        local install_cli_prompt
        if [[ "$INSTALL_GLOBAL" == true ]]; then
            install_cli_prompt="Install 'gloam' to /usr/local/bin?"
        else
            install_cli_prompt="Install 'gloam' to ~/.local/bin?"
        fi

        echo ""
        read -rp "$install_cli_prompt [y/N]: " choice
        if [[ "$choice" =~ ^[Yy]$ ]]; then
            INSTALL_CLI=true
            if [[ "$INSTALL_GLOBAL" == true ]]; then
                sudo mkdir -p "$(dirname "$cli_path")"
                [[ "$(realpath "$0")" != "$(realpath "$cli_path" 2>/dev/null)" ]] && sudo cp "$0" "$cli_path"
                sudo chmod +x "$cli_path"
            else
                mkdir -p "$(dirname "$cli_path")"
                [[ "$(realpath "$0")" != "$(realpath "$cli_path" 2>/dev/null)" ]] && cp "$0" "$cli_path"
                chmod +x "$cli_path"
            fi
            executable_path="$cli_path"
            echo -e "${GREEN}Installed to $cli_path${RESET}"

            # Offer to install the panel widget
            echo ""
            read -rp "Install the Light/Dark Mode Toggle panel widget? [y/N]: " choice
            [[ "$choice" =~ ^[Yy]$ ]] && { INSTALL_WIDGET=true; install_plasmoid; }

            # Offer to install keyboard shortcut
            echo ""
            read -rp "Add a keyboard shortcut (Meta+Shift+L) to toggle themes? [y/N]: " choice
            [[ "$choice" =~ ^[Yy]$ ]] && { INSTALL_SHORTCUT=true; install_shortcut; }
        else
            # Use absolute path of current script
            executable_path=$(readlink -f "$0")
            echo ""
            echo -e "${YELLOW}Note:${RESET} The panel widget and keyboard shortcut require the CLI to be installed."
        fi
    else
        executable_path=$(readlink -f "$0")
    fi

    # Install systemd service
    if [[ "$INSTALL_GLOBAL" == true ]]; then
        sudo mkdir -p "$service_dir"
        sudo tee "$service_file" > /dev/null <<EOF
[Unit]
Description=Plasma Light/Dark Theme Sync
After=graphical-session.target

[Service]
ExecCondition=/bin/sh -c '[ "\$(id -u)" -ge 1000 ]'
ExecStart=$executable_path watch
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF
    else
        mkdir -p "$service_dir"
        cat > "$service_file" <<EOF
[Unit]
Description=Plasma Light/Dark Theme Sync
After=graphical-session.target

[Service]
ExecStart=$executable_path watch
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF
    fi

    systemctl --user daemon-reload
    systemctl --user enable --now "$SERVICE_NAME"

    # Enable automatic theme switching in KDE Quick Settings
    kwriteconfig6 --file kdeglobals --group KDE --key AutomaticLookAndFeel true

    echo -e "${GREEN}Successfully configured and started $SERVICE_NAME.${RESET}"

    # Push config to other users if requested
    push_config_to_users

    # Set system defaults for new users if requested
    set_system_defaults

    # Write global installation marker
    write_global_install_marker

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
    # Check if any global files exist and request sudo once if needed
    local global_service="/etc/systemd/user/${SERVICE_NAME}.service"
    local global_service_link="/etc/systemd/user/default.target.wants/${SERVICE_NAME}.service"
    local global_cli="/usr/local/bin/gloam"
    local global_plasmoid="/usr/share/plasma/plasmoids/${PLASMOID_ID}"
    local global_shortcut="/usr/share/applications/gloam-toggle.desktop"
    local global_theme_light="/usr/share/plasma/look-and-feel/org.kde.custom.light"
    local global_theme_dark="/usr/share/plasma/look-and-feel/org.kde.custom.dark"
    local skel_config="/etc/skel/.config/gloam.conf"
    local xdg_shortcuts="/etc/xdg/kglobalshortcutsrc"

    local needs_sudo=false
    [[ -f "$global_service" || -f "$global_cli" || -d "$global_plasmoid" || -f "$global_shortcut" || -d "$global_theme_light" || -d "$global_theme_dark" || -f "$skel_config" || -L "$global_service_link" || -f "$GLOBAL_INSTALL_MARKER" || -d "$GLOBAL_SCRIPTS_DIR" || -f /etc/sudoers.d/gloam-sddm || -f /etc/sudoers.d/gloam-sddm-bg || -d /usr/local/lib/gloam || -d /usr/share/wallpapers/gloam-dynamic ]] && needs_sudo=true

    if [[ "$needs_sudo" == true ]]; then
        # Warn about global installation
        if [[ -f "$GLOBAL_INSTALL_MARKER" ]]; then
            local admin_user admin_date
            admin_user=$(grep "^user=" "$GLOBAL_INSTALL_MARKER" 2>/dev/null | cut -d= -f2)
            admin_date=$(grep "^date=" "$GLOBAL_INSTALL_MARKER" 2>/dev/null | cut -d= -f2)

            echo ""
            echo -e "${YELLOW}Warning: This will remove the global installation.${RESET}"
            echo "  Configured by: ${admin_user:-unknown}"
            echo "  Date: ${admin_date:-unknown}"
            echo ""
            echo "This will affect ALL users on this system."
            read -rp "Continue with removal? [y/N]: " choice
            [[ ! "$choice" =~ ^[Yy]$ ]] && { echo "Removal cancelled."; exit 0; }
        fi

        echo "Requesting sudo..."
        sudo -v || { echo -e "${RED}Sudo required to remove global files.${RESET}"; exit 1; }
    fi

    # Stop and disable service
    systemctl --user stop "$SERVICE_NAME" 2>/dev/null || true
    systemctl --user disable "$SERVICE_NAME" 2>/dev/null || true

    # Restore original themes if using custom themes
    if [[ -f "$CONFIG_FILE" ]]; then
        local base_light base_dark
        base_light=$(grep "^BASE_THEME_LIGHT=" "$CONFIG_FILE" 2>/dev/null | cut -d= -f2)
        base_dark=$(grep "^BASE_THEME_DARK=" "$CONFIG_FILE" 2>/dev/null | cut -d= -f2)

        # Reset Quick Settings to original themes
        if [[ -n "$base_light" ]]; then
            kwriteconfig6 --file kdeglobals --group KDE --key DefaultLightLookAndFeel "$base_light"
            echo "Reset light theme to: $base_light"
        fi
        if [[ -n "$base_dark" ]]; then
            kwriteconfig6 --file kdeglobals --group KDE --key DefaultDarkLookAndFeel "$base_dark"
            echo "Reset dark theme to: $base_dark"
        fi

        # Apply the appropriate base theme if currently using custom theme
        local current_laf
        current_laf=$(kreadconfig6 --file kdeglobals --group KDE --key LookAndFeelPackage 2>/dev/null)
        if [[ "$current_laf" == "org.kde.custom.light" && -n "$base_light" ]]; then
            echo "Applying original theme: $base_light"
            plasma-apply-lookandfeel -a "$base_light" 2>/dev/null || true
        elif [[ "$current_laf" == "org.kde.custom.dark" && -n "$base_dark" ]]; then
            echo "Applying original theme: $base_dark"
            plasma-apply-lookandfeel -a "$base_dark" 2>/dev/null || true
        fi

        # Restore icons/cursors that were moved from local to /usr/share/icons/
        # shellcheck source=/dev/null
        source "$CONFIG_FILE"
        local _moved_theme _moved_from _global_path
        for _var_prefix in ICON CURSOR; do
            local _asset_subdir
            [[ "$_var_prefix" == "ICON" ]] && _asset_subdir="icons" || _asset_subdir="cursors"
            for _mode_suffix in LIGHT DARK; do
                _moved_from="${_var_prefix}_${_mode_suffix}_MOVED_FROM"
                _moved_from="${!_moved_from:-}"
                [[ -z "$_moved_from" ]] && continue

                local _theme_var="${_var_prefix}_${_mode_suffix}"
                _moved_theme="${!_theme_var:-}"
                [[ -z "$_moved_theme" ]] && continue

                # Restore main theme and any dependency themes from the bundle
                local _bundle_dir
                local _mode_lc="${_mode_suffix,,}"
                for _theme_install in /usr/share/plasma/look-and-feel "${HOME}/.local/share/plasma/look-and-feel"; do
                    _bundle_dir="${_theme_install}/org.kde.custom.${_mode_lc}/contents/${_asset_subdir}"
                    [[ -d "$_bundle_dir" ]] && break || _bundle_dir=""
                done

                # Collect all theme names to restore (main + dependencies from bundle)
                local _themes_to_restore=("$_moved_theme")
                if [[ -n "$_bundle_dir" ]]; then
                    for _bundled in "$_bundle_dir"/*/; do
                        [[ -d "$_bundled" ]] || continue
                        local _bname
                        _bname="$(basename "$_bundled")"
                        [[ "$_bname" == "$_moved_theme" ]] && continue
                        _themes_to_restore+=("$_bname")
                    done
                fi

                for _restore_name in "${_themes_to_restore[@]}"; do
                    _global_path="/usr/share/icons/${_restore_name}"
                    [[ -d "$_global_path" ]] || continue

                    # Only restore if the original location doesn't already have it
                    if [[ ! -d "${_moved_from}/${_restore_name}" ]]; then
                        mkdir -p "$_moved_from"
                        sudo cp -r "$_global_path" "${_moved_from}/${_restore_name}"
                        sudo chown -R "$(id -u):$(id -g)" "${_moved_from}/${_restore_name}"
                        echo "Restored ${_restore_name} to ${_moved_from}/"
                    fi
                    sudo rm -rf "$_global_path"
                    echo "Removed $_global_path"
                done
            done
        done
    fi

    # Remove config and log files
    [[ -f "$CONFIG_FILE" ]] && rm "$CONFIG_FILE" && echo "Removed $CONFIG_FILE" || true
    [[ -f "$LOG_FILE" ]] && rm "$LOG_FILE" && echo "Removed $LOG_FILE" || true

    # Remove service files
    local local_service="${HOME}/.config/systemd/user/${SERVICE_NAME}.service"
    [[ -f "$local_service" ]] && rm "$local_service" && echo "Removed $local_service" || true
    [[ -L "$global_service_link" ]] && sudo rm "$global_service_link" && echo "Removed $global_service_link" || true
    [[ -f "$global_service" ]] && sudo rm "$global_service" && echo "Removed $global_service" || true

    # Remove CLI
    local local_cli="${HOME}/.local/bin/gloam"
    [[ -f "$local_cli" ]] && rm "$local_cli" && echo "Removed $local_cli" || true
    [[ -f "$global_cli" ]] && sudo rm "$global_cli" && echo "Removed $global_cli" || true

    # Remove global scripts
    [[ -d "$GLOBAL_SCRIPTS_DIR" ]] && sudo rm -rf "$GLOBAL_SCRIPTS_DIR" && echo "Removed $GLOBAL_SCRIPTS_DIR" || true

    # Remove SDDM sudoers rule and wrapper script
    [[ -f /etc/sudoers.d/gloam-sddm ]] && sudo rm /etc/sudoers.d/gloam-sddm && echo "Removed /etc/sudoers.d/gloam-sddm" || true
    [[ -f /etc/sudoers.d/gloam-sddm-bg ]] && sudo rm /etc/sudoers.d/gloam-sddm-bg && echo "Removed /etc/sudoers.d/gloam-sddm-bg" || true
    [[ -d /usr/local/lib/gloam ]] && sudo rm -rf /usr/local/lib/gloam && echo "Removed /usr/local/lib/gloam" || true

    # Remove plasmoid, shortcut, and custom themes
    remove_plasmoid
    remove_shortcut
    remove_custom_themes
    remove_wallpaper_packs

    # Remove system defaults for new users
    [[ -f "$skel_config" ]] && sudo rm "$skel_config" && echo "Removed $skel_config" || true
    local skel_ux_files=(
        plasma-org.kde.plasma.desktop-appletsrc
        plasmashellrc
        kcminputrc
        kwinrc
        kglobalshortcutsrc
        kscreenlockerrc
        krunnerrc
        dolphinrc
        konsolerc
        breezerc
    )
    for cfg in "${skel_ux_files[@]}"; do
        [[ -f "/etc/skel/.config/${cfg}" ]] && sudo rm "/etc/skel/.config/${cfg}" && echo "Removed /etc/skel/.config/${cfg}" || true
    done
    [[ -d /etc/skel/.local/share/plasma/plasmoids ]] && sudo rm -rf /etc/skel/.local/share/plasma/plasmoids && echo "Removed /etc/skel/.local/share/plasma/plasmoids" || true
    [[ -d /etc/skel/.local/share/konsole ]] && sudo rm -rf /etc/skel/.local/share/konsole && echo "Removed /etc/skel/.local/share/konsole" || true

    # Remove keyboard shortcut from /etc/xdg/kglobalshortcutsrc
    if [[ -f "$xdg_shortcuts" ]] && grep -q "$SHORTCUT_ID" "$xdg_shortcuts" 2>/dev/null; then
        sudo kwriteconfig6 --file "$xdg_shortcuts" --group "services" --group "$SHORTCUT_ID" --key "_launch" --delete
        echo "Removed system keyboard shortcut"
    fi

    # Reset Flatpak overrides (only if gloam set them)
    local flatpak_overrides="${HOME}/.local/share/flatpak/overrides/global"
    if command -v flatpak &>/dev/null && [[ -f "$flatpak_overrides" ]] && grep -q "GTK_THEME" "$flatpak_overrides" 2>/dev/null; then
        flatpak override --user --unset-env=GTK_THEME 2>/dev/null || true
        flatpak override --user --unset-env=GTK_ICON_THEME 2>/dev/null || true
        flatpak override --user --unset-env=QT_STYLE_OVERRIDE 2>/dev/null || true
        echo "Reset Flatpak theme overrides"
    fi

    # Unmask splash service in case we masked it
    if systemctl --user is-enabled plasma-ksplash.service 2>&1 | grep -q "masked"; then
        systemctl --user unmask plasma-ksplash.service 2>/dev/null || true
        echo "Unmasked plasma-ksplash.service"
    fi

    # Remove global installation marker
    [[ -f "$GLOBAL_INSTALL_MARKER" ]] && sudo rm "$GLOBAL_INSTALL_MARKER" && echo "Removed $GLOBAL_INSTALL_MARKER" || true

    systemctl --user daemon-reload
    echo -e "${GREEN}Remove complete.${RESET}"
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
    echo -e "${BOLD}Installation locations:${RESET}"

    # CLI location
    local local_cli="${HOME}/.local/bin/gloam"
    local global_cli="/usr/local/bin/gloam"
    if [[ -x "$global_cli" ]]; then
        echo -e "    CLI: ${GREEN}$global_cli (global)${RESET}"
    elif [[ -x "$local_cli" ]]; then
        echo -e "    CLI: ${GREEN}$local_cli (local)${RESET}"
    else
        echo -e "    CLI: ${YELLOW}not installed${RESET}"
    fi

    # Service location
    local local_service="${HOME}/.config/systemd/user/${SERVICE_NAME}.service"
    local global_service="/etc/systemd/user/${SERVICE_NAME}.service"
    if [[ -f "$global_service" ]]; then
        echo -e "    Service: ${GREEN}$global_service (global)${RESET}"
    elif [[ -f "$local_service" ]]; then
        echo -e "    Service: ${GREEN}$local_service (local)${RESET}"
    else
        echo -e "    Service: ${YELLOW}not installed${RESET}"
    fi

    # Plasmoid location
    local local_plasmoid="${HOME}/.local/share/plasma/plasmoids/${PLASMOID_ID}"
    local global_plasmoid="/usr/share/plasma/plasmoids/${PLASMOID_ID}"
    if [[ -d "$global_plasmoid" ]]; then
        echo -e "    Panel widget: ${GREEN}installed (global)${RESET}"
    elif [[ -d "$local_plasmoid" ]]; then
        echo -e "    Panel widget: ${GREEN}installed (local)${RESET}"
    else
        echo -e "    Panel widget: ${YELLOW}not installed${RESET}"
    fi

    # Shortcut location
    local local_shortcut="${HOME}/.local/share/applications/gloam-toggle.desktop"
    local global_shortcut="/usr/share/applications/gloam-toggle.desktop"
    if [[ -f "$global_shortcut" ]]; then
        echo -e "    Keyboard shortcut: ${GREEN}installed (global)${RESET} (Meta+Shift+L)"
    elif [[ -f "$local_shortcut" ]]; then
        echo -e "    Keyboard shortcut: ${GREEN}installed (local)${RESET} (Meta+Shift+L)"
    else
        echo -e "    Keyboard shortcut: ${YELLOW}not installed${RESET}"
    fi

    # Check for custom themes
    local custom_light_global="/usr/share/plasma/look-and-feel/org.kde.custom.light"
    local custom_light_local="${HOME}/.local/share/plasma/look-and-feel/org.kde.custom.light"
    local custom_dark_global="/usr/share/plasma/look-and-feel/org.kde.custom.dark"
    local custom_dark_local="${HOME}/.local/share/plasma/look-and-feel/org.kde.custom.dark"

    if [[ -d "$custom_light_global" ]]; then
        echo -e "    Custom (Light): ${GREEN}installed (global)${RESET}"
    elif [[ -d "$custom_light_local" ]]; then
        echo -e "    Custom (Light): ${GREEN}installed (local)${RESET}"
    else
        echo -e "    Custom (Light): ${YELLOW}not installed${RESET}"
    fi

    if [[ -d "$custom_dark_global" ]]; then
        echo -e "    Custom (Dark): ${GREEN}installed (global)${RESET}"
    elif [[ -d "$custom_dark_local" ]]; then
        echo -e "    Custom (Dark): ${GREEN}installed (local)${RESET}"
    else
        echo -e "    Custom (Dark): ${YELLOW}not installed${RESET}"
    fi

    # Show bundled assets in custom themes
    local custom_theme_dir=""
    if [[ -d "$custom_light_global" ]]; then
        custom_theme_dir="$custom_light_global"
    elif [[ -d "$custom_light_local" ]]; then
        custom_theme_dir="$custom_light_local"
    fi

    if [[ -n "$custom_theme_dir" ]]; then
        local bundled_assets=()
        [[ -d "${custom_theme_dir}/contents/colors" ]] && bundled_assets+=("colors")
        [[ -d "${custom_theme_dir}/contents/icons" ]] && bundled_assets+=("icons")
        [[ -d "${custom_theme_dir}/contents/cursors" ]] && bundled_assets+=("cursors")
        [[ -d "${custom_theme_dir}/contents/desktoptheme" ]] && bundled_assets+=("plasma style")
        [[ -d "${custom_theme_dir}/contents/wallpapers" ]] && bundled_assets+=("wallpapers")
        [[ -d "${custom_theme_dir}/contents/sddm" ]] && bundled_assets+=("sddm background")

        # Check dark theme sddm too
        local custom_dark_dir=""
        [[ -d "$custom_dark_global" ]] && custom_dark_dir="$custom_dark_global"
        [[ -z "$custom_dark_dir" && -d "$custom_dark_local" ]] && custom_dark_dir="$custom_dark_local"
        if [[ -n "$custom_dark_dir" && -d "${custom_dark_dir}/contents/sddm" ]] && ! [[ " ${bundled_assets[*]} " == *" sddm background "* ]]; then
            bundled_assets+=("sddm background")
        fi

        if [[ ${#bundled_assets[@]} -gt 0 ]]; then
            local joined
            joined=$(IFS=", "; echo "${bundled_assets[*]}")
            echo -e "    Bundled assets: ${GREEN}${joined}${RESET}"
        else
            echo -e "    Bundled assets: ${YELLOW}none${RESET}"
        fi
    fi

    # Check if panel layout is in /etc/skel for new users
    local skel_panel="/etc/skel/.config/plasma-org.kde.plasma.desktop-appletsrc"
    if [[ -f "$skel_panel" ]]; then
        echo -e "    Panel layout: ${GREEN}in /etc/skel${RESET}"
    else
        echo -e "    Panel layout: ${YELLOW}not in /etc/skel${RESET}"
    fi

    # Check splash service status
    if systemctl --user is-enabled plasma-ksplash.service 2>&1 | grep -q "masked"; then
        echo -e "    Splash screen: ${GREEN}disabled (service masked)${RESET}"
    else
        echo -e "    Splash screen: ${YELLOW}enabled${RESET}"
    fi

    # Check system defaults for new users
    local xdg_globals="/etc/xdg/kdeglobals"
    local skel_config="/etc/skel/.config/gloam.conf"
    local service_link="/etc/systemd/user/default.target.wants/${SERVICE_NAME}.service"

    local sys_defaults_set=false
    if [[ -f "$xdg_globals" ]]; then
        local sys_light sys_dark
        sys_light=$(grep -E "^DefaultLightLookAndFeel=" "$xdg_globals" 2>/dev/null | cut -d= -f2)
        sys_dark=$(grep -E "^DefaultDarkLookAndFeel=" "$xdg_globals" 2>/dev/null | cut -d= -f2)
        [[ -n "$sys_light" || -n "$sys_dark" ]] && sys_defaults_set=true
    fi

    if [[ "$sys_defaults_set" == true && -f "$skel_config" && -L "$service_link" ]]; then
        echo -e "    New user setup: ${GREEN}fully configured${RESET}"
    elif [[ "$sys_defaults_set" == true || -f "$skel_config" || -L "$service_link" ]]; then
        echo -e "    New user setup: ${YELLOW}partially configured${RESET}"
    else
        echo -e "    New user setup: ${YELLOW}not configured${RESET}"
    fi

    echo ""
    local current_laf
    current_laf=$(kreadconfig6 --file kdeglobals --group KDE --key LookAndFeelPackage 2>/dev/null)
    local laf_light laf_dark
    laf_light=$(kreadconfig6 --file kdeglobals --group KDE --key DefaultLightLookAndFeel 2>/dev/null)
    laf_dark=$(kreadconfig6 --file kdeglobals --group KDE --key DefaultDarkLookAndFeel 2>/dev/null)

    echo -e "${BOLD}Current mode:${RESET}"
    if [[ "$current_laf" == "$laf_light" ]]; then
        echo "  ☀️ Light ($(get_friendly_name laf "$current_laf") - $current_laf)"
    elif [[ "$current_laf" == "$laf_dark" ]]; then
        echo "  🌙 Dark ($(get_friendly_name laf "$current_laf") - $current_laf)"
    else
        echo "  Unknown ($current_laf)"
    fi

    echo ""
    if [[ -f "$CONFIG_FILE" ]]; then
        echo -e "${BOLD}Configuration ($CONFIG_FILE):${RESET}"
        # shellcheck source=/dev/null
        source "$CONFIG_FILE"
        echo -e "☀️ Light theme: ${BOLD}$(get_friendly_name laf "$LAF_LIGHT")${RESET} ($LAF_LIGHT)"
        echo "    Colors: ${COLOR_LIGHT:-unset}"
        echo "    Kvantum: ${KVANTUM_LIGHT:-unset}"
        echo "    App style: ${APPSTYLE_LIGHT:-unset}"
        echo "    GTK: ${GTK_LIGHT:-unset}"
        echo "    Style: ${STYLE_LIGHT:-unset}"
        echo "    Decorations: $([[ -n "${DECORATION_LIGHT:-}" ]] && get_friendly_name decoration "$DECORATION_LIGHT" || echo "unchanged")"
        echo "    Icons: ${ICON_LIGHT:-unset}"
        echo "    Cursors: ${CURSOR_LIGHT:-unset}"
        echo "    Splash: $(get_friendly_name splash "${SPLASH_LIGHT:-}")"
        echo "    Login: $(get_friendly_name sddm "${SDDM_LIGHT:-}")"
        echo "    Wallpaper: ${WALLPAPER:+Custom (Dynamic, Light, Dark)}"
        echo "    Konsole: ${KONSOLE_LIGHT:-unset}"
        echo "    Script: ${SCRIPT_LIGHT:-unset}"
        echo -e "🌙 Dark theme:  ${BOLD}$(get_friendly_name laf "$LAF_DARK")${RESET} ($LAF_DARK)"
        echo "    Colors: ${COLOR_DARK:-unset}"
        echo "    Kvantum: ${KVANTUM_DARK:-unset}"
        echo "    App style: ${APPSTYLE_DARK:-unset}"
        echo "    GTK: ${GTK_DARK:-unset}"
        echo "    Style: ${STYLE_DARK:-unset}"
        echo "    Decorations: $([[ -n "${DECORATION_DARK:-}" ]] && get_friendly_name decoration "$DECORATION_DARK" || echo "unchanged")"
        echo "    Icons: ${ICON_DARK:-unset}"
        echo "    Cursors: ${CURSOR_DARK:-unset}"
        echo "    Splash: $(get_friendly_name splash "${SPLASH_DARK:-}")"
        echo "    Login: $(get_friendly_name sddm "${SDDM_DARK:-}")"
        echo "    Wallpaper: ${WALLPAPER:+Custom (Dynamic, Light, Dark)}"
        echo "    Konsole: ${KONSOLE_DARK:-unset}"
        echo "    Script: ${SCRIPT_DARK:-unset}"
        if [[ -n "${WALLPAPER_BASE:-}" ]]; then
            echo ""
            echo "    Wallpaper base: ${WALLPAPER_BASE}"
        fi
    else
        echo "Configuration: not installed"
    fi
}

show_configure_help() {
    cat <<EOF
Usage: $0 configure [options]

Description:
  Scan themes, save config, enable systemd service, and optionally install helper tools.
  With no options, runs the full configuration wizard.
  With options, only reconfigures the specified components.

Options:
  -c, --colors        Configure color schemes only
  -k, --kvantum       Configure Kvantum themes only
  -a, --appstyle      Configure application style (Qt widget style)
  -g, --gtk           Configure GTK themes only
  -p, --style         Configure Plasma styles only
  -d, --decorations   Configure window decorations only
  -i, --icons         Configure icon themes only
  -C, --cursors       Configure cursor themes only
  -S, --splash        Configure splash screens only
  -l, --login         Configure login screen (SDDM) themes
  -W, --wallpaper     Configure day/night wallpapers
  -o, --konsole       Configure Konsole profiles only
  -s, --script        Configure custom scripts only
  -w, --widget        Install/reinstall panel widget
  -K, --shortcut      Install/reinstall keyboard shortcut (Meta+Shift+L)
  -I, --import <file>  Import an existing gloam.conf and skip interactive setup

Panel Widget:
  During configuration, if you install the command globally (~/.local/bin),
  you'll be offered to install a Light/Dark Mode Toggle panel widget. This adds
  a sun/moon button to your panel for quick theme switching.

Examples:
  $0 configure              Configure all theme options
  $0 configure -k -i        Configure only Kvantum and icon themes
  $0 configure --splash     Configure only splash screens
  $0 configure --import /path/to/gloam.conf
                            Import config from another machine/user
EOF
}

show_help() {
    cat <<EOF
gloam - A dark/light mode theme switcher for KDE Plasma's day/night cycle

Usage: $0 <command> [options]

Commands:
  configure    Scan themes, save config, enable systemd service
  watch        Start the theme monitoring loop (foreground)
  light        Switch to Light mode (and sync sub-themes)
  dark         Switch to Dark mode (and sync sub-themes)
  toggle       Toggle between Light and Dark mode
  remove       Stop service, remove all installed files and widget
  status       Show service status and current configuration
  help         Show this help message

Run '$0 configure --help' for detailed configuration options.
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
    ""|help|-h|--help) show_help ;;
    *)
        echo "Usage: $0 <command> [options]"
        echo "Try '$0 help' for more information."
        exit 1
        ;;
esac
