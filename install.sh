#!/usr/bin/env bash
set -euo pipefail

# nullbot installer
# Usage: curl -fsSL https://raw.githubusercontent.com/ppiankov/nullbot-dist/main/install.sh | bash

REPO="ppiankov/nullbot-dist"
INSTALL_DIR="${NULLBOT_INSTALL_DIR:-/usr/local/bin}"
CONFIG_DIR="$HOME/.nullbot"
CW_CONFIG_DIR="$HOME/.chainwatch"
WL_CONFIG_DIR="$HOME/.workledger"

# --- helpers ---

info()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33mwarning:\033[0m %s\n' "$*"; }
error() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

detect_platform() {
    local os arch
    os="$(uname -s | tr '[:upper:]' '[:lower:]')"
    arch="$(uname -m)"

    case "$os" in
        darwin) os="darwin" ;;
        linux)  os="linux"  ;;
        *)      error "Unsupported OS: $os" ;;
    esac

    case "$arch" in
        x86_64|amd64)  arch="amd64" ;;
        arm64|aarch64) arch="arm64" ;;
        *)             error "Unsupported architecture: $arch" ;;
    esac

    echo "${os}_${arch}"
}

latest_version() {
    local version
    version=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" 2>/dev/null \
        | grep '"tag_name"' | sed 's/.*"v\(.*\)".*/\1/' || true)
    if [ -z "$version" ]; then
        error "Could not determine latest version. Check https://github.com/${REPO}/releases"
    fi
    echo "$version"
}

download_binary() {
    local name="$1" platform="$2" version="$3" tmpdir="$4"
    local filename="${name}-${platform}"
    local url="https://github.com/${REPO}/releases/download/v${version}/${filename}"

    info "  Downloading ${name} v${version} (${platform})"
    curl -fsSL -o "${tmpdir}/${name}" "$url" \
        || error "Download failed: ${url}"
    chmod +x "${tmpdir}/${name}"
}

install_binary() {
    local name="$1" tmpdir="$2"
    if [ -w "$INSTALL_DIR" ]; then
        mv "${tmpdir}/${name}" "${INSTALL_DIR}/${name}"
    else
        info "  Need sudo to install to ${INSTALL_DIR}"
        sudo mv "${tmpdir}/${name}" "${INSTALL_DIR}/${name}"
    fi
    info "  Installed ${INSTALL_DIR}/${name}"
}

# --- phase 1: chainwatch ---

install_chainwatch() {
    info "Phase 1: Installing chainwatch (policy gate)"

    local platform version tmpdir
    platform="$(detect_platform)"
    version="$(latest_version)"
    tmpdir="$(mktemp -d)"

    download_binary "chainwatch" "$platform" "$version" "$tmpdir"
    install_binary "chainwatch" "$tmpdir"
    rm -rf "$tmpdir"

    info "Bootstrapping chainwatch policy config"
    if [ -d "$CW_CONFIG_DIR" ]; then
        info "  Config already exists at ${CW_CONFIG_DIR}"
    else
        "${INSTALL_DIR}/chainwatch" init --profile clawbot 2>/dev/null \
            || warn "  chainwatch init failed — run manually: chainwatch init --profile clawbot"
    fi
}

# --- phase 2: nullbot ---

install_nullbot() {
    info "Phase 2: Installing nullbot (fleet observer)"

    local platform version tmpdir
    platform="$(detect_platform)"
    version="$(latest_version)"
    tmpdir="$(mktemp -d)"

    download_binary "nullbot" "$platform" "$version" "$tmpdir"
    install_binary "nullbot" "$tmpdir"
    rm -rf "$tmpdir"
}

# --- phase 3: pastewatch ---

PW_REPO="ppiankov/pastewatch"

pastewatch_asset_name() {
    local platform="$1"
    case "$platform" in
        darwin_arm64)  echo "pastewatch-cli" ;;
        darwin_amd64)  echo "pastewatch-cli" ;;  # universal binary
        linux_amd64)   echo "pastewatch-cli-linux-amd64" ;;
        linux_arm64)   echo "pastewatch-cli-linux-arm64" ;;
        *)             echo "" ;;
    esac
}

latest_pastewatch_version() {
    local version
    version=$(curl -fsSL "https://api.github.com/repos/${PW_REPO}/releases/latest" 2>/dev/null \
        | grep '"tag_name"' | sed 's/.*"v\(.*\)".*/\1/' || true)
    echo "$version"
}

install_pastewatch() {
    info "Phase 3: Installing pastewatch (secret redaction)"

    local platform asset_name pw_version tmpdir
    platform="$(detect_platform)"
    asset_name="$(pastewatch_asset_name "$platform")"

    if [ -z "$asset_name" ]; then
        warn "  pastewatch not available for ${platform} — skipping"
        return 0
    fi

    pw_version="$(latest_pastewatch_version)"
    if [ -z "$pw_version" ]; then
        warn "  Could not determine pastewatch version — skipping"
        return 0
    fi

    tmpdir="$(mktemp -d)"
    local url="https://github.com/${PW_REPO}/releases/download/v${pw_version}/${asset_name}"

    info "  Downloading pastewatch-cli v${pw_version} (${platform})"
    curl -fsSL -o "${tmpdir}/pastewatch-cli" "$url" \
        || { warn "  Download failed — skipping pastewatch"; rm -rf "$tmpdir"; return 0; }
    chmod +x "${tmpdir}/pastewatch-cli"

    install_binary "pastewatch-cli" "$tmpdir"
    rm -rf "$tmpdir"
}

# --- phase 4: nullbot config ---

configure_nullbot() {
    info "Phase 4: Configuring nullbot"
    mkdir -p "$CONFIG_DIR"

    local config_file="${CONFIG_DIR}/config.yaml"

    if [ -f "$config_file" ]; then
        info "  Config already exists at ${config_file}"
        return
    fi

    # Hiveram URL
    local hiveram_url="https://workledger.fly.dev/api/v1"
    echo ""
    echo "Enter Hiveram API URL (press Enter for default)."
    printf "URL [${hiveram_url}]: "
    read -r custom_url
    if [ -n "$custom_url" ]; then
        hiveram_url="$custom_url"
    fi

    cat > "$config_file" << EOF
workledger:
  url: ${hiveram_url}
  api_key_env: WORKLEDGER_API_KEY
EOF
    info "  Config written to ${config_file}"

    # Workledger API key
    mkdir -p "$WL_CONFIG_DIR"
    local env_file="${WL_CONFIG_DIR}/api-key.env"

    if [ -f "$env_file" ]; then
        info "  Workledger secrets already exist at ${env_file}"
    else
        echo ""
        echo "Enter your Hiveram API key (WORKLEDGER_API_KEY)."
        echo "Get one from your Hiveram dashboard or team admin."
        printf "API key: "
        read -r apikey
        if [ -n "$apikey" ]; then
            echo "export WORKLEDGER_API_KEY='${apikey}'" > "$env_file"
            chmod 600 "$env_file"
            info "  API key saved to ${env_file}"
        else
            warn "  Skipped API key — nullbot won't connect to Hiveram"
        fi
    fi

    # Add to shell profile if not already there
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
        local source_line='[ -f ~/.workledger/api-key.env ] && source ~/.workledger/api-key.env'
        if ! grep -qF "$source_line" "$profile" 2>/dev/null; then
            echo "" >> "$profile"
            echo "# hiveram / nullbot" >> "$profile"
            echo "$source_line" >> "$profile"
            info "  Added source line to ${profile}"
        fi
    fi
}

# --- phase 4: LLM + pastewatch proxy ---

configure_llm() {
    info "Phase 4: LLM provider + pastewatch proxy (optional — for assisted observation)"
    mkdir -p "$CONFIG_DIR"

    local llm_file="${CONFIG_DIR}/llm.env"

    if [ -f "$llm_file" ]; then
        info "  LLM config already exists at ${llm_file}"
        return
    fi

    echo ""
    echo "Nullbot can use any OpenAI-compatible LLM API for assisted observation."
    echo "Supported: Groq, OpenAI, Anthropic, Azure, OpenRouter, or any compatible endpoint."
    echo "All LLM traffic is routed through pastewatch proxy for secret redaction."
    echo "Without it, nullbot runs in deterministic-only mode (still useful)."
    printf "LLM API key (press Enter to skip): "
    read -r llm_key

    if [ -n "$llm_key" ]; then
        # Ask for upstream LLM URL
        local default_upstream="https://api.groq.com"
        echo ""
        echo "Which LLM provider?"
        echo "  1) Groq        (https://api.groq.com)"
        echo "  2) OpenAI      (https://api.openai.com)"
        echo "  3) Anthropic   (https://api.anthropic.com)"
        echo "  4) OpenRouter  (https://openrouter.ai/api)"
        echo "  5) Custom URL"
        printf "Choice [1]: "
        read -r llm_choice

        local upstream_url
        case "${llm_choice:-1}" in
            1) upstream_url="https://api.groq.com" ;;
            2) upstream_url="https://api.openai.com" ;;
            3) upstream_url="https://api.anthropic.com" ;;
            4) upstream_url="https://openrouter.ai/api" ;;
            5)
                printf "Custom upstream URL: "
                read -r upstream_url
                ;;
            *) upstream_url="$default_upstream" ;;
        esac

        {
            echo "export NULLBOT_LLM_API_KEY='${llm_key}'"
            echo "export NULLBOT_LLM_UPSTREAM='${upstream_url}'"
            echo "export NULLBOT_LLM_BASE_URL='http://127.0.0.1:8443'"
        } > "$llm_file"
        chmod 600 "$llm_file"
        info "  LLM key saved to ${llm_file}"
        info "  Upstream: ${upstream_url} (via pastewatch proxy on :8443)"

        # Add to shell profile
        local profile
        if [ -f "$HOME/.zshrc" ]; then
            profile="$HOME/.zshrc"
        elif [ -f "$HOME/.bashrc" ]; then
            profile="$HOME/.bashrc"
        else
            profile=""
        fi

        if [ -n "$profile" ]; then
            local source_line='[ -f ~/.nullbot/llm.env ] && source ~/.nullbot/llm.env'
            if ! grep -qF "$source_line" "$profile" 2>/dev/null; then
                echo "$source_line" >> "$profile"
                info "  Added LLM source line to ${profile}"
            fi
        fi
    else
        info "  Skipped — nullbot will run in deterministic-only mode"
    fi
}

# --- phase 4b: pastewatch proxy systemd (linux) ---

setup_pastewatch_proxy() {
    if [ "$(uname -s)" != "Linux" ]; then
        return 0
    fi

    if ! command -v pastewatch-cli &>/dev/null; then
        return 0
    fi

    if ! command -v systemctl &>/dev/null; then
        return 0
    fi

    # Only set up if LLM is configured
    if [ ! -f "${CONFIG_DIR}/llm.env" ]; then
        return 0
    fi

    info "  Setting up pastewatch proxy service"

    local systemd_dir="/etc/systemd/system"
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    local proxy_svc="${script_dir}/config/pastewatch-proxy.service"
    local proxy_logrotate="${script_dir}/config/pastewatch-proxy.logrotate"

    if [ ! -f "$proxy_svc" ]; then
        local tmpdir
        tmpdir="$(mktemp -d)"
        local base_url="https://raw.githubusercontent.com/${REPO}/main/config"
        curl -fsSL -o "${tmpdir}/pastewatch-proxy.service" "${base_url}/pastewatch-proxy.service" || { warn "  Failed to download pastewatch-proxy.service"; return 0; }
        curl -fsSL -o "${tmpdir}/pastewatch-proxy.logrotate" "${base_url}/pastewatch-proxy.logrotate" || true
        proxy_svc="${tmpdir}/pastewatch-proxy.service"
        proxy_logrotate="${tmpdir}/pastewatch-proxy.logrotate"
    fi

    local sudo_prefix=""
    if [ "$(id -u)" != "0" ]; then
        sudo_prefix="sudo"
    fi

    # Create log directory
    if [ ! -d /var/log/pastewatch ]; then
        $sudo_prefix mkdir -p /var/log/pastewatch
        info "  Created /var/log/pastewatch"
    fi

    $sudo_prefix cp "$proxy_svc" "${systemd_dir}/pastewatch-proxy.service"
    info "  Installed pastewatch-proxy.service (LLM traffic on :8443)"

    # Hiveram proxy — scans WO payloads for secrets before reaching workledger
    local hiveram_svc="${script_dir}/config/pastewatch-hiveram.service"
    local hiveram_logrotate="${script_dir}/config/pastewatch-hiveram.logrotate"
    if [ ! -f "$hiveram_svc" ]; then
        curl -fsSL -o "${tmpdir}/pastewatch-hiveram.service" "${base_url}/pastewatch-hiveram.service" || true
        curl -fsSL -o "${tmpdir}/pastewatch-hiveram.logrotate" "${base_url}/pastewatch-hiveram.logrotate" || true
        hiveram_svc="${tmpdir}/pastewatch-hiveram.service"
        hiveram_logrotate="${tmpdir}/pastewatch-hiveram.logrotate"
    fi
    if [ -f "$hiveram_svc" ]; then
        $sudo_prefix cp "$hiveram_svc" "${systemd_dir}/pastewatch-hiveram.service"
        info "  Installed pastewatch-hiveram.service (Hiveram traffic on :8444)"
    fi

    if [ -d /etc/logrotate.d ]; then
        [ -f "$proxy_logrotate" ] && $sudo_prefix cp "$proxy_logrotate" /etc/logrotate.d/pastewatch-proxy
        [ -f "$hiveram_logrotate" ] && $sudo_prefix cp "$hiveram_logrotate" /etc/logrotate.d/pastewatch-hiveram
    fi

    $sudo_prefix systemctl daemon-reload
    $sudo_prefix systemctl enable pastewatch-proxy.service 2>/dev/null || true
    $sudo_prefix systemctl enable pastewatch-hiveram.service 2>/dev/null || true
    info "  Both pastewatch proxies enabled (start before nullbot)"

    [ -n "${tmpdir:-}" ] && rm -rf "$tmpdir"
}

# --- phase 5: ebpf enforcement (linux only) ---

LOG_DIR="/var/log/chainwatch"

has_ebpf_support() {
    # macOS: no eBPF support
    [ "$(uname -s)" = "Linux" ] || return 1
    # Kernel must have BTF (eBPF CO-RE requirement)
    [ -f /sys/kernel/btf/vmlinux ] || return 1
    # Kernel version >= 5.8 (BPF ring buffer support)
    local kver
    kver=$(uname -r | cut -d. -f1-2)
    local major minor
    major=$(echo "$kver" | cut -d. -f1)
    minor=$(echo "$kver" | cut -d. -f2)
    [ "$major" -gt 5 ] || { [ "$major" -eq 5 ] && [ "$minor" -ge 8 ]; } || return 1
    # systemd must be present
    command -v systemctl &>/dev/null || return 1
    return 0
}

setup_enforcement() {
    info "Phase 6: eBPF/seccomp enforcement"

    if [ "$(uname -s)" != "Linux" ]; then
        return 0
    fi

    if ! has_ebpf_support; then
        warn "  eBPF not available (need Linux ≥5.8 with BTF + systemd)"
        warn "  Skipping enforcement — nullbot runs without kernel-level containment"
        return 0
    fi

    info "  eBPF support detected (kernel $(uname -r), BTF present)"

    # Create log directory
    if [ ! -d "$LOG_DIR" ]; then
        if [ -w /var/log ] || [ "$(id -u)" = "0" ]; then
            mkdir -p "$LOG_DIR"
        else
            sudo mkdir -p "$LOG_DIR"
        fi
        info "  Created ${LOG_DIR}"
    fi

    # Install systemd units
    local systemd_dir="/etc/systemd/system"
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    # Determine source for config files (installer repo or inline)
    local nullbot_svc="${script_dir}/config/nullbot.service"
    local enforce_svc="${script_dir}/config/chainwatch-enforce.service"
    local logrotate_cfg="${script_dir}/config/chainwatch-enforce.logrotate"

    if [ -f "$nullbot_svc" ] && [ -f "$enforce_svc" ]; then
        # Running from cloned repo
        info "  Installing systemd units from config/"
    else
        # Running from curl pipe — download configs
        info "  Downloading systemd unit files"
        local tmpdir
        tmpdir="$(mktemp -d)"
        local base_url="https://raw.githubusercontent.com/${REPO}/main/config"
        curl -fsSL -o "${tmpdir}/nullbot.service" "${base_url}/nullbot.service" || { warn "  Failed to download nullbot.service"; return 0; }
        curl -fsSL -o "${tmpdir}/chainwatch-enforce.service" "${base_url}/chainwatch-enforce.service" || { warn "  Failed to download chainwatch-enforce.service"; return 0; }
        curl -fsSL -o "${tmpdir}/chainwatch-enforce.logrotate" "${base_url}/chainwatch-enforce.logrotate" || { warn "  Failed to download logrotate config"; return 0; }
        nullbot_svc="${tmpdir}/nullbot.service"
        enforce_svc="${tmpdir}/chainwatch-enforce.service"
        logrotate_cfg="${tmpdir}/chainwatch-enforce.logrotate"
    fi

    # Install units (needs root)
    local sudo_prefix=""
    if [ "$(id -u)" != "0" ]; then
        sudo_prefix="sudo"
    fi

    $sudo_prefix cp "$nullbot_svc" "${systemd_dir}/nullbot.service"
    $sudo_prefix cp "$enforce_svc" "${systemd_dir}/chainwatch-enforce.service"
    info "  Installed nullbot.service and chainwatch-enforce.service"
    info "  chainwatch-enforce.service launches nullbot under seccomp enforcement"

    # Install logrotate config
    if [ -d /etc/logrotate.d ]; then
        $sudo_prefix cp "$logrotate_cfg" /etc/logrotate.d/chainwatch-enforce
        info "  Installed logrotate config"
    fi

    # Reload systemd
    $sudo_prefix systemctl daemon-reload

    # Enable enforcement service (it launches nullbot as a child)
    # nullbot.service is available for standalone use without enforcement
    $sudo_prefix systemctl enable chainwatch-enforce.service 2>/dev/null || true
    info "  Services enabled (start with: systemctl start chainwatch-enforce)"

    # Clean up temp files if used
    [ -n "${tmpdir:-}" ] && rm -rf "$tmpdir"
}

# --- phase 7: lock binaries (linux) ---

lock_binaries() {
    if [ "$(uname -s)" != "Linux" ]; then
        return 0
    fi

    if ! command -v chattr &>/dev/null; then
        return 0
    fi

    info "Phase 7: Locking binaries (immutable flag)"

    local sudo_prefix=""
    if [ "$(id -u)" != "0" ]; then
        sudo_prefix="sudo"
    fi

    local locked=0
    for bin in chainwatch nullbot pastewatch-cli; do
        local path="${INSTALL_DIR}/${bin}"
        if [ -f "$path" ]; then
            $sudo_prefix chattr +i "$path" 2>/dev/null && locked=$((locked + 1)) || true
        fi
    done

    if [ "$locked" -gt 0 ]; then
        info "  Locked ${locked} binaries with immutable flag"
        info "  To update: chattr -i /usr/local/bin/{chainwatch,nullbot,pastewatch-cli}"
    else
        warn "  Could not set immutable flag (filesystem may not support it)"
    fi
}

# --- phase 8: verify ---

verify() {
    info "Phase 8: Verifying installation"
    local ok=true

    # chainwatch
    if command -v chainwatch &>/dev/null; then
        local cw_ver
        cw_ver=$(chainwatch version 2>/dev/null || echo "ok")
        info "  chainwatch: ${cw_ver}"
    else
        warn "  chainwatch: not on PATH"
        ok=false
    fi

    # nullbot
    if command -v nullbot &>/dev/null; then
        info "  nullbot: installed"
    else
        warn "  nullbot: not on PATH"
        ok=false
    fi

    # pastewatch
    if command -v pastewatch-cli &>/dev/null; then
        info "  pastewatch: installed"
    else
        info "  pastewatch: not installed (optional — secret redaction)"
    fi

    # chainwatch config
    if [ -d "$CW_CONFIG_DIR" ]; then
        info "  chainwatch config: ${CW_CONFIG_DIR}"
    else
        warn "  chainwatch config: not initialized"
        ok=false
    fi

    # nullbot config
    if [ -f "${CONFIG_DIR}/config.yaml" ]; then
        info "  nullbot config: ${CONFIG_DIR}/config.yaml"
    else
        warn "  nullbot config: missing"
        ok=false
    fi

    # hiveram connection
    if [ -f "${WL_CONFIG_DIR}/api-key.env" ]; then
        # shellcheck disable=SC1091
        source "${WL_CONFIG_DIR}/api-key.env" 2>/dev/null || true
        if [ -n "${WORKLEDGER_API_KEY:-}" ]; then
            local hiveram_url
            hiveram_url=$(grep 'url:' "${CONFIG_DIR}/config.yaml" 2>/dev/null | awk '{print $2}' | head -1)
            if [ -n "$hiveram_url" ]; then
                local healthz="${hiveram_url%/api/v1}/healthz"
                if curl -s --max-time 5 "$healthz" >/dev/null 2>&1; then
                    info "  hiveram: connected (${healthz})"
                else
                    warn "  hiveram: unreachable (${healthz})"
                fi
            fi
        else
            warn "  hiveram: API key not set"
        fi
    else
        warn "  hiveram: not configured"
    fi

    # llm + proxy
    if [ -f "${CONFIG_DIR}/llm.env" ]; then
        info "  llm: configured"
        if [ "$(uname -s)" = "Linux" ] && systemctl is-enabled pastewatch-proxy.service &>/dev/null 2>&1; then
            info "  pastewatch LLM proxy: enabled (:8443)"
        elif command -v pastewatch-cli &>/dev/null; then
            info "  pastewatch LLM proxy: available (start manually)"
        else
            warn "  pastewatch LLM proxy: not available (LLM traffic unscanned)"
        fi
        if [ "$(uname -s)" = "Linux" ] && systemctl is-enabled pastewatch-hiveram.service &>/dev/null 2>&1; then
            info "  pastewatch Hiveram proxy: enabled (:8444)"
        fi
    else
        info "  llm: not configured (deterministic-only mode)"
    fi

    # enforcement (linux only)
    if [ "$(uname -s)" = "Linux" ] && command -v systemctl &>/dev/null; then
        if systemctl is-enabled chainwatch-enforce.service &>/dev/null; then
            info "  enforcement: enabled (chainwatch-enforce.service)"
            if systemctl is-active chainwatch-enforce.service &>/dev/null; then
                info "  enforcement: active"
            else
                info "  enforcement: not running (start with: systemctl start nullbot)"
            fi
        elif has_ebpf_support; then
            warn "  enforcement: not installed (re-run installer to set up)"
        else
            info "  enforcement: not available (kernel lacks eBPF support)"
        fi
    fi

    # binary integrity (linux)
    if [ "$(uname -s)" = "Linux" ] && command -v lsattr &>/dev/null; then
        local immutable_count=0
        for bin in chainwatch nullbot pastewatch-cli; do
            if lsattr "${INSTALL_DIR}/${bin}" 2>/dev/null | grep -q 'i'; then
                immutable_count=$((immutable_count + 1))
            fi
        done
        if [ "$immutable_count" -gt 0 ]; then
            info "  binary integrity: ${immutable_count} binaries locked (immutable)"
        else
            warn "  binary integrity: binaries not locked (run: chattr +i /usr/local/bin/{chainwatch,nullbot,pastewatch-cli})"
        fi
    fi

    echo ""
    if $ok; then
        info "Installation complete."
        if [ "$(uname -s)" = "Linux" ] && systemctl is-enabled chainwatch-enforce.service &>/dev/null; then
            info "Start with enforcement: systemctl start chainwatch-enforce"
            info "Start without enforcement: systemctl start nullbot"
        else
            info "Open a new terminal, then run: nullbot pull --dry-run"
        fi
    else
        warn "Installation completed with warnings. Review the messages above."
    fi
}

# --- main ---

main() {
    echo ""
    echo "  nullbot installer"
    echo "  ================="
    echo "  Fleet observer + chainwatch policy gate"
    echo ""

    install_chainwatch
    echo ""
    install_nullbot
    echo ""
    install_pastewatch
    echo ""
    configure_nullbot
    echo ""
    configure_llm
    setup_pastewatch_proxy
    echo ""
    setup_enforcement
    echo ""
    lock_binaries
    echo ""
    verify
}

main "$@"
