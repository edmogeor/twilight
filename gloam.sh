#!/usr/bin/env bash
{
################################################################################
#                                                                              #
#                        ░██                                                   #
#                        ░██                                                   #
#              ░████████ ░██  ░███████   ░██████   ░█████████████              #
#             ░██    ░██ ░██ ░██    ░██       ░██  ░██   ░██   ░██             #
#             ░██    ░██ ░██ ░██    ░██  ░███████  ░██   ░██   ░██             #
#             ░██   ░███ ░██ ░██    ░██ ░██   ░██  ░██   ░██   ░██             #
#              ░█████░██ ░██  ░███████   ░█████░██ ░██   ░██   ░██             #
#                    ░██                                                       #
#              ░███████                                                        #
#                                                                              #
#           KDE Plasma 6 Day/Night Theme Synchronizer & Manager                #
#                                                                              #
#  gloam bridges the gap in KDE Plasma by synchronizing external themes that   #
#  don't switch automatically. It hooks into Plasma's native day/night         #
#  transition to instantly synchronize Kvantum, GTK apps, Flatpaks, Konsole,   #
#  and more.                                                                   #
#                                                                              #
#  Copyright (c) 2026 edmogeor                                                 #
#  GitHub:  https://github.com/edmogeor/gloam                                  #
#  License: GPLv3                                                              #
#                                                                              #
################################################################################

# --- CONFIGURATION & GLOBALS --------------------------------------------------

set -euo pipefail

# --- Colour palette (indigo accent) ---
# gum style colours (ANSI 256-colour)
# Chosen to work on both light and dark terminal backgrounds.
CLR_PRIMARY="99"        # indigo
CLR_SECONDARY="105"     # light indigo
CLR_SUCCESS="35"        # green (visible on light & dark)
CLR_WARNING="214"       # amber/yellow
CLR_ERROR="196"         # red
CLR_MUTED="243"         # mid-grey (good contrast on both backgrounds)
CLR_ACCENT="135"        # purple-indigo for highlights

# ANSI fallbacks (for log file output & non-interactive paths)
BOLD='\033[1m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[38;5;99m'
RESET='\033[0m'

# Version
GLOAM_VERSION="1.3.2"
GLOAM_REPO="edmogeor/gloam"


# Global installation mode flags
INSTALL_GLOBAL=false
PUSH_TO_USERS=false
SET_SYSTEM_DEFAULTS=false
SELECTED_USERS=()

# Global installation marker file
GLOBAL_INSTALL_MARKER="/etc/gloam.admin"

# Keys added/overwritten by gloam in /etc/xdg/kdeglobals (populated during install, read during removal)
XDG_KEYS_ADDED=()
XDG_KEYS_OVERWRITTEN=()

# Skel files/dirs created by gloam (populated during install, read during removal)
SKEL_FILES_CREATED=()
SKEL_DIRS_CREATED=()

# Previous Flatpak override values (populated during install, read during removal)
FLATPAK_PREV_OVERRIDES=()

# Session logout tracking — set to true when patches, plasmoid, or shortcut are installed
NEEDS_LOGOUT=false

# Global scripts directory
GLOBAL_SCRIPTS_DIR="/usr/local/share/gloam"

# UX config files to copy for desktop layout replication
UX_CONFIGS=(
    plasmashellrc
    kcminputrc
    kwinrc
    kglobalshortcutsrc
    kscreenlockerrc
    krunnerrc
    dolphinrc
    konsolerc
    breezerc
    kcmfonts
)

# Font keys to copy from kdeglobals (group:key format)
FONT_KEYS=(
    "General:font"
    "General:fixed"
    "General:smallestReadableFont"
    "General:toolBarFont"
    "General:menuFont"
    "WM:activeFont"
)

# --- UTILITIES & LOGGING ------------------------------------------------------

# Log file
LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}"
LOG_FILE="${LOG_DIR}/gloam.log"
MODE_FILE="${XDG_RUNTIME_DIR}/gloam-runtime"
LOG_MAX_SIZE=102400  # 100KB
GLOAM_DEBUG="${GLOAM_DEBUG:-false}"

_log_write() {
    local level="$1" message="$2"
    mkdir -p "$LOG_DIR"
    if [[ -f "$LOG_FILE" ]] && (( $(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0) > LOG_MAX_SIZE )); then
        tail -n 100 "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
    fi
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $message" >> "$LOG_FILE"
}

GLOAM_LOG_MODE="pretty"  # "pretty" = gum styled, "raw" = timestamped plain text

_log_print() {
    local level="$1"; shift
    if [[ "$GLOAM_LOG_MODE" == "raw" ]]; then
        echo "[$(date '+%H:%M:%S')] [$level] $*"
    else
        case "$level" in
            INFO)  msg_info "$*" ;;
            WARN)  msg_warn "$*" ;;
            ERROR) msg_err "$*" ;;
            DEBUG) msg_muted "DEBUG: $*" ;;
        esac
    fi
}

log()   { _log_write "INFO" "$*"; _log_print INFO "$*"; }
warn()  { _log_write "WARN" "$*"; _log_print WARN "$*"; }
error() { _log_write "ERROR" "$*"; _log_print ERROR "$*"; }
die()   { error "$*"; exit 1; }
debug() { [[ "$GLOAM_DEBUG" == "true" ]] && { _log_write "DEBUG" "$*"; _log_print DEBUG "$*"; }; }

# Temp file tracking and cleanup
GLOAM_TMPFILES=()

gloam_mktemp() {
    local f
    f=$(mktemp /tmp/gloam-XXXXXXXX)
    GLOAM_TMPFILES+=("$f")
    echo "$f"
}

cleanup() {
    # Stop any running spinner
    [[ -n "${_spinner_pid:-}" ]] && kill "$_spinner_pid" 2>/dev/null && wait "$_spinner_pid" 2>/dev/null || true
    for f in "${GLOAM_TMPFILES[@]}"; do
        [[ -f "$f" ]] && rm -f "$f"
    done
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM

# --- gum wrapper functions (themed) -----------------------------------------

_gum_check_cancel() {
    [[ $1 -eq 130 ]] && exit 130
    return $1
}

_gum_confirm() {
    gum confirm \
        --prompt.foreground "$CLR_PRIMARY" \
        --selected.background "$CLR_PRIMARY" \
        --unselected.foreground "$CLR_MUTED" \
        "$@" || _gum_check_cancel $?
}

_gum_choose() {
    gum choose \
        --header.foreground "$CLR_PRIMARY" \
        --cursor.foreground "$CLR_SECONDARY" \
        --selected.foreground "$CLR_PRIMARY" \
        "$@" || _gum_check_cancel $?
}

_gum_filter() {
    gum filter \
        --header.foreground "$CLR_PRIMARY" \
        --indicator.foreground "$CLR_SECONDARY" \
        --match.foreground "$CLR_ACCENT" \
        --prompt.foreground "$CLR_PRIMARY" \
        --cursor-text.foreground "$CLR_PRIMARY" \
        --selected-indicator.foreground "$CLR_PRIMARY" \
        "$@" || _gum_check_cancel $?
}

_gum_input() {
    gum input \
        --header.foreground "$CLR_PRIMARY" \
        --cursor.foreground "$CLR_SECONDARY" \
        --prompt.foreground "$CLR_PRIMARY" \
        --placeholder.foreground "$CLR_MUTED" \
        "$@" || _gum_check_cancel $?
}

_gum_spin() {
    gum spin \
        --spinner dot \
        --spinner.foreground "$CLR_PRIMARY" \
        "$@"
}

# Start/stop a background spinner for long-running inline operations.
# Usage: _spinner_start "Loading..."; do_work; _spinner_stop
# Works with bash functions that modify variables (no subshell).
_spinner_pid=""
_spinner_start() {
    local title="$1"
    _spinner_title="$title"
    (
        set +e
        local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
        local i=0
        tput civis 2>/dev/null
        while true; do
            printf "\r\033[38;5;%sm%s\033[0m %s" "$CLR_PRIMARY" "${frames[i % ${#frames[@]}]}" "$title"
            i=$(( i + 1 ))
            sleep 0.08
        done
    ) &
    _spinner_pid=$!
}
_spinner_stop() {
    [[ -z "$_spinner_pid" ]] && return
    kill "$_spinner_pid" 2>/dev/null || true
    wait "$_spinner_pid" 2>/dev/null || true
    printf "\r\033[K"
    tput cnorm 2>/dev/null
    _spinner_pid=""
}

_spinner_print() {
    local msg="$1"
    if [[ -n "$_spinner_pid" ]]; then
        kill "$_spinner_pid" 2>/dev/null || true
        wait "$_spinner_pid" 2>/dev/null || true
        printf "\r\033[K"
        echo "$msg"
        _spinner_start "$_spinner_title"
    else
        echo "$msg"
    fi
}

sudo_auth() {
    msg_info "Waiting for sudo authentication..."
    local ok=true
    sudo -v || ok=false
    tput cuu1 2>/dev/null; tput el 2>/dev/null
    if $ok; then msg_ok "Sudo authenticated."; return 0
    else error "Sudo authentication failed."; return 1; fi
}

# --- Styled message helpers --------------------------------------------------

msg_ok() {
    gum style --foreground "$CLR_SUCCESS" "✓ $*"
}

msg_warn() {
    gum style --foreground "$CLR_WARNING" "⚠ $*"
}

msg_err() {
    gum style --foreground "$CLR_ERROR" "✗ $*" >&2
}

msg_info() {
    gum style --foreground "$CLR_PRIMARY" "$*"
}

msg_header() {
    echo ""
    gum style \
        --foreground "$CLR_PRIMARY" \
        --bold \
        --border normal \
        --border-foreground "$CLR_PRIMARY" \
        --padding "0 2" \
        "$*"
}

msg_muted() {
    gum style --foreground "$CLR_MUTED" "$@"
}

# Resolve script directory once (before any cd can change cwd)
GLOAM_SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"

# Get patches directory (script location for local, /usr/local/share/gloam for global)
get_patches_dir() {
    local local_patches="${GLOAM_SCRIPT_DIR}/patches"
    local global_patches="${GLOBAL_SCRIPTS_DIR}/patches"
    if [[ -d "$local_patches" ]]; then
        echo "$local_patches"
    elif [[ -d "$global_patches" ]]; then
        echo "$global_patches"
    else
        return 1
    fi
}

# Fetch patches from GitHub if not available locally (for global installs without patches)
fetch_patches_if_missing() {
    local patches_dir
    patches_dir=$(get_patches_dir) && return 0

    msg_info "Patches not found locally, fetching from GitHub..."
    local tmp_dir
    tmp_dir=$(mktemp -d)
    local tarball_url="https://api.github.com/repos/${GLOAM_REPO}/tarball/$(curl -fsSL --max-time 5 "https://api.github.com/repos/${GLOAM_REPO}/releases/latest" 2>/dev/null | grep '"tag_name"' | sed 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' || echo "main")"

    if ! curl -fsSL --max-time 30 "$tarball_url" | tar xz -C "$tmp_dir" --strip-components=1 2>/dev/null; then
        rm -rf "$tmp_dir"
        return 1
    fi

    if [[ -d "$tmp_dir/patches" ]]; then
        sudo mkdir -p "${GLOBAL_SCRIPTS_DIR}" || { rm -rf "$tmp_dir"; return 1; }
        sudo rm -rf "${GLOBAL_SCRIPTS_DIR}/patches"
        sudo cp -r "$tmp_dir/patches" "${GLOBAL_SCRIPTS_DIR}/" || { rm -rf "$tmp_dir"; return 1; }
        rm -rf "$tmp_dir"
        return 0
    fi

    rm -rf "$tmp_dir"
    return 1
}

# Base paths (may be overridden by global install)
KVANTUM_DIR="${HOME}/.config/Kvantum"
CONFIG_FILE="${HOME}/.config/gloam.conf"
SERVICE_NAME="gloam"
PLASMOID_ID="org.kde.plasma.lightdarktoggle"
SHORTCUT_ID="gloam-toggle.desktop"

# Patch management
PATCH_BUILD_DIR="${HOME}/.cache/gloam/patch-build"
PATCH_STAGED_SO="${HOME}/.cache/gloam/staged-plasma-integration.so"

# Delays (seconds) for KDE to finish writing configs after LookAndFeel apply
DELAY_LAF_SETTLE=0.5
DELAY_LAF_PROPAGATE=1

# Expected config variables (must match the heredoc that writes gloam.conf)
EXPECTED_CONFIG_VARS=(
    LAF_LIGHT LAF_DARK KVANTUM_LIGHT KVANTUM_DARK ICON_LIGHT ICON_DARK
    PLASMA_CHANGEICONS GTK_LIGHT GTK_DARK COLOR_LIGHT COLOR_DARK
    STYLE_LIGHT STYLE_DARK DECORATION_LIGHT DECORATION_DARK
    CURSOR_LIGHT CURSOR_DARK KONSOLE_LIGHT KONSOLE_DARK
    SPLASH_LIGHT SPLASH_DARK SDDM_LIGHT SDDM_DARK
    APPSTYLE_LIGHT APPSTYLE_DARK WALLPAPER WP_SOURCE_LIGHT WP_SOURCE_DARK
    SCRIPT_LIGHT SCRIPT_DARK CUSTOM_THEME_LIGHT CUSTOM_THEME_DARK
    BASE_THEME_LIGHT BASE_THEME_DARK THEME_INSTALL_GLOBAL WALLPAPER_BASE
    ICON_LIGHT_MOVED_FROM ICON_DARK_MOVED_FROM
    CURSOR_LIGHT_MOVED_FROM CURSOR_DARK_MOVED_FROM
    INSTALL_GLOBAL PUSH_TO_USERS SET_SYSTEM_DEFAULTS COPY_DESKTOP_LAYOUT
    INSTALL_CLI INSTALL_WIDGET INSTALL_SHORTCUT
)

# Run a command with sudo if condition is true, otherwise run directly
maybe_sudo() {
    if [[ "$1" == true ]]; then
        sudo "${@:2}"
    else
        "${@:2}"
    fi
}

gloam_cmd() { maybe_sudo "$INSTALL_GLOBAL" "$@"; }
theme_cmd() { maybe_sudo "${THEME_INSTALL_GLOBAL:-false}" "$@"; }

has_any_config() {
    local vars=(
        KVANTUM_LIGHT KVANTUM_DARK STYLE_LIGHT STYLE_DARK
        DECORATION_LIGHT DECORATION_DARK COLOR_LIGHT COLOR_DARK
        ICON_LIGHT ICON_DARK CURSOR_LIGHT CURSOR_DARK
        GTK_LIGHT GTK_DARK KONSOLE_LIGHT KONSOLE_DARK
        SPLASH_LIGHT SPLASH_DARK SDDM_LIGHT SDDM_DARK
        APPSTYLE_LIGHT APPSTYLE_DARK WALLPAPER SCRIPT_LIGHT SCRIPT_DARK
    )
    for var in "${vars[@]}"; do
        [[ -n "${!var:-}" ]] && return 0
    done
    return 1
}

status_check() {
    local label="$1" global="$2" local="$3" test_op="$4" extra="${5:-Installed}"
    local global_ok=false local_ok=false
    case "$test_op" in
        -f) [[ -f "$global" ]] && global_ok=true; [[ -f "$local" ]] && local_ok=true ;;
        -d) [[ -d "$global" ]] && global_ok=true; [[ -d "$local" ]] && local_ok=true ;;
        -x) [[ -x "$global" ]] && global_ok=true; [[ -x "$local" ]] && local_ok=true ;;
    esac
    if [[ "$global_ok" == true ]]; then
        echo "  $(gum style --foreground "$CLR_SUCCESS" "✓") ${label}: $(gum style --foreground "$CLR_SUCCESS" "${extra} (Global)")"
    elif [[ "$local_ok" == true ]]; then
        echo "  $(gum style --foreground "$CLR_SUCCESS" "✓") ${label}: $(gum style --foreground "$CLR_SUCCESS" "${extra} (Local)")"
    else
        echo "  $(gum style --foreground "$CLR_WARNING" "○") ${label}: $(gum style --foreground "$CLR_MUTED" "Not installed")"
    fi
}

# --- PATH HELPERS -------------------------------------------------------------

# Path helper: returns global or local path based on INSTALL_GLOBAL
global_or_local() {
    local global_path="$1" local_path="$2"
    if [[ "$INSTALL_GLOBAL" == true ]]; then
        echo "$global_path"
    else
        echo "$local_path"
    fi
}

get_cli_path() {
    global_or_local "/usr/local/bin/gloam" "${HOME}/.local/bin/gloam"
}

get_plasmoid_path() {
    global_or_local "/usr/share/plasma/plasmoids/${PLASMOID_ID}" "${HOME}/.local/share/plasma/plasmoids/${PLASMOID_ID}"
}

get_desktop_file_path() {
    global_or_local "/usr/share/applications/gloam-toggle.desktop" "${HOME}/.local/share/applications/gloam-toggle.desktop"
}

get_theme_install_dir() {
    global_or_local "/usr/share/plasma/look-and-feel" "${HOME}/.local/share/plasma/look-and-feel"
}

get_service_dir() {
    global_or_local "/etc/systemd/user" "${HOME}/.config/systemd/user"
}

get_service_file() {
    echo "$(get_service_dir)/${SERVICE_NAME}.service"
}

# Copy this script to the CLI path if it differs from the source
install_cli_binary() {
    local cli_path
    cli_path="$(get_cli_path)"
    gloam_cmd mkdir -p "$(dirname "$cli_path")"
    if [[ "$(realpath "$0")" != "$(realpath "$cli_path" 2>/dev/null)" ]]; then
        gloam_cmd cp "$0" "$cli_path"
    fi
    gloam_cmd chmod 755 "$cli_path"
    deploy_patches_dir
}

# Deploy patch files to global location so they survive across sessions
deploy_patches_dir() {
    [[ "$INSTALL_GLOBAL" == true ]] || return 0
    local src_patches="${GLOAM_SCRIPT_DIR}/patches"
    [[ -d "$src_patches" ]] || return 0
    [[ "$src_patches" == "${GLOBAL_SCRIPTS_DIR}/patches" ]] && return 0
    sudo mkdir -p "${GLOBAL_SCRIPTS_DIR}"
    sudo rm -rf "${GLOBAL_SCRIPTS_DIR}/patches"
    sudo cp -r "$src_patches" "${GLOBAL_SCRIPTS_DIR}/"
}

# --- UPDATE LOGIC -------------------------------------------------------------

# Check if a newer version is available on GitHub
# Sets GLOAM_REMOTE_VERSION if an update is available, returns 0
# Returns 1 if already up to date or check failed
# Arguments: $1 = "verbose" to print status messages
check_for_updates() {
    local verbose="${1:-}"
    local api_url="https://api.github.com/repos/${GLOAM_REPO}/releases/latest"

    local response
    response=$(curl -fsSL --max-time 3 "$api_url" 2>/dev/null) || {
        [[ "$verbose" == "verbose" ]] && debug "Could not check for updates (network error or no releases found)."
        return 1
    }

    local remote_tag
    remote_tag=$(printf '%s' "$response" | grep '"tag_name"' | sed 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
    [[ -z "$remote_tag" ]] && return 1

    GLOAM_REMOTE_VERSION="${remote_tag#v}"

    # Compare versions: if remote <= current, we're up to date
    local newest
    newest=$(printf '%s\n%s\n' "$GLOAM_VERSION" "$GLOAM_REMOTE_VERSION" | sort -V | tail -n1)
    if [[ "$newest" == "$GLOAM_VERSION" ]]; then
        return 1
    fi

    return 0
}

# Download and install an available update
apply_update() {
    local api_url="https://api.github.com/repos/${GLOAM_REPO}/releases/latest"
    local response
    response=$(curl -fsSL --max-time 3 "$api_url" 2>/dev/null) || {
        error "Could not fetch release info. Check your network connection."
        return 1
    }

    local tarball_url
    tarball_url=$(printf '%s' "$response" | grep '"tarball_url"' | sed 's/.*"tarball_url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
    if [[ -z "$tarball_url" ]]; then
        error "Could not find download URL in release. Update manually from https://github.com/${GLOAM_REPO}/releases"
        return 1
    fi

    _spinner_start "Downloading v${GLOAM_REMOTE_VERSION}..."

    local tmp_dir
    tmp_dir=$(mktemp -d)

    if ! curl -fsSL --max-time 30 "$tarball_url" | tar xz -C "$tmp_dir" --strip-components=1; then
        _spinner_stop
        error "Failed to download update from ${tarball_url}. Check your network connection or try again later."
        rm -rf "$tmp_dir"
        return 1
    fi

    # Update the CLI binary (mv to new inode so the running script is not corrupted)
    local cli_path cli_dir tmp_cli
    cli_path="$(get_cli_path)"
    cli_dir="$(dirname "$cli_path")"
    tmp_cli=$(gloam_cmd mktemp "${cli_dir}/gloam.XXXXXX")
    gloam_cmd cp "$tmp_dir/gloam.sh" "$tmp_cli"
    gloam_cmd chmod 755 "$tmp_cli"
    gloam_cmd mv "$tmp_cli" "$cli_path"

    # Update patches directory for global installs
    if [[ -d "$tmp_dir/patches" ]]; then
        sudo mkdir -p "${GLOBAL_SCRIPTS_DIR}"
        sudo rm -rf "${GLOBAL_SCRIPTS_DIR}/patches"
        sudo cp -r "$tmp_dir/patches" "${GLOBAL_SCRIPTS_DIR}/"
    fi

    # Update the plasmoid if already installed
    if [[ -d "$tmp_dir/plasmoid" ]]; then
        local kp_args=(-t Plasma/Applet)
        [[ "$INSTALL_GLOBAL" == true ]] && kp_args+=(--global)
        if kpackagetool6 "${kp_args[@]}" --show "$PLASMOID_ID" &>/dev/null; then
            gloam_cmd kpackagetool6 "${kp_args[@]}" --upgrade "$tmp_dir/plasmoid" >/dev/null 2>&1
        fi
    fi

    rm -rf "$tmp_dir"

    _spinner_stop
    echo ""
    msg_ok "Updated to v${GLOAM_REMOTE_VERSION}."
    return 0
}

do_update() {
    msg_header "Update"

    if [[ ! -f "/usr/local/bin/gloam" ]]; then
        warn "gloam is not installed globally."
        echo ""
        if _gum_confirm "Would you like to install globally?"; then
            INSTALL_GLOBAL=true
        else
            msg_muted "Run 'gloam configure' to update a local installation."
            return 0
        fi
    else
        INSTALL_GLOBAL=true
    fi

    _spinner_start "Checking for updates..."
    if ! check_for_updates; then
        _spinner_stop
        msg_ok "Already up to date (v${GLOAM_VERSION})."
        return 0
    fi
    _spinner_stop

    msg_info "Update available: v${GLOAM_VERSION} → v${GLOAM_REMOTE_VERSION}"
    echo ""
    _gum_confirm "Update now?" || { msg_muted "Update skipped."; return 0; }

    apply_update || return 1

    if [[ -f "$CONFIG_FILE" ]] && ! check_config_valid; then
        echo ""
        warn "Your configuration is outdated after this update."
        echo ""
        if _gum_confirm "Reconfigure now?"; then
            exec "$(get_cli_path)" --no-banner configure
        else
            msg_muted "Run 'gloam configure' when ready."
        fi
    fi
}

# --- INSTALLATION (GLOBAL/SYSTEM) ---------------------------------------------

# Check for existing global installation
check_existing_global_install() {
    [[ ! -f "$GLOBAL_INSTALL_MARKER" ]] && return 0

    local admin_user admin_date
    admin_user=$(grep "^user=" "$GLOBAL_INSTALL_MARKER" 2>/dev/null | cut -d= -f2)
    admin_date=$(grep "^date=" "$GLOBAL_INSTALL_MARKER" 2>/dev/null | cut -d= -f2)

    gum style \
        --foreground "$CLR_WARNING" \
        --border normal \
        --border-foreground "$CLR_WARNING" \
        --padding "0 2" \
        --margin "0" \
        "⚠ Global installation already exists" "" \
        "  Configured by: ${admin_user:-unknown}" \
        "  Date:          ${admin_date:-unknown}" "" \
        "  Continuing will overwrite the existing global configuration."

    _gum_confirm "Continue anyway?" && return 0
    return 1
}

# Write a key to /etc/xdg/kdeglobals, tracking new and overwritten keys for clean removal/restore
write_xdg_default() {
    local file="$1" group="$2" key="$3" value="$4"
    local existing
    existing=$(sudo kreadconfig6 --file "$file" --group "$group" --key "$key" 2>/dev/null) || true
    if [[ -z "$existing" ]]; then
        XDG_KEYS_ADDED+=("${group}:${key}")
    else
        XDG_KEYS_OVERWRITTEN+=("${group}:${key}=${existing}")
    fi
    sudo kwriteconfig6 --file "$file" --group "$group" --key "$key" "$value"
}

# Track /etc/skel/.config/ file before copying — only records files gloam creates (not pre-existing)
track_skel_file() {
    local path="$1"
    [[ -f "$path" ]] || SKEL_FILES_CREATED+=("$(basename "$path")")
}

# Track /etc/skel/ directory before copying — only records dirs gloam creates (not pre-existing)
track_skel_dir() {
    local path="$1" relative="$2"
    [[ -d "$path" ]] || SKEL_DIRS_CREATED+=("$relative")
}

# Track Flatpak override before gloam sets it — saves previous value for restore
track_flatpak_override() {
    local var="$1"
    local overrides="${HOME}/.local/share/flatpak/overrides/global"
    local prev=""
    if [[ -f "$overrides" ]]; then
        prev=$(sed -n "s/^${var}=//p" "$overrides" 2>/dev/null) || true
    fi
    FLATPAK_PREV_OVERRIDES+=("${var}=${prev}")
}

# Write global installation marker
write_global_install_marker() {
    [[ "$INSTALL_GLOBAL" != true ]] && return
    local added_keys="" overwritten_keys="" skel_files="" skel_dirs=""
    [[ ${#XDG_KEYS_ADDED[@]} -gt 0 ]] && added_keys=$(IFS=,; echo "${XDG_KEYS_ADDED[*]}")
    [[ ${#XDG_KEYS_OVERWRITTEN[@]} -gt 0 ]] && overwritten_keys=$(IFS=,; echo "${XDG_KEYS_OVERWRITTEN[*]}")
    [[ ${#SKEL_FILES_CREATED[@]} -gt 0 ]] && skel_files=$(IFS=,; echo "${SKEL_FILES_CREATED[*]}")
    [[ ${#SKEL_DIRS_CREATED[@]} -gt 0 ]] && skel_dirs=$(IFS=,; echo "${SKEL_DIRS_CREATED[*]}")
    sudo tee "$GLOBAL_INSTALL_MARKER" > /dev/null <<EOF
user=$USER
date=$(date '+%Y-%m-%d %H:%M')
xdg_keys_added=$added_keys
xdg_keys_overwritten=$overwritten_keys
skel_files_created=$skel_files
skel_dirs_created=$skel_dirs
EOF
}

# Global installation prompts
ask_global_install() {
    msg_header "Installation Mode"
    msg_muted "Local install: Components in your home directory only"
    msg_muted "Global install: Components available to all users (requires sudo)"

    if _gum_confirm "Install globally?"; then
        if ! sudo_auth; then
            error "Sudo authentication failed."
            if ! _gum_confirm --default=yes "Continue with local installation?"; then
                exit 1
            fi
            msg_ok "Local install"
            return
        fi

        # Check for existing global installation
        if ! check_existing_global_install; then
            msg_muted "Falling back to local installation."
            msg_ok "Local install"
            return
        fi

        INSTALL_GLOBAL=true
        msg_ok "Global install"

        # Ask about applying settings to other users
        ask_apply_to_users
    else
        msg_ok "Local install"
    fi
}

ask_apply_to_users() {
    # Find real users (UID 1000-60000, has home dir under /home, not current user)
    local users=()
    while IFS=: read -r username _ uid _ _ home _; do
        [[ "$uid" -ge 1000 && "$uid" -lt 60000 && "$home" == /home/* && -d "$home" && "$username" != "$USER" ]] && users+=("$username:$home")
    done < /etc/passwd

    local has_other_users=false
    [[ ${#users[@]} -gt 0 ]] && has_other_users=true

    msg_header "Apply to Other Users"
    msg_muted "Your configuration can be applied to other users on this system."

    if [[ "$has_other_users" == true ]]; then
        local choice
        choice=$(_gum_choose --header "Apply settings to other users?" \
            "Both existing and new users" \
            "Existing users only" \
            "New users only (set as system defaults)" \
            "Neither")
        case "$choice" in
            "Existing users only")
                SELECTED_USERS=("${users[@]}")
                PUSH_TO_USERS=true
                msg_ok "Existing users only"
                ;;
            "New users only (set as system defaults)")
                SET_SYSTEM_DEFAULTS=true
                msg_ok "New users only"
                ;;
            "Both existing and new users")
                SELECTED_USERS=("${users[@]}")
                PUSH_TO_USERS=true
                SET_SYSTEM_DEFAULTS=true
                msg_ok "Both existing and new users"
                ;;
            *)
                msg_ok "Neither"
                return
                ;;
        esac
    else
        if _gum_confirm "Set as system defaults for new users?"; then
            SET_SYSTEM_DEFAULTS=true
            msg_ok "New users only"
        else
            msg_ok "Neither"
            return
        fi
    fi

    # Ask about copying desktop settings
    msg_header "Copy Desktop Settings"
    msg_muted "Also copy the following settings:" \
        "  - Panel layout, positions and widgets (plasmoids)" \
        "  - Mouse and touchpad settings" \
        "  - Window manager effects and tiling" \
        "  - Keyboard shortcuts" \
        "  - Desktop and lock screen wallpapers" \
        "  - App settings (Dolphin, Konsole profiles, KRunner)"
    if _gum_confirm "Copy desktop settings?"; then
        COPY_DESKTOP_LAYOUT=true
        msg_ok "Copy desktop settings"
    else
        msg_ok "Skip desktop settings"
    fi
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

# Install bundled assets (icons, cursors, wallpapers) from custom theme dirs to system-wide locations
install_bundled_assets_system_wide() {
    local theme_dir_light="${THEME_INSTALL_DIR:-}/org.kde.custom.light"

    # Install bundled icons and cursors to /usr/share/icons/
    for asset_type in icons cursors; do
        for _theme_dir in "$theme_dir_light" "${THEME_INSTALL_DIR:-}/org.kde.custom.dark"; do
            [[ -d "${_theme_dir}/contents/${asset_type}" ]] || continue
            for asset_dir in "${_theme_dir}/contents/${asset_type}"/*/; do
                [[ -d "$asset_dir" ]] || continue
                local asset_name
                asset_name="$(basename "$asset_dir")"
                [[ -d "/usr/share/icons/${asset_name}" ]] || sudo cp -r "$asset_dir" "/usr/share/icons/${asset_name}"
            done
        done
    done

    # Install bundled wallpapers to /usr/share/wallpapers/
    if [[ -d "${theme_dir_light}/contents/wallpapers" ]]; then
        for pack_dir in "${theme_dir_light}/contents/wallpapers"/gloam*/; do
            [[ -d "$pack_dir" ]] || continue
            local pack_name
            pack_name="$(basename "$pack_dir")"
            [[ -d "/usr/share/wallpapers/${pack_name}" ]] || sudo cp -r "$pack_dir" "/usr/share/wallpapers/${pack_name}"
        done
    fi

    # Fallback: install icon/cursor themes directly from local dirs (no custom theme)
    install_icons_system_wide

    # Set system-wide default desktop wallpaper via Plasma plugin config
    if [[ "${WALLPAPER:-}" == true && -d "/usr/share/wallpapers/gloam" ]]; then
        local wp_main_xml="/usr/share/plasma/wallpapers/org.kde.image/contents/config/main.xml"
        if [[ -f "$wp_main_xml" ]]; then
            sudo sed -i '/<entry name="Image"/,/<\/entry>/ s|<default>[^<]*</default>|<default>file:///usr/share/wallpapers/gloam</default>|' "$wp_main_xml" 2>/dev/null || true
        fi
    fi
}

push_config_to_users() {
    [[ "$PUSH_TO_USERS" != true ]] && return
    [[ ${#SELECTED_USERS[@]} -eq 0 ]] && return

    local service_file
    service_file="$(get_service_file)"

    for entry in "${SELECTED_USERS[@]}"; do
        local username="${entry%%:*}"
        local homedir="${entry#*:}"
        local target_config="${homedir}/.config/gloam.conf"
        local target_service_dir="${homedir}/.config/systemd/user"
        local target_service="${target_service_dir}/${SERVICE_NAME}.service"

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
                sudo sed -i 's|Image=file://.*/wallpapers/gloam|Image=file:///usr/share/wallpapers/gloam|g' \
                    "${homedir}/.config/plasma-org.kde.plasma.desktop-appletsrc"
                sudo chown "$username:" "${homedir}/.config/plasma-org.kde.plasma.desktop-appletsrc"
            fi

            # UX config files (panels, input, window manager, shortcuts, apps, font rendering)
            for cfg in "${UX_CONFIGS[@]}"; do
                [[ -f "${HOME}/.config/${cfg}" ]] || continue
                sudo cp "${HOME}/.config/${cfg}" "${homedir}/.config/${cfg}"
                sudo chown "$username:" "${homedir}/.config/${cfg}"
            done

            # Copy font settings from kdeglobals
            for entry in "${FONT_KEYS[@]}"; do
                local group="${entry%%:*}" key="${entry#*:}" val
                val=$(kreadconfig6 --file kdeglobals --group "$group" --key "$key" 2>/dev/null) || continue
                [[ -n "$val" ]] && sudo -u "$username" kwriteconfig6 --file "${homedir}/.config/kdeglobals" \
                    --group "$group" --key "$key" "$val" 2>/dev/null || true
            done

            # Rewrite gloam wallpaper paths in lock screen config
            if [[ -f "${homedir}/.config/kscreenlockerrc" ]]; then
                sudo sed -i 's|Image=file://.*/wallpapers/gloam|Image=file:///usr/share/wallpapers/gloam|g' \
                    "${homedir}/.config/kscreenlockerrc"
            fi

            # Set lockscreen wallpaper if not already a gloam wallpaper
            if [[ "${WALLPAPER:-}" == true ]] && ! grep -q 'wallpapers/gloam' "${homedir}/.config/kscreenlockerrc" 2>/dev/null; then
                sudo -u "$username" kwriteconfig6 --file "${homedir}/.config/kscreenlockerrc" \
                    --group Greeter --group Wallpaper --group org.kde.image --group General \
                    --key Image "file:///usr/share/wallpapers/gloam" 2>/dev/null || true
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
            if ! sudo grep -q 'wallpapers/gloam' "${homedir}/.config/kscreenlockerrc" 2>/dev/null; then
                sudo -u "$username" kwriteconfig6 --file "${homedir}/.config/kscreenlockerrc" \
                    --group Greeter --group Wallpaper --group org.kde.image --group General \
                    --key Image "file:///usr/share/wallpapers/gloam" 2>/dev/null || true
            fi
        fi

        # Register keyboard shortcut for this user
        sudo -u "$username" kwriteconfig6 --file "${homedir}/.config/kglobalshortcutsrc" \
            --group services --group "$SHORTCUT_ID" --key "_launch" "Meta+Shift+L" 2>/dev/null || true

        # Install systemd service for this user (if not using global service dir)
        if [[ "$INSTALL_GLOBAL" != true ]]; then
            sudo mkdir -p "$target_service_dir"
            sudo cp "$service_file" "$target_service"
            sudo chown -R "$username:" "$target_service_dir"
        fi

        # Enable service for user (will take effect on their next login)
        sudo -u "$username" systemctl --user daemon-reload 2>/dev/null || warn "Failed to daemon-reload for user: $username (not logged in?)"
        sudo -u "$username" systemctl --user enable "$SERVICE_NAME" 2>/dev/null || warn "Failed to enable service for user: $username (not logged in?)"

    done
    msg_ok "Pushed configuration to selected users"

    install_bundled_assets_system_wide

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

    apply_sddm_for_current_mode
}

set_system_defaults() {
    [[ "$SET_SYSTEM_DEFAULTS" != true ]] && return

    _spinner_start "Setting system defaults for new users..."

    # Set default light/dark themes in /etc/xdg/kdeglobals
    local xdg_globals="/etc/xdg/kdeglobals"
    sudo mkdir -p /etc/xdg
    write_xdg_default "$xdg_globals" KDE DefaultLightLookAndFeel "${LAF_LIGHT:-}"
    write_xdg_default "$xdg_globals" KDE DefaultDarkLookAndFeel "${LAF_DARK:-}"
    write_xdg_default "$xdg_globals" KDE AutomaticLookAndFeel true

    # Copy gloam config to /etc/skel so new users get it
    sudo mkdir -p /etc/skel/.config
    track_skel_file /etc/skel/.config/gloam.conf
    sudo cp "$CONFIG_FILE" /etc/skel/.config/gloam.conf

    # Copy desktop settings if requested
    if [[ "${COPY_DESKTOP_LAYOUT:-}" == true ]]; then
        # Panel applet layout (with wallpaper path rewrite)
        local panel_config="${HOME}/.config/plasma-org.kde.plasma.desktop-appletsrc"
        if [[ -f "$panel_config" ]]; then
            track_skel_file /etc/skel/.config/plasma-org.kde.plasma.desktop-appletsrc
            sudo cp "$panel_config" /etc/skel/.config/plasma-org.kde.plasma.desktop-appletsrc
            sudo sed -i 's|Image=file://.*/wallpapers/gloam|Image=file:///usr/share/wallpapers/gloam|g' \
                /etc/skel/.config/plasma-org.kde.plasma.desktop-appletsrc
        fi

        for cfg in "${UX_CONFIGS[@]}"; do
            [[ -f "${HOME}/.config/${cfg}" ]] || continue
            track_skel_file "/etc/skel/.config/${cfg}"
            sudo cp "${HOME}/.config/${cfg}" "/etc/skel/.config/${cfg}"
        done

        # Copy font settings to system-wide kdeglobals defaults
        for entry in "${FONT_KEYS[@]}"; do
            local group="${entry%%:*}" key="${entry#*:}" val
            val=$(kreadconfig6 --file kdeglobals --group "$group" --key "$key" 2>/dev/null) || continue
            [[ -n "$val" ]] && write_xdg_default "$xdg_globals" "$group" "$key" "$val"
        done

        # Rewrite gloam wallpaper paths in lock screen config
        if [[ -f /etc/skel/.config/kscreenlockerrc ]]; then
            sudo sed -i 's|Image=file://.*/wallpapers/gloam|Image=file:///usr/share/wallpapers/gloam|g' \
                /etc/skel/.config/kscreenlockerrc
        fi

        # Set lockscreen wallpaper if not already a gloam wallpaper
        if [[ "${WALLPAPER:-}" == true ]] && ! grep -q 'wallpapers/gloam' /etc/skel/.config/kscreenlockerrc 2>/dev/null; then
            sudo kwriteconfig6 --file /etc/skel/.config/kscreenlockerrc \
                --group Greeter --group Wallpaper --group org.kde.image --group General \
                --key Image "file:///usr/share/wallpapers/gloam"
        fi

        # Konsole profiles (color schemes and profiles)
        local konsole_dir="${HOME}/.local/share/konsole"
        if [[ -d "$konsole_dir" ]] && [[ -n "$(ls -A "$konsole_dir" 2>/dev/null)" ]]; then
            track_skel_dir /etc/skel/.local/share/konsole konsole
            sudo mkdir -p /etc/skel/.local/share/konsole
            sudo cp -r "$konsole_dir"/* /etc/skel/.local/share/konsole/
        fi

        # Custom plasmoids so panel widgets work
        local plasmoids_dir="${HOME}/.local/share/plasma/plasmoids"
        if [[ -d "$plasmoids_dir" ]] && [[ -n "$(ls -A "$plasmoids_dir" 2>/dev/null)" ]]; then
            track_skel_dir /etc/skel/.local/share/plasma/plasmoids plasma/plasmoids
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

    install_bundled_assets_system_wide

    # Set keyboard shortcut in /etc/xdg/kglobalshortcutsrc
    sudo kwriteconfig6 --file /etc/xdg/kglobalshortcutsrc --group "services" --group "$SHORTCUT_ID" --key "_launch" "Meta+Shift+L"

    _spinner_stop
    msg_ok "System defaults configured for new users."
}

read_json_name() {
    local file="$1"
    # Extract the KPlugin "Name" — use tail -1 because Authors "Name" entries come first
    sed -n 's/.*"Name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$file" 2>/dev/null | tail -1
}

get_friendly_name() {
    local type="$1"
    local id="$2"
    [[ -z "$id" ]] && return 0

    case "$type" in
        laf)
            for dir in /usr/share/plasma/look-and-feel "${HOME}/.local/share/plasma/look-and-feel"; do
                if [[ -f "${dir}/${id}/metadata.json" ]]; then
                    local name; name=$(read_json_name "${dir}/${id}/metadata.json")
                    [[ -n "$name" ]] && echo "$name" && return 0
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
                    if [[ -f "${dir}/${id}/metadata.json" ]]; then
                        local name; name=$(read_json_name "${dir}/${id}/metadata.json")
                        [[ -n "$name" ]] && echo "$name" && return 0
                    fi
                done
                echo "${id#kwin4_decoration_qml_}" && return 0
            fi
            # Simple names like "Breeze", "Oxygen" - return as-is
            ;;
        splash)
            [[ "$id" == "None" ]] && echo "None" && return 0
            for dir in /usr/share/plasma/look-and-feel "${HOME}/.local/share/plasma/look-and-feel"; do
                if [[ -f "${dir}/${id}/metadata.json" ]]; then
                    local name; name=$(read_json_name "${dir}/${id}/metadata.json")
                    [[ -n "$name" ]] && echo "$name" && return 0
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
    msg_header "Global Themes"
    warn "Make sure your Light and Dark themes are set to your preferred themes."
    msg_muted "You can set them in: System Settings > Quick Settings"
}

# --- THEME SCANNING -----------------------------------------------------------

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

select_themes() {
    local prompt_msg="$1" scan_cmd="$2" var_prefix="$3" opts="${4:-}" callback="${5:-}"

    _gum_confirm "$prompt_msg" || return 1

    local items=() ids=()
    if [[ "$opts" == *"id_name"* ]]; then
        while IFS='|' read -r id name; do
            [[ -n "$id" ]] || continue
            ids+=("$id")
            items+=("$name")
        done < <($scan_cmd)
    else
        mapfile -t items < <($scan_cmd)
        ids=("${items[@]}")
    fi

    if [[ ${#items[@]} -eq 0 ]]; then
        msg_muted "None found, skipping."
        return 1
    fi

    local display_items=()
    [[ "$opts" == *"has_none"* ]] && display_items+=("None (Disable)")
    display_items+=("${items[@]}")

    local gum_select=_gum_choose
    (( ${#display_items[@]} > 10 )) && gum_select=_gum_filter

    local light_choice dark_choice
    light_choice=$(printf '%s\n' "${display_items[@]}" | "$gum_select" --header "Select ☀️ LIGHT mode") || return 1
    dark_choice=$(printf '%s\n' "${display_items[@]}" | "$gum_select" --header "Select 🌙 DARK mode") || return 1

    local light_val="" dark_val=""
    local _is_light=true
    for choice in "$light_choice" "$dark_choice"; do
        local val="$choice"
        if [[ "$choice" == "None (Disable)" ]]; then
            val="None"
        else
            for i in "${!items[@]}"; do
                [[ "${items[$i]}" == "$choice" ]] && val="${ids[$i]}" && break
            done
        fi
        if [[ "$_is_light" == true ]]; then
            light_val="$val"
            _is_light=false
        else
            dark_val="$val"
        fi
    done

    local label
    label=$(echo "$prompt_msg" | sed -n 's/Configure \([^?]*\)?.*/\1/p')
    [[ -n "$label" ]] && label="${label^}" || label="Selection"
    msg_muted "$label"
    echo "  ☀️ $(gum style --bold --foreground "$CLR_PRIMARY" "$light_choice")"
    echo "  🌙 $(gum style --bold --foreground "$CLR_PRIMARY" "$dark_choice")"

    printf -v "${var_prefix}_LIGHT" '%s' "$light_val"
    printf -v "${var_prefix}_DARK" '%s' "$dark_val"
    [[ -n "$callback" ]] && $callback
    echo ""
    return 0
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

find_largest_image() {
    local dir="$1"
    local best_img="" best_pixels=0
    for img in "${dir}/"*; do
        [[ -f "$img" ]] || continue
        local dims
        dims=$(get_image_dimensions "$img")
        [[ -z "$dims" ]] && continue
        local w h
        w="${dims%x*}"; h="${dims#*x}"
        if (( w * h > best_pixels )); then
            best_pixels=$(( w * h ))
            best_img="$img"
        fi
    done
    echo "$best_img"
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

# --- ASSET MANAGEMENT ---------------------------------------------------------

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

    # _wp_run: run with sudo if global, otherwise directly
    _wp_run() { if [[ "$_global" == true ]]; then sudo "$@"; else "$@"; fi; }

    # Clean and create directory structure
    _wp_run rm -rf "$wallpaper_dir"
    _wp_run mkdir -p "${wallpaper_dir}/contents/images"

    # Copy light images
    for img in "${_light_imgs[@]}"; do
        [[ -f "$img" ]] || continue
        local dims ext
        dims=$(get_image_dimensions "$img")
        [[ -z "$dims" ]] && continue
        ext="${img##*.}"
        _wp_run cp "$img" "${wallpaper_dir}/contents/images/${dims}.${ext,,}"
    done

    # Copy dark images (if any)
    if [[ ${#_dark_imgs[@]} -gt 0 ]]; then
        _wp_run mkdir -p "${wallpaper_dir}/contents/images_dark"
        for img in "${_dark_imgs[@]}"; do
            [[ -f "$img" ]] || continue
            local dims ext
            dims=$(get_image_dimensions "$img")
            [[ -z "$dims" ]] && continue
            ext="${img##*.}"
            _wp_run cp "$img" "${wallpaper_dir}/contents/images_dark/${dims}.${ext,,}"
        done
    fi

    # Generate metadata.json
    local metadata
    metadata=$(cat <<METADATA
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
)
    if [[ "$_global" == true ]]; then
        echo "$metadata" | sudo tee "${wallpaper_dir}/metadata.json" > /dev/null
    else
        echo "$metadata" > "${wallpaper_dir}/metadata.json"
    fi

    _spinner_print "$(msg_ok "Created: ${display_name} — ${wallpaper_dir}/")"
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

# --- EXTRAS (WIDGET/SHORTCUT) -------------------------------------------------

install_plasmoid() {
    local script_dir
    script_dir="$(dirname "$(readlink -f "$0")")"
    local plasmoid_src="${script_dir}/plasmoid"

    if [[ ! -d "$plasmoid_src" ]]; then
        error "Plasmoid source not found at $plasmoid_src. Reinstall gloam or run from the project directory."
        return 1
    fi

    local kp_args=(-t Plasma/Applet)
    [[ "$INSTALL_GLOBAL" == true ]] && kp_args+=(--global)

    # Upgrade if already installed, otherwise install fresh
    if kpackagetool6 "${kp_args[@]}" --show "$PLASMOID_ID" &>/dev/null; then
        gloam_cmd kpackagetool6 "${kp_args[@]}" --upgrade "$plasmoid_src" >/dev/null 2>&1
    else
        gloam_cmd kpackagetool6 "${kp_args[@]}" --install "$plasmoid_src" >/dev/null 2>&1
    fi

    NEEDS_LOGOUT=true
    msg_ok "Installed Light/Dark Mode Toggle widget."
    msg_muted "You can add it to your panel by right-clicking the panel > Add Widgets > Light/Dark Mode Toggle"
}

remove_plasmoid() {
    local kp_args=(-t Plasma/Applet)
    local removed=false

    # Try removing local install
    if kpackagetool6 "${kp_args[@]}" --show "$PLASMOID_ID" &>/dev/null; then
        kpackagetool6 "${kp_args[@]}" --remove "$PLASMOID_ID" &>/dev/null
        removed=true
    fi

    # Try removing global install
    if kpackagetool6 "${kp_args[@]}" --global --show "$PLASMOID_ID" &>/dev/null; then
        sudo kpackagetool6 "${kp_args[@]}" --global --remove "$PLASMOID_ID" &>/dev/null
        removed=true
    fi
    [[ "$removed" == true ]]
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

    gloam_cmd mkdir -p "$(dirname "$desktop_file")"
    if [[ "$INSTALL_GLOBAL" == true ]]; then
        echo "$desktop_content" | sudo tee "$desktop_file" > /dev/null
    else
        echo "$desktop_content" > "$desktop_file"
    fi

    # Register the shortcut with KDE (Meta+Shift+L) - always per-user
    kwriteconfig6 --file kglobalshortcutsrc --group "services" --group "$SHORTCUT_ID" --key "_launch" "Meta+Shift+L"

    NEEDS_LOGOUT=true
    msg_ok "Keyboard shortcut installed: Meta+Shift+L"
    msg_muted "You can change it in System Settings > Shortcuts > Commands"
}

remove_shortcut() {
    local local_file="${HOME}/.local/share/applications/gloam-toggle.desktop"
    local global_file="/usr/share/applications/gloam-toggle.desktop"
    local removed=false

    [[ -f "$local_file" ]] && { rm -f "$local_file"; removed=true; }
    [[ -f "$global_file" ]] && { sudo rm -f "$global_file"; removed=true; }

    # Remove from kglobalshortcutsrc (per-user) only if we actually had the shortcut installed
    if [[ "$removed" == true ]] && grep -q "$SHORTCUT_ID" "${HOME}/.config/kglobalshortcutsrc" 2>/dev/null; then
        kwriteconfig6 --file kglobalshortcutsrc --group "services" --group "$SHORTCUT_ID" --key "_launch" --delete
    fi
    [[ "$removed" == true ]]
}

# --- SYSTEMD & SERVICE --------------------------------------------------------

cleanup_stale() {
    local dirty=0
    local local_service="${HOME}/.config/systemd/user/${SERVICE_NAME}.service"

    if systemctl --user is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        systemctl --user stop "$SERVICE_NAME" >/dev/null 2>&1
        dirty=1
    fi
    if systemctl --user is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then
        systemctl --user disable "$SERVICE_NAME" >/dev/null 2>&1
        dirty=1
    fi
    [[ -f "$local_service" ]] && rm "$local_service" && dirty=1
    [[ -f "$CONFIG_FILE" ]] && rm "$CONFIG_FILE" && dirty=1
    if [[ "$dirty" -eq 1 ]]; then
        systemctl --user daemon-reload
    fi
}

check_desktop_environment() {
    if [[ "$XDG_CURRENT_DESKTOP" != *"KDE"* ]]; then
        die "KDE Plasma desktop environment is required. Detected: ${XDG_CURRENT_DESKTOP:-unknown}"
    fi
}

detect_pkg_manager() {
    if command -v pacman &>/dev/null; then
        echo "pacman"
    elif command -v apt &>/dev/null; then
        echo "apt"
    elif command -v dnf &>/dev/null; then
        echo "dnf"
    elif command -v zypper &>/dev/null; then
        echo "zypper"
    else
        echo ""
    fi
}

# Map a command/package name to the distro-specific package name
# Usage: get_pkg_name <package> <pkg_manager>
get_pkg_name() {
    local pkg="$1" mgr="$2"
    case "$pkg" in
        gum)
            echo "gum" ;;
        cmake)
            echo "cmake" ;;
        make)
            case "$mgr" in
                apt)    echo "build-essential" ;;
                dnf)    echo "make" ;;
                zypper) echo "make" ;;
                *)      echo "make" ;;
            esac ;;
        patch)
            echo "patch" ;;
        nm)
            echo "binutils" ;;
        *)
            echo "$pkg" ;;
    esac
}

install_packages() {
    local mgr="$1"
    shift
    local pkgs=("$@")

    case "$mgr" in
        pacman) sudo pacman -S --noconfirm "${pkgs[@]}" ;;
        apt)    sudo apt install -y "${pkgs[@]}" ;;
        dnf)    sudo dnf install -y "${pkgs[@]}" ;;
        zypper) sudo zypper install -y "${pkgs[@]}" ;;
    esac
}

check_dependencies() {
    # This runs before gum is available — use only plain bash + ANSI codes

    # KDE dependencies — required, no offer to install
    local kde_missing=()
    command -v kreadconfig6 &>/dev/null || kde_missing+=("kreadconfig6")
    command -v kwriteconfig6 &>/dev/null || kde_missing+=("kwriteconfig6")

    if [[ ${#kde_missing[@]} -gt 0 ]]; then
        echo -e "${RED}${BOLD}Missing KDE dependencies:${RESET}"
        printf '  - %s\n' "${kde_missing[@]}"
        echo -e "Please install the KDE Frameworks packages for your distribution."
        exit 1
    fi

    # Non-KDE dependencies — offer to install
    # Format: "command:package-name"
    local deps=("gum:gum" "cmake:cmake" "make:make" "patch:patch" "git:git" "curl:curl" "nm:nm")
    local missing_cmds=()
    local missing_pkgs=()

    for entry in "${deps[@]}"; do
        local cmd="${entry%%:*}"
        local pkg="${entry##*:}"
        if ! command -v "$cmd" &>/dev/null; then
            missing_cmds+=("$cmd")
            missing_pkgs+=("$pkg")
        fi
    done

    [[ ${#missing_pkgs[@]} -eq 0 ]] && return 0

    echo -e "${YELLOW}${BOLD}Missing dependencies:${RESET}"
    for i in "${!missing_cmds[@]}"; do
        echo -e "  ${YELLOW}•${RESET} ${missing_cmds[$i]} (${missing_pkgs[$i]})"
    done

    local mgr
    mgr=$(detect_pkg_manager)

    if [[ -z "$mgr" ]]; then
        echo -e "${RED}Could not detect a supported package manager. Please install manually: ${missing_pkgs[*]}${RESET}"
        exit 1
    fi

    # Resolve distro-specific package names
    local resolved_pkgs=()
    for pkg in "${missing_pkgs[@]}"; do
        resolved_pkgs+=("$(get_pkg_name "$pkg" "$mgr")")
    done

    echo ""
    read -rp "Install with $mgr? [Y/n] " answer
    case "${answer:-Y}" in
        [Yy]|[Yy]es|"") ;;
        *)
            echo -e "${RED}Missing dependencies: ${missing_pkgs[*]}${RESET}"
            exit 1
            ;;
    esac

    install_packages "$mgr" "${resolved_pkgs[@]}" || { echo -e "${RED}Failed to install dependencies: ${resolved_pkgs[*]}${RESET}"; exit 1; }
    echo -e "${GREEN}${BOLD}Dependencies installed.${RESET}"
}

# --- PATCH MANAGEMENT ---------------------------------------------------------
#
# gloam ships a source patch for Plasma that fixes an issue with live theme
# switching. It is treated as a soft dependency — gloam works without it but
# the experience is degraded.
#
# plasma-integration (forceRefresh)
#    Qt apps (Dolphin, Kate, Gwenview, etc.) don't refresh their palette when
#    the colour scheme changes at runtime. This patch adds a DBus signal
#    handler (org.kde.KGlobalSettings.forceRefresh) that forces an immediate
#    style + palette reload in every running Qt app.

# Detect if the plasma-integration forceRefresh patch is installed
is_patch_plasma_integration_installed() {
    command -v nm &>/dev/null || return 1
    local so_file output
    for so_file in /usr/lib/qt6/plugins/platformthemes/KDEPlasmaPlatformTheme6.so \
                   /usr/lib64/qt6/plugins/platformthemes/KDEPlasmaPlatformTheme6.so; do
        if [[ -f "$so_file" ]]; then
            output=$(nm -C "$so_file" 2>/dev/null) && [[ "$output" == *"forceStyleRefresh"* ]] && return 0
        fi
    done
    return 1
}


# Find plasma-integration platformtheme plugin
_get_plasma_integration_so() {
    for candidate in /usr/lib/qt6/plugins/platformthemes/KDEPlasmaPlatformTheme6.so \
                     /usr/lib64/qt6/plugins/platformthemes/KDEPlasmaPlatformTheme6.so; do
        [[ -f "$candidate" ]] && echo "$candidate" && return 0
    done
    return 1
}

install_patch_plasma_integration() {
    local patches_dir
    patches_dir=$(get_patches_dir) || {
        fetch_patches_if_missing || { error "Could not fetch patches. Run from source directory or check network."; return 1; }
        patches_dir=$(get_patches_dir)
    }
    local patch_file="${patches_dir}/plasma-integration-force-refresh.patch"
    local src_dir="${PATCH_BUILD_DIR}/plasma-integration"

    [[ -f "$patch_file" ]] || { error "Patch file not found: $patch_file"; return 1; }

    local original_so
    original_so=$(_get_plasma_integration_so) || { error "Could not find plasma-integration plugin."; return 1; }

    _spinner_start "Building plasma-integration with forceRefresh patch (~ 4 mins)..."
    rm -rf "$src_dir"
    mkdir -p "$(dirname "$src_dir")"
    if ! git clone --depth 1 https://invent.kde.org/plasma/plasma-integration.git "$src_dir" 2>/dev/null; then
        _spinner_stop
        error "Failed to clone plasma-integration repository."
        return 1
    fi

    (
        cd "$src_dir" || exit 1
        patch -p1 < "$patch_file" >/dev/null 2>&1 || exit 4
        mkdir -p build && cd build || exit 1
        cmake .. -DCMAKE_INSTALL_PREFIX=/usr -DBUILD_QT5=OFF -DBUILD_QT6=ON >/dev/null 2>&1 || exit 2
        make -j"$(nproc)" >/dev/null 2>&1 || exit 3
    )
    local build_rc=$?
    if [[ $build_rc -ne 0 ]]; then
        _spinner_stop
        case $build_rc in
            4) error "Patch failed to apply. Upstream may have changed." ;;
            2) error "CMake configure failed. You may need to install build dependencies for plasma-integration." ;;
            *) error "Build failed for plasma-integration." ;;
        esac
        return 1
    fi

    _spinner_stop

    local built_so
    built_so=$(find "${src_dir}/build" -name "KDEPlasmaPlatformTheme6.so" 2>/dev/null | head -1)
    if [[ -z "$built_so" ]]; then
        error "Build produced no output."
        return 1
    fi

    if pgrep -x plasmashell &>/dev/null; then
        # KDE is running — stage for install on next session start
        if [[ ! -x /usr/local/lib/gloam/install-staged-patch ]]; then
            setup_patch_sudoers
        fi
        cp "$built_so" "$PATCH_STAGED_SO"
        msg_ok "plasma-integration patch built and staged."
        msg_muted "It will be installed on next login (before KDE starts)."
    else
        # KDE not running — install directly
        if [[ ! -f "${original_so}.gloam-orig" ]] || ! is_patch_plasma_integration_installed; then
            sudo cp "$original_so" "${original_so}.gloam-orig"
        fi
        msg_info "Installing plasma-integration (requires sudo)..."
        sudo cp "$built_so" "${original_so}.tmp"
        sudo mv "${original_so}.tmp" "$original_so"
        msg_ok "plasma-integration forceRefresh patch installed."
    fi
}

install_staged_patches() {
    [[ -f "$PATCH_STAGED_SO" ]] || return 0
    if [[ ! -x /usr/local/lib/gloam/install-staged-patch ]]; then
        log "Staged patch found but helper not installed. Skipping."
        return 1
    fi
    sudo /usr/local/lib/gloam/install-staged-patch "$PATCH_STAGED_SO" || {
        log "Failed to install staged patch."
        return 1
    }
    rm -f "$PATCH_STAGED_SO"
    log "Staged plasma-integration patch installed."
}

setup_patch_sudoers() {
    sudo mkdir -p /usr/local/lib/gloam
    sudo tee /usr/local/lib/gloam/install-staged-patch > /dev/null <<'SCRIPT'
#!/bin/bash
# Install a staged plasma-integration .so, called by gloam service on startup.
set -euo pipefail
staged="$1"
[[ -f "$staged" ]] || exit 1
for so in /usr/lib/qt6/plugins/platformthemes/KDEPlasmaPlatformTheme6.so \
          /usr/lib64/qt6/plugins/platformthemes/KDEPlasmaPlatformTheme6.so; do
    [[ -f "$so" ]] || continue
    # Back up original if no backup exists or if current .so lacks the patch
    if [[ ! -f "${so}.gloam-orig" ]] || ! nm -C "$so" 2>/dev/null | grep -q forceStyleRefresh; then
        cp "$so" "${so}.gloam-orig"
    fi
    cp "$staged" "${so}.tmp"
    mv "${so}.tmp" "$so"
    exit 0
done
exit 1
SCRIPT
    sudo chmod 755 /usr/local/lib/gloam/install-staged-patch
    echo "ALL ALL=(ALL) NOPASSWD: /usr/local/lib/gloam/install-staged-patch" | \
        sudo tee /etc/sudoers.d/gloam-patch > /dev/null
    sudo chmod 440 /etc/sudoers.d/gloam-patch
}


remove_patches() {
    local removed_count=0

    # Remove plasma-integration patch (restore backup)
    local integration_so
    integration_so=$(_get_plasma_integration_so) || integration_so=""
    if [[ -n "$integration_so" && -f "${integration_so}.gloam-orig" ]]; then
        sudo mv "${integration_so}.gloam-orig" "$integration_so"
        (( removed_count++ )) || true
    elif is_patch_plasma_integration_installed; then
        warn "plasma-integration patch is installed but no backup found. Reinstall plasma-integration to restore the original."
    fi

    # Clean up orphaned backup files (e.g. leftover after system update replaced the .so)
    local _bak
    for _bak in /usr/lib{,64}/qt6/plugins/platformthemes/KDEPlasmaPlatformTheme6.so.gloam-orig; do
        [[ -f "$_bak" ]] && sudo rm "$_bak"
    done

    rm -rf "$PATCH_BUILD_DIR"
    rm -f "$PATCH_STAGED_SO"

    return $(( removed_count == 0 ))
}

check_patches() {
    is_patch_plasma_integration_installed && return 0

    # Import mode: install without prompting
    if [[ -n "${IMPORT_CONFIG:-}" ]]; then
        msg_header "Plasma Patches"
        sudo_auth || die "Sudo required to install patches."
        msg_info "  Patching plasma-integration..."
        install_patch_plasma_integration || warn "plasma-integration patch failed. Continuing."
        deploy_patches_dir
        if [[ -f "$PATCH_STAGED_SO" ]]; then
            msg_ok "Plasma patch staged (will install on next login)."
        else
            msg_ok "Plasma patch installed."
        fi
        NEEDS_LOGOUT=true
        return 0
    fi

    # Interactive mode
    msg_header "Plasma Patches"

    gum style \
        --foreground "$CLR_WARNING" \
        --padding "0 2" \
        "gloam requires a source patch applied to Plasma:"

    echo ""

    gum style --foreground "$CLR_ERROR" "  ✗ plasma-integration — Qt App Theme Refresh"
    msg_muted "    Without this patch, Qt apps (Dolphin, Kate, etc.) must be"
    msg_muted "    restarted to pick up theme changes. The patch adds a DBus"
    msg_muted "    signal handler that forces an immediate style refresh."
    echo ""

    msg_muted "This requires cloning and building plasma-integration from source."
    msg_muted "Note: You'll need to re-run 'gloam configure --patches' after Plasma updates."
    echo ""

    if ! _gum_confirm "Install patch and continue?"; then
        msg_muted "Aborted."
        exit 0
    fi

    sudo_auth || die "Sudo required to install patches."
    install_patch_plasma_integration || warn "plasma-integration patch failed. Continuing."

    deploy_patches_dir

    echo ""
    msg_warn "Plasma updates will overwrite this patch."
    msg_muted "Re-run 'gloam configure --patches' after updating Plasma."
    NEEDS_LOGOUT=true
}

get_laf() {
    kreadconfig6 --file kdeglobals --group KDE --key LookAndFeelPackage
}

reload_laf_config() {
    LAF_LIGHT=$(kreadconfig6 --file kdeglobals --group KDE --key DefaultLightLookAndFeel)
    LAF_DARK=$(kreadconfig6 --file kdeglobals --group KDE --key DefaultDarkLookAndFeel)
    # Silent reload as per request
}

# --- THEME APPLICATION --------------------------------------------------------

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
    track_flatpak_override GTK_THEME
    flatpak override --user --env=GTK_THEME="$theme" 2>/dev/null || true
}

apply_flatpak_icons() {
    local icons="$1"
    command -v flatpak &>/dev/null || return 0
    track_flatpak_override GTK_ICON_THEME
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
    track_flatpak_override QT_STYLE_OVERRIDE
    flatpak override --user --env=QT_STYLE_OVERRIDE=kvantum 2>/dev/null || true
}

apply_gtk_theme() {
    local theme="$1"

    # Update GTK settings (3.0 and 4.0)
    for ver in gtk-3.0 gtk-4.0; do
        mkdir -p "${HOME}/.config/${ver}"
        sed -i "s/^gtk-theme-name=.*/gtk-theme-name=$theme/" "${HOME}/.config/${ver}/settings.ini" 2>/dev/null || \
            echo -e "[Settings]\ngtk-theme-name=$theme" >> "${HOME}/.config/${ver}/settings.ini"
    done
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
        sleep "$DELAY_LAF_PROPAGATE"
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

install_sddm_background_helper() {
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
}

apply_sddm_theme() {
    local theme="$1"
    if [[ -n "$theme" ]]; then
        sleep "$DELAY_LAF_PROPAGATE"
        if [[ -x /usr/local/lib/gloam/set-sddm-theme ]]; then
            sudo /usr/local/lib/gloam/set-sddm-theme "$theme" 2>/dev/null || warn "Failed to apply SDDM theme: $theme"
        else
            sudo kwriteconfig6 --file /etc/sddm.conf.d/kde_settings.conf \
                --group Theme --key Current "$theme" 2>/dev/null || warn "Failed to apply SDDM theme: $theme"
        fi
    fi
}

# Re-apply dynamic wallpapers from the bundled location to desktop and lock screen
reapply_bundled_wallpapers() {
    if [[ "${WALLPAPER:-}" == true && -n "${WALLPAPER_BASE:-}" ]]; then
        apply_desktop_wallpaper "${WALLPAPER_BASE}/gloam"
        apply_lockscreen_wallpaper "${WALLPAPER_BASE}/gloam"
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
            [[ "$wp" == *"/wallpapers/gloam"* ]]
            ;;
        lockscreen)
            local wp
            wp=$(kreadconfig6 --file kscreenlockerrc \
                --group Greeter --group Wallpaper --group org.kde.image --group General \
                --key Image 2>/dev/null)
            [[ "$wp" == *"/wallpapers/gloam"* ]]
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

# Find the SDDM background file for a given variant (light/dark)
find_sddm_bg() {
    local variant="$1"
    { compgen -G "/usr/local/lib/gloam/sddm-bg-${variant}.*" 2>/dev/null || true; } | head -1
}

# Determine current mode variant and apply the matching SDDM wallpaper
apply_sddm_for_current_mode() {
    [[ -x /usr/local/lib/gloam/set-sddm-background ]] || return 0
    local current_laf variant="light"
    current_laf=$(kreadconfig6 --file kdeglobals --group KDE --key LookAndFeelPackage 2>/dev/null)
    # Check if current LAF matches any dark theme variant
    if [[ "$current_laf" == "${LAF_DARK:-}" || "$current_laf" == "${BASE_THEME_DARK:-}" || "$current_laf" == "org.kde.custom.dark" ]]; then
        variant="dark"
    fi
    local bg
    bg=$(find_sddm_bg "$variant")
    [[ -n "$bg" ]] && apply_sddm_wallpaper "$bg" || true
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

    # Pick the largest image from the gloam pack for each variant
    local best_light best_dark
    best_light=$(find_largest_image "${wp_base}/gloam/contents/images")
    best_dark=$(find_largest_image "${wp_base}/gloam/contents/images_dark")

    # Copy images to system-accessible location
    if [[ -n "$best_light" ]]; then
        local ext="${best_light##*.}"
        sudo cp "$best_light" "/usr/local/lib/gloam/sddm-bg-light.${ext,,}"
    fi
    if [[ -n "$best_dark" ]]; then
        local ext="${best_dark##*.}"
        sudo cp "$best_dark" "/usr/local/lib/gloam/sddm-bg-dark.${ext,,}"
    fi

    install_sddm_background_helper
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
# If $1 is "current", only check options being configured in this run
has_bundleable_options() {
    local mode="${1:-}"
    if [[ "$mode" == "current" ]]; then
        [[ "$configure_colors" == true || "$configure_icons" == true || \
           "$configure_cursors" == true || "$configure_style" == true || \
           "$configure_decorations" == true || "$configure_splash" == true || \
           "$configure_login" == true || "$configure_appstyle" == true || \
           "$configure_wallpaper" == true || "$configure_all" == true ]]
    else
        [[ -n "${COLOR_LIGHT:-}" || -n "${COLOR_DARK:-}" || \
           -n "${ICON_LIGHT:-}" || -n "${ICON_DARK:-}" || \
           -n "${CURSOR_LIGHT:-}" || -n "${CURSOR_DARK:-}" || \
           -n "${STYLE_LIGHT:-}" || -n "${STYLE_DARK:-}" || \
           -n "${DECORATION_LIGHT:-}" || -n "${DECORATION_DARK:-}" || \
           -n "${SPLASH_LIGHT:-}" || -n "${SPLASH_DARK:-}" || \
           -n "${SDDM_LIGHT:-}" || -n "${SDDM_DARK:-}" || \
           -n "${APPSTYLE_LIGHT:-}" || -n "${APPSTYLE_DARK:-}" ]]
    fi
}

# Set theme install directory based on installation mode
request_sudo_for_global_install() {
    THEME_INSTALL_DIR="$(get_theme_install_dir)"
    if [[ "$INSTALL_GLOBAL" == true ]]; then
        THEME_INSTALL_GLOBAL=true
    else
        THEME_INSTALL_GLOBAL=false
    fi
    return 0
}

# --- THEME GENERATION & BUNDLING ----------------------------------------------

# Bundle an icon or cursor theme (and its symlink dependencies) into a custom theme directory.
# Args: asset_type ("icons"|"cursors") theme_name theme_dir mode
#   - asset_type: subdirectory name under contents/
#   - theme_name: name of the theme to bundle
#   - theme_dir: the custom theme directory (e.g. .../org.kde.custom.light)
#   - mode: "light" or "dark" (for tracking moved-from location)
# Also uses: THEME_INSTALL_GLOBAL (global var)
bundle_theme_asset() {
    local asset_type="$1" theme_name="$2" theme_dir="$3" mode="$4"
    [[ -z "$theme_name" ]] && return 0

    # For cursors, require a "cursors" subdir to confirm it's a cursor theme
    local match_subdir=""
    [[ "$asset_type" == "cursors" ]] && match_subdir="/cursors"

    # Find the theme source directory
    local src="" src_dir=""
    for dir in /usr/share/icons "${HOME}/.local/share/icons" "${HOME}/.icons"; do
        if [[ -d "${dir}/${theme_name}${match_subdir}" ]]; then
            src="${dir}/${theme_name}"
            src_dir="$dir"
            break
        fi
    done
    [[ -z "$src" ]] && return 0

    # Collect the theme and any sibling themes it symlinks to
    local themes_to_bundle=("$theme_name")
    local link_target
    while IFS= read -r link_target; do
        local dep_name
        dep_name=$(echo "$link_target" | sed -n 's|^\.\./\([^/]*\)/.*|\1|p')
        [[ -z "$dep_name" ]] && continue
        local already=false
        for existing in "${themes_to_bundle[@]}"; do
            [[ "$existing" == "$dep_name" ]] && already=true && break
        done
        [[ "$already" == true ]] && continue
        [[ -d "${src_dir}/${dep_name}" ]] && themes_to_bundle+=("$dep_name")
    done < <(find -L "$src" -maxdepth 1 -type l -printf '%l\n' 2>/dev/null || find "$src" -maxdepth 1 -type l -exec readlink {} \; 2>/dev/null)

    for name in "${themes_to_bundle[@]}"; do
        local src_path="${src_dir}/${name}"
        [[ -d "$src_path" ]] || continue
        theme_cmd mkdir -p "${theme_dir}/contents/${asset_type}"
        theme_cmd cp -r "$src_path" "${theme_dir}/contents/${asset_type}/${name}"
        # Global install: ensure themes are in /usr/share/icons for system-wide access
        if [[ "${THEME_INSTALL_GLOBAL:-false}" == true && "$src_path" != /usr/share/icons/* ]]; then
            sudo cp -r "$src_path" "/usr/share/icons/${name}"
            rm -rf "$src_path"
            # Record original location for restore on uninstall (main theme only)
            if [[ "$name" == "$theme_name" ]]; then
                local moved_var="${asset_type^^}_${mode^^}_MOVED_FROM"
                # ICON -> ICON, CURSORS -> CURSOR (strip trailing S for variable name)
                moved_var="${moved_var/ICONS/ICON}"
                moved_var="${moved_var/CURSORS/CURSOR}"
                printf -v "$moved_var" '%s' "$(dirname "$src_path")"
            fi
        fi
    done

    # Re-apply theme after moving to system location
    if [[ "${THEME_INSTALL_GLOBAL:-false}" == true && "$src" != /usr/share/icons/* ]]; then
        if [[ "$asset_type" == "icons" ]]; then
            "$PLASMA_CHANGEICONS" "$theme_name" >/dev/null 2>&1 || warn "Failed to re-apply icon theme: $theme_name"
        else
            plasma-apply-cursortheme "$theme_name" >/dev/null 2>&1 || warn "Failed to re-apply cursor theme: $theme_name"
        fi
    fi
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
        die "Base theme not found: ${base_theme}\nReinstall the theme or run 'gloam configure' to select a new one."
    fi

    # Remove existing custom theme and copy base theme
    theme_cmd rm -rf "$theme_dir"
    theme_cmd cp -r "$base_theme_dir" "$theme_dir"

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
    author_block=$(awk '/"Authors"/,/\]/' "${base_theme_dir}/metadata.json" 2>/dev/null) || warn "Could not extract author block from ${base_theme_dir}/metadata.json"
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

    if [[ "${THEME_INSTALL_GLOBAL:-false}" == true ]]; then
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

        # Use sudo for awk on global installs (file may be root-owned)
        if [[ "${THEME_INSTALL_GLOBAL:-false}" == true ]]; then
            sudo awk -v section="$section" -v key="$key" -v value="$value" "$awk_script" "$defaults_file" > "$tmpfile"
        else
            awk -v section="$section" -v key="$key" -v value="$value" "$awk_script" "$defaults_file" > "$tmpfile"
        fi
        theme_cmd mv "$tmpfile" "$defaults_file"
        if [[ "${THEME_INSTALL_GLOBAL:-false}" == true ]]; then
            sudo chmod 644 "$defaults_file"
            sudo chown root:root "$defaults_file"
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
            theme_cmd rm -rf "${theme_dir}/contents/splash"
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
            theme_cmd mkdir -p "${theme_dir}/contents/colors"
            theme_cmd cp "$color_src" "${theme_dir}/contents/colors/${color_scheme}.colors"
        fi
    fi

    # Bundle icon and cursor themes (and their symlink dependencies) into theme directory
    bundle_theme_asset "icons" "$icon_theme" "$theme_dir" "$mode"
    bundle_theme_asset "cursors" "$cursor_theme" "$theme_dir" "$mode"

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
            theme_cmd mkdir -p "${theme_dir}/contents/desktoptheme"
            theme_cmd cp -r "$style_src"/* "${theme_dir}/contents/desktoptheme/"
        fi
    fi

    # Export current panel layout via Plasma's serialization API
    local layout_js layout_dir="${theme_dir}/contents/layouts"
    layout_js=$(qdbus6 org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell.dumpCurrentLayoutJS 2>/dev/null) || true
    if [[ -n "$layout_js" ]]; then
        theme_cmd mkdir -p "$layout_dir"
        if [[ "${THEME_INSTALL_GLOBAL:-false}" == true ]]; then
            echo "$layout_js" | sudo tee "${layout_dir}/org.kde.plasma.desktop-layout.js" > /dev/null
        else
            echo "$layout_js" > "${layout_dir}/org.kde.plasma.desktop-layout.js"
        fi
    fi

    _spinner_print "$(msg_ok "Created: ${theme_name} (based on $(basename "$base_theme_dir"))")"
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
            if [[ -d "${candidate}/gloam" ]]; then
                wp_src="$candidate"
                break
            fi
        done

        local has_packs=false
        [[ -n "$wp_src" ]] && has_packs=true

        if [[ "$has_packs" == true ]]; then
            theme_cmd mkdir -p "${theme_dir_light}/contents/wallpapers"
            theme_cmd cp -r "${wp_src}/gloam" "${theme_dir_light}/contents/wallpapers/gloam"
            theme_cmd rm -rf "${wp_src}/gloam"

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
        sddm_bg=$(find_sddm_bg "$variant")

        # If SDDM image doesn't exist, create it from the wallpaper pack
        if [[ -z "$sddm_bg" || ! -f "$sddm_bg" ]] && [[ -n "$sddm_wp_base" ]]; then
            local img_dir="${sddm_wp_base}/gloam/contents/images"
            [[ "$variant" == "dark" ]] && img_dir="${sddm_wp_base}/gloam/contents/images_dark"
            local best_img
            best_img=$(find_largest_image "$img_dir")
            if [[ -n "$best_img" ]]; then
                local ext="${best_img##*.}"
                sudo mkdir -p /usr/local/lib/gloam
                sudo cp "$best_img" "/usr/local/lib/gloam/sddm-bg-${variant}.${ext,,}"
                sddm_bg="/usr/local/lib/gloam/sddm-bg-${variant}.${ext,,}"
            fi
        fi

        [[ -n "$sddm_bg" && -f "$sddm_bg" ]] || continue

        local target_theme_dir="$theme_dir_light"
        [[ "$variant" == "dark" ]] && target_theme_dir="$theme_dir_dark"
        [[ -d "$target_theme_dir" ]] || continue

        theme_cmd mkdir -p "${target_theme_dir}/contents/sddm"
        theme_cmd cp "$sddm_bg" "${target_theme_dir}/contents/sddm/"
    done
}

# Remove custom themes on uninstall
remove_custom_themes() {
    local removed=false
    for theme in org.kde.custom.light org.kde.custom.dark; do
        local local_path="${HOME}/.local/share/plasma/look-and-feel/${theme}"
        local global_path="/usr/share/plasma/look-and-feel/${theme}"

        [[ -d "$local_path" ]] && { rm -rf "$local_path"; removed=true; }
        [[ -d "$global_path" ]] && { sudo rm -rf "$global_path"; removed=true; }
    done
    [[ "$removed" == true ]]
}

remove_wallpaper_packs() {
    local removed=false
    for pack in gloam; do
        local local_path="${HOME}/.local/share/wallpapers/${pack}"
        local global_path="/usr/share/wallpapers/${pack}"
        [[ -d "$local_path" ]] && { rm -rf "$local_path"; removed=true; }
        [[ -d "$global_path" ]] && { sudo rm -rf "$global_path"; removed=true; }
    done
    [[ "$removed" == true ]]
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
    sleep "$DELAY_LAF_SETTLE"

    # Determine which mode we're switching to
    local mode
    if [[ "$laf" == "$LAF_DARK" ]]; then
        mode="dark"
    elif [[ "$laf" == "$LAF_LIGHT" ]]; then
        mode="light"
    else
        log "Unknown LookAndFeel: $laf — skipping"
        return
    fi

    local MODE="${mode^^}"  # DARK or LIGHT

    # Resolve config variables for this mode via indirect references
    local _kvantum="KVANTUM_${MODE}" _gtk="GTK_${MODE}" _icon="ICON_${MODE}"
    local _color="COLOR_${MODE}" _style="STYLE_${MODE}" _decoration="DECORATION_${MODE}"
    local _cursor="CURSOR_${MODE}" _splash="SPLASH_${MODE}" _appstyle="APPSTYLE_${MODE}"
    local _konsole="KONSOLE_${MODE}" _sddm="SDDM_${MODE}" _script="SCRIPT_${MODE}"
    local kvantum="${!_kvantum:-}" gtk="${!_gtk:-}" icon="${!_icon:-}"
    local color="${!_color:-}" style="${!_style:-}" decoration="${!_decoration:-}"
    local cursor="${!_cursor:-}" splash="${!_splash:-}" appstyle="${!_appstyle:-}"
    local konsole="${!_konsole:-}" sddm="${!_sddm:-}" script="${!_script:-}"
    local kvantum_style="kvantum"
    [[ "$mode" == "dark" ]] && kvantum_style="kvantum-dark"

    # Check if we're using custom themes (bundled options handled by theme itself)
    local using_custom_themes=false
    [[ -n "${CUSTOM_THEME_LIGHT:-}" || -n "${CUSTOM_THEME_DARK:-}" ]] && using_custom_themes=true

    # Kvantum - always apply (not bundleable)
    if [[ -n "$kvantum" ]]; then
        mkdir -p "${HOME}/.config/Kvantum"
        kwriteconfig6 --file "${HOME}/.config/Kvantum/kvantum.kvconfig" --group General --key theme "$kvantum"
        refresh_kvantum_style "$kvantum_style"
    fi

    # GTK theme - always apply (not bundleable)
    [[ -n "$gtk" ]] && apply_gtk_theme "$gtk"

    # Flatpak icons - always apply (not bundleable)
    if [[ -n "$gtk" ]]; then
        apply_flatpak_icons "${icon:-$(get_current_icon_theme)}"
    fi

    # These are only applied if NOT using custom themes (they're bundled in custom themes)
    if [[ "$using_custom_themes" == false ]]; then
        [[ -n "$icon" && -n "$PLASMA_CHANGEICONS" ]] && "$PLASMA_CHANGEICONS" "$icon"
        [[ -n "$color" ]] && apply_color_scheme "$color"
        [[ -n "$style" ]] && apply_plasma_style "$style"
        [[ -n "$decoration" ]] && apply_window_decoration "$decoration"
        [[ -n "$cursor" ]] && apply_cursor_theme "$cursor"
        apply_splash "$splash"
        if [[ -n "$appstyle" && -z "$kvantum" ]]; then
            apply_app_style "$appstyle"
        fi
    else
        # Still ensure splash "None" stays disabled (theme sets it, but LookAndFeel may override)
        [[ "$splash" == "None" ]] && apply_splash "None"
    fi

    # Konsole - always apply (not bundleable)
    [[ -n "$konsole" ]] && apply_konsole_profile "$konsole"

    # Login screen (SDDM) - always apply (system-level, not applied by plasma-apply-lookandfeel)
    [[ -n "$sddm" ]] && apply_sddm_theme "$sddm"

    # Wallpapers - switch each surface unless the user has overridden it
    if [[ "${WALLPAPER:-}" == true ]]; then
        local wp_base="${WALLPAPER_BASE:-${HOME}/.local/share/wallpapers}"
        is_gloam_wallpaper desktop && apply_desktop_wallpaper "${wp_base}/gloam"
        is_gloam_wallpaper lockscreen && apply_lockscreen_wallpaper "${wp_base}/gloam"
        # SDDM background - check if gloam images exist on disk (user opted in during configure)
        # Note: can't use is_gloam_wallpaper sddm here because the LookAndFeel's defaults
        # may have switched the SDDM theme, and the new theme won't have a gloam background yet
        local sddm_bg
        sddm_bg=$(find_sddm_bg "$mode")
        [[ -n "$sddm_bg" ]] && apply_sddm_wallpaper "$sddm_bg"
    fi

    # Browser color scheme - skip on initial startup to avoid feedback loop
    # with Plasma's AutomaticLookAndFeel (Plasma sets this via the portal itself)
    [[ "$initial" != true ]] && apply_browser_color_scheme "$mode"

    # Custom script - always apply
    if [[ -n "$script" && -x "$script" ]]; then
        log "Running ${mode} script: $script"
        if "$script" >> "$LOG_FILE" 2>&1; then
            log "${mode^} script completed successfully"
        else
            log "${mode^} script failed with exit code $?"
        fi
    elif [[ -n "$script" && ! -x "$script" ]]; then
        log "${mode^} script not executable: $script"
    fi

    dbus-send --session --type=signal /KGlobalSettings org.kde.KGlobalSettings.forceRefresh 2>/dev/null || warn "dbus forceRefresh signal failed — open apps may not update until restarted"
    log "Switched to ${MODE} mode"
}

do_watch() {
    GLOAM_LOG_MODE="raw"

    if [[ ! -f "$CONFIG_FILE" ]]; then
        die "No config found at $CONFIG_FILE. Run configure first."
    fi
    if ! check_config_valid; then
        warn "Configuration is outdated or incompatible. Please run 'gloam configure' to reconfigure."
    fi
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"

    install_staged_patches

    log "Watcher started"

    # Wait for KNightTime dbus service
    local wait_count=0
    while ! busctl --user status org.kde.NightTime &>/dev/null; do
        if (( wait_count >= 20 )); then
            log "KNightTime dbus not ready after 5s, proceeding anyway"
            break
        fi
        sleep 0.25
        (( wait_count++ ))
    done

    local auto_mode
    auto_mode=$(kreadconfig6 --file kdeglobals --group KDE --key AutomaticLookAndFeel)
    if [[ "$auto_mode" == "true" ]]; then
        local daylight_known=false
        local is_daylight=true
        local subscribe_output
        if subscribe_output=$(busctl --user call org.kde.NightTime /org/kde/NightTime/Manager \
                org.kde.NightTime.Manager Subscribe 'a{sv}' 0 2>/dev/null); then
            # Extract cookie for cleanup
            local cookie
            cookie=$(echo "$subscribe_output" | grep -oP '(?<="Cookie" u )\d+')
            # Extract schedule timestamps: each cycle is (noon, morning-start, morning-end, evening-start, evening-end) in ms
            local now_ms
            now_ms=$(date +%s%3N)
            # Strip everything up to the timestamp array
            local -a timestamps
            read -ra timestamps <<< "$(echo "$subscribe_output" | sed 's/.*a(xxxxx) [0-9]* //')"
            # Match Plasma's autoswitcher: light after morning-end, dark after evening-end
            # (transitions are kept as-is during the transition period)
            local i morning_end evening_end
            for (( i=0; i < ${#timestamps[@]}; i+=5 )); do
                morning_end=${timestamps[i+2]}
                evening_end=${timestamps[i+4]}
                if (( now_ms >= morning_end && now_ms < evening_end )); then
                    is_daylight=true
                    daylight_known=true
                    break
                elif (( now_ms < morning_end )); then
                    is_daylight=false
                    daylight_known=true
                    break
                elif (( now_ms >= evening_end )); then
                    is_daylight=false
                    daylight_known=true
                fi
            done
            # Unsubscribe
            busctl --user call org.kde.NightTime /org/kde/NightTime/Manager \
                org.kde.NightTime.Manager Unsubscribe u "${cookie:-0}" &>/dev/null
        fi
        if [[ "$daylight_known" == true ]]; then
            if [[ "$is_daylight" == "false" ]]; then
                PREV_LAF="$LAF_DARK"
            else
                PREV_LAF="$LAF_LIGHT"
            fi
        else
            # KNightTime unavailable or has no schedule yet (GeoClue not ready);
            # fall back to whichever theme Plasma persisted from the last session
            log "KNightTime schedule unavailable, using persisted theme"
            PREV_LAF=$(kreadconfig6 --file kdeglobals --group KDE --key LookAndFeelPackage)
            [[ -z "$PREV_LAF" || ("$PREV_LAF" != "$LAF_LIGHT" && "$PREV_LAF" != "$LAF_DARK") ]] && PREV_LAF="$LAF_LIGHT"
        fi
    else
        PREV_LAF=$(kreadconfig6 --file kdeglobals --group KDE --key LookAndFeelPackage)
        [[ -z "$PREV_LAF" || ("$PREV_LAF" != "$LAF_LIGHT" && "$PREV_LAF" != "$LAF_DARK") ]] && PREV_LAF="$LAF_DARK"
    fi
    log "Initial theme: $PREV_LAF"
    plasma-apply-lookandfeel -a "$PREV_LAF" 2>/dev/null
    [[ "$auto_mode" == "true" ]] && kwriteconfig6 --file kdeglobals --group KDE --key AutomaticLookAndFeel true
    apply_theme "$PREV_LAF" true
    if [[ "$auto_mode" == "true" ]]; then
        set_mode auto
    elif [[ "$PREV_LAF" == "$LAF_DARK" ]]; then
        set_mode dark
    else
        set_mode light
    fi
    # Ensure knighttimed gets a fresh GeoClue location. The daemon gives up
    # permanently if GeoClue isn't ready at startup, so wait for it and restart.
    # After restarting, re-query the schedule and correct the theme if needed,
    # since Plasma's auto mode may not immediately re-evaluate.
    (
        local gc_wait=0
        while ! busctl --system status org.freedesktop.GeoClue2 &>/dev/null; do
            if (( gc_wait >= 60 )); then
                log "GeoClue not available after 60s, giving up"
                exit 0
            fi
            sleep 1
            (( gc_wait++ ))
        done
        sleep 5  # give GeoClue a moment to be fully ready
        log "Restarting knighttimed to pick up GeoClue location"
        systemctl --user restart plasma-knighttimed.service
        # Wait for knighttimed to produce a schedule with actual timestamps
        local kn_wait=0 sub_out
        while true; do
            if sub_out=$(busctl --user call org.kde.NightTime /org/kde/NightTime/Manager \
                    org.kde.NightTime.Manager Subscribe 'a{sv}' 0 2>/dev/null) \
                    && [[ "$sub_out" == *"a(xxxxx)"* ]] \
                    && ! [[ "$sub_out" =~ a\(xxxxx\)\ 0$ ]]; then
                break
            fi
            if (( kn_wait >= 30 )); then
                log "KNightTime schedule not available after 30s, giving up"
                exit 0
            fi
            sleep 1
            (( kn_wait++ ))
        done
        if [[ -n "$sub_out" ]]; then
            local ck
            ck=$(echo "$sub_out" | grep -oP '(?<="Cookie" u )\d+')
            local now_ms
            now_ms=$(date +%s%3N)
            local -a ts
            read -ra ts <<< "$(echo "$sub_out" | sed 's/.*a(xxxxx) [0-9]* //')"
            local is_day=true day_known=false i me ee
            for (( i=0; i < ${#ts[@]}; i+=5 )); do
                me=${ts[i+2]}; ee=${ts[i+4]}
                if (( now_ms >= me && now_ms < ee )); then
                    is_day=true; day_known=true; break
                elif (( now_ms < me )); then
                    is_day=false; day_known=true; break
                elif (( now_ms >= ee )); then
                    is_day=false; day_known=true
                fi
            done
            busctl --user call org.kde.NightTime /org/kde/NightTime/Manager \
                org.kde.NightTime.Manager Unsubscribe u "${ck:-0}" &>/dev/null
            if [[ "$day_known" == true ]]; then
                local correct_laf="$LAF_LIGHT"
                [[ "$is_day" == false ]] && correct_laf="$LAF_DARK"
                local current_laf
                current_laf=$(kreadconfig6 --file kdeglobals --group KDE --key LookAndFeelPackage)
                if [[ "$current_laf" != "$correct_laf" ]]; then
                    log "GeoClue fix: correcting theme from $current_laf to $correct_laf"
                    plasma-apply-lookandfeel -a "$correct_laf" 2>/dev/null
                    kwriteconfig6 --file kdeglobals --group KDE --key AutomaticLookAndFeel true
                    apply_theme "$correct_laf"
                    # Record the apply timestamp so the main dbus-monitor loop
                    # debounces the notifyChange signal emitted by
                    # plasma-apply-lookandfeel above and doesn't apply twice.
                    date +%s > "${XDG_RUNTIME_DIR}/gloam-last-apply"
                    set_mode auto
                fi
            fi
        fi
    ) &

    local last_apply=0
    # Retry loop: dbus-monitor exits immediately if the session bus isn't ready
    # yet (can happen on the first startup attempt before plasma-core.target is
    # fully initialised). Retrying here avoids a service failure/restart cycle
    # that would skip the initial theme application entirely.
    while true; do
        dbus-monitor --session "type='signal',interface='org.kde.KGlobalSettings',member='notifyChange',path='/KGlobalSettings'" 2>/dev/null |
        while read -r line; do
            [[ "$line" == *"member=notifyChange"* ]] || continue
            # Debounce: ignore events within 3 seconds of last apply to prevent
            # feedback loop with Plasma's AutomaticLookAndFeel. Also check the
            # shared timestamp written by the GeoClue background subshell so
            # that its plasma-apply-lookandfeel call doesn't trigger a redundant
            # second apply from this loop.
            local now
            now=$(date +%s)
            local subshell_apply=0
            [[ -f "${XDG_RUNTIME_DIR}/gloam-last-apply" ]] && \
                subshell_apply=$(cat "${XDG_RUNTIME_DIR}/gloam-last-apply" 2>/dev/null || echo 0)
            if (( now - last_apply < 3 )) || (( now - subshell_apply < 3 )); then
                continue
            fi
            reload_laf_config
            laf=$(get_laf)
            if [[ "$laf" != "$PREV_LAF" ]]; then
                apply_theme "$laf"
                PREV_LAF="$laf"
                last_apply=$(date +%s)
                # Notify the plasmoid
                local auto_mode
                auto_mode=$(kreadconfig6 --file kdeglobals --group KDE --key AutomaticLookAndFeel)
                if [[ "$auto_mode" == "true" ]]; then
                    set_mode auto
                elif [[ "$laf" == "$LAF_DARK" ]]; then
                    set_mode dark
                else
                    set_mode light
                fi
            fi
        done
        # dbus-monitor exited (session bus not yet ready or transient disconnect).
        # Wait briefly before retrying.
        sleep 1
    done
}

check_config_valid() {
    local file="${1:-$CONFIG_FILE}"
    [[ ! -f "$file" ]] && return 0
    local file_vars
    file_vars=$(grep -oP '^[A-Z_]+(?==)' "$file" | sort)
    local var
    for var in "${EXPECTED_CONFIG_VARS[@]}"; do
        grep -qx "$var" <<< "$file_vars" || return 1
    done
    return 0
}

load_config_strict() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        die "No config found at $CONFIG_FILE. Run configure first."
    fi
    if ! check_config_valid; then
        die "Your configuration is outdated or incompatible. Please run 'gloam configure' to reconfigure."
    fi
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
}

# --- SESSION LOGOUT PROMPT ----------------------------------------------------

prompt_logout_if_needed() {
    [[ "$NEEDS_LOGOUT" == true ]] || return 0

    echo ""
    msg_warn "A session restart is needed for some changes to take effect."
    if _gum_confirm "Log out now?"; then
        if command -v qdbus6 &>/dev/null; then
            qdbus6 org.kde.Shutdown /Shutdown logout
        elif command -v qdbus &>/dev/null; then
            qdbus org.kde.Shutdown /Shutdown logout
        else
            warn "Could not find qdbus. Please log out manually."
        fi
    else
        msg_muted "Remember to log out and back in for all changes to take effect."
    fi
}

# --- CLI COMMANDS -------------------------------------------------------------

show_osd() {
    local icon="$1" text="$2"
    qdbus org.freedesktop.Notifications /org/kde/osdService \
        org.kde.osdService.showText "$icon" "$text" 2>/dev/null || true
}

# Write mode state and notify the plasmoid via DBus signal
set_mode() {
    echo "$1" > "$MODE_FILE"
}

# Switch to a specific mode: "light" or "dark"
# Pass --keep-auto to re-enable AutomaticLookAndFeel after plasma-apply-lookandfeel clears it.
# Pass --silent to skip showing the OSD.
do_switch() {
    local keep_auto=false
    local silent=false
    while [[ "${1:-}" == --* ]]; do
        case "$1" in
            --keep-auto) keep_auto=true; shift ;;
            --silent) silent=true; shift ;;
            *) break ;;
        esac
    done
    local mode="$1"
    load_config_strict

    local laf_var="LAF_${mode^^}"
    local laf="${!laf_var}"
    local icon label
    if [[ "$mode" == "light" ]]; then icon="☀️"; label="Light"; else icon="🌙"; label="Dark"; fi

    local friendly_name
    friendly_name=$(get_friendly_name laf "$laf")
    [[ "$keep_auto" != true ]] && set_mode "$mode"
    [[ "$silent" != true ]] && show_osd "$([[ "$mode" == "light" ]] && echo "weather-clear" || echo "weather-clear-night")" "$label"
    echo -e "Switching to ${icon} ${label} theme: ${BOLD}$friendly_name${RESET}"

    # If the LAF is already applied (e.g. auto had the same theme), just update the auto flag
    local current_laf
    current_laf=$(kreadconfig6 --file kdeglobals --group KDE --key LookAndFeelPackage)
    if [[ "$current_laf" == "$laf" ]]; then
        if [[ "$keep_auto" == true ]]; then
            kwriteconfig6 --file kdeglobals --group KDE --key AutomaticLookAndFeel true
        else
            kwriteconfig6 --file kdeglobals --group KDE --key AutomaticLookAndFeel false
        fi
        return
    fi

    plasma-apply-lookandfeel -a "$laf" 2>/dev/null

    if [[ "$keep_auto" == true ]]; then
        kwriteconfig6 --file kdeglobals --group KDE --key AutomaticLookAndFeel true
    fi

    apply_theme "$laf"
}

do_light() { do_switch light; }
do_dark()  { do_switch dark; }

do_auto() {
    set_mode auto
    show_osd "contrast" "Auto"
    # Determine correct theme for current time via KNightTime
    local is_daylight=true
    local subscribe_output
    if subscribe_output=$(busctl --user call org.kde.NightTime /org/kde/NightTime/Manager \
            org.kde.NightTime.Manager Subscribe 'a{sv}' 0 2>/dev/null); then
        local cookie
        cookie=$(echo "$subscribe_output" | grep -oP '(?<="Cookie" u )\d+')
        local now_ms
        now_ms=$(date +%s%3N)
        local -a timestamps
        read -ra timestamps <<< "$(echo "$subscribe_output" | sed 's/.*a(xxxxx) [0-9]* //')"
        local i morning_end evening_end
        for (( i=0; i < ${#timestamps[@]}; i+=5 )); do
            morning_end=${timestamps[i+2]}
            evening_end=${timestamps[i+4]}
            if (( now_ms >= morning_end && now_ms < evening_end )); then
                is_daylight=true
                break
            elif (( now_ms < morning_end )); then
                is_daylight=false
                break
            elif (( now_ms >= evening_end )); then
                is_daylight=false
            fi
        done
        busctl --user call org.kde.NightTime /org/kde/NightTime/Manager \
            org.kde.NightTime.Manager Unsubscribe u "${cookie:-0}" &>/dev/null
    fi

    if [[ "$is_daylight" == true ]]; then
        do_switch --keep-auto --silent light
    else
        do_switch --keep-auto --silent dark
    fi
}

# Cycle: light → dark → auto → light
do_toggle() {
    load_config_strict
    local auto_mode
    auto_mode=$(kreadconfig6 --file kdeglobals --group KDE --key AutomaticLookAndFeel)
    local current_laf
    current_laf=$(kreadconfig6 --file kdeglobals --group KDE --key LookAndFeelPackage)

    if [[ "$auto_mode" == "true" ]]; then
        do_light
        echo "Mode: Light"
    elif [[ "$current_laf" == "$LAF_DARK" ]]; then
        do_auto
        echo "Mode: Auto"
    else
        do_dark
        echo "Mode: Dark"
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

print_config_summary() {
    local laf_light_val="$1" laf_dark_val="$2" show_ids="${3:-false}"
    local light_suffix="" dark_suffix=""
    local em_dash
    em_dash=$(gum style --foreground "$CLR_MUTED" "—")
    if [[ "$show_ids" == true ]]; then
        light_suffix=" ($laf_light_val)"
        dark_suffix=" ($laf_dark_val)"
    fi
    _cfg_val() { [[ -n "${1:-}" ]] && echo "$1" || echo "$em_dash"; }
    echo "  ☀️ $(gum style --bold --foreground "$CLR_PRIMARY" "$(get_friendly_name laf "$laf_light_val")")${light_suffix}"
    echo "    Colors: $(_cfg_val "${COLOR_LIGHT:-}")"
    echo "    Kvantum: $(_cfg_val "${KVANTUM_LIGHT:-}")"
    echo "    App style: $(_cfg_val "${APPSTYLE_LIGHT:-}")"
    echo "    GTK: $(_cfg_val "${GTK_LIGHT:-}")"
    echo "    Style: $(_cfg_val "${STYLE_LIGHT:-}")"
    echo "    Decorations: $(_cfg_val "$([[ -n "${DECORATION_LIGHT:-}" ]] && get_friendly_name decoration "$DECORATION_LIGHT")")"
    echo "    Icons: $(_cfg_val "${ICON_LIGHT:-}")"
    echo "    Cursors: $(_cfg_val "${CURSOR_LIGHT:-}")"
    echo "    Splash: $(_cfg_val "$([[ -n "${SPLASH_LIGHT:-}" ]] && get_friendly_name splash "${SPLASH_LIGHT}")")"
    echo "    Login: $(_cfg_val "$([[ -n "${SDDM_LIGHT:-}" ]] && get_friendly_name sddm "${SDDM_LIGHT}")")"
    echo "    Wallpaper: $([[ -n "${WALLPAPER:-}" ]] && echo "Custom (Dynamic, Light, Dark)" || echo "$em_dash")"
    echo "    Konsole: $(_cfg_val "${KONSOLE_LIGHT:-}")"
    echo "    Script: $(_cfg_val "${SCRIPT_LIGHT:-}")"
    echo "  🌙 $(gum style --bold --foreground "$CLR_PRIMARY" "$(get_friendly_name laf "$laf_dark_val")")${dark_suffix}"
    echo "    Colors: $(_cfg_val "${COLOR_DARK:-}")"
    echo "    Kvantum: $(_cfg_val "${KVANTUM_DARK:-}")"
    echo "    App style: $(_cfg_val "${APPSTYLE_DARK:-}")"
    echo "    GTK: $(_cfg_val "${GTK_DARK:-}")"
    echo "    Style: $(_cfg_val "${STYLE_DARK:-}")"
    echo "    Decorations: $(_cfg_val "$([[ -n "${DECORATION_DARK:-}" ]] && get_friendly_name decoration "$DECORATION_DARK")")"
    echo "    Icons: $(_cfg_val "${ICON_DARK:-}")"
    echo "    Cursors: $(_cfg_val "${CURSOR_DARK:-}")"
    echo "    Splash: $(_cfg_val "$([[ -n "${SPLASH_DARK:-}" ]] && get_friendly_name splash "${SPLASH_DARK}")")"
    echo "    Login: $(_cfg_val "$([[ -n "${SDDM_DARK:-}" ]] && get_friendly_name sddm "${SDDM_DARK}")")"
    echo "    Wallpaper: $([[ -n "${WALLPAPER:-}" ]] && echo "Custom (Dynamic, Light, Dark)" || echo "$em_dash")"
    echo "    Konsole: $(_cfg_val "${KONSOLE_DARK:-}")"
    echo "    Script: $(_cfg_val "${SCRIPT_DARK:-}")"
}

do_configure() {
    check_desktop_environment


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
    local configure_patches=false
    local IMPORT_CONFIG=""
    local IMPORT_REQUESTED=false
    local EXPORT_REQUESTED=false
    local EXPORT_DIR=""

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
            -P|--patches)       configure_patches=true; configure_all=false ;;
            -I|--import)        if [[ $# -gt 1 && ! "$2" =~ ^- ]]; then IMPORT_CONFIG="$2"; shift; fi; IMPORT_REQUESTED=true ;;
            -e|--export)        EXPORT_REQUESTED=true ;;
            help|-h|--help)     show_configure_help; exit 0 ;;
            *)
                error "Unknown option: $1"
                msg_muted "Options: -c|--colors -k|--kvantum -a|--appstyle -g|--gtk -p|--style -d|--decorations -i|--icons -C|--cursors -S|--splash -l|--login -W|--wallpaper -o|--konsole -s|--script -w|--widget -K|--shortcut -P|--patches -I|--import <file> -e|--export <dir>"
                exit 1
                ;;
        esac
        shift
    done

    # Handle --export: copy config to target directory and exit
    if [[ "$EXPORT_REQUESTED" == true ]]; then
        if [[ -z "$EXPORT_DIR" ]]; then
            EXPORT_DIR=$(_gum_input --header "Export directory" --placeholder "/path/to/directory" --width 60) || exit 1
        fi
        if [[ ! -f "$CONFIG_FILE" ]]; then
            die "No config found at $CONFIG_FILE. Run configure first."
        fi
        EXPORT_DIR="${EXPORT_DIR%/}"
        if [[ ! -d "$EXPORT_DIR" ]]; then
            die "Directory not found: $EXPORT_DIR"
        fi
        cp "$CONFIG_FILE" "${EXPORT_DIR}/gloam.conf"
        msg_ok "Config exported to ${EXPORT_DIR}/gloam.conf"
        exit 0
    fi

    # Handle --patches: always rebuild and reinstall Plasma patch
    if [[ "$configure_patches" == true ]]; then
        # Detect if running from global installation
        if [[ -x "/usr/local/bin/gloam" ]] && [[ "$(realpath "$0" 2>/dev/null)" == "/usr/local/bin/gloam" ]]; then
            INSTALL_GLOBAL=true
        fi

        msg_header "Plasma Patches"

        msg_muted "This will rebuild and install the plasma-integration patch from source."
        msg_muted "Build tools (cmake, make, git, curl) are required."
        echo ""

        local _pi_installed=true
        if is_patch_plasma_integration_installed; then
            gum style --foreground "$CLR_SUCCESS" "  ✓ plasma-integration — Qt App Theme Refresh"
        else
            gum style --foreground "$CLR_ERROR" "  ✗ plasma-integration — Qt App Theme Refresh"
            msg_muted "    Without this patch, Qt apps (Dolphin, Kate, etc.) must be"
            msg_muted "    restarted to pick up theme changes. The patch adds a DBus"
            msg_muted "    signal handler that forces an immediate style refresh."
            _pi_installed=false
        fi
        echo ""

        local _prompt="Install patch?"
        [[ "$_pi_installed" == true ]] && _prompt="Reinstall patch?"
        if ! _gum_confirm "$_prompt"; then
            msg_muted "Aborted."
            exit 0
        fi

        sudo_auth || die "Sudo required to install patches."
        install_patch_plasma_integration || warn "plasma-integration patch failed."
        deploy_patches_dir
        echo ""
        msg_warn "Plasma updates will overwrite this patch."
        msg_muted "Re-run 'gloam configure --patches' after updating Plasma."
        NEEDS_LOGOUT=true
        prompt_logout_if_needed
        exit 0
    fi

    # Prompt for import path if needed, before showing disclaimer
    if [[ "$IMPORT_REQUESTED" == true && -z "$IMPORT_CONFIG" ]]; then
        IMPORT_CONFIG=$(_gum_input --header "Import config file" --placeholder "/path/to/gloam.conf" --width 60) || exit 1
    fi

    # Show disclaimer
    echo ""
    gum style \
        --foreground "$CLR_WARNING" \
        --border normal \
        --border-foreground "$CLR_WARNING" \
        --padding "0 2" \
        "⚠ Disclaimer" "" \
        "  gloam modifies Plasma theme settings, system configs, and user files." \
        "  It is recommended to back up your system before proceeding." \
        "  The authors are not responsible for any system issues."
    _gum_confirm "Continue?" || { msg_muted "Aborted."; exit 0; }

    # Check for recommended Plasma patches
    check_patches

    # Handle config import - source the file and skip all interactive questions
    if [[ -n "${IMPORT_CONFIG}" ]]; then
        if [[ ! -f "$IMPORT_CONFIG" ]]; then
            die "Config file not found: $IMPORT_CONFIG"
        fi
        if ! check_config_valid "$IMPORT_CONFIG"; then
            die "Imported config is outdated or incompatible. It may be from a different version of gloam."
        fi
        msg_header "Configuration"
        _spinner_start "Importing configuration from ${IMPORT_CONFIG}..."
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
            _spinner_stop
            local error_list=""
            for err in "${import_errors[@]}"; do
                error_list+="  • ${err}"$'\n'
            done
            gum style \
                --foreground "$CLR_ERROR" \
                --border normal \
                --border-foreground "$CLR_ERROR" \
                --padding "0 2" \
                "Import failed — missing assets:" "" \
                "$error_list"
            exit 1
        fi
        _spinner_stop
        msg_ok "Imported configuration from ${IMPORT_CONFIG}"

        # Authenticate sudo if config requires global installation
        if [[ "${INSTALL_GLOBAL:-false}" == true ]]; then
            msg_info "Config requires global installation, requesting sudo..."
            sudo_auth || die "Sudo required for global installation."
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
            die "Imported config is missing theme definitions (LAF_LIGHT/LAF_DARK). Check that the config file is valid."
        fi
        msg_header "Global Themes"
        echo "  ☀️ $(gum style --bold --foreground "$CLR_PRIMARY" "$(get_friendly_name laf "$laf_light")")"
        echo "  🌙 $(gum style --bold --foreground "$CLR_PRIMARY" "$(get_friendly_name laf "$laf_dark")")"
        cleanup_stale
        # Remove app-specific overrides so they follow the global theme
        clean_app_overrides
    # Load existing config if modifying specific options (includes INSTALL_GLOBAL)
    elif [[ "$configure_all" == false && -f "$CONFIG_FILE" ]]; then
        if ! check_config_valid; then
            die "Your configuration is outdated or incompatible. Please run 'gloam configure' to reconfigure."
        fi
        # shellcheck source=/dev/null
        source "$CONFIG_FILE"
        # Authenticate sudo if this is a global installation
        if [[ "$INSTALL_GLOBAL" == true ]]; then
            msg_info "Global installation detected, requesting sudo..."
            sudo_auth || die "Sudo required for global installation."
        fi
    elif [[ "$configure_all" == true ]]; then
        # Full configuration - ask about global installation first
        ask_global_install

        if [[ -f "$CONFIG_FILE" ]]; then
            warn "Existing configuration found."
            if _gum_confirm "Do you want to overwrite it?"; then
                source "$CONFIG_FILE"
                cleanup_stale
            else
                msg_muted "Use configure options to modify specific settings (e.g. --kvantum, --gtk)."
                msg_muted "Run 'gloam help' for available options."
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

    # Read light/dark themes from KDE Quick Settings configuration
    log "Reading theme configuration from KDE settings..."
    local laf_light laf_dark
    laf_light=$(kreadconfig6 --file kdeglobals --group KDE --key DefaultLightLookAndFeel)
    laf_dark=$(kreadconfig6 --file kdeglobals --group KDE --key DefaultDarkLookAndFeel)

    # If KDE still points to our custom themes, resolve back to the base themes
    # Try config variable first, then fall back to reading the custom theme's metadata
    _resolve_base_theme() {
        local custom_id="$1" mode="$2" config_var="$3"
        # Config variable available
        [[ -n "${!config_var:-}" ]] && echo "${!config_var}" && return 0
        # Extract from custom theme metadata ("Custom light theme based on <id>")
        local meta_file
        for dir in /usr/share/plasma/look-and-feel "${HOME}/.local/share/plasma/look-and-feel"; do
            meta_file="${dir}/${custom_id}/metadata.json"
            if [[ -f "$meta_file" ]]; then
                local base_id
                base_id=$(sed -n "s/.*\"Description\"[[:space:]]*:[[:space:]]*\"Custom ${mode} theme based on \([^\"]*\)\".*/\1/p" "$meta_file")
                [[ -n "$base_id" ]] && echo "$base_id" && return 0
            fi
        done
        return 1
    }

    if [[ "$laf_light" == "org.kde.custom.light" ]]; then
        local resolved
        if resolved=$(_resolve_base_theme "org.kde.custom.light" "light" "BASE_THEME_LIGHT"); then
            laf_light="$resolved"
            BASE_THEME_LIGHT="$resolved"
        else
            die "KDE is set to use Custom (Light) but the base theme is unknown. Set your light theme in System Settings > Quick Settings."
        fi
    fi
    if [[ "$laf_dark" == "org.kde.custom.dark" ]]; then
        local resolved
        if resolved=$(_resolve_base_theme "org.kde.custom.dark" "dark" "BASE_THEME_DARK"); then
            laf_dark="$resolved"
            BASE_THEME_DARK="$resolved"
        else
            die "KDE is set to use Custom (Dark) but the base theme is unknown. Set your dark theme in System Settings > Quick Settings."
        fi
    fi
    echo "  ☀️ $(gum style --bold --foreground "$CLR_PRIMARY" "$(get_friendly_name laf "$laf_light")")"
    echo "  🌙 $(gum style --bold --foreground "$CLR_PRIMARY" "$(get_friendly_name laf "$laf_dark")")"

    if [[ "$laf_light" == "$laf_dark" ]]; then
        die "☀️ Light and 🌙 Dark LookAndFeel are the same ($laf_light).\nConfigure different themes in System Settings > Colors & Themes > Global Theme."
    fi

    msg_header "Configure Sub-Themes"
    msg_muted "Override individual settings for light and dark modes."
    echo ""

    # Select Color Schemes
    if [[ "$configure_all" == true || "$configure_colors" == true ]]; then
        if ! select_themes "Configure color schemes? (normally automatically set by global theme)" scan_color_schemes COLOR; then
            COLOR_LIGHT=""
            COLOR_DARK=""
        fi
    fi

    # Select Kvantum themes
    local _flatpak_warned=false
    if [[ "$configure_all" == true || "$configure_kvantum" == true ]]; then
        kvantum_flatpak_callback() {
            if command -v flatpak &>/dev/null; then
                setup_flatpak_permissions
                setup_flatpak_kvantum
                _flatpak_warned=true
            fi
        }
        if ! select_themes "Configure Kvantum themes? (not automatically set by global theme)" scan_kvantum_themes KVANTUM "" kvantum_flatpak_callback; then
            KVANTUM_LIGHT=""
            KVANTUM_DARK=""
        fi
    fi

    # Select Application Style (Qt widget style)
    if [[ "$configure_all" == true || "$configure_appstyle" == true ]]; then
        if ! select_themes "Configure application style? (normally automatically set by global theme)" scan_app_styles APPSTYLE; then
            APPSTYLE_LIGHT=""
            APPSTYLE_DARK=""
        fi
    fi

    # Select GTK/Flatpak themes
    if [[ "$configure_all" == true || "$configure_gtk" == true ]]; then
        gtk_callback() {
            if command -v flatpak &>/dev/null; then
                setup_flatpak_permissions
                warn "Flatpak apps may need to be closed and reopened to update theme."
            fi
        }
        if ! select_themes "Configure GTK/Flatpak themes? (not automatically set by global theme)" scan_gtk_themes GTK "" gtk_callback; then
            GTK_LIGHT=""
            GTK_DARK=""
        fi
    fi

    # Select Plasma Styles
    if [[ "$configure_all" == true || "$configure_style" == true ]]; then
        if ! select_themes "Configure Plasma styles? (normally automatically set by global theme)" scan_plasma_styles STYLE; then
            STYLE_LIGHT=""
            STYLE_DARK=""
        fi
    fi

    # Select Window Decorations
    if [[ "$configure_all" == true || "$configure_decorations" == true ]]; then
        if ! select_themes "Configure window decorations? (normally automatically set by global theme)" scan_window_decorations DECORATION "id_name"; then
            DECORATION_LIGHT=""
            DECORATION_DARK=""
        fi
    fi

    # Select icon themes
    if [[ "$configure_all" == true || "$configure_icons" == true ]]; then
        for path in /usr/lib/plasma-changeicons /usr/libexec/plasma-changeicons /usr/lib64/plasma-changeicons; do
            if [[ -x "$path" ]]; then
                PLASMA_CHANGEICONS="$path"
                break
            fi
        done
        if [[ -z "${PLASMA_CHANGEICONS:-}" ]]; then
            PLASMA_CHANGEICONS=$(find /usr/lib /usr/libexec /usr/lib64 -name "plasma-changeicons" -print -quit 2>/dev/null || true)
        fi
        if [[ -z "$PLASMA_CHANGEICONS" ]]; then
            die "plasma-changeicons not found. Install the plasma-workspace package for your distribution."
        fi
        if ! select_themes "Configure icon themes? (normally automatically set by global theme)" scan_icon_themes ICON; then
            ICON_LIGHT=""
            ICON_DARK=""
            PLASMA_CHANGEICONS=""
        fi
    fi

    # Select Cursor themes
    if [[ "$configure_all" == true || "$configure_cursors" == true ]]; then
        if ! select_themes "Configure cursor themes? (normally automatically set by global theme)" scan_cursor_themes CURSOR "id_name"; then
            CURSOR_LIGHT=""
            CURSOR_DARK=""
        fi
    fi

    # Select Splash Screens
    if [[ "$configure_all" == true || "$configure_splash" == true ]]; then
        if ! select_themes "Configure splash screen override? (normally automatically set by global theme)" scan_splash_themes SPLASH "id_name has_none"; then
            SPLASH_LIGHT=""
            SPLASH_DARK=""
        fi
    fi

    # Select Login Screen (SDDM) Themes
    if [[ "$configure_all" == true || "$configure_login" == true ]]; then
    if _gum_confirm "Configure login screen (SDDM) themes? (requires sudo)"; then
        local sddm_ids=() sddm_names=()
        while IFS='|' read -r id name; do
            sddm_ids+=("$id")
            sddm_names+=("$name")
        done < <(scan_sddm_themes)

        if [[ ${#sddm_ids[@]} -eq 0 ]]; then
            warn "No SDDM themes found in /usr/share/sddm/themes/"
            SDDM_LIGHT=""
            SDDM_DARK=""
        else
            local light_choice dark_choice
            light_choice=$(printf '%s\n' "${sddm_names[@]}" | _gum_choose --header "Select ☀️ LIGHT mode login theme") || true
            dark_choice=$(printf '%s\n' "${sddm_names[@]}" | _gum_choose --header "Select 🌙 DARK mode login theme") || true

            msg_muted "Login screen (SDDM) themes"
            echo "  ☀️ $(gum style --bold --foreground "$CLR_PRIMARY" "$light_choice")"
            echo "  🌙 $(gum style --bold --foreground "$CLR_PRIMARY" "$dark_choice")"
            echo ""

            # Map display name back to id
            SDDM_LIGHT=""
            SDDM_DARK=""
            for i in "${!sddm_names[@]}"; do
                [[ "${sddm_names[$i]}" == "$light_choice" ]] && SDDM_LIGHT="${sddm_ids[$i]}"
                [[ "${sddm_names[$i]}" == "$dark_choice" ]] && SDDM_DARK="${sddm_ids[$i]}"
            done

            # Set up sudoers rule for non-interactive SDDM switching
            if [[ -n "${SDDM_LIGHT:-}" || -n "${SDDM_DARK:-}" ]]; then
                log "Setting up passwordless sudo for SDDM theme switching..."
                sudo_auth || { error "Sudo required for SDDM theme switching."; SDDM_LIGHT=""; SDDM_DARK=""; }
                if [[ -n "${SDDM_LIGHT:-}" || -n "${SDDM_DARK:-}" ]]; then
                    setup_sddm_sudoers
                    msg_ok "SDDM sudoers rule installed."
                fi
            fi
        fi
    else
        SDDM_LIGHT=""
        SDDM_DARK=""
    fi
    fi

    echo ""

    # Configure day/night wallpapers
    if [[ "$configure_all" == true || "$configure_wallpaper" == true ]]; then
    if _gum_confirm "Configure wallpapers? (normally automatically set by global theme)"; then
        local wp_light_input
        wp_light_input=$(_gum_input \
            --header "☀️ LIGHT wallpaper path(s)" \
            --placeholder "Space-separated files, or a folder" \
            --width 60)
        local wp_light_paths=()
        while IFS= read -r img; do
            wp_light_paths+=("$img")
        done < <(resolve_image_paths "$wp_light_input")

        if [[ ${#wp_light_paths[@]} -eq 0 ]]; then
            warn "No valid images found for light mode."
        fi

        local wp_dark_input
        wp_dark_input=$(_gum_input \
            --header "🌙 DARK wallpaper path(s)" \
            --placeholder "Space-separated files, or a folder" \
            --width 60)
        local wp_dark_paths=()
        while IFS= read -r img; do
            wp_dark_paths+=("$img")
        done < <(resolve_image_paths "$wp_dark_input")

        if [[ ${#wp_dark_paths[@]} -eq 0 ]]; then
            warn "No valid images found for dark mode."
        fi

        if [[ ${#wp_light_paths[@]} -gt 0 && ${#wp_dark_paths[@]} -gt 0 ]]; then
            # Store original source paths for import/re-generation
            WP_SOURCE_LIGHT="${wp_light_paths[*]}"
            WP_SOURCE_DARK="${wp_dark_paths[*]}"

            _spinner_start "Creating wallpaper pack..."
            generate_wallpaper_pack "gloam" "Custom" wp_light_paths wp_dark_paths

            local wallpaper_dir
            if [[ "${THEME_INSTALL_GLOBAL:-${INSTALL_GLOBAL:-false}}" == true ]]; then
                wallpaper_dir="/usr/share/wallpapers/gloam"
            else
                wallpaper_dir="${HOME}/.local/share/wallpapers/gloam"
            fi
            apply_desktop_wallpaper "$wallpaper_dir"
            apply_lockscreen_wallpaper "$wallpaper_dir"
            _spinner_stop

            if _gum_confirm "Set SDDM login background? (requires sudo)"; then
                sudo_auth || { error "Sudo required for SDDM wallpaper."; }
                if sudo -n true 2>/dev/null; then
                    setup_sddm_wallpaper
                    msg_ok "SDDM backgrounds installed."
                    apply_sddm_for_current_mode
                fi
            fi

            WALLPAPER=true
        else
            warn "Need at least one image for each mode. Skipping wallpaper."
            WALLPAPER=""
        fi
    else
        WALLPAPER=""
    fi
    fi

    # Select Konsole profiles
    if [[ "$configure_all" == true || "$configure_konsole" == true ]]; then
    echo ""
    if _gum_confirm "Configure Konsole profiles? (not automatically set by global theme)"; then
        mapfile -t konsole_profiles < <(scan_konsole_profiles)

        if [[ ${#konsole_profiles[@]} -eq 0 ]]; then
            msg_muted "No Konsole profiles found, skipping."
            KONSOLE_LIGHT=""
            KONSOLE_DARK=""
        else
            local light_choice dark_choice
            light_choice=$(printf '%s\n' "${konsole_profiles[@]}" | _gum_choose --header "Select ☀️ LIGHT mode Konsole profile") || true
            dark_choice=$(printf '%s\n' "${konsole_profiles[@]}" | _gum_choose --header "Select 🌙 DARK mode Konsole profile") || true

            echo ""
            msg_muted "Konsole profiles"
            echo "  ☀️ $(gum style --bold --foreground "$CLR_PRIMARY" "$light_choice")"
            echo "  🌙 $(gum style --bold --foreground "$CLR_PRIMARY" "$dark_choice")"

            KONSOLE_LIGHT="${light_choice:-}"
            KONSOLE_DARK="${dark_choice:-}"
        fi
    else
        KONSOLE_LIGHT=""
        KONSOLE_DARK=""
    fi
    fi

    # Configure custom scripts
    if [[ "$configure_all" == true || "$configure_script" == true ]]; then
    if _gum_confirm "Configure custom scripts?"; then
        SCRIPT_LIGHT=$(_gum_input \
            --header "☀️ LIGHT mode script path" \
            --placeholder "Leave empty to skip" \
            --width 60) || true
        if [[ -n "$SCRIPT_LIGHT" && ! -x "$SCRIPT_LIGHT" ]]; then
            warn "$SCRIPT_LIGHT is not executable"
        fi

        SCRIPT_DARK=$(_gum_input \
            --header "🌙 DARK mode script path" \
            --placeholder "Leave empty to skip" \
            --width 60) || true
        if [[ -n "$SCRIPT_DARK" && ! -x "$SCRIPT_DARK" ]]; then
            warn "$SCRIPT_DARK is not executable"
        fi

        # Copy scripts globally if global install and script is in user's home
        if [[ "$INSTALL_GLOBAL" == true ]]; then
            if [[ -n "$SCRIPT_LIGHT" && -f "$SCRIPT_LIGHT" && "$SCRIPT_LIGHT" == "$HOME"* ]]; then
                sudo mkdir -p "$GLOBAL_SCRIPTS_DIR"
                sudo cp "$SCRIPT_LIGHT" "$GLOBAL_SCRIPTS_DIR/$(basename "$SCRIPT_LIGHT")"
                sudo chmod +x "$GLOBAL_SCRIPTS_DIR/$(basename "$SCRIPT_LIGHT")"
                SCRIPT_LIGHT="$GLOBAL_SCRIPTS_DIR/$(basename "$SCRIPT_LIGHT")"
            fi
            if [[ -n "$SCRIPT_DARK" && -f "$SCRIPT_DARK" && "$SCRIPT_DARK" == "$HOME"* ]]; then
                sudo mkdir -p "$GLOBAL_SCRIPTS_DIR"
                sudo cp "$SCRIPT_DARK" "$GLOBAL_SCRIPTS_DIR/$(basename "$SCRIPT_DARK")"
                sudo chmod +x "$GLOBAL_SCRIPTS_DIR/$(basename "$SCRIPT_DARK")"
                SCRIPT_DARK="$GLOBAL_SCRIPTS_DIR/$(basename "$SCRIPT_DARK")"
            fi
        fi
    else
        SCRIPT_LIGHT=""
        SCRIPT_DARK=""
    fi
    fi

    # Check if anything was configured
    if ! has_any_config; then
        msg_muted "Nothing to configure. Exiting."
        exit 0
    fi

    echo ""
    msg_info "Configuration summary:"
    print_config_summary "$laf_light" "$laf_dark"

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
            warn "Custom themes exist but base themes are not recorded. Run 'gloam configure' to regenerate custom themes."
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

        # Verify base themes still exist
        if ! check_base_theme_exists "$BASE_THEME_LIGHT"; then
            error "Base theme '$BASE_THEME_LIGHT' is no longer installed. Reinstall the theme or run 'gloam configure' to select a new one."
            exit 1
        fi
        if ! check_base_theme_exists "$BASE_THEME_DARK"; then
            error "Base theme '$BASE_THEME_DARK' is no longer installed. Reinstall the theme or run 'gloam configure' to select a new one."
            exit 1
        fi

        # Set up theme install directory
        if [[ "$THEME_INSTALL_GLOBAL" == true ]]; then
            THEME_INSTALL_DIR="/usr/share/plasma/look-and-feel"
        else
            THEME_INSTALL_DIR="${HOME}/.local/share/plasma/look-and-feel"
        fi

        _spinner_start "Regenerating custom themes..."
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
            plasma-apply-lookandfeel -a "$LAF_DARK" 2>/dev/null
        else
            plasma-apply-lookandfeel -a "$LAF_LIGHT" 2>/dev/null
        fi

        reapply_bundled_wallpapers
        apply_sddm_for_current_mode
        _spinner_stop

        msg_ok "Custom themes updated."

    elif has_bundleable_options current; then
        # First time - ask user if they want custom themes
        msg_header "Custom Themes"
        msg_muted "Bundles your selections into native Plasma themes so overrides are applied" \
            "automatically during theme switches — no manual reapplication needed."
        echo ""
        if _gum_confirm --default=yes "Generate custom themes from your selections? (Recommended)"; then
            if request_sudo_for_global_install; then
                # Store base themes for future regeneration
                BASE_THEME_LIGHT="$laf_light"
                BASE_THEME_DARK="$laf_dark"

                _spinner_start "Generating custom themes..."
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
                    plasma-apply-lookandfeel -a "$LAF_DARK" 2>/dev/null
                else
                    plasma-apply-lookandfeel -a "$LAF_LIGHT" 2>/dev/null
                fi

                # Re-apply wallpapers from bundled location
                if [[ "${WALLPAPER:-}" == true && -n "${WALLPAPER_BASE:-}" ]]; then
                    local wp_mode="gloam"
                    apply_desktop_wallpaper "${WALLPAPER_BASE}/${wp_mode}"
                    apply_lockscreen_wallpaper "${WALLPAPER_BASE}/${wp_mode}"
                fi

                apply_sddm_for_current_mode
                _spinner_stop

                msg_ok "Custom themes installed and set as defaults."
            fi
        fi
    fi

    fi # end of interactive block (skipped during --import)

    # Import: generate custom themes and apply settings
    if [[ -n "${IMPORT_CONFIG}" && -n "${BASE_THEME_LIGHT:-}" && -n "${BASE_THEME_DARK:-}" ]]; then
        echo ""
        if [[ "${THEME_INSTALL_GLOBAL:-false}" == true ]]; then
            THEME_INSTALL_DIR="/usr/share/plasma/look-and-feel"
        else
            THEME_INSTALL_DIR="${HOME}/.local/share/plasma/look-and-feel"
        fi

        CUSTOM_THEME_LIGHT="org.kde.custom.light"
        CUSTOM_THEME_DARK="org.kde.custom.dark"

        _spinner_start "Generating custom themes..."
        generate_custom_theme "light" "$BASE_THEME_LIGHT"
        generate_custom_theme "dark" "$BASE_THEME_DARK"

        # Regenerate wallpaper pack from original source images
        if [[ "${WALLPAPER:-}" == true && -n "${WP_SOURCE_LIGHT:-}" && -n "${WP_SOURCE_DARK:-}" ]]; then
            local wp_light_paths=() wp_dark_paths=()
            local img
            for img in ${WP_SOURCE_LIGHT}; do
                [[ -f "$img" ]] && wp_light_paths+=("$img")
            done
            for img in ${WP_SOURCE_DARK}; do
                [[ -f "$img" ]] && wp_dark_paths+=("$img")
            done
            if [[ ${#wp_light_paths[@]} -gt 0 && ${#wp_dark_paths[@]} -gt 0 ]]; then
                generate_wallpaper_pack "gloam" "Custom" wp_light_paths wp_dark_paths
            fi
        fi

        bundle_wallpapers_and_sddm

        # Set up SDDM sudoers rules (skipped during import since interactive prompts are bypassed)
        if [[ -n "${SDDM_LIGHT:-}" || -n "${SDDM_DARK:-}" ]]; then
            setup_sddm_sudoers
        fi

        # Set up SDDM wallpaper helper script if backgrounds were bundled
        if [[ -n "$({ compgen -G '/usr/local/lib/gloam/sddm-bg-*' 2>/dev/null || true; })" ]]; then
            install_sddm_background_helper
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
            plasma-apply-lookandfeel -a "$LAF_DARK" 2>/dev/null
        else
            plasma-apply-lookandfeel -a "$LAF_LIGHT" 2>/dev/null
        fi

        reapply_bundled_wallpapers
        apply_sddm_for_current_mode
        _spinner_stop

        msg_ok "Custom themes installed."
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
            die "Widget and shortcut require the CLI to be installed first. Run 'gloam configure' first."
        fi
        install_cli_binary
        [[ "$configure_widget" == true ]] && install_plasmoid
        [[ "$configure_shortcut" == true ]] && install_shortcut
        prompt_logout_if_needed
        return 0
    fi

    # Skip install prompts if partial reconfigure
    if [[ "$configure_all" == false && "$installed_previously" == true ]]; then
        install_cli_binary
        executable_path="$cli_path"
    elif [[ -n "${IMPORT_CONFIG}" ]]; then
        # Import mode - install based on config flags
        if [[ "${INSTALL_CLI:-false}" == true ]]; then
            msg_header "Install Tools"
            msg_muted "Install the CLI, panel widget, and keyboard shortcut."
            install_cli_binary
            executable_path="$cli_path"
            msg_ok "Installed to $cli_path"
            [[ "${INSTALL_WIDGET:-false}" == true ]] && install_plasmoid
            [[ "${INSTALL_SHORTCUT:-false}" == true ]] && install_shortcut
        else
            executable_path=$(readlink -f "$0")
        fi
    elif [[ "$configure_all" == true ]]; then
        msg_header "Install Tools"
        msg_muted "Install the CLI, panel widget, and keyboard shortcut."

        # Install the CLI
        local install_cli_prompt
        install_cli_prompt="Install 'gloam' to $(get_cli_path)?"

        if _gum_confirm "$install_cli_prompt"; then
            INSTALL_CLI=true
            install_cli_binary
            executable_path="$cli_path"
            msg_ok "Installed to $cli_path"

            # Offer to install the panel widget
            if _gum_confirm "Install the Light/Dark Mode Toggle panel widget?"; then
                INSTALL_WIDGET=true; install_plasmoid
            fi

            # Offer to install keyboard shortcut
            if _gum_confirm "Add a keyboard shortcut (Meta+Shift+L)?"; then
                INSTALL_SHORTCUT=true; install_shortcut
            fi
        else
            # Use absolute path of current script
            executable_path=$(readlink -f "$0")
            warn "The panel widget and keyboard shortcut require the CLI to be installed."
        fi
    else
        executable_path=$(readlink -f "$0")
    fi

    # Install systemd service
    msg_header "Activate"
    local exec_condition=""
    if [[ "$INSTALL_GLOBAL" == true ]]; then
        exec_condition=$'\nExecCondition=/bin/sh -c \'[ "$(id -u)" -ge 1000 ]\''
    fi

    local service_content="[Unit]
Description=Plasma Light/Dark Theme Sync
After=plasma-kwin_wayland.service plasma-kwin_x11.service
Before=plasma-core.target

[Service]${exec_condition}
Type=simple
ExecStart=$executable_path watch
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target"

    gloam_cmd mkdir -p "$service_dir"
    if [[ "$INSTALL_GLOBAL" == true ]]; then
        echo "$service_content" | sudo tee "$service_file" > /dev/null
    else
        echo "$service_content" > "$service_file"
    fi

    systemctl --user daemon-reload
    systemctl --user enable "$SERVICE_NAME" 2>/dev/null
    systemctl --user start --no-block "$SERVICE_NAME" 2>/dev/null

    # Enable automatic theme switching in KDE Quick Settings
    kwriteconfig6 --file kdeglobals --group KDE --key AutomaticLookAndFeel true

    msg_ok "Successfully configured and started $SERVICE_NAME."

    # Push config to other users if requested
    push_config_to_users

    # Set system defaults for new users if requested
    set_system_defaults

    # Write flatpak tracking to config (per-user state, after skel copy so it's not in skel)
    if [[ ${#FLATPAK_PREV_OVERRIDES[@]} -gt 0 ]]; then
        echo "FLATPAK_PREV_OVERRIDES=$(IFS=,; echo "${FLATPAK_PREV_OVERRIDES[*]}")" >> "$CONFIG_FILE"
    fi

    # Write global installation marker
    write_global_install_marker

    # Offer to log out if patches, widget, or shortcut were installed
    prompt_logout_if_needed

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

    # Check for patch backup files that require sudo to restore/remove
    local has_patch_files=false
    local _so
    _so=$(_get_plasma_integration_so 2>/dev/null) && [[ -f "${_so}.gloam-orig" ]] && has_patch_files=true
    [[ "$has_patch_files" != true ]] && is_patch_plasma_integration_installed && has_patch_files=true

    local needs_sudo=false
    [[ -f "$global_service" || -f "$global_cli" || -d "$global_plasmoid" || -f "$global_shortcut" || -d "$global_theme_light" || -d "$global_theme_dark" || -f "$skel_config" || -L "$global_service_link" || -f "$GLOBAL_INSTALL_MARKER" || -d "$GLOBAL_SCRIPTS_DIR" || -f /etc/sudoers.d/gloam-sddm || -f /etc/sudoers.d/gloam-sddm-bg || -f /etc/sudoers.d/gloam-patch || -d /usr/local/lib/gloam || -d /usr/share/wallpapers/gloam || "$has_patch_files" == true ]] && needs_sudo=true

    if [[ "$needs_sudo" == true ]]; then
        # Warn about global installation
        if [[ -f "$GLOBAL_INSTALL_MARKER" ]]; then
            local admin_user admin_date
            admin_user=$(grep "^user=" "$GLOBAL_INSTALL_MARKER" 2>/dev/null | cut -d= -f2)
            admin_date=$(grep "^date=" "$GLOBAL_INSTALL_MARKER" 2>/dev/null | cut -d= -f2)

            echo ""
            gum style --border double --border-foreground "$CLR_WARNING" --padding "0 2" --foreground "$CLR_WARNING" \
                "$(gum style --bold "⚠ This will remove the global installation.")" \
                "" \
                "Configured by: ${admin_user:-unknown}" \
                "Date: ${admin_date:-unknown}" \
                "" \
                "This will affect ALL users on this system."
            echo ""
            _gum_confirm "Continue with removal?" || { msg_muted "Removal cancelled."; exit 0; }
        fi

        msg_info "Requesting sudo..."
        sudo_auth || die "Sudo required to remove global files."
    fi

    _spinner_start "Removing gloam..."

    # Helper to print removal status
    local _removed_count=0
    _remove_print() {
        (( _removed_count++ )) || true
        _spinner_print "$(msg_muted "Removed: $1")"
    }

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
        fi
        if [[ -n "$base_dark" ]]; then
            kwriteconfig6 --file kdeglobals --group KDE --key DefaultDarkLookAndFeel "$base_dark"
        fi

        # Apply the appropriate base theme if currently using custom theme
        local current_laf
        current_laf=$(kreadconfig6 --file kdeglobals --group KDE --key LookAndFeelPackage 2>/dev/null)
        if [[ "$current_laf" == "org.kde.custom.light" && -n "$base_light" ]]; then
            plasma-apply-lookandfeel -a "$base_light" 2>/dev/null || true
        elif [[ "$current_laf" == "org.kde.custom.dark" && -n "$base_dark" ]]; then
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
                    fi
                    sudo rm -rf "$_global_path"
                done
            done
        done
    fi

    # Restore Flatpak overrides (must happen before config file removal)
    if command -v flatpak &>/dev/null; then
        local flatpak_csv=""
        [[ -f "$CONFIG_FILE" ]] && flatpak_csv=$(grep "^FLATPAK_PREV_OVERRIDES=" "$CONFIG_FILE" 2>/dev/null | cut -d= -f2-) || true
        if [[ -n "$flatpak_csv" ]]; then
            IFS=',' read -ra fp_entries <<< "$flatpak_csv"
            for entry in "${fp_entries[@]}"; do
                local var="${entry%%=*}" old_val="${entry#*=}"
                if [[ -n "$old_val" ]]; then
                    flatpak override --user --env="${var}=${old_val}" 2>/dev/null || true
                else
                    flatpak override --user --unset-env="$var" 2>/dev/null || true
                fi
            done
        elif [[ -f "$CONFIG_FILE" ]] && grep -qE "^GTK_(LIGHT|DARK)=.+" "$CONFIG_FILE" 2>/dev/null; then
            # Fallback for installs before tracking (only if gloam configured GTK themes)
            local flatpak_overrides="${HOME}/.local/share/flatpak/overrides/global"
            if [[ -f "$flatpak_overrides" ]] && grep -q "GTK_THEME" "$flatpak_overrides" 2>/dev/null; then
                flatpak override --user --unset-env=GTK_THEME 2>/dev/null || true
                flatpak override --user --unset-env=GTK_ICON_THEME 2>/dev/null || true
                flatpak override --user --unset-env=QT_STYLE_OVERRIDE 2>/dev/null || true
            fi
        fi
    fi

    # Remove config and log files
    [[ -f "$CONFIG_FILE" ]] && { rm "$CONFIG_FILE"; _remove_print "Configuration (~/.config/gloam.conf)"; } || true
    [[ -f "$LOG_FILE" ]] && { rm "$LOG_FILE"; _remove_print "Log file"; } || true

    # Remove service files
    local local_service="${HOME}/.config/systemd/user/${SERVICE_NAME}.service"
    [[ -f "$local_service" ]] && { rm "$local_service"; _remove_print "User service"; } || true
    [[ -L "$global_service_link" ]] && { sudo rm "$global_service_link"; _remove_print "Global service autostart"; } || true
    [[ -f "$global_service" ]] && { sudo rm "$global_service"; _remove_print "Global service (/etc/systemd/user/gloam.service)"; } || true

    # Remove CLI
    local local_cli="${HOME}/.local/bin/gloam"
    [[ -f "$local_cli" ]] && { rm "$local_cli"; _remove_print "CLI (~/.local/bin/gloam)"; }
    [[ -f "$global_cli" ]] && { sudo rm "$global_cli"; _remove_print "Global CLI (/usr/local/bin/gloam)"; }

    # Remove SDDM sudoers rule and wrapper script
    [[ -f /etc/sudoers.d/gloam-sddm ]] && { sudo rm /etc/sudoers.d/gloam-sddm; _remove_print "SDDM theme sudoers rule"; }
    [[ -f /etc/sudoers.d/gloam-sddm-bg ]] && { sudo rm /etc/sudoers.d/gloam-sddm-bg; _remove_print "SDDM background sudoers rule"; }
    [[ -f /etc/sudoers.d/gloam-patch ]] && { sudo rm /etc/sudoers.d/gloam-patch; _remove_print "Patch install sudoers rule"; }
    [[ -d /usr/local/lib/gloam ]] && { sudo rm -rf /usr/local/lib/gloam; _remove_print "SDDM background helper"; }

    # Remove plasmoid, shortcut, and custom themes
    if remove_plasmoid; then _remove_print "Panel widget"; fi
    if remove_shortcut; then _remove_print "Keyboard shortcut (Meta+Shift+L)"; fi
    if remove_custom_themes; then _remove_print "Custom themes (org.kde.custom.light/dark)"; fi
    if remove_wallpaper_packs; then _remove_print "Wallpaper pack"; fi

    # Remove system defaults for new users (only files/dirs gloam created)
    local skel_files_csv="" skel_dirs_csv=""
    if [[ -f "$GLOBAL_INSTALL_MARKER" ]]; then
        skel_files_csv=$(grep "^skel_files_created=" "$GLOBAL_INSTALL_MARKER" 2>/dev/null | cut -d= -f2-) || true
        skel_dirs_csv=$(grep "^skel_dirs_created=" "$GLOBAL_INSTALL_MARKER" 2>/dev/null | cut -d= -f2-) || true
    fi

    local skel_removed=false
    if [[ -n "$skel_files_csv" ]]; then
        # Tracked install: only remove files gloam created
        IFS=',' read -ra created_files <<< "$skel_files_csv"
        for cfg in "${created_files[@]}"; do
            [[ -f "/etc/skel/.config/${cfg}" ]] && { sudo rm "/etc/skel/.config/${cfg}"; skel_removed=true; }
        done
    else
        # No skel tracking (legacy install or set_system_defaults wasn't used): remove gloam.conf only
        [[ -f "$skel_config" ]] && { sudo rm "$skel_config"; skel_removed=true; }
    fi

    if [[ -n "$skel_dirs_csv" ]]; then
        IFS=',' read -ra created_dirs <<< "$skel_dirs_csv"
        for dir in "${created_dirs[@]}"; do
            [[ -d "/etc/skel/.local/share/${dir}" ]] && { sudo rm -rf "/etc/skel/.local/share/${dir}"; skel_removed=true; }
        done
    fi
    [[ "$skel_removed" == true ]] && _remove_print "System defaults (/etc/skel)"

    # Remove/restore keys gloam set in /etc/xdg/kdeglobals
    local xdg_removed=false
    if [[ -f /etc/xdg/kdeglobals && -f "$GLOBAL_INSTALL_MARKER" ]]; then
        # Delete keys that gloam added (didn't exist before)
        local added_keys_csv
        added_keys_csv=$(grep "^xdg_keys_added=" "$GLOBAL_INSTALL_MARKER" 2>/dev/null | cut -d= -f2-)
        if [[ -n "$added_keys_csv" ]]; then
            IFS=',' read -ra added_keys <<< "$added_keys_csv"
            for entry in "${added_keys[@]}"; do
                local group="${entry%%:*}" key="${entry#*:}"
                sudo kwriteconfig6 --file /etc/xdg/kdeglobals --group "$group" --key "$key" --delete 2>/dev/null || true
                xdg_removed=true
            done
        fi

        # Restore keys that gloam overwrote to their previous values
        local overwritten_csv
        overwritten_csv=$(grep "^xdg_keys_overwritten=" "$GLOBAL_INSTALL_MARKER" 2>/dev/null | cut -d= -f2-)
        if [[ -n "$overwritten_csv" ]]; then
            IFS=',' read -ra overwritten_keys <<< "$overwritten_csv"
            for entry in "${overwritten_keys[@]}"; do
                local gk="${entry%%=*}" old_val="${entry#*=}"
                local group="${gk%%:*}" key="${gk#*:}"
                sudo kwriteconfig6 --file /etc/xdg/kdeglobals --group "$group" --key "$key" "$old_val" 2>/dev/null || true
                xdg_removed=true
            done
        fi
    fi
    [[ "$xdg_removed" == true ]] && _remove_print "System theme defaults (/etc/xdg/kdeglobals)"

    # Remove keyboard shortcut from /etc/xdg/kglobalshortcutsrc
    if [[ -f "$xdg_shortcuts" ]] && grep -q "$SHORTCUT_ID" "$xdg_shortcuts" 2>/dev/null; then
        sudo kwriteconfig6 --file "$xdg_shortcuts" --group "services" --group "$SHORTCUT_ID" --key "_launch" --delete
        _remove_print "Global keyboard shortcut config"
    fi

    # Unmask splash service in case we masked it
    if systemctl --user is-enabled plasma-ksplash.service 2>&1 | grep -q "masked"; then
        systemctl --user unmask plasma-ksplash.service 2>/dev/null || true
    fi

    # Remove global installation marker
    [[ -f "$GLOBAL_INSTALL_MARKER" ]] && { sudo rm "$GLOBAL_INSTALL_MARKER"; _remove_print "Installation marker"; }

    systemctl --user daemon-reload
    _spinner_stop

    # Remove Plasma patches (before GLOBAL_SCRIPTS_DIR, which contains patch sources needed for rebuild)
    if remove_patches; then
        _remove_print "Plasma patches"
    fi

    # Remove global scripts (after patches, which may need files from this directory)
    [[ -d "$GLOBAL_SCRIPTS_DIR" ]] && { sudo rm -rf "$GLOBAL_SCRIPTS_DIR"; _remove_print "Custom scripts"; }

    echo ""
    if (( _removed_count > 0 )); then
        msg_ok "Remove complete."
        NEEDS_LOGOUT=true
        prompt_logout_if_needed
    else
        msg_muted "Nothing to remove."
    fi
}

do_status() {
    msg_header "Version"
    echo "  $(gum style --foreground "$CLR_PRIMARY" "gloam v${GLOAM_VERSION}")"
    
    # Check for updates
    local api_url="https://api.github.com/repos/${GLOAM_REPO}/releases/latest"
    local response
    response=$(curl -fsSL --max-time 3 "$api_url" 2>/dev/null) || true
    if [[ -n "$response" ]]; then
        local remote_tag
        remote_tag=$(printf '%s' "$response" | grep '"tag_name"' | sed 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
        if [[ -n "$remote_tag" ]]; then
            local remote_version="${remote_tag#v}"
            local newest
            newest=$(printf '%s\n%s\n' "$GLOAM_VERSION" "$remote_version" | sort -V | tail -n1)
            if [[ "$newest" != "$GLOAM_VERSION" ]]; then
                echo "  $(gum style --foreground "$CLR_WARNING" "Update available: v${remote_version}")"
            else
                echo "  $(gum style --foreground "$CLR_SUCCESS" "Up to date")"
            fi
        fi
    fi

    msg_header "Service status"
    if systemctl --user is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        echo "    Running: $(gum style --foreground "$CLR_SUCCESS" "yes")"
    else
        echo "    Running: $(gum style --foreground "$CLR_ERROR" "no")"
    fi
    if systemctl --user is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then
        echo "    Enabled: $(gum style --foreground "$CLR_SUCCESS" "yes")"
    else
        echo "    Enabled: $(gum style --foreground "$CLR_ERROR" "no")"
    fi

    msg_header "Installation locations"

    status_check "CLI" "/usr/local/bin/gloam" "${HOME}/.local/bin/gloam" -x
    status_check "Service" "/etc/systemd/user/${SERVICE_NAME}.service" "${HOME}/.config/systemd/user/${SERVICE_NAME}.service" -f
    status_check "Panel widget" "/usr/share/plasma/plasmoids/${PLASMOID_ID}" "${HOME}/.local/share/plasma/plasmoids/${PLASMOID_ID}" -d
    status_check "Keyboard shortcut" "/usr/share/applications/gloam-toggle.desktop" "${HOME}/.local/share/applications/gloam-toggle.desktop" -f "Installed (Meta+Shift+L)"
    status_check "Custom (Light)" "/usr/share/plasma/look-and-feel/org.kde.custom.light" "${HOME}/.local/share/plasma/look-and-feel/org.kde.custom.light" -d
    status_check "Custom (Dark)" "/usr/share/plasma/look-and-feel/org.kde.custom.dark" "${HOME}/.local/share/plasma/look-and-feel/org.kde.custom.dark" -d

    # Check if any gloam component is installed
    local has_install=false
    [[ -f "/usr/local/bin/gloam" ]] && has_install=true
    [[ -f "${HOME}/.local/bin/gloam" ]] && has_install=true
    [[ -f "/etc/systemd/user/${SERVICE_NAME}.service" ]] && has_install=true
    [[ -f "${HOME}/.config/systemd/user/${SERVICE_NAME}.service" ]] && has_install=true
    [[ -d "/usr/share/plasma/plasmoids/${PLASMOID_ID}" ]] && has_install=true
    [[ -d "${HOME}/.local/share/plasma/plasmoids/${PLASMOID_ID}" ]] && has_install=true
    [[ -f "/usr/share/applications/gloam-toggle.desktop" ]] && has_install=true
    [[ -f "${HOME}/.local/share/applications/gloam-toggle.desktop" ]] && has_install=true
    [[ -d "/usr/share/plasma/look-and-feel/org.kde.custom.light" ]] && has_install=true
    [[ -d "${HOME}/.local/share/plasma/look-and-feel/org.kde.custom.light" ]] && has_install=true
    [[ -f "$CONFIG_FILE" ]] && has_install=true

    if [[ "$has_install" == true ]]; then
        # Show bundled assets in custom themes
        local custom_light_global="/usr/share/plasma/look-and-feel/org.kde.custom.light"
        local custom_light_local="${HOME}/.local/share/plasma/look-and-feel/org.kde.custom.light"
        local custom_dark_global="/usr/share/plasma/look-and-feel/org.kde.custom.dark"
        local custom_dark_local="${HOME}/.local/share/plasma/look-and-feel/org.kde.custom.dark"
        local custom_theme_dir=""
        [[ -d "$custom_light_global" ]] && custom_theme_dir="$custom_light_global"
        [[ -z "$custom_theme_dir" && -d "$custom_light_local" ]] && custom_theme_dir="$custom_light_local"

        if [[ -n "$custom_theme_dir" ]]; then
            local bundled_assets=()
            [[ -d "${custom_theme_dir}/contents/colors" ]] && bundled_assets+=("Colors")
            [[ -d "${custom_theme_dir}/contents/icons" ]] && bundled_assets+=("Icons")
            [[ -d "${custom_theme_dir}/contents/cursors" ]] && bundled_assets+=("Cursors")
            [[ -d "${custom_theme_dir}/contents/desktoptheme" ]] && bundled_assets+=("Plasma style")
            [[ -d "${custom_theme_dir}/contents/wallpapers" ]] && bundled_assets+=("Wallpapers")
            [[ -d "${custom_theme_dir}/contents/sddm" ]] && bundled_assets+=("SDDM background")

            # Check dark theme sddm too
            local custom_dark_dir=""
            [[ -d "$custom_dark_global" ]] && custom_dark_dir="$custom_dark_global"
            [[ -z "$custom_dark_dir" && -d "$custom_dark_local" ]] && custom_dark_dir="$custom_dark_local"
            if [[ -n "$custom_dark_dir" && -d "${custom_dark_dir}/contents/sddm" ]] && ! [[ " ${bundled_assets[*]} " == *" SDDM background "* ]]; then
                bundled_assets+=("SDDM background")
            fi

            if [[ ${#bundled_assets[@]} -gt 0 ]]; then
                local joined
                joined=$(IFS="  "; echo "${bundled_assets[*]}")
                echo "  $(gum style --foreground "$CLR_MUTED" "•") Bundled assets: $(gum style --foreground "$CLR_SUCCESS" "$joined")"
            else
                echo "  $(gum style --foreground "$CLR_MUTED" "•") Bundled assets: $(gum style --foreground "$CLR_WARNING" "None")"
            fi
        fi

        # Check if panel layout is in /etc/skel for new users
        local skel_panel="/etc/skel/.config/plasma-org.kde.plasma.desktop-appletsrc"
        if [[ -f "$skel_panel" ]]; then
            echo "  $(gum style --foreground "$CLR_MUTED" "•") Panel layout: $(gum style --foreground "$CLR_SUCCESS" "In /etc/skel")"
        else
            echo "  $(gum style --foreground "$CLR_MUTED" "•") Panel layout: $(gum style --foreground "$CLR_WARNING" "Not in /etc/skel")"
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
            echo "  $(gum style --foreground "$CLR_MUTED" "•") New user setup: $(gum style --foreground "$CLR_SUCCESS" "Fully configured")"
        elif [[ "$sys_defaults_set" == true || -f "$skel_config" || -L "$service_link" ]]; then
            echo "  $(gum style --foreground "$CLR_MUTED" "•") New user setup: $(gum style --foreground "$CLR_WARNING" "Partially configured")"
        else
            echo "  $(gum style --foreground "$CLR_MUTED" "•") New user setup: $(gum style --foreground "$CLR_WARNING" "Not configured")"
        fi
    fi

    local current_laf
    current_laf=$(kreadconfig6 --file kdeglobals --group KDE --key LookAndFeelPackage 2>/dev/null)
    local laf_light laf_dark
    laf_light=$(kreadconfig6 --file kdeglobals --group KDE --key DefaultLightLookAndFeel 2>/dev/null)
    laf_dark=$(kreadconfig6 --file kdeglobals --group KDE --key DefaultDarkLookAndFeel 2>/dev/null)

    msg_header "Current mode"
    if [[ "$current_laf" == "$laf_light" ]]; then
        echo "  ☀️ Light ($(get_friendly_name laf "$current_laf") - $current_laf)"
    elif [[ "$current_laf" == "$laf_dark" ]]; then
        echo "  🌙 Dark ($(get_friendly_name laf "$current_laf") - $current_laf)"
    else
        echo "  Unknown ($current_laf)"
    fi

    if [[ -f "$CONFIG_FILE" ]]; then
        msg_header "Configuration"
        msg_muted "$CONFIG_FILE"
        # shellcheck source=/dev/null
        source "$CONFIG_FILE"
        echo ""
        print_config_summary "$LAF_LIGHT" "$LAF_DARK" true
        if [[ -n "${WALLPAPER_BASE:-}" ]]; then
            echo "    Wallpaper base: $(gum style --foreground "$CLR_SUCCESS" "${WALLPAPER_BASE}")"
        fi
        
        # Show SDDM themes if configured
        if [[ -n "${SDDM_LIGHT:-}" || -n "${SDDM_DARK:-}" ]]; then
            local em_dash
            em_dash=$(gum style --foreground "$CLR_MUTED" "—")
            msg_header "SDDM Themes"
            echo "  ☀️ $([[ -n "${SDDM_LIGHT:-}" ]] && get_friendly_name sddm "${SDDM_LIGHT}" || echo "$em_dash")"
            echo "  🌙 $([[ -n "${SDDM_DARK:-}" ]] && get_friendly_name sddm "${SDDM_DARK}" || echo "$em_dash")"
        fi
        
        # Show push users if configured
        if [[ -f "$GLOBAL_INSTALL_MARKER" ]]; then
            local push_users=""
            while IFS=: read -r username _ uid _ _ home _; do
                [[ "$uid" -ge 1000 && "$uid" -lt 60000 && "$home" == /home/* && -d "$home" && "$username" != "$USER" ]] && push_users+="${username}, "
            done < /etc/passwd
            push_users="${push_users%, }"
            if [[ -n "$push_users" ]]; then
                msg_header "Push Targets"
                echo "  $(gum style --foreground "$CLR_MUTED" "•") ${push_users}"
            fi
        fi
        
        # Show last theme switch from log
        if [[ -f "$LOG_FILE" ]]; then
            local last_switch
            last_switch=$(grep "Applying theme:" "$LOG_FILE" 2>/dev/null | tail -1 | sed 's/\[//' | sed 's/\].*//')
            if [[ -n "$last_switch" ]]; then
                msg_header "Last Switch"
                echo "  $(gum style --foreground "$CLR_MUTED" "•") ${last_switch}"
            fi
        fi
    fi
}

show_configure_help() {
    echo "$(gum style --foreground "$CLR_MUTED" "Usage:") $(gum style --bold "gloam configure") $(gum style --foreground "$CLR_MUTED" "[options]")"
    echo ""
    gum style --foreground "$CLR_MUTED" --italic \
        "  Scan themes, save config, enable systemd service, and optionally install helper tools." \
        "  With no options, runs the full configuration wizard." \
        "  With options, only reconfigures the specified components."
    echo ""
    echo "$(gum style --bold --foreground "$CLR_PRIMARY" "Options:")"
    echo "  $(gum style --bold --foreground "$CLR_SECONDARY" -- "-c, --colors")        Configure color schemes only"
    echo "  $(gum style --bold --foreground "$CLR_SECONDARY" -- "-k, --kvantum")       Configure Kvantum themes only"
    echo "  $(gum style --bold --foreground "$CLR_SECONDARY" -- "-a, --appstyle")      Configure application style (Qt widget style)"
    echo "  $(gum style --bold --foreground "$CLR_SECONDARY" -- "-g, --gtk")           Configure GTK themes only"
    echo "  $(gum style --bold --foreground "$CLR_SECONDARY" -- "-p, --style")         Configure Plasma styles only"
    echo "  $(gum style --bold --foreground "$CLR_SECONDARY" -- "-d, --decorations")   Configure window decorations only"
    echo "  $(gum style --bold --foreground "$CLR_SECONDARY" -- "-i, --icons")         Configure icon themes only"
    echo "  $(gum style --bold --foreground "$CLR_SECONDARY" -- "-C, --cursors")       Configure cursor themes only"
    echo "  $(gum style --bold --foreground "$CLR_SECONDARY" -- "-S, --splash")        Configure splash screens only"
    echo "  $(gum style --bold --foreground "$CLR_SECONDARY" -- "-l, --login")         Configure login screen (SDDM) themes"
    echo "  $(gum style --bold --foreground "$CLR_SECONDARY" -- "-W, --wallpaper")     Configure day/night wallpapers"
    echo "  $(gum style --bold --foreground "$CLR_SECONDARY" -- "-o, --konsole")       Configure Konsole profiles only"
    echo "  $(gum style --bold --foreground "$CLR_SECONDARY" -- "-s, --script")        Configure custom scripts only"
    echo "  $(gum style --bold --foreground "$CLR_SECONDARY" -- "-w, --widget")        Install/reinstall panel widget"
    echo "  $(gum style --bold --foreground "$CLR_SECONDARY" -- "-K, --shortcut")      Install/reinstall keyboard shortcut (Meta+Shift+L)"
    echo "  $(gum style --bold --foreground "$CLR_SECONDARY" -- "-P, --patches")      Install/reinstall Plasma patches"
    echo "  $(gum style --bold --foreground "$CLR_SECONDARY" -- "-I, --import") $(gum style --foreground "$CLR_MUTED" "<file>")   Import an existing gloam.conf and skip interactive setup"
    echo "  $(gum style --bold --foreground "$CLR_SECONDARY" -- "-e, --export") $(gum style --foreground "$CLR_MUTED" "<dir>")    Export current gloam.conf to a directory"
    echo ""
    echo "$(gum style --bold --foreground "$CLR_PRIMARY" "Panel Widget:")"
    gum style --foreground "$CLR_MUTED" --italic \
        "  During configuration, if you install the command globally (~/.local/bin)," \
        "  you'll be offered to install a Light/Dark Mode Toggle panel widget. This adds" \
        "  a sun/moon button to your panel for quick theme switching."
    echo ""
    echo "$(gum style --bold --foreground "$CLR_PRIMARY" "Examples:")"
    echo "  $(gum style --bold "gloam configure")              Configure all theme options"
    echo "  $(gum style --bold "gloam configure -k -i")        Configure only Kvantum and icon themes"
    echo "  $(gum style --bold "gloam configure --splash")     Configure only splash screens"
    echo "  $(gum style --bold "gloam configure --export") $(gum style --foreground "$CLR_MUTED" "/path/to/dir")"
    echo "                                Export config for use on another machine/user"
    echo "  $(gum style --bold "gloam configure --import") $(gum style --foreground "$CLR_MUTED" "/path/to/gloam.conf")"
    echo "                                Import config from another machine/user"
    echo "  $(gum style --bold "gloam configure --patches")   Reinstall Plasma patches after system update"
}

show_banner() {
    gum style \
        --foreground "$CLR_PRIMARY" \
        --bold \
        --padding "0 1" \
        --margin "1 0 1 0" \
        "$(cat <<'BANNER'
           ░██
           ░██
 ░████████ ░██  ░███████   ░██████   ░█████████████
░██    ░██ ░██ ░██    ░██       ░██  ░██   ░██   ░██
░██    ░██ ░██ ░██    ░██  ░███████  ░██   ░██   ░██
░██   ░███ ░██ ░██    ░██ ░██   ░██  ░██   ░██   ░██
 ░█████░██ ░██  ░███████   ░█████░██ ░██   ░██   ░██
       ░██
 ░███████
BANNER
)"
    gum style --foreground "$CLR_MUTED" --italic \
        " Syncs Kvantum, GTK, and custom scripts with Plasma 6's" \
        " native light/dark (day/night) theme switching — and more."
    echo ""
}

show_help() {
    echo "$(gum style --foreground "$CLR_MUTED" "Usage:") $(gum style --bold "gloam") $(gum style --foreground "$CLR_MUTED" "<command> [options]")"
    echo ""
    echo "$(gum style --bold --foreground "$CLR_PRIMARY" "Commands:")"
    echo "  $(gum style --bold --foreground "$CLR_SECONDARY" "configure")    Scan themes, save config, enable systemd service"
    echo "  $(gum style --bold --foreground "$CLR_SECONDARY" "watch")        Start the theme monitoring loop (foreground)"
    echo "  $(gum style --bold --foreground "$CLR_SECONDARY" "light")        Switch to Light mode (and sync sub-themes)"
    echo "  $(gum style --bold --foreground "$CLR_SECONDARY" "dark")         Switch to Dark mode (and sync sub-themes)"
    echo "  $(gum style --bold --foreground "$CLR_SECONDARY" "toggle")       Cycle between Light, Dark, and Auto mode"
    echo "  $(gum style --bold --foreground "$CLR_SECONDARY" "auto")         Switch to Auto mode (follow system day/night schedule)"
    echo "  $(gum style --bold --foreground "$CLR_SECONDARY" "remove")       Stop service, remove all installed files and widget"
    echo "  $(gum style --bold --foreground "$CLR_SECONDARY" "status")       Show service status and current configuration"
    echo "  $(gum style --bold --foreground "$CLR_SECONDARY" "update")       Check for and install the latest version"
    echo "  $(gum style --bold --foreground "$CLR_SECONDARY" "version")      Show the installed version"
    echo "  $(gum style --bold --foreground "$CLR_SECONDARY" "help")         Show this help message"
    echo ""
    echo "Run '$(gum style --bold "gloam configure --help")' for detailed configuration options."
}

# --- MAIN ENTRY POINT ---------------------------------------------------------

check_dependencies

# Show banner only for interactive commands (--no-banner used by internal re-exec)
case "${1:-}" in
    watch|light|dark|toggle|auto) ;;
    --no-banner) shift ;;
    *) show_banner ;;
esac

case "${1:-}" in
    configure) do_configure "$@" ;;
    watch)     do_watch ;;
    light)     do_light ;;
    dark)      do_dark ;;
    toggle)    do_toggle ;;
    auto)      do_auto ;;
    remove)    do_remove ;;
    status)    do_status ;;
    update)    do_update ;;
    version|--version|-v) echo ""; echo "gloam $(gum style --foreground "$CLR_PRIMARY" "v${GLOAM_VERSION}")" ;;
    ""|help|-h|--help) show_help ;;
    *)
        error "Unknown command: ${1:-}"
        echo "$(gum style --foreground "$CLR_MUTED" "Usage:") $(gum style --bold "gloam") $(gum style --foreground "$CLR_MUTED" "<command> [options]")"
        echo "Run '$(gum style --bold "gloam help")' for more information."
        exit 1
        ;;
esac
exit 0
}
