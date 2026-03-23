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

# --- phase 3: nullbot config ---

configure_nullbot() {
    info "Phase 3: Configuring nullbot"
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

# --- phase 4: groq (optional) ---

configure_groq() {
    info "Phase 4: Groq API key (optional — for LLM-assisted observation)"
    mkdir -p "$CONFIG_DIR"

    local groq_file="${CONFIG_DIR}/groq.env"

    if [ -f "$groq_file" ]; then
        info "  Groq key already exists at ${groq_file}"
        return
    fi

    echo ""
    echo "Nullbot can use Groq for LLM-assisted observation."
    echo "Without it, nullbot runs in deterministic-only mode (still useful)."
    printf "Groq API key (press Enter to skip): "
    read -r groq_key

    if [ -n "$groq_key" ]; then
        echo "export GROQ_API_KEY='${groq_key}'" > "$groq_file"
        chmod 600 "$groq_file"
        info "  Groq key saved to ${groq_file}"

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
            local source_line='[ -f ~/.nullbot/groq.env ] && source ~/.nullbot/groq.env'
            if ! grep -qF "$source_line" "$profile" 2>/dev/null; then
                echo "$source_line" >> "$profile"
                info "  Added groq source line to ${profile}"
            fi
        fi
    else
        info "  Skipped — nullbot will run in deterministic-only mode"
    fi
}

# --- phase 5: verify ---

verify() {
    info "Phase 5: Verifying installation"
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

    # groq
    if [ -f "${CONFIG_DIR}/groq.env" ]; then
        info "  groq: configured"
    else
        info "  groq: not configured (deterministic-only mode)"
    fi

    echo ""
    if $ok; then
        info "Installation complete."
        info "Open a new terminal, then run: nullbot pull --dry-run"
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
    configure_nullbot
    echo ""
    configure_groq
    echo ""
    verify
}

main "$@"
