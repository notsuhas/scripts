#!/usr/bin/env bash
# ============================================================================
# Claude Code LXC Deployer for Proxmox
# Wraps the community-scripts Docker LXC (unprivileged, Debian 13) and
# layers Claude Code, Codex, Gemini, gh, languages, and tooling on top.
#
# Provisions a dedicated non-root user that owns /project, Claude Code config,
# Homebrew, npm globals, cargo, etc. Root only handles apt and system services.
#
# Run on your Proxmox host:
# curl -fsSL https://raw.githubusercontent.com/notsuhas/scripts/refs/heads/master/proxmox-ai.sh -o /tmp/proxmox-ai.sh && bash /tmp/proxmox-ai.sh
# ============================================================================
set -euo pipefail

# ── Colors & Helpers ────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

header() {
    echo ""
    echo -e "${BOLD}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║  Claude Code LXC Deployer (Proxmox)              ║${NC}"
    echo -e "${BOLD}║  via community-scripts Docker LXC (unpriv.)      ║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════════════════╝${NC}"
    echo ""
}

# ── Pre-flight checks ──────────────────────────────────────────────────────
preflight() {
    [[ $(id -u) -eq 0 ]] || error "This script must be run as root on the Proxmox host."
    command -v pct &>/dev/null || error "pct not found. Are you running this on a Proxmox host?"
    command -v pveam &>/dev/null || error "pveam not found. Are you running this on a Proxmox host?"
    command -v pvesh &>/dev/null || error "pvesh not found. Are you running this on a Proxmox host?"
}

# ── Configuration ───────────────────────────────────────────────────────────
get_config() {
    local next_id
    next_id=$(pvesh get /cluster/nextid 2>/dev/null || echo "100")

    echo -e "${BOLD}Container Configuration${NC}"
    echo "─────────────────────────────────────────────────"

    read -rp "Container ID [$next_id]: " CT_ID
    CT_ID="${CT_ID:-$next_id}"
    [[ "$CT_ID" =~ ^[0-9]+$ ]] || error "Container ID must be a number."
    pct status "$CT_ID" &>/dev/null && error "Container ID $CT_ID already exists."

    read -rp "Hostname [claude-code]: " CT_HOSTNAME
    CT_HOSTNAME="${CT_HOSTNAME:-claude-code}"

    read -rsp "Root password: " CT_PASSWORD
    echo ""
    [[ -n "$CT_PASSWORD" ]] || error "Root password cannot be empty."

    read -rp "Non-root username [dev]: " CT_USER
    CT_USER="${CT_USER:-dev}"
    [[ "$CT_USER" =~ ^[a-z_][a-z0-9_-]{0,30}$ ]] || error "Invalid username. Use lowercase, start with letter or underscore."
    [[ "$CT_USER" != "root" ]] || error "Username cannot be 'root'."

    read -rsp "Password for user '$CT_USER' (Enter to reuse root password): " CT_USER_PASSWORD
    echo ""
    CT_USER_PASSWORD="${CT_USER_PASSWORD:-$CT_PASSWORD}"

    read -rp "CPU cores [4]: " CT_CORES
    CT_CORES="${CT_CORES:-4}"

    read -rp "RAM in MB [4096]: " CT_RAM
    CT_RAM="${CT_RAM:-4096}"

    read -rp "Disk size in GB [20]: " CT_DISK
    CT_DISK="${CT_DISK:-20}"

    read -rp "Container storage [local-lvm]: " CT_STORAGE
    CT_STORAGE="${CT_STORAGE:-local-lvm}"

    read -rp "Template storage [local]: " CT_TPL_STORAGE
    CT_TPL_STORAGE="${CT_TPL_STORAGE:-local}"

    read -rp "Bridge [vmbr0]: " CT_BRG
    CT_BRG="${CT_BRG:-vmbr0}"

    read -rp "IP address (DHCP or x.x.x.x/xx) [dhcp]: " CT_IP
    CT_IP="${CT_IP:-dhcp}"

    CT_GW=""
    if [[ "$CT_IP" != "dhcp" ]]; then
        read -rp "Gateway: " CT_GW
        [[ -n "$CT_GW" ]] || error "Gateway is required for static IP."
    fi

    read -rp "DNS server [1.1.1.1]: " CT_DNS
    CT_DNS="${CT_DNS:-1.1.1.1}"

    read -rp "Timezone [Asia/Kolkata]: " CT_TZ
    CT_TZ="${CT_TZ:-Asia/Kolkata}"

    read -rp "Path to SSH public key (optional, press Enter to skip): " CT_SSH_KEY

    echo ""
    echo -e "${BOLD}Summary${NC}"
    echo "─────────────────────────────────────────────────"
    echo "  CT ID:        $CT_ID"
    echo "  Hostname:     $CT_HOSTNAME"
    echo "  Base:         Debian 13 (unprivileged, Docker)"
    echo "  Non-root:     $CT_USER (owns /project, brew, npm globals, claude config)"
    echo "  CPU:          $CT_CORES cores"
    echo "  RAM:          $CT_RAM MB ($(( CT_RAM / 1024 )) GB)"
    echo "  Disk:         ${CT_DISK}G on $CT_STORAGE"
    echo "  Template on:  $CT_TPL_STORAGE"
    echo "  Bridge:       $CT_BRG"
    echo "  Network:      $CT_IP${CT_GW:+ (gw $CT_GW)}"
    echo "  DNS:          $CT_DNS"
    echo "  Timezone:     $CT_TZ"
    echo "─────────────────────────────────────────────────"
    echo ""
    echo "  Note: the community Docker installer will ask 3 prompts during setup"
    echo "        (Portainer UI, Portainer Agent, Docker TCP socket)."
    echo "        Press 'n' + Enter for each unless you want them."
    echo ""
    read -rp "Proceed? (y/N): " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
}

# ── Run Community-Scripts Docker LXC ───────────────────────────────────────
run_community_script() {
    info "Preparing community-scripts environment..."
    mkdir -p /usr/local/community-scripts

    cat > /usr/local/community-scripts/diagnostics <<EOF
DIAGNOSTICS=no
EOF

    cat > /usr/local/community-scripts/default.vars <<EOF
var_template_storage=$CT_TPL_STORAGE
var_container_storage=$CT_STORAGE
EOF

    local ssh_key_content=""
    if [[ -n "${CT_SSH_KEY:-}" && -f "$CT_SSH_KEY" ]]; then
        ssh_key_content="$(cat "$CT_SSH_KEY")"
    fi

    info "Launching community-scripts Docker LXC..."
    echo ""

    export mode="default"
    export var_unprivileged="1"
    export var_os="debian"
    export var_version="13"
    export var_ctid="$CT_ID"
    export var_hostname="$CT_HOSTNAME"
    export var_disk="$CT_DISK"
    export var_cpu="$CT_CORES"
    export var_ram="$CT_RAM"
    export var_brg="$CT_BRG"
    export var_net="$CT_IP"
    export var_gateway="$CT_GW"
    export var_ns="$CT_DNS"
    export var_timezone="$CT_TZ"
    export var_pw="$CT_PASSWORD"
    export var_ssh="yes"
    export var_ssh_authorized_key="$ssh_key_content"
    export var_template_storage="$CT_TPL_STORAGE"
    export var_container_storage="$CT_STORAGE"
    export var_fuse="yes"
    export var_keyctl="1"
    export var_nesting="1"
    export var_tags="docker;claude-code"
    export var_verbose="no"

    bash -c 'source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/docker.sh)' \
        || error "community-scripts Docker LXC creation failed."

    pct status "$CT_ID" &>/dev/null || error "Container $CT_ID was not created."
    pct status "$CT_ID" | grep -q running || {
        info "Starting container $CT_ID..."
        pct start "$CT_ID"
        sleep 5
    }

    info "Waiting for network (up to 60s)..."
    local attempts=0
    while ! pct exec "$CT_ID" -- ping -c1 -W2 1.1.1.1 &>/dev/null; do
        attempts=$(( attempts + 1 ))
        if [[ $attempts -ge 30 ]]; then
            warn "Network timed out — continuing anyway"
            return 0
        fi
        sleep 2
    done
    success "Container is online."
}

# ── Provision Container ────────────────────────────────────────────────────
# Strategy:
#   1. Root-side script: apt installs, user creation, SSH config, system services
#   2. User-side script: brew, claude code, npm globals, cargo, rustup, /project setup
#
# Splitting into two files keeps heredoc escaping sane and makes the privilege
# boundary explicit.
provision_container() {
    info "Provisioning container (this takes a few minutes)..."

    local tz="$CT_TZ"
    local user="$CT_USER"
    local user_pw="$CT_USER_PASSWORD"

    # ────────────────────────────────────────────────────────────────────────
    # ROOT-SIDE PROVISIONING
    # ────────────────────────────────────────────────────────────────────────
    cat > /tmp/provision-root-${CT_ID}.sh << PROVISION_ROOT_EOF
#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive
TZ="${tz}"
USERNAME="${user}"
USER_PASSWORD='${user_pw}'

echo ">>> [root] Setting timezone to \$TZ..."
ln -sf "/usr/share/zoneinfo/\$TZ" /etc/localtime
echo "\$TZ" > /etc/timezone
dpkg-reconfigure -f noninteractive tzdata

echo ">>> [root] Generating locale..."
apt-get update -qq
apt-get install -y -qq locales sudo
sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen
locale-gen en_US.UTF-8 > /dev/null 2>&1
update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

echo ">>> [root] Updating system..."
apt-get upgrade -y -qq

echo ">>> [root] Installing core packages..."
apt-get install -y -qq \\
    git curl wget unzip zip \\
    ca-certificates gnupg lsb-release apt-transport-https \\
    bash-completion locales \\
    zsh \\
    htop nano vim tmux screen \\
    jq yq tree \\
    net-tools iproute2 iputils-ping dnsutils \\
    openssh-server \\
    cron logrotate \\
    procps file

echo ">>> [root] Installing build tools & dev libraries..."
apt-get install -y -qq \\
    build-essential make cmake pkg-config autoconf automake libtool \\
    python3 python3-pip python3-venv python3-dev \\
    libssl-dev libffi-dev libsqlite3-dev zlib1g-dev \\
    libreadline-dev libbz2-dev libncurses-dev liblzma-dev libxml2-dev libxslt-dev

echo ">>> [root] Installing search & productivity tools..."
apt-get install -y -qq \\
    ripgrep fd-find fzf bat \\
    rsync \\
    sqlite3

echo ">>> [root] Installing database clients..."
apt-get install -y -qq \\
    postgresql-client redis-tools

echo ">>> [root] Installing GitHub CLI (gh) via apt..."
apt-get install -y -qq gh

echo ">>> [root] Installing Node.js 22.x LTS (system binary; per-user prefix configured later)..."
curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
apt-get install -y -qq nodejs
echo "    Node.js \$(node --version) / npm \$(npm --version)"

echo ">>> [root] Installing Go (system-wide)..."
GO_VERSION=\$(curl -fsSL "https://go.dev/VERSION?m=text" | head -1)
curl -fsSL "https://go.dev/dl/\${GO_VERSION}.linux-amd64.tar.gz" -o /tmp/go.tar.gz
rm -rf /usr/local/go
tar -C /usr/local -xzf /tmp/go.tar.gz
rm /tmp/go.tar.gz
echo 'export PATH=\$PATH:/usr/local/go/bin' > /etc/profile.d/go.sh
echo "    Go \$(/usr/local/go/bin/go version | awk '{print \$3}')"

echo ">>> [root] Creating non-root user '\$USERNAME'..."
if ! id "\$USERNAME" &>/dev/null; then
    useradd -m -s /bin/bash -G sudo,docker "\$USERNAME"
    echo "\${USERNAME}:\${USER_PASSWORD}" | chpasswd
    echo "    User created, added to sudo and docker groups"
else
    echo "    User already exists"
fi

# Passwordless sudo (convenience — adjust if you want stricter)
echo "\$USERNAME ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/\$USERNAME
chmod 0440 /etc/sudoers.d/\$USERNAME

echo ">>> [root] Setting up /project owned by \$USERNAME..."
mkdir -p /project
chown -R "\$USERNAME:\$USERNAME" /project

echo ">>> [root] Configuring SSH (root + user both allowed)..."
sed -i "s/^#*PermitRootLogin.*/PermitRootLogin yes/" /etc/ssh/sshd_config
sed -i "s/^#*PasswordAuthentication.*/PasswordAuthentication yes/" /etc/ssh/sshd_config
systemctl enable ssh
systemctl restart ssh

echo ">>> [root] Setting up weekly system update cron..."
cat > /etc/cron.d/system-update << 'CRON'
# Weekly system update - Sunday 3:00 AM local time
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
0 3 * * 0 root apt-get update -qq && apt-get upgrade -y -qq && apt-get autoremove -y -qq && apt-get clean -qq >> /var/log/auto-update.log 2>&1
CRON
chmod 0644 /etc/cron.d/system-update

cat > /etc/logrotate.d/auto-update << 'LOGROTATE'
/var/log/auto-update.log {
    monthly
    rotate 3
    compress
    missingok
    notifempty
}
LOGROTATE

echo ">>> [root] Root-side provisioning complete."
PROVISION_ROOT_EOF

    chmod +x /tmp/provision-root-${CT_ID}.sh
    pct push "$CT_ID" /tmp/provision-root-${CT_ID}.sh /tmp/provision-root.sh
    pct exec "$CT_ID" -- chmod +x /tmp/provision-root.sh
    pct exec "$CT_ID" -- /tmp/provision-root.sh

    # ────────────────────────────────────────────────────────────────────────
    # USER-SIDE PROVISIONING
    # ────────────────────────────────────────────────────────────────────────
    # Everything below runs as $CT_USER inside the container.
    # Single-quoted heredoc delimiter (PROVISION_USER_EOF) prevents host-side
    # variable expansion — we inject $tz/$user via sed below.
    cat > /tmp/provision-user-${CT_ID}.sh << 'PROVISION_USER_EOF'
#!/bin/bash
set -e
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8
TZ="__TZ_PLACEHOLDER__"

echo ">>> [user] Running as $(whoami) in $HOME"

echo ">>> [user] Configuring per-user npm global prefix..."
mkdir -p "$HOME/.npm-global"
npm config set prefix "$HOME/.npm-global"
export PATH="$HOME/.npm-global/bin:$PATH"

echo ">>> [user] Installing global npm packages..."
npm install -g typescript ts-node eslint prettier

echo ">>> [user] Installing Homebrew (Linuxbrew) into user home..."
NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
# Brew installs to /home/linuxbrew/.linuxbrew if writable, else ~/.linuxbrew
if [[ -d /home/linuxbrew/.linuxbrew ]]; then
    BREW_PREFIX="/home/linuxbrew/.linuxbrew"
else
    BREW_PREFIX="$HOME/.linuxbrew"
fi
eval "$($BREW_PREFIX/bin/brew shellenv)"
echo "    brew $(brew --version | head -1)"

echo ">>> [user] Installing Rust via rustup..."
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable
source "$HOME/.cargo/env"
echo "    Rust $(rustc --version | awk '{print $2}')"

echo ">>> [user] Installing Claude Code..."
curl -fsSL https://claude.ai/install.sh | bash
CLAUDE_BIN=""
for candidate in "$HOME/.local/bin/claude" "$HOME/.claude/bin/claude"; do
    if [[ -x "$candidate" ]]; then
        CLAUDE_BIN="$candidate"
        break
    fi
done
if [[ -n "$CLAUDE_BIN" ]]; then
    echo "    Claude Code installed at $CLAUDE_BIN"
    "$CLAUDE_BIN" --version 2>/dev/null || true
else
    echo "    WARNING: claude binary not found after install — check PATH"
fi

echo ">>> [user] Installing Codex CLI..."
npm install -g @openai/codex 2>/dev/null || \
    echo "    WARNING: codex install failed — run: npm install -g @openai/codex"

echo ">>> [user] Installing Gemini CLI..."
npm install -g @google/gemini-cli 2>/dev/null || \
    echo "    WARNING: gemini install failed — run: npm install -g @google/gemini-cli"

echo ">>> [user] Configuring Claude Code permissions (full auto-approve)..."
mkdir -p "$HOME/.claude"
cat > "$HOME/.claude/settings.json" << 'SETTINGS_EOF'
{
    "$schema": "https://json.schemastore.org/claude-code-settings.json",
    "permissions": {
        "allow": [
            "Bash(*)",
            "Read(*)",
            "Write(*)",
            "Edit(*)",
            "MultiEdit(*)",
            "WebFetch(*)",
            "WebSearch(*)",
            "TodoRead(*)",
            "TodoWrite(*)",
            "Grep(*)",
            "Glob(*)",
            "LS(*)",
            "Task(*)",
            "mcp__*"
        ]
    },
    "env": {
        "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1",
        "CLAUDE_CODE_MAX_OUTPUT_TOKENS": "64000",
        "MAX_THINKING_TOKENS": "31999"
    },
    "alwaysThinkingEnabled": true,
    "enableRemoteControl": true
}
SETTINGS_EOF

echo ">>> [user] Installing skills..."
mkdir -p "$HOME/.claude/skills"
SKILLS=(
    "anthropics/skills:frontend-design"
    "anthropics/skills:webapp-testing"
    "obra/superpowers:brainstorming"
    "obra/superpowers:writing-plans"
    "obra/superpowers:executing-plans"
    "obra/superpowers:test-driven-development"
    "obra/superpowers:requesting-code-review"
    "obra/superpowers:receiving-code-review"
    "obra/superpowers:verification-before-completion"
    "juliusbrussee/caveman:caveman-commit"
    "pbakaus/impeccable:impeccable"
)
for entry in "${SKILLS[@]}"; do
    repo="${entry%:*}"
    skill="${entry#*:}"
    npx -y skills add "$repo" --skill "$skill" --agent claude-code --yes 2>/dev/null || \
        echo "    WARNING: $skill install failed"
done
# context7-cli uses a different add format
npx -y skills add https://github.com/upstash/context7 --skill context7-cli --agent claude-code --yes 2>/dev/null || \
    echo "    WARNING: context7-cli install failed"

echo ">>> [user] Installing ctx7 CLI globally (per-user)..."
npm install -g ctx7@latest 2>/dev/null || \
    echo "    WARNING: ctx7 install failed"

echo ">>> [user] Installing Playwright for webapp-testing skill..."
npx -y playwright install chromium 2>/dev/null || \
    echo "    WARNING: Playwright install failed — Chromium deps may need sudo apt"
# Playwright system deps need root — run via sudo
sudo npx -y playwright install-deps chromium 2>/dev/null || \
    echo "    WARNING: Playwright system deps install failed"

echo ">>> [user] Setting up /project workspace..."
cat > /project/CLAUDE.md << 'CLAUDEMD'
# Claude Code Workspace

## Environment

- **OS**: Debian 13 unprivileged LXC on Proxmox (community-scripts Docker LXC)
- **Working directory**: /project
- **User**: non-root user (owns brew, npm globals, cargo, claude config)
- **Root**: reserved for apt and system services only

## Available Tools

- **Languages**: Node.js 22 LTS, Python 3 (use --break-system-packages or venv), Go (latest), Rust (latest)
- **Package managers**: npm (per-user prefix ~/.npm-global), pip, cargo, brew, go install
- **Docker**: Docker Engine + Compose plugin (user is in docker group)
- **Containers**: Watchtower (auto-updates), Code Server (port 8443)
- **AI CLIs**: claude, codex, gemini, ctx7
- **GitHub**: gh (apt-installed)
- **Search tools**: ripgrep (rg), fd-find (fdfind), fzf
- **Databases**: PostgreSQL client (psql), Redis client (redis-cli), SQLite3

## Permissions

All Claude Code tools are pre-approved — no permission prompts. Bash, Read, Write, Edit, WebFetch, WebSearch, Task, and MCP tools all run without confirmation.

## Agent Teams

Agent teams are enabled via CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1.
Use the Task tool for subagents. tmux is installed for split-pane visualization.

## Remote Control

Remote control is enabled. Use /remote-control or press spacebar to show QR code.

## Docker Usage

Docker compose files go in /project/docker/<service-name>/docker-compose.yml.
The user is in the docker group, so `docker` and `docker compose` work without sudo.
Watchtower auto-updates any containers with `restart: unless-stopped`.

## Conventions

- Prefer creating files over printing long code blocks
- Use git for version control on all projects in /project/src/
- Python: prefer venvs; if installing globally, use --break-system-packages
- npm global installs go to ~/.npm-global (no sudo needed)
CLAUDEMD

echo ">>> [user] Setting up shell environment..."
cat >> "$HOME/.bashrc" << BASHRC

# ── Claude Code Container ──────────────────────────────────
export EDITOR=nano
export LANG=en_US.UTF-8
export TZ="$TZ"

# Per-user paths
export PATH="\$HOME/.npm-global/bin:\$HOME/.local/bin:\$HOME/.claude/bin:\$HOME/.cargo/bin:/usr/local/go/bin:\$PATH"

# Homebrew
if [[ -d /home/linuxbrew/.linuxbrew ]]; then
    eval "\$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
elif [[ -d "\$HOME/.linuxbrew" ]]; then
    eval "\$(\$HOME/.linuxbrew/bin/brew shellenv)"
fi

# Aliases
alias ll="ls -lah --color=auto"
alias cls="clear"
alias ..="cd .."
alias ...="cd ../.."
alias gs="git status"
alias gl="git log --oneline -20"
alias dc="docker compose"
alias dps="docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'"

# Always start in /project
cd /project 2>/dev/null || true
BASHRC

echo ">>> [user] Setting up Git defaults..."
git config --global init.defaultBranch main
git config --global core.editor nano
git config --global pull.rebase false

echo ">>> [user] Setting up Docker services in /project/docker/..."
mkdir -p /project/docker/watchtower
cat > /project/docker/watchtower/docker-compose.yml << DCOMPOSE
services:
  watchtower:
    image: containrrr/watchtower
    container_name: watchtower
    restart: unless-stopped
    environment:
      TZ: "$TZ"
      WATCHTOWER_CLEANUP: "true"
      WATCHTOWER_INCLUDE_STOPPED: "true"
      WATCHTOWER_SCHEDULE: "0 0 4 * * *"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
DCOMPOSE

mkdir -p /project/docker/code-server
cat > /project/docker/code-server/docker-compose.yml << DCOMPOSE2
services:
  code-server:
    image: lscr.io/linuxserver/code-server:latest
    container_name: code-server
    restart: unless-stopped
    environment:
      PUID: "$(id -u)"
      PGID: "$(id -g)"
      TZ: "$TZ"
      PASSWORD: admin
    volumes:
      - ./config:/config
      - /project:/config/workspace
    ports:
      - 8443:8443
DCOMPOSE2

cd /project/docker/watchtower && docker compose up -d
cd /project/docker/code-server && docker compose up -d

echo ">>> [user] User-side provisioning complete."
PROVISION_USER_EOF

    # Inject the timezone into the user script (single-quoted heredoc kept it literal)
    sed -i "s|__TZ_PLACEHOLDER__|${tz}|g" /tmp/provision-user-${CT_ID}.sh

    chmod +x /tmp/provision-user-${CT_ID}.sh
    pct push "$CT_ID" /tmp/provision-user-${CT_ID}.sh /tmp/provision-user.sh
    pct exec "$CT_ID" -- chmod +x /tmp/provision-user.sh
    pct exec "$CT_ID" -- chown "$CT_USER:$CT_USER" /tmp/provision-user.sh

    # Run as the new user with a proper login shell so PATH and env are sane
    pct exec "$CT_ID" -- su - "$CT_USER" -c "/tmp/provision-user.sh"

    # ────────────────────────────────────────────────────────────────────────
    # POST-PROVISION CLEANUP (as root inside container)
    # ────────────────────────────────────────────────────────────────────────
    cat > /tmp/cleanup-${CT_ID}.sh << 'CLEANUP_EOF'
#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive
echo ">>> [root] Cleaning up..."
apt-get autoremove -y -qq
apt-get clean -qq
rm -rf /var/lib/apt/lists/*
rm -f /tmp/provision-root.sh /tmp/provision-user.sh
echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║         Provisioning Complete!                   ║"
echo "╚══════════════════════════════════════════════════╝"
CLEANUP_EOF
    chmod +x /tmp/cleanup-${CT_ID}.sh
    pct push "$CT_ID" /tmp/cleanup-${CT_ID}.sh /tmp/cleanup.sh
    pct exec "$CT_ID" -- chmod +x /tmp/cleanup.sh
    pct exec "$CT_ID" -- /tmp/cleanup.sh

    rm -f /tmp/provision-root-${CT_ID}.sh /tmp/provision-user-${CT_ID}.sh /tmp/cleanup-${CT_ID}.sh
}

# ── Print Summary ─────────────────────────────────────────────────────────
print_summary() {
    local ct_ip
    ct_ip=$(pct exec "$CT_ID" -- hostname -I 2>/dev/null | awk '{print $1}')

    echo ""
    echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}${BOLD}║         Claude Code LXC Ready!                   ║${NC}"
    echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${BOLD}Container:${NC} $CT_ID ($CT_HOSTNAME) — unprivileged Debian 13"
    echo -e "  ${BOLD}IP:${NC}        ${ct_ip:-pending (DHCP)}"
    echo -e "  ${BOLD}Resources:${NC} ${CT_CORES} CPU / $(( CT_RAM / 1024 )) GB RAM / ${CT_DISK} GB disk"
    echo -e "  ${BOLD}Storage:${NC}   $CT_STORAGE (template on $CT_TPL_STORAGE)"
    echo -e "  ${BOLD}Timezone:${NC}  $CT_TZ"
    echo ""
    echo -e "  ${BOLD}Users:${NC}"
    echo -e "    root      — apt, system services, systemctl"
    echo -e "    $CT_USER  — owns /project, claude, brew, npm globals, cargo, docker"
    echo ""
    echo -e "  ${BOLD}Connect:${NC}"
    echo -e "    Console:  ${CYAN}pct enter $CT_ID${NC} then ${CYAN}su - $CT_USER${NC}"
    [[ -n "${ct_ip:-}" ]] && echo -e "    SSH:      ${CYAN}ssh $CT_USER@${ct_ip}${NC} (or root@)"
    [[ -n "${ct_ip:-}" ]] && echo -e "    Code:     ${CYAN}http://${ct_ip}:8443${NC} (password: admin)"
    echo ""
    echo -e "  ${BOLD}Start AI CLIs (as $CT_USER):${NC}"
    echo -e "    ${CYAN}claude${NC}    (shell auto-cd's to /project on login)"
    echo -e "    ${CYAN}codex${NC}     (OpenAI Codex CLI)"
    echo -e "    ${CYAN}gemini${NC}    (Google Gemini CLI)"
    echo ""
    echo -e "  ${BOLD}Installed (system):${NC}"
    echo "    • Node.js 22 LTS         • Python 3 + pip + venv"
    echo "    • Go (latest)            • Docker + Compose"
    echo "    • Git, ripgrep, fzf, fd  • gh CLI"
    echo "    • PostgreSQL/Redis CLI   • Watchtower + Code Server"
    echo ""
    echo -e "  ${BOLD}Installed (per-user, in /home/$CT_USER):${NC}"
    echo "    • Claude Code            • Codex CLI"
    echo "    • Gemini CLI             • Homebrew (Linuxbrew)"
    echo "    • Rust + cargo           • ctx7 CLI"
    echo "    • npm globals (~/.npm-global)"
    echo "    • Playwright (Chromium)"
    echo ""
    echo -e "  ${BOLD}Skills installed (~/.claude/skills/):${NC}"
    echo "    • frontend-design / webapp-testing"
    echo "    • brainstorming / writing-plans / executing-plans"
    echo "    • test-driven-development"
    echo "    • requesting-code-review / receiving-code-review"
    echo "    • verification-before-completion"
    echo "    • caveman-commit / impeccable / context7-cli"
    echo ""
    echo -e "  ${BOLD}Config:${NC}      /home/$CT_USER/.claude/settings.json"
    echo -e "  ${BOLD}Permissions:${NC} All Claude tools pre-approved (no prompts)"
    echo -e "  ${BOLD}Features:${NC}    Agent teams, 64k output tokens, remote control"
    echo -e "  ${BOLD}Auto-updates:${NC} Sundays 3 AM (apt) / Daily 4 AM (Docker)"
    echo ""
    echo -e "${YELLOW}${BOLD}  ┌─ Post-Setup (run these as $CT_USER inside the container) ──────┐${NC}"
    echo ""
    echo -e "  ${BOLD}1. Authenticate Claude Code${NC}"
    echo -e "     ${CYAN}claude${NC}"
    echo ""
    echo -e "  ${BOLD}2. Authenticate Codex / Gemini${NC}"
    echo -e "     ${CYAN}codex${NC}"
    echo -e "     ${CYAN}gemini${NC}"
    echo ""
    echo -e "  ${BOLD}3. Authenticate gh${NC}"
    echo -e "     ${CYAN}gh auth login${NC}"
    echo ""
    echo -e "  ${BOLD}4. Set up Context7 MCP${NC}"
    echo -e "     ${CYAN}ctx7 setup${NC}  (or ${CYAN}ctx7 setup --api-key YOUR_KEY${NC})"
    echo ""
    echo -e "  ${BOLD}5. Try brew${NC}"
    echo -e "     ${CYAN}brew install <whatever>${NC}  (no root, no bypass — works cleanly)"
    echo ""
    echo -e "${YELLOW}${BOLD}  └────────────────────────────────────────────────────────────────┘${NC}"
    echo ""
}

# ── Main ──────────────────────────────────────────────────────────────────
main() {
    header
    preflight
    get_config
    run_community_script
    provision_container
    print_summary
}

main "$@"