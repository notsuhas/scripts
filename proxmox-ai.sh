#!/usr/bin/env bash
# ============================================================================
#  Claude Code LXC Deployer for Proxmox
#  Wraps the community-scripts Docker LXC (unprivileged, Debian 13) and
#  layers Claude Code, Codex, Gemini, gh, languages, and tooling on top.
#
#  Run on your Proxmox host:
#    curl -fsSL https://raw.githubusercontent.com/notsuhas/scripts/refs/heads/master/proxmox-ai.sh -o /tmp/proxmox-ai.sh && bash /tmp/proxmox-ai.sh
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
  echo -e "${BOLD}║        Claude Code LXC Deployer (Proxmox)       ║${NC}"
  echo -e "${BOLD}║   via community-scripts Docker LXC (unpriv.)    ║${NC}"
  echo -e "${BOLD}╚══════════════════════════════════════════════════╝${NC}"
  echo ""
}

# ── Pre-flight checks ──────────────────────────────────────────────────────
preflight() {
  [[ $(id -u) -eq 0 ]] || error "This script must be run as root on the Proxmox host."
  command -v pct &>/dev/null   || error "pct not found. Are you running this on a Proxmox host?"
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
  [[ -n "$CT_PASSWORD" ]] || error "Password cannot be empty."

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

  # Suppress telemetry whiptail dialog
  cat > /usr/local/community-scripts/diagnostics <<EOF
DIAGNOSTICS=no
EOF

  # Pre-seed storage so the storage selection step is silent
  cat > /usr/local/community-scripts/default.vars <<EOF
var_template_storage=$CT_TPL_STORAGE
var_container_storage=$CT_STORAGE
EOF

  # Read SSH key contents (community-scripts wants the key body, not a path)
  local ssh_key_content=""
  if [[ -n "${CT_SSH_KEY:-}" && -f "$CT_SSH_KEY" ]]; then
    ssh_key_content="$(cat "$CT_SSH_KEY")"
  fi

  info "Launching community-scripts Docker LXC..."
  echo ""

  # Settings consumed by misc/build.func during 'default' install mode
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

  # Sanity check — container should exist and be running
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

# ── Provision Container (everything beyond Docker) ────────────────────────
provision_container() {
  info "Provisioning container with Claude Code stack (this takes a few minutes)..."

  local tz="$CT_TZ"

  cat > /tmp/provision-${CT_ID}.sh << PROVISION_EOF
#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive
TZ="${tz}"

echo ">>> Setting timezone to \$TZ..."
ln -sf "/usr/share/zoneinfo/\$TZ" /etc/localtime
echo "\$TZ" > /etc/timezone
dpkg-reconfigure -f noninteractive tzdata

echo ">>> Generating locale..."
apt-get update -qq
apt-get install -y -qq locales
sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen
locale-gen en_US.UTF-8 > /dev/null 2>&1
update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

echo ">>> Updating system..."
apt-get upgrade -y -qq

echo ">>> Installing core packages..."
apt-get install -y -qq \
  git curl wget unzip zip \
  ca-certificates gnupg lsb-release apt-transport-https \
  bash-completion locales \
  htop nano vim tmux screen \
  jq yq tree \
  net-tools iproute2 iputils-ping dnsutils \
  openssh-server \
  cron logrotate

echo ">>> Installing build tools & dev libraries..."
apt-get install -y -qq \
  build-essential make cmake pkg-config autoconf automake libtool \
  python3 python3-pip python3-venv python3-dev \
  libssl-dev libffi-dev libsqlite3-dev zlib1g-dev \
  libreadline-dev libbz2-dev libncurses-dev liblzma-dev libxml2-dev libxslt-dev

echo ">>> Installing search & productivity tools..."
apt-get install -y -qq \
  ripgrep fd-find fzf bat \
  rsync \
  sqlite3

echo ">>> Installing database clients..."
apt-get install -y -qq \
  postgresql-client redis-tools

echo ">>> Installing GitHub CLI (gh) via apt..."
apt-get install -y -qq gh
echo "    gh \$(gh --version | head -1 | awk '{print \$3}')"

echo ">>> Installing Node.js 22.x LTS..."
curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
apt-get install -y -qq nodejs
echo "    Node.js \$(node --version) / npm \$(npm --version)"

echo ">>> Installing global npm packages..."
npm install -g typescript ts-node eslint prettier

echo ">>> Installing Claude Code, Codex, and Gemini CLIs..."
curl -fsSL https://claude.ai/install.sh | bash

CLAUDE_BIN=""
for candidate in "\$HOME/.local/bin/claude" "\$HOME/.claude/bin/claude" "/usr/local/bin/claude"; do
  if [[ -x "\$candidate" ]]; then
    CLAUDE_BIN="\$candidate"
    break
  fi
done

if [[ -n "\$CLAUDE_BIN" ]]; then
  if [[ "\$CLAUDE_BIN" != "/usr/local/bin/claude" ]]; then
    ln -sf "\$CLAUDE_BIN" /usr/local/bin/claude
  fi
  echo "    Claude Code installed at \$CLAUDE_BIN"
  claude --version 2>/dev/null || true
else
  echo "    WARNING: claude binary not found after install — PATH may need adjustment"
fi

npm install -g @openai/codex 2>/dev/null || \
  echo "    WARNING: codex install failed — run: npm install -g @openai/codex"
echo "    codex \$(codex --version 2>/dev/null || echo '(not on PATH yet)')"

npm install -g @google/gemini-cli 2>/dev/null || \
  echo "    WARNING: gemini install failed — run: npm install -g @google/gemini-cli"
echo "    gemini \$(gemini --version 2>/dev/null || echo '(not on PATH yet)')"

echo ">>> Installing Go..."
GO_VERSION=\$(curl -fsSL "https://go.dev/VERSION?m=text" | head -1)
curl -fsSL "https://go.dev/dl/\${GO_VERSION}.linux-amd64.tar.gz" -o /tmp/go.tar.gz
rm -rf /usr/local/go
tar -C /usr/local -xzf /tmp/go.tar.gz
rm /tmp/go.tar.gz
echo 'export PATH=\$PATH:/usr/local/go/bin' >> /etc/profile.d/go.sh
echo "    Go \$(/usr/local/go/bin/go version | awk '{print \$3}')"

echo ">>> Installing Rust..."
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source "\$HOME/.cargo/env"
echo "    Rust \$(rustc --version | awk '{print \$2}')"

echo ">>> Configuring Claude Code permissions (full auto-approve)..."
mkdir -p /root/.claude

cat > /root/.claude/settings.json << 'SETTINGS_EOF'
{
  "\$schema": "https://json.schemastore.org/claude-code-settings.json",
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

echo ">>> Installing skills via skills.sh..."
mkdir -p /root/.claude/skills

npx -y skills add anthropics/skills --skill frontend-design --agent claude-code --yes 2>/dev/null || \
  echo "    WARNING: frontend-design install failed"

npx -y skills add anthropics/skills --skill webapp-testing --agent claude-code --yes 2>/dev/null || \
  echo "    WARNING: webapp-testing install failed"

npx -y skills add obra/superpowers --skill brainstorming --agent claude-code --yes 2>/dev/null || \
  echo "    WARNING: brainstorming install failed"

npx -y skills add obra/superpowers --skill writing-plans --agent claude-code --yes 2>/dev/null || \
  echo "    WARNING: writing-plans install failed"

npx -y skills add obra/superpowers --skill executing-plans --agent claude-code --yes 2>/dev/null || \
  echo "    WARNING: executing-plans install failed"

npx -y skills add obra/superpowers --skill test-driven-development --agent claude-code --yes 2>/dev/null || \
  echo "    WARNING: test-driven-development install failed"

npx -y skills add obra/superpowers --skill requesting-code-review --agent claude-code --yes 2>/dev/null || \
  echo "    WARNING: requesting-code-review install failed"

npx -y skills add obra/superpowers --skill receiving-code-review --agent claude-code --yes 2>/dev/null || \
  echo "    WARNING: receiving-code-review install failed"

npx -y skills add obra/superpowers --skill verification-before-completion --agent claude-code --yes 2>/dev/null || \
  echo "    WARNING: verification-before-completion install failed"

npx -y skills add juliusbrussee/caveman --skill caveman-commit --agent claude-code --yes 2>/dev/null || \
  echo "    WARNING: caveman-commit install failed"

npx -y skills add pbakaus/impeccable --skill impeccable --agent claude-code --yes 2>/dev/null || \
  echo "    WARNING: impeccable install failed"

npx -y skills add https://github.com/upstash/context7 --skill context7-cli --agent claude-code --yes 2>/dev/null || \
  echo "    WARNING: context7-cli install failed"

echo "    Skills installed to ~/.claude/skills/"

echo ">>> Installing ctx7 CLI globally..."
npm install -g ctx7@latest 2>/dev/null || \
  echo "    WARNING: ctx7 install failed — run: npm install -g ctx7@latest"

echo ">>> Setting up /project directory..."
mkdir -p /project

cat > /project/CLAUDE.md << 'CLAUDEMD'
# Claude Code Workspace

## Environment
- **OS**: Debian 13 unprivileged LXC on Proxmox (community-scripts Docker LXC)
- **Working directory**: /project
- **User**: root

## Available Tools
- **Languages**: Node.js 22 LTS, Python 3 (use --break-system-packages for pip), Go (latest), Rust (latest)
- **Package managers**: npm, pip (use --break-system-packages), cargo, go install
- **Docker**: Docker Engine + Compose plugin (installed by community-scripts)
- **Containers**: Watchtower (auto-updates), Code Server (port 8443)
- **AI CLIs**: claude, codex, gemini, ctx7
- **GitHub**: gh (apt-installed)
- **Search tools**: ripgrep (rg), fd-find (fdfind), fzf
- **Databases**: PostgreSQL client (psql), Redis client (redis-cli), SQLite3

## Permissions
All tools are pre-approved — no permission prompts. Bash, Read, Write, Edit, WebFetch, WebSearch, Task, and MCP tools all run without confirmation.

## Agent Teams
Agent teams are enabled via CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1.
Use the Task tool for subagents. tmux is installed for split-pane visualization.

## Remote Control
Remote control is enabled. Use /remote-control or press spacebar to show QR code.

## Docker Usage
Docker compose files go in /docker/<service-name>/docker-compose.yml.
Watchtower auto-updates any containers with \`restart: unless-stopped\`.

## Conventions
- Prefer creating files over printing long code blocks
- Use git for version control on all projects in /project/src/
- When installing Python packages: pip install --break-system-packages <package>

## Installed Skills
- **frontend-design** (anthropics/skills) — production-grade UI
- **webapp-testing** (anthropics/skills) — Playwright browser testing
- **brainstorming** (obra/superpowers) — refine ideas before coding
- **writing-plans** (obra/superpowers) — structured implementation plans
- **executing-plans** (obra/superpowers) — run plans via subagents
- **test-driven-development** (obra/superpowers) — TDD workflow
- **requesting-code-review** (obra/superpowers) — structured code review requests
- **receiving-code-review** (obra/superpowers) — handling review feedback well
- **verification-before-completion** (obra/superpowers) — sanity checks before finishing
- **caveman-commit** (juliusbrussee/caveman) — git commit workflow
- **impeccable** (pbakaus/impeccable) — security hardening guidance
- **context7-cli** (upstash/context7) — live library docs via ctx7 CLI
CLAUDEMD

echo ">>> Installing Playwright for webapp-testing skill..."
npx -y playwright install --with-deps chromium 2>/dev/null || \
  echo "    WARNING: Playwright install failed — run manually if needed"

echo ">>> Configuring SSH..."
sed -i "s/^#*PermitRootLogin.*/PermitRootLogin yes/" /etc/ssh/sshd_config
sed -i "s/^#*PasswordAuthentication.*/PasswordAuthentication yes/" /etc/ssh/sshd_config
systemctl enable ssh
systemctl restart ssh

echo ">>> Setting up shell environment..."
cat >> /root/.bashrc << BASHRC

# ── Claude Code Container ──────────────────────────────────
export EDITOR=nano
export LANG=en_US.UTF-8
export TZ="${tz}"
export PATH="\$HOME/.local/bin:\$HOME/.claude/bin:\$HOME/.cargo/bin:/usr/local/go/bin:\$PATH"

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

echo ">>> Setting up Git defaults..."
git config --global init.defaultBranch main
git config --global core.editor nano
git config --global pull.rebase false

echo ">>> Setting up Docker services..."
mkdir -p /docker/watchtower
cat > /docker/watchtower/docker-compose.yml << DCOMPOSE
services:
  watchtower:
    image: containrrr/watchtower
    container_name: watchtower
    restart: unless-stopped
    environment:
      TZ: "${tz}"
      WATCHTOWER_CLEANUP: "true"
      WATCHTOWER_INCLUDE_STOPPED: "true"
      WATCHTOWER_SCHEDULE: "0 0 4 * * *"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
DCOMPOSE

mkdir -p /docker/code-server
cat > /docker/code-server/docker-compose.yml << DCOMPOSE2
services:
  code-server:
    image: lscr.io/linuxserver/code-server:latest
    container_name: code-server
    restart: unless-stopped
    environment:
      PUID: "0"
      PGID: "0"
      TZ: "${tz}"
      PASSWORD: admin
    volumes:
      - ./config:/config
      - /:/config/workspace
    ports:
      - 8443:8443
DCOMPOSE2

cd /docker/watchtower && docker compose up -d
cd /docker/code-server && docker compose up -d

echo ">>> Setting up weekly system update cron..."
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

echo ">>> Cleaning up..."
apt-get autoremove -y -qq
apt-get clean -qq
rm -rf /var/lib/apt/lists/*

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║          Provisioning Complete!                  ║"
echo "╚══════════════════════════════════════════════════╝"
PROVISION_EOF

  chmod +x /tmp/provision-${CT_ID}.sh
  pct push "$CT_ID" /tmp/provision-${CT_ID}.sh /tmp/provision.sh
  pct exec "$CT_ID" -- chmod +x /tmp/provision.sh
  pct exec "$CT_ID" -- /tmp/provision.sh
  rm -f /tmp/provision-${CT_ID}.sh
}

# ── Print Summary ─────────────────────────────────────────────────────────
print_summary() {
  local ct_ip
  ct_ip=$(pct exec "$CT_ID" -- hostname -I 2>/dev/null | awk '{print $1}')

  echo ""
  echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════╗${NC}"
  echo -e "${GREEN}${BOLD}║       Claude Code LXC Ready!                    ║${NC}"
  echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "  ${BOLD}Container:${NC}  $CT_ID ($CT_HOSTNAME) — unprivileged Debian 13"
  echo -e "  ${BOLD}IP:${NC}         ${ct_ip:-pending (DHCP)}"
  echo -e "  ${BOLD}Resources:${NC}  ${CT_CORES} CPU / $(( CT_RAM / 1024 )) GB RAM / ${CT_DISK} GB disk"
  echo -e "  ${BOLD}Storage:${NC}    $CT_STORAGE (template on $CT_TPL_STORAGE)"
  echo -e "  ${BOLD}Timezone:${NC}   $CT_TZ"
  echo ""
  echo -e "  ${BOLD}Connect:${NC}"
  echo -e "    Console:  ${CYAN}pct enter $CT_ID${NC}"
  [[ -n "${ct_ip:-}" ]] && echo -e "    SSH:      ${CYAN}ssh root@${ct_ip}${NC}"
  [[ -n "${ct_ip:-}" ]] && echo -e "    Code:     ${CYAN}http://${ct_ip}:8443${NC}  (password: admin)"
  echo ""
  echo -e "  ${BOLD}Start AI CLIs:${NC}"
  echo -e "    ${CYAN}claude${NC}   (shell auto-cd's to /project on login)"
  echo -e "    ${CYAN}codex${NC}    (OpenAI Codex CLI)"
  echo -e "    ${CYAN}gemini${NC}   (Google Gemini CLI)"
  echo ""
  echo -e "  ${BOLD}Installed:${NC}"
  echo "    • Claude Code (native)    • Codex CLI (npm)"
  echo "    • Gemini CLI (npm)        • gh CLI (apt)"
  echo "    • Node.js 22 LTS          • Python 3 + pip + venv"
  echo "    • Go (latest)             • Rust (via rustup)"
  echo "    • Docker + Compose        • Git, ripgrep, fzf, fd"
  echo "    • PostgreSQL & Redis CLI  • Playwright (Chromium)"
  echo "    • ctx7 CLI (global)       • Watchtower + Code Server"
  echo ""
  echo -e "  ${BOLD}Skills installed (~/.claude/skills/):${NC}"
  echo "    • frontend-design                  anthropics/skills"
  echo "    • webapp-testing                   anthropics/skills"
  echo "    • brainstorming                    obra/superpowers"
  echo "    • writing-plans                    obra/superpowers"
  echo "    • executing-plans                  obra/superpowers"
  echo "    • test-driven-development          obra/superpowers"
  echo "    • requesting-code-review           obra/superpowers"
  echo "    • receiving-code-review            obra/superpowers"
  echo "    • verification-before-completion   obra/superpowers"
  echo "    • caveman-commit                   juliusbrussee/caveman"
  echo "    • impeccable                       pbakaus/impeccable"
  echo "    • context7-cli                     upstash/context7"
  echo ""
  echo -e "  ${BOLD}Config:${NC}      ~/.claude/settings.json"
  echo -e "  ${BOLD}Permissions:${NC} All tools pre-approved (no prompts)"
  echo -e "  ${BOLD}Features:${NC}    Agent teams, 64k output tokens, remote control"
  echo -e "  ${BOLD}Auto-updates:${NC} Sundays 3 AM local (system) / Daily 4 AM local (Docker)"
  echo ""
  echo -e "${YELLOW}${BOLD}  ┌─ Post-Setup (run these inside the container) ──────────────────┐${NC}"
  echo ""
  echo -e "  ${BOLD}1. Authenticate Claude Code${NC}"
  echo -e "     ${CYAN}claude${NC}"
  echo "     Follow the browser login flow on first launch."
  echo ""
  echo -e "  ${BOLD}2. Authenticate Codex / Gemini${NC}"
  echo -e "     ${CYAN}codex${NC}      # signs in with your OpenAI account"
  echo -e "     ${CYAN}gemini${NC}     # signs in with your Google account"
  echo ""
  echo -e "  ${BOLD}3. Authenticate gh${NC}"
  echo -e "     ${CYAN}gh auth login${NC}"
  echo ""
  echo -e "  ${BOLD}4. Set up Context7 MCP (live library docs)${NC}"
  echo -e "     ${CYAN}ctx7 setup${NC}"
  echo "     Opens a browser OAuth flow for a free Context7 account."
  echo "     Prefer an API key instead? Skip OAuth:"
  echo -e "     ${CYAN}ctx7 setup --api-key YOUR_KEY${NC}"
  echo "     Get a key at: https://context7.com"
  echo "     Once set up, Claude Code uses ctx7 automatically via the"
  echo "     context7-cli skill when you ask about any library or framework."
  echo ""
  echo -e "  ${BOLD}5. Add more skills anytime${NC}"
  echo -e "     ${CYAN}npx skills add <owner/repo> --agent claude-code${NC}"
  echo -e "     Browse: ${CYAN}https://skills.sh${NC}"
  echo ""
  echo -e "  ${BOLD}6. Use ctx7 manually from the shell${NC}"
  echo -e "     ${CYAN}ctx7 library react${NC}               # resolve library ID"
  echo -e "     ${CYAN}ctx7 docs /facebook/react hooks${NC}  # fetch docs for that topic"
  echo -e "     ${CYAN}ctx7 skills search <keyword>${NC}     # search skills registry"
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
