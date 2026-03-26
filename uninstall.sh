#!/usr/bin/env bash
set -euo pipefail

# nullbot uninstaller
# Reverses everything install.sh did.

INSTALL_DIR="${NULLBOT_INSTALL_DIR:-/usr/local/bin}"
CONFIG_DIR="$HOME/.nullbot"
CW_CONFIG_DIR="$HOME/.chainwatch"

info()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33mwarning:\033[0m %s\n' "$*"; }

main() {
    echo ""
    echo "  nullbot uninstaller"
    echo "  ==================="
    echo ""

    local sudo_prefix=""
    if [ "$(id -u)" != "0" ]; then
        sudo_prefix="sudo"
    fi

    # Phase 1: stop services
    if command -v systemctl &>/dev/null; then
        info "Stopping services"
        for svc in chainwatch-enforce nullbot pastewatch-proxy pastewatch-hiveram; do
            if systemctl is-active "${svc}.service" &>/dev/null 2>&1; then
                $sudo_prefix systemctl stop "${svc}.service"
                info "  stopped ${svc}"
            fi
        done
    fi

    # Phase 2: disable and remove systemd units
    if command -v systemctl &>/dev/null; then
        info "Removing systemd units"
        for svc in chainwatch-enforce nullbot pastewatch-proxy pastewatch-hiveram; do
            local unit="/etc/systemd/system/${svc}.service"
            if [ -f "$unit" ]; then
                $sudo_prefix systemctl disable "${svc}.service" 2>/dev/null || true
                $sudo_prefix rm -f "$unit"
                info "  removed ${svc}.service"
            fi
        done
        $sudo_prefix systemctl daemon-reload
    fi

    # Phase 3: remove logrotate configs
    info "Removing logrotate configs"
    for cfg in chainwatch-enforce pastewatch-proxy pastewatch-hiveram; do
        if [ -f "/etc/logrotate.d/${cfg}" ]; then
            $sudo_prefix rm -f "/etc/logrotate.d/${cfg}"
            info "  removed ${cfg}"
        fi
    done

    # Phase 4: unlock and remove binaries
    info "Removing binaries"
    for bin in chainwatch nullbot pastewatch-cli; do
        local path="${INSTALL_DIR}/${bin}"
        if [ -f "$path" ]; then
            # Remove immutable flag if set
            if command -v chattr &>/dev/null; then
                $sudo_prefix chattr -i "$path" 2>/dev/null || true
            fi
            $sudo_prefix rm -f "$path"
            info "  removed ${path}"
        fi
    done

    # Phase 5: remove config (ask first)
    echo ""
    printf "Remove config directories? (${CONFIG_DIR}, ${CW_CONFIG_DIR}) [y/N]: "
    read -r remove_config
    if [ "${remove_config:-n}" = "y" ] || [ "${remove_config:-n}" = "Y" ]; then
        rm -rf "$CONFIG_DIR"
        rm -rf "$CW_CONFIG_DIR"
        info "Removed config directories"
    else
        info "Config directories preserved"
    fi

    # Phase 6: remove logs (ask first)
    printf "Remove log directories? (/var/log/chainwatch, /var/log/pastewatch) [y/N]: "
    read -r remove_logs
    if [ "${remove_logs:-n}" = "y" ] || [ "${remove_logs:-n}" = "Y" ]; then
        $sudo_prefix rm -rf /var/log/chainwatch /var/log/pastewatch
        info "Removed log directories"
    else
        info "Log directories preserved"
    fi

    # Phase 7: clean shell profile
    info "Cleaning shell profile"
    local profile
    if [ -f "$HOME/.zshrc" ]; then
        profile="$HOME/.zshrc"
    elif [ -f "$HOME/.bashrc" ]; then
        profile="$HOME/.bashrc"
    elif [ -f "$HOME/.bash_profile" ]; then
        profile="$HOME/.bash_profile"
    else
        profile=""
    fi

    if [ -n "$profile" ]; then
        # Remove nullbot-related lines
        local tmpfile
        tmpfile="$(mktemp)"
        grep -v 'nullbot\|workledger/api-key' "$profile" > "$tmpfile" 2>/dev/null || true
        if ! diff -q "$profile" "$tmpfile" &>/dev/null; then
            cp "$tmpfile" "$profile"
            info "  Cleaned ${profile}"
        fi
        rm -f "$tmpfile"
    fi

    echo ""
    info "Uninstall complete."
    info "Workledger secrets (~/.workledger/) were NOT removed — delete manually if needed."
}

main "$@"
