#!/usr/bin/env bash
# Bootstrap: put the dotfiles repo on this machine, then install every module.
#
#   curl -fsSL https://raw.githubusercontent.com/MarcusToledo/dotfiles/master/install.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/MarcusToledo/dotfiles/master/install.sh | bash -s -- --profile ubuntu
#   ~/dotfiles/install.sh [--profile mac|ubuntu|vps] [--dry-run] [--only herdr,omp]
#
# Phase 1 is self-contained (it may be running from a pipe, with no repo on
# disk): check git/curl, clone or fast-forward ${DOTFILES_DIR:-~/dotfiles},
# then re-exec that checkout's install.sh so the latest version runs.
# Phase 2 runs inside the checkout: source lib/common.sh and run the modules
# below in order, each as `<module>/install.sh --profile <p> [--dry-run]`.
# Adding a module = one directory with an install.sh + one word in MODULES.
set -euo pipefail

MODULES="herdr omp"

REPO_URL="https://github.com/MarcusToledo/dotfiles.git"
REPO_DIR="${DOTFILES_DIR:-$HOME/dotfiles}"
USAGE="install.sh [--profile mac|ubuntu|vps] [--dry-run] [--only m1,m2]  (modules: $MODULES)"

opt_profile=""
opt_dry_run=false
opt_only=""

# Phase-1 output; phase 2 uses step/log/warn/die from lib/common.sh.
say()     { printf '==> %s\n' "$*"; }
note()    { printf '    %s\n' "$*"; }
caution() { printf '  ! %s\n' "$*" >&2; }
fail()    { printf '  x %s\n' "$*" >&2; exit 1; }

parse_cli() {
  local name
  while (($#)); do
    case "$1" in
      --profile)
        [[ -n "${2:-}" ]] || fail "--profile needs a value (usage: $USAGE)"
        opt_profile="$2"
        shift 2
        ;;
      --only)
        [[ -n "${2:-}" ]] || fail "--only needs a value (usage: $USAGE)"
        opt_only="$2"
        shift 2
        ;;
      --dry-run) opt_dry_run=true; shift ;;
      *) fail "unknown argument: $1 (usage: $USAGE)" ;;
    esac
  done
  for name in ${opt_only//,/ }; do
    case " $MODULES " in
      *" $name "*) ;;
      *) fail "unknown module in --only: $name (modules: $MODULES)" ;;
    esac
  done
}

# --- phase 1: prerequisites + repo ---------------------------------------

check_prereqs() {
  local tool missing=""
  case "$(uname -s)" in
    Darwin)
      # /usr/bin/git is only a stub until the Command Line Tools are installed.
      if ! command -v git >/dev/null 2>&1 ||
        { [[ "$(command -v git)" == /usr/bin/git ]] && ! xcode-select -p >/dev/null 2>&1; }; then
        $opt_dry_run && fail "git missing: run 'xcode-select --install', wait for it to finish, then rerun"
        xcode-select --install || true
        fail "git missing: finish the Command Line Tools installer that just opened, then rerun this command"
      fi
      command -v curl >/dev/null 2>&1 || fail "curl missing (it ships with macOS; check your PATH)"
      ;;
    Linux)
      for tool in git curl; do
        command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
      done
      if [[ -n "$missing" ]]; then
        command -v apt-get >/dev/null 2>&1 ||
          fail "missing:$missing; install these tools with your distribution's package manager"
        if $opt_dry_run; then
          fail "missing:$missing; install with: sudo apt-get update && sudo apt-get install -y$missing"
        fi
        if [[ "$(id -u)" -eq 0 ]]; then
          # shellcheck disable=SC2086 # collected command names (git/curl), not user input
          apt-get update && apt-get install -y $missing
        else
          command -v sudo >/dev/null 2>&1 ||
            fail "missing:$missing; sudo unavailable. Install with: apt-get update && apt-get install -y$missing"
          # shellcheck disable=SC2086 # collected command names (git/curl), not user input
          sudo apt-get update && sudo apt-get install -y $missing
        fi
      fi
      ;;
    *) fail "unsupported OS: $(uname -s)" ;;
  esac
}

sync_repo() {
  if [[ -e "$REPO_DIR/.git" ]]; then
    if [[ -n "$(git -C "$REPO_DIR" status --porcelain)" ]]; then
      caution "$REPO_DIR has local changes: not pulling, using the local state"
    elif $opt_dry_run; then
      note "$REPO_DIR is clean; would run git pull --ff-only (skipped under --dry-run)"
    elif git -C "$REPO_DIR" pull --ff-only; then
      note "$REPO_DIR at $(git -C "$REPO_DIR" rev-parse --short HEAD)"
    else
      caution "git pull --ff-only failed in $REPO_DIR: continuing with the local state"
    fi
  elif [[ -e "$REPO_DIR" && -n "$(ls -A "$REPO_DIR")" ]]; then
    fail "$REPO_DIR exists but is not a git checkout; move it aside or set DOTFILES_DIR"
  else
    $opt_dry_run && note "$REPO_DIR absent: cloning anyway (--dry-run only skips pulls)"
    git clone "$REPO_URL" "$REPO_DIR"
  fi
}

bootstrap() {
  say "dotfiles bootstrap: $REPO_DIR"
  check_prereqs
  sync_repo
  [[ -f "$REPO_DIR/install.sh" ]] || fail "$REPO_DIR/install.sh not found"
  exec env DOTFILES_BOOTSTRAPPED=1 bash "$REPO_DIR/install.sh" "$@"
}

# --- phase 2: modules (running from the checkout) ------------------------

install_modules() {
  local self="${BASH_SOURCE[0]:-}" root selected="" m modifier

  [[ -n "$self" && -f "$self" ]] || fail "DOTFILES_BOOTSTRAPPED is set but this script is not running from a checkout"
  root="$(cd "$(dirname "$self")" && pwd)"
  [[ -f "$root/lib/common.sh" ]] || fail "$root/lib/common.sh not found"
  unset DOTFILES_BOOTSTRAPPED
  # shellcheck source=lib/common.sh
  source "$root/lib/common.sh"

  PROFILE="$opt_profile"
  DRY_RUN=$opt_dry_run
  # shellcheck disable=SC2119 # no arguments: auto-detects PROFILE when empty and validates it
  parse_args

  for m in $MODULES; do
    if [[ -z "$opt_only" ]]; then
      selected="$selected $m"
    else
      case ",$opt_only," in *",$m,"*) selected="$selected $m" ;; esac
    fi
  done
  [[ -n "$selected" ]] || die "--only selected no module (modules: $MODULES)"

  modifier="$(sed -n '1s/^# keymap-modifier:[[:space:]]*\([^[:space:]]*\).*/\1/p' \
    "$DOTFILES_ROOT/herdr/profiles/$PROFILE.toml" 2>/dev/null || true)"
  if [[ -z "$modifier" ]]; then
    modifier="unknown"
    warn "herdr/profiles/$PROFILE.toml does not start with '# keymap-modifier: <x>'"
  fi

  step "dotfiles: $DOTFILES_ROOT"
  log "os: $(detect_os)  profile: $PROFILE  keymap modifier: $modifier"
  log "modules:$selected"
  $DRY_RUN && log "dry-run: nothing on disk will change"

  for m in $selected; do
    [[ -f "$DOTFILES_ROOT/$m/install.sh" ]] || die "module $m: $m/install.sh not found"
    step "module: $m"
    if $DRY_RUN; then
      bash "$DOTFILES_ROOT/$m/install.sh" --profile "$PROFILE" --dry-run ||
        die "module $m failed (exit $?); later modules were not run"
    else
      bash "$DOTFILES_ROOT/$m/install.sh" --profile "$PROFILE" ||
        die "module $m failed (exit $?); later modules were not run"
    fi
  done

  step "done:$selected"
}

# Everything is inside functions so a truncated `curl | bash` download runs nothing.
main() {
  parse_cli "$@"
  if [[ "${DOTFILES_BOOTSTRAPPED:-}" == 1 ]]; then
    install_modules
  else
    bootstrap "$@"
  fi
}

main "$@"
