# Shared helpers for dotfiles installers. Source it; do not execute.
#
#   source "$repo/lib/common.sh"
#   parse_args "$@"          # sets PROFILE (auto-detected) and DRY_RUN
#   run brew install foo     # prints instead of running under --dry-run
#
# Profiles: mac (macOS), ubuntu (Linux desktop), vps (headless Linux).
# Each profile declares its herdr keymap modifier; see herdr/profiles/*.toml.

# shellcheck shell=bash

# shellcheck disable=SC2034 # read by the scripts that source this file
DOTFILES_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRY_RUN=false
PROFILE=""

if [[ -t 1 ]]; then
  _c_bold=$'\e[1m' _c_dim=$'\e[2m' _c_red=$'\e[31m' _c_yellow=$'\e[33m' _c_reset=$'\e[0m'
else
  _c_bold="" _c_dim="" _c_red="" _c_yellow="" _c_reset=""
fi

step() { printf '%s==> %s%s\n' "$_c_bold" "$*" "$_c_reset"; }
log()  { printf '    %s\n' "$*"; }
warn() { printf '%s  ! %s%s\n' "$_c_yellow" "$*" "$_c_reset" >&2; }
die()  { printf '%s  x %s%s\n' "$_c_red" "$*" "$_c_reset" >&2; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

# run <cmd...>: execute, or only print it under --dry-run.
run() {
  if $DRY_RUN; then
    printf '%s    [dry-run] %s%s\n' "$_c_dim" "$*" "$_c_reset"
  else
    "$@"
  fi
}

detect_os() {
  case "$(uname -s)" in
    Darwin) echo macos ;;
    Linux) echo linux ;;
    *) die "unsupported OS: $(uname -s)" ;;
  esac
}

# Linux desktop vs headless: a graphical default target or a live graphical
# session means desktop (ubuntu); anything else is a server (vps).
detect_profile() {
  if [[ "$(detect_os)" == macos ]]; then
    echo mac
  elif [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}${XDG_CURRENT_DESKTOP:-}" ]] ||
    [[ "$(systemctl get-default 2>/dev/null || true)" == graphical.target ]]; then
    echo ubuntu
  else
    echo vps
  fi
}

# parse_args [--profile <name>] [--dry-run]: unknown flags are fatal.
parse_args() {
  while (($#)); do
    case "$1" in
      --profile) PROFILE="${2:?--profile needs a value}"; shift 2 ;;
      --profile=*) PROFILE="${1#*=}"; shift ;;
      --dry-run) DRY_RUN=true; shift ;;
      *) die "unknown argument: $1 (accepted: --profile <mac|ubuntu|vps>, --dry-run)" ;;
    esac
  done
  [[ -n "$PROFILE" ]] || PROFILE="$(detect_profile)"
  case "$PROFILE" in
    mac | ubuntu | vps) ;;
    *) die "unknown profile: $PROFILE (mac, ubuntu, vps)" ;;
  esac
}

# Tools installed by these scripts land here; make them visible to later steps.
export PATH="$HOME/.local/bin:$HOME/.bun/bin:$PATH"
[[ -x /opt/homebrew/bin/brew ]] && eval "$(/opt/homebrew/bin/brew shellenv)"

# backup <path>: copy an existing file aside as <path>.bak-<timestamp>.
backup() {
  [[ -e "$1" || -L "$1" ]] || return 0
  run cp -P "$1" "$1.bak-$(date +%Y%m%d%H%M%S)"
}

# ensure_symlink <target> <link>: idempotent; moves a different file at <link> aside.
ensure_symlink() {
  local target="$1" link="$2"
  if [[ -L "$link" && "$(readlink "$link")" == "$target" ]]; then
    log "$link -> $target: ok"
    return 0
  fi
  if [[ -e "$link" || -L "$link" ]]; then
    run mv "$link" "$link.bak-$(date +%Y%m%d%H%M%S)"
  fi
  run mkdir -p "$(dirname "$link")"
  run ln -sfn "$target" "$link"
  log "$link -> $target: linked"
}
