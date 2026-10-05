#!/usr/bin/env bash
# omp module: oh-my-pi (omp), the my-omp config at ~/.omp and what it expects
# on the machine. Every step is idempotent and honours --dry-run.
#
#   omp/install.sh [--profile mac|ubuntu|vps] [--dry-run]
#
# Steps: prerequisites; bun; node; omp + pi-skill-evolution (bun globals);
# my-omp at ~/.omp; plugins; ~/.claude/CLAUDE.md; global skills; herdr
# integration; design-inspiration MCP server; ai-memory client + tunnel;
# manual steps.
# Versions and pins live in the block below: bump them here.
set -euo pipefail

# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
parse_args "$@"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

OMP_VERSION=18.3.1
SKILL_EVOLUTION_VERSION=0.2.0
# omp 18.3.x needs a bun that parses `using` and bun.lock lockfileVersion 2.
BUN_VERSION=1.4.2

MY_OMP_REPO=git@github.com:MarcusToledo/my-omp.git
MY_OMP_BRANCH=master
OMP_HOME="$HOME/.omp"

DESIGN_MCP_REPO=https://github.com/YonasValentin/design-inspiration-mcp-server.git
DESIGN_MCP_COMMIT=2935c0775fb1cfe3d95503615901e1fa743430e8
DESIGN_MCP_DIR="$HOME/.local/share/mcp-servers/design-inspiration-mcp-server"
# Serper's free tier rejects `site:` operators; the patch scopes by keyword.
DESIGN_MCP_PATCH="$here/patches/design-inspiration-mcp-server.patch"

AI_MEMORY_VERSION=2.3.2
AI_MEMORY_PORT=49374
VPS_HOST=marcus@100.83.227.115
TUNNEL_LABEL=com.marcus.ai-memory-tunnel
TUNNEL_UNIT=ai-memory-tunnel.service

# Highest `engines.node` in the design-inspiration lockfile (@hono/node-server,
# via @modelcontextprotocol/sdk); agent/mcp.json also starts it with `node`.
# Below this, node comes from brew (mac) or the nodejs.org LTS tarball (linux).
NODE_MIN=18.14.1
NODE_DIST=https://nodejs.org/dist

# One skill per line: <installed name> <`skills add` arguments>.
SKILLS="humanizer blader/humanizer
find-skills vercel-labs/skills -s find-skills
herdr herdrdev/herdr -s herdr
code-documentation bytedance/deer-flow -s code-documentation"
SKILLS_DIR="$HOME/.agents/skills"

# Names agent/mcp.json expands from agent/.env.
ENV_NAMES="SERPER_API_KEY FIGMA_OAUTH_CLIENT_SECRET"

# --- helpers -----------------------------------------------------------------

# global_version <package>: version of an installed bun global, empty if absent.
global_version() {
  local pj="${BUN_INSTALL:-$HOME/.bun}/install/global/node_modules/$1/package.json"
  [[ -f "$pj" ]] || return 0
  grep -m 1 '"version"' "$pj" | sed 's/.*"version":[[:space:]]*"\([^"]*\)".*/\1/' || true
}

# github_ssh: `ssh -T git@github.com` exits 1 even on success; trust the banner.
# A dry run must not add GitHub to known_hosts, so it only accepts known keys.
github_ssh() {
  local hostkeys=accept-new out
  $DRY_RUN && hostkeys=yes
  out="$(ssh -T -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=$hostkeys git@github.com 2>&1 || true)"
  [[ "$out" == *"successfully authenticated"* ]]
}

# require_github_ssh: die (warn under --dry-run) unless GitHub SSH auth works.
require_github_ssh() {
  if github_ssh; then
    log "GitHub SSH auth: ok"
    return 0
  fi
  local msg="GitHub SSH auth failed (ssh -T git@github.com). my-omp is private: create a key (ssh-keygen -t ed25519), add ~/.ssh/id_ed25519.pub at https://github.com/settings/keys, then re-run."
  if $DRY_RUN; then
    warn "$msg"
    return 1
  fi
  die "$msg"
}

# omp_home_conflicts: tracked paths of origin/<branch> that exist in ~/.omp with
# other content. The allowlist .gitignore means only curated config is tracked
# (agent/config.yml, mcp.json, models.yml, AGENTS.md, agents/, commands/,
# extensions/, skills/, plugins manifest + lockfiles + patches); runtime state
# (agent.db, sessions, caches) is ignored, so `reset --hard` never touches it.
# Anything printed here is local content a reset would silently overwrite.
omp_home_conflicts() {
  local entry meta path sha
  git -C "$OMP_HOME" ls-tree -r -z "origin/$MY_OMP_BRANCH" | while IFS= read -r -d '' entry; do
    meta="${entry%%$'\t'*}" path="${entry#*$'\t'}"
    sha="${meta##* }"
    [[ -e "$OMP_HOME/$path" || -L "$OMP_HOME/$path" ]] || continue
    if [[ -L "$OMP_HOME/$path" || ! -f "$OMP_HOME/$path" ]] ||
      [[ "$(git -C "$OMP_HOME" hash-object -- "$path")" != "$sha" ]]; then
      printf '%s\n' "$path"
    fi
  done
}

# adopt_omp_home: ~/.omp exists without history (omp creates it on first run).
adopt_omp_home() {
  log "$OMP_HOME exists without git history (created by omp's first run)"
  if $DRY_RUN; then
    require_github_ssh || true
    [[ -d "$OMP_HOME/.git" ]] || run git -C "$OMP_HOME" init -q -b "$MY_OMP_BRANCH"
    if [[ ! -d "$OMP_HOME/.git" ]] || ! git -C "$OMP_HOME" remote get-url origin >/dev/null 2>&1; then
      run git -C "$OMP_HOME" remote add origin "$MY_OMP_REPO"
    fi
    run git -C "$OMP_HOME" fetch -q origin "$MY_OMP_BRANCH"
    log "[dry-run] then reset --hard origin/$MY_OMP_BRANCH, unless a tracked path already holds different local content"
    return 0
  fi
  require_github_ssh
  [[ -d "$OMP_HOME/.git" ]] || git -C "$OMP_HOME" init -q -b "$MY_OMP_BRANCH"
  git -C "$OMP_HOME" remote get-url origin >/dev/null 2>&1 ||
    git -C "$OMP_HOME" remote add origin "$MY_OMP_REPO"
  git -C "$OMP_HOME" fetch -q origin "$MY_OMP_BRANCH"
  local conflicts
  conflicts="$(omp_home_conflicts)"
  if [[ -n "$conflicts" ]]; then
    die "$(printf 'reset --hard origin/%s would overwrite local content in %s:\n%s\nMove these aside (e.g. mv agent/config.yml agent/config.yml.local), then re-run.' \
      "$MY_OMP_BRANCH" "$OMP_HOME" "$conflicts")"
  fi
  git -C "$OMP_HOME" symbolic-ref HEAD "refs/heads/$MY_OMP_BRANCH"
  git -C "$OMP_HOME" reset -q --hard "origin/$MY_OMP_BRANCH"
  git -C "$OMP_HOME" branch -q --set-upstream-to="origin/$MY_OMP_BRANCH"
  log "adopted: $OMP_HOME at origin/$MY_OMP_BRANCH ($(git -C "$OMP_HOME" rev-parse --short HEAD))"
}

# update_omp_home: fast-forward only, and only from a clean worktree.
update_omp_home() {
  local dirty before
  dirty="$(git -C "$OMP_HOME" status --porcelain)"
  if [[ -n "$dirty" ]]; then
    warn "$OMP_HOME has local changes; skipping pull (commit or stash them, then re-run):"
    printf '%s\n' "$dirty" | sed 's/^/      /' >&2
    return 0
  fi
  require_github_ssh || return 0
  before="$(git -C "$OMP_HOME" rev-parse HEAD)"
  if ! run git -C "$OMP_HOME" pull -q --ff-only; then
    warn "git pull --ff-only failed in $OMP_HOME (diverged from origin?); resolve by hand"
    return 0
  fi
  if $DRY_RUN; then
    return 0
  elif [[ "$(git -C "$OMP_HOME" rev-parse HEAD)" == "$before" ]]; then
    log "up to date ($(git -C "$OMP_HOME" rev-parse --short HEAD))"
  else
    log "updated ${before:0:7} -> $(git -C "$OMP_HOME" rev-parse --short HEAD)"
  fi
}

# install_design_mcp: clone at the pinned commit, apply the local patch, build.
install_design_mcp() {
  local dir="$DESIGN_MCP_DIR" patch="$DESIGN_MCP_PATCH" pin="${DESIGN_MCP_COMMIT:0:7}" head build=false
  [[ -f "$patch" ]] || die "missing $patch"

  if [[ ! -e "$dir" ]]; then
    if $DRY_RUN; then
      log "[dry-run] absent: would clone $DESIGN_MCP_REPO @ $pin into $dir, git apply $(basename "$patch"), npm ci, npm run build"
      return 0
    fi
    mkdir -p "$(dirname "$dir")"
    git clone -q "$DESIGN_MCP_REPO" "$dir"
    git -C "$dir" -c advice.detachedHead=false checkout -q "$DESIGN_MCP_COMMIT"
  fi
  [[ -d "$dir/.git" ]] || die "$dir exists but is not a git checkout; move it aside and re-run"

  head="$(git -C "$dir" rev-parse HEAD)"
  if [[ "$head" != "$DESIGN_MCP_COMMIT" ]]; then
    log "at ${head:0:7}, pinned $pin: local edits get stashed, then checkout"
    if $DRY_RUN; then
      log "[dry-run] would stash, fetch, checkout $pin, re-apply the patch and rebuild"
      return 0
    fi
    if [[ -n "$(git -C "$dir" status --porcelain --untracked-files=no)" ]]; then
      git -C "$dir" stash push -q -m "dotfiles: before checkout of $pin"
    fi
    git -C "$dir" fetch -q origin
    git -C "$dir" -c advice.detachedHead=false checkout -q "$DESIGN_MCP_COMMIT"
    build=true
  fi

  if git -C "$dir" apply --reverse --check "$patch" 2>/dev/null; then
    log "local patch: applied"
  elif git -C "$dir" apply --check "$patch" 2>/dev/null; then
    run git -C "$dir" apply "$patch"
    build=true
  else
    die "$patch does not apply to $dir @ $pin (and is not already applied). Inspect local edits there, or regenerate the patch for the pinned commit."
  fi

  if [[ ! -d "$dir/node_modules" || "$dir/package-lock.json" -nt "$dir/node_modules" ]]; then
    (cd "$dir" && run npm ci --no-audit --no-fund --loglevel=error)
    build=true
  fi
  if $build || [[ ! -f "$dir/dist/index.js" || "$dir/src/index.ts" -nt "$dir/dist/index.js" ]]; then
    (cd "$dir" && run npm run build --silent)
    log "built $dir/dist/index.js"
  else
    log "dist/index.js @ $pin: up to date"
  fi
}

# ai_memory_asset: release asset name for this OS/arch.
ai_memory_asset() {
  case "$(uname -s)/$(uname -m)" in
    Darwin/arm64) echo ai-memory-macos-aarch64 ;;
    Darwin/x86_64) echo ai-memory-macos-x86_64 ;;
    Linux/aarch64 | Linux/arm64) echo ai-memory-linux-aarch64 ;;
    Linux/x86_64) echo ai-memory-linux-x86_64 ;;
    *) die "no ai-memory release asset for $(uname -s)/$(uname -m)" ;;
  esac
}

# sha256_ok <dir> <sums file>: check every file listed in <sums file> inside <dir>.
sha256_ok() {
  if have sha256sum; then
    (cd "$1" && sha256sum --status -c "$2")
  else
    (cd "$1" && shasum -a 256 --status -c "$2")
  fi
}

# install_ai_memory <asset>: download, verify sha256, install to ~/.local/bin.
install_ai_memory() {
  local asset="$1" tmp url
  url="https://github.com/akitaonrails/ai-memory/releases/download/v$AI_MEMORY_VERSION/$asset.tar.gz"
  tmp="$(mktemp -d)"
  curl -fsSL "$url" -o "$tmp/$asset.tar.gz"
  curl -fsSL "$url.sha256" -o "$tmp/$asset.tar.gz.sha256"
  if ! sha256_ok "$tmp" "$asset.tar.gz.sha256"; then
    rm -rf "$tmp"
    die "sha256 mismatch for $asset.tar.gz ($url)"
  fi
  tar -xzf "$tmp/$asset.tar.gz" -C "$tmp"
  mkdir -p "$HOME/.local/bin"
  install -m 0755 "$tmp/ai-memory" "$HOME/.local/bin/ai-memory"
  rm -rf "$tmp"
  log "installed $(ai-memory --version)"
}

tunnel_plist() {
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$TUNNEL_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/ssh</string>
    <string>-N</string>
    <string>-o</string><string>BatchMode=yes</string>
    <string>-o</string><string>ExitOnForwardFailure=yes</string>
    <string>-o</string><string>ServerAliveInterval=60</string>
    <string>-L</string><string>$AI_MEMORY_PORT:127.0.0.1:$AI_MEMORY_PORT</string>
    <string>$VPS_HOST</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
</dict>
</plist>
EOF
}

tunnel_unit() {
  cat <<EOF
[Unit]
Description=SSH tunnel to the ai-memory server on the VPS (127.0.0.1:$AI_MEMORY_PORT)
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/bin/ssh -N -o BatchMode=yes -o ExitOnForwardFailure=yes -o ServerAliveInterval=60 -L $AI_MEMORY_PORT:127.0.0.1:$AI_MEMORY_PORT $VPS_HOST
Restart=always
RestartSec=10

[Install]
WantedBy=default.target
EOF
}

# write_if_changed <generator> <path>: returns 0 when the file was (or would be)
# written, 1 when it already matches.
write_if_changed() {
  local gen="$1" path="$2" stage
  stage="$(mktemp)"
  "$gen" >"$stage"
  if [[ -f "$path" ]] && cmp -s "$stage" "$path"; then
    rm -f "$stage"
    log "$path: up to date"
    return 1
  fi
  if [[ -f "$path" ]]; then
    log "$path: differs, rewriting"
    backup "$path"
  else
    log "$path: absent, writing"
  fi
  run mkdir -p "$(dirname "$path")"
  run cp "$stage" "$path"
  rm -f "$stage"
}

tunnel_launchd() {
  local plist="$HOME/Library/LaunchAgents/$TUNNEL_LABEL.plist" domain
  domain="gui/$(id -u)"
  if write_if_changed tunnel_plist "$plist"; then
    if launchctl print "$domain/$TUNNEL_LABEL" >/dev/null 2>&1; then
      run launchctl bootout "$domain/$TUNNEL_LABEL"
    fi
    run launchctl bootstrap "$domain" "$plist"
  elif launchctl print "$domain/$TUNNEL_LABEL" >/dev/null 2>&1; then
    log "launchd job $TUNNEL_LABEL: loaded"
  else
    run launchctl bootstrap "$domain" "$plist"
  fi
}

tunnel_systemd() {
  local unit_path="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/$TUNNEL_UNIT"
  if ! have systemctl; then
    $DRY_RUN || die "systemctl not found; the ubuntu profile runs the ai-memory tunnel as a systemd --user unit"
    warn "systemctl not found here; would install $TUNNEL_UNIT on an Ubuntu desktop with systemd"
  fi
  if write_if_changed tunnel_unit "$unit_path"; then
    run systemctl --user daemon-reload
    run systemctl --user enable -q "$TUNNEL_UNIT"
    run systemctl --user restart "$TUNNEL_UNIT"
  elif systemctl --user -q is-enabled "$TUNNEL_UNIT" 2>/dev/null &&
    systemctl --user -q is-active "$TUNNEL_UNIT" 2>/dev/null; then
    log "$TUNNEL_UNIT: enabled, active"
  else
    run systemctl --user enable --now "$TUNNEL_UNIT"
  fi
}

port_open() {
  if have nc; then
    nc -z -w 3 127.0.0.1 "$AI_MEMORY_PORT" >/dev/null 2>&1
  else
    (exec 3<>"/dev/tcp/127.0.0.1/$AI_MEMORY_PORT") 2>/dev/null
  fi
}

# probe_ai_memory: a freshly (re)started tunnel needs a moment to listen.
probe_ai_memory() {
  local tries=5
  $DRY_RUN && tries=1
  while ((tries > 0)); do
    if port_open; then
      log "127.0.0.1:$AI_MEMORY_PORT: listening"
      return 0
    fi
    tries=$((tries - 1))
    ((tries > 0)) && sleep 1
  done
  if [[ "$PROFILE" == vps ]]; then
    warn "ai-memory not listening on 127.0.0.1:$AI_MEMORY_PORT: start the container (cd ~/docker/ai-memory && docker compose up -d)"
  else
    warn "ai-memory tunnel not up on 127.0.0.1:$AI_MEMORY_PORT: check Tailscale (tailscale status) and the SSH key for $VPS_HOST (ssh $VPS_HOST true)"
  fi
}

# version_ge <a> <b>: dotted numeric versions, a >= b.
version_ge() {
  local i
  local -a a b
  IFS=. read -r -a a <<<"$1"
  IFS=. read -r -a b <<<"$2"
  for i in 0 1 2; do
    if ((${a[i]:-0} > ${b[i]:-0})); then return 0; fi
    if ((${a[i]:-0} < ${b[i]:-0})); then return 1; fi
  done
  return 0
}

# node_ok: node, npm and npx on PATH, node >= NODE_MIN.
node_ok() {
  local v
  have node && have npm && have npx || return 1
  v="$(node --version 2>/dev/null || true)"
  version_ge "${v#v}" "$NODE_MIN"
}

# install_node_linux: current LTS from nodejs.org into ~/.local/share/node-<ver>,
# node/npm/npx linked into ~/.local/bin. No sudo; distro packages are too old
# (Ubuntu 22.04 ships node 12).
install_node_linux() {
  local arch index version name dest tmp bin
  case "$(uname -m)" in
    x86_64 | amd64) arch=x64 ;;
    aarch64 | arm64) arch=arm64 ;;
    *) die "node: no official Linux tarball for $(uname -m); install Node.js >= $NODE_MIN manually" ;;
  esac
  # index.json lists releases newest first, one per line; LTS lines carry "lts":"<codename>".
  # Download whole, then filter without early exit: grep -m 1 on a pipe would
  # SIGPIPE the writer.
  index="$(curl -fsSL "$NODE_DIST/index.json")" || die "node: could not download $NODE_DIST/index.json"
  version="$(grep '"lts":"' <<<"$index" | sed -n '1s/.*"version":"\(v[0-9.]*\)".*/\1/p' || true)"
  [[ "$version" == v[0-9]* ]] || die "node: could not resolve the current LTS from $NODE_DIST/index.json"
  name="node-$version-linux-$arch"
  dest="$HOME/.local/share/node-$version"
  if [[ -x "$dest/bin/node" ]]; then
    log "node $version: already unpacked at $dest"
  elif $DRY_RUN; then
    log "[dry-run] would download $NODE_DIST/$version/$name.tar.gz, verify it against SHASUMS256.txt, unpack to $dest"
  else
    log "node $version ($arch) -> $dest"
    tmp="$(mktemp -d)"
    curl -fsSL --retry 3 -o "$tmp/$name.tar.gz" "$NODE_DIST/$version/$name.tar.gz"
    curl -fsSL --retry 3 -o "$tmp/SHASUMS256.txt" "$NODE_DIST/$version/SHASUMS256.txt"
    if ! grep " $name.tar.gz\$" "$tmp/SHASUMS256.txt" >"$tmp/sum" || ! sha256_ok "$tmp" sum; then
      rm -rf "$tmp"
      die "node: $name.tar.gz failed verification against $NODE_DIST/$version/SHASUMS256.txt"
    fi
    mkdir -p "$tmp/unpack" "$(dirname "$dest")"
    tar -xzf "$tmp/$name.tar.gz" -C "$tmp/unpack" --strip-components=1
    mv "$tmp/unpack" "$dest"
    rm -rf "$tmp"
  fi
  run mkdir -p "$HOME/.local/bin"
  for bin in node npm npx; do
    run ln -sfn "$dest/bin/$bin" "$HOME/.local/bin/$bin"
  done
}

# System tools are installed via apt/Homebrew when available. Collect all
# missing packages before changing this machine to avoid repeated prompts.
step "prerequisites"
missing_tools=""
for tool in curl git ssh tar; do
  have "$tool" || missing_tools="$missing_tools $tool"
done
have sha256sum || have shasum || missing_tools="$missing_tools sha256sum"
# bun's installer unpacks a zip; needed when bun is absent or older than BUN_VERSION.
if ! have unzip && ! version_ge "$(bun --version 2>/dev/null || echo 0)" "$BUN_VERSION"; then
  missing_tools="$missing_tools unzip"
fi
if [[ -n "$missing_tools" ]]; then
  if [[ "$(detect_os)" == macos ]]; then
    have brew || die "missing:$missing_tools; install Homebrew (https://brew.sh) and retry"
    packages="$(echo "$missing_tools" | sed 's/ ssh/ openssh/; s/ sha256sum/ coreutils/')"
    if $DRY_RUN; then
      log "[dry-run] brew install$packages"
    else
      # shellcheck disable=SC2086 # collected command names, not user input
      brew install $packages
    fi
  else
    packages="$(echo "$missing_tools" | sed 's/ ssh/ openssh-client/; s/ sha256sum/ coreutils/')"
    have apt-get || die "missing:$missing_tools; install with your distribution's package manager"
    if $DRY_RUN; then
      log "[dry-run] sudo apt-get update && sudo apt-get install -y$packages"
    else
      if [[ "$(id -u)" -eq 0 ]]; then
        apt-get update
        # shellcheck disable=SC2086 # collected command names, not user input
        apt-get install -y $packages
      else
        have sudo || die "missing:$missing_tools; sudo unavailable. Install with: apt-get update && apt-get install -y$packages"
        sudo apt-get update
        # shellcheck disable=SC2086 # collected command names, not user input
        sudo apt-get install -y $packages
      fi
    fi
  fi
else
  log "curl git ssh tar sha256: ok"
fi
if [[ "$(detect_os)" == macos ]] && ! have brew && ! node_ok; then
  die "node >= $NODE_MIN requires Homebrew on macOS; install it from https://brew.sh"
fi

# --- bun -----------------------------------------------------------------------
step "bun"
bun_cur="$(bun --version 2>/dev/null || true)"
if [[ -n "$bun_cur" ]] && version_ge "$bun_cur" "$BUN_VERSION"; then
  log "bun $bun_cur: ok"
else
  log "bun ${bun_cur:-absent} -> $BUN_VERSION (~/.bun/bin)"
  run bash -o pipefail -c "curl -fsSL https://bun.sh/install | bash -s bun-v$BUN_VERSION"
  hash -r
  if ! $DRY_RUN; then
    bun_cur="$(bun --version 2>/dev/null || true)"
    if [[ -z "$bun_cur" ]] || ! version_ge "$bun_cur" "$BUN_VERSION"; then
      die "bun is ${bun_cur:-missing} at $(command -v bun || echo '?'); need >= $BUN_VERSION at ~/.bun/bin/bun (put ~/.bun/bin first in PATH)"
    fi
  fi
fi

# --- node ----------------------------------------------------------------------
step "node >= $NODE_MIN"
if node_ok; then
  log "node $(node --version): ok"
elif [[ "$(detect_os)" == macos ]]; then
  if brew list --versions node >/dev/null 2>&1; then
    run brew upgrade node
  else
    run brew install node
  fi
else
  install_node_linux
fi
hash -r
if ! $DRY_RUN && ! node_ok; then
  die "node >= $NODE_MIN is installed but not first on PATH (found: $(command -v node || echo none)); put ~/.local/bin (linux) or Homebrew first in PATH and re-run"
fi

# --- omp + pi-skill-evolution ------------------------------------------------
step "omp $OMP_VERSION + pi-skill-evolution $SKILL_EVOLUTION_VERSION (bun globals)"
pending=""
for spec in "@oh-my-pi/pi-coding-agent@$OMP_VERSION" "pi-skill-evolution@$SKILL_EVOLUTION_VERSION"; do
  pkg="${spec%@*}" want="${spec##*@}"
  cur="$(global_version "$pkg")"
  if [[ "$cur" == "$want" ]]; then
    log "$pkg $cur: ok"
  else
    log "$pkg ${cur:-absent} -> $want"
    pending="$pending $spec"
  fi
done
if [[ -n "$pending" ]]; then
  # shellcheck disable=SC2086 # one argument per package spec
  run bun add -g $pending
fi
if have omp; then
  omp_cur="$(omp --version 2>/dev/null)" || $DRY_RUN || die "omp --version failed; check bun (bun --version) and reinstall with this script"
  log "omp --version: ${omp_cur:-unknown}"
fi

# --- my-omp config -------------------------------------------------------------
step "my-omp config at $OMP_HOME"
if [[ ! -e "$OMP_HOME" ]]; then
  if require_github_ssh; then
    run git clone -q --branch "$MY_OMP_BRANCH" "$MY_OMP_REPO" "$OMP_HOME"
  fi
elif [[ ! -d "$OMP_HOME/.git" ]] || ! git -C "$OMP_HOME" rev-parse -q --verify HEAD >/dev/null; then
  adopt_omp_home
else
  update_omp_home
fi

# --- plugins -------------------------------------------------------------------
step "omp plugins ($OMP_HOME/plugins)"
plugins="$OMP_HOME/plugins"
if [[ -f "$plugins/package.json" ]]; then
  [[ -f "$plugins/bun.lock" ]] || die "$plugins/bun.lock missing; --frozen-lockfile needs it (it is tracked in my-omp)"
  while read -r patch; do
    [[ -f "$plugins/$patch" ]] || die "package.json patchedDependencies references $patch, which is missing"
  done < <(sed -n 's/.*"\(patches\/[^"]*\)".*/\1/p' "$plugins/package.json")
  run bun install --cwd="$plugins" --frozen-lockfile
elif $DRY_RUN; then
  log "[dry-run] would run bun install --frozen-lockfile in $plugins once my-omp is in place"
else
  die "$plugins/package.json missing; my-omp is not in place at $OMP_HOME"
fi

# --- CLAUDE.md -----------------------------------------------------------------
step "Claude Code instructions"
ensure_symlink "$OMP_HOME/agent/AGENTS.md" "$HOME/.claude/CLAUDE.md"

# --- global skills ---------------------------------------------------------------
step "global skills ($SKILLS_DIR)"
while read -r -u 3 name args; do
  [[ -n "$name" ]] || continue
  if [[ -f "$SKILLS_DIR/$name/SKILL.md" ]]; then
    log "$name: ok"
  else
    # Without --agent, skills tries every detected agent; PromptScript rejects
    # global installs while the CLI still exits 0. Universal is omp's skill path.
    # shellcheck disable=SC2086 # args is a word list
    run npx --yes skills add $args -a universal -g -y </dev/null
    if ! $DRY_RUN; then
      [[ -f "$SKILLS_DIR/$name/SKILL.md" ]] || die "skills reported success but $name/SKILL.md is missing"
    fi
  fi
done 3<<<"$SKILLS"

# --- herdr integration -----------------------------------------------------------
step "herdr integration (omp)"
if ! have herdr; then
  $DRY_RUN || die "herdr not found; the herdr module must run before omp (install.sh --only herdr,omp)"
  warn "herdr not found; in a real run the herdr module installs it first"
fi
herdr_omp="$(herdr integration status 2>/dev/null | grep '^omp:' || true)"
case "$herdr_omp" in
  "omp: current"*)
    log "$herdr_omp"
    ;;
  *)
    log "${herdr_omp:-omp: status unknown}"
    run herdr integration install omp
    # The extension is tracked in my-omp: a different herdr version rewrites it.
    ext=agent/extensions/herdr-omp-agent-state.ts
    if ! $DRY_RUN && [[ -d "$OMP_HOME/.git" ]] && ! git -C "$OMP_HOME" diff --quiet -- "$ext"; then
      warn "herdr wrote a different $ext than my-omp tracks; review and commit it in $OMP_HOME"
    fi
    ;;
esac

# --- design-inspiration MCP server -----------------------------------------------
step "design-inspiration MCP server (${DESIGN_MCP_COMMIT:0:7} + local patch)"
install_design_mcp

# --- ai-memory -------------------------------------------------------------------
step "ai-memory client $AI_MEMORY_VERSION"
cur="$(ai-memory --version 2>/dev/null || true)"
if [[ "${cur##* }" == "$AI_MEMORY_VERSION" ]]; then
  log "$cur: ok"
else
  asset="$(ai_memory_asset)"
  log "${cur:-absent} -> $AI_MEMORY_VERSION ($asset)"
  run install_ai_memory "$asset"
fi

step "ai-memory server (127.0.0.1:$AI_MEMORY_PORT, profile $PROFILE)"
case "$PROFILE" in
  mac) tunnel_launchd ;;
  ubuntu) tunnel_systemd ;;
  vps) log "container is local (~/docker/ai-memory/compose.yml, not versioned): no tunnel" ;;
esac
probe_ai_memory

# --- manual steps ----------------------------------------------------------------
step "manual steps"
env_file="$OMP_HOME/agent/.env"
missing=""
for name in $ENV_NAMES; do
  if [[ -f "$env_file" ]] &&
    grep -Eq "^(export[[:space:]]+)?$name=(\"[^\"]+\"|'[^']+'|[^\"'[:space:]#])" "$env_file"; then
    log "$name: set"
  else
    missing="$missing $name"
  fi
done
if [[ -n "$missing" ]]; then
  warn "set in $env_file (chmod 600, never committed):$missing"
fi
warn "run /login inside omp for each provider (anthropic, openai-codex); credentials live in $OMP_HOME/agent/agent.db, not in git"
if [[ -f "$HOME/.pi/session-search/config.json" ]]; then
  log "$HOME/.pi/session-search/config.json: ok"
else
  warn "create ~/.pi/session-search/config.json for pi-session-search (OpenAI embedder text-embedding-3-small)"
fi
