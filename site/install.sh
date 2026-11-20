#!/usr/bin/env bash
# Ruby4Lich5 installer for macOS and Linux.
#
# Installs everything Lich5 needs and then Lich5 itself:
#   1. system packages (Homebrew on macOS; apt, pacman or dnf on Linux)
#   2. rbenv + ruby-build
#   3. the Ruby version the latest Lich release recommends
#   4. the latest Lich5 release, verified by SHA-256
#   5. Lich's gems, via Bundler
#
# It follows the gswiki guides (Lich:Software/Installation/macOS, /Linux,
# /Upgrading) step for step. Run it again at any time: it skips what is already
# done. On an existing Lich folder it never overwrites anything; it only makes
# sure Ruby and the gems are current (the "update Ruby" path).
#
# Usage:
#   curl -fsSL https://ruby4lich5.elanthia.online/install.sh | bash
#   curl -fsSL https://ruby4lich5.elanthia.online/install.sh | bash -s -- --no-gtk
#
# Windows users: use Ruby4Lich5.exe instead.
#   https://github.com/elanthia-online/Ruby4Lich5/releases/latest

# Everything is inside braces and main runs on the last line, so a download that
# stops partway runs nothing at all.
{

set -euo pipefail

# ---------------------------------------------------------------------------
# Settings
# ---------------------------------------------------------------------------
LICH_REPO="elanthia-online/lich-5"
FALLBACK_RUBY="4.0.9"            # used only if the latest Lich's version.rb can't be read
WIKI="https://gswiki.play.net/Lich:Software/Installation"
DISCORD="https://discord.gg/KF9Wr8u"

LICH_DIR=""
RUBY_VERSION_WANTED=""
WITH_GTK=1
MODIFY_RC=1
ASSUME_YES=0
DRY_RUN=0

OS=""; PKG=""; DISTRO=""; SUDO=""
RBENV_ROOT="${RBENV_ROOT:-$HOME/.rbenv}"
RBENV=""
LICH_TAG=""; REQUIRED_RUBY=""
EXISTING_LICH=0
TMP_DIR=""

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
  BOLD=$(printf '\033[1m'); DIM=$(printf '\033[2m'); RED=$(printf '\033[31m')
  GREEN=$(printf '\033[32m'); YELLOW=$(printf '\033[33m'); RESET=$(printf '\033[0m')
else
  BOLD=""; DIM=""; RED=""; GREEN=""; YELLOW=""; RESET=""
fi

# A check mark when the terminal speaks UTF-8, plain text otherwise.
case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
  *UTF-8*|*utf8*|*UTF8*|*utf-8*) CHECK="✓" ;;
  *) CHECK="ok" ;;
esac

step() { printf '\n%s==> %s%s\n' "$BOLD" "$*" "$RESET"; }
info() { printf '    %s\n' "$*"; }
ok()   { printf '    %s%s%s %s\n' "$GREEN" "$CHECK" "$RESET" "$*"; }
warn() { printf '    %s!%s %s\n' "$YELLOW" "$RESET" "$*" >&2; }
die() {
  printf '\n%sError:%s %s\n' "$RED" "$RESET" "$*" >&2
  printf '%sNeed help? Ask in #scripting or #help on the GemStone IV Discord (%s),\n' "$DIM" "$DISCORD" >&2
  printf 'or follow the manual guide: %s%s\n' "$WIKI" "$RESET" >&2
  exit 1
}

# Print a command, then run it (or only print it with --dry-run).
run() {
  printf '    %s$ %s%s\n' "$DIM" "$*" "$RESET"
  [ "$DRY_RUN" -eq 1 ] && return 0
  "$@"
}

# Ask a yes/no question. Reads from the terminal even when the script itself
# arrives on stdin (curl | bash).
confirm() {
  [ "$ASSUME_YES" -eq 1 ] && return 0
  if ! { exec 3</dev/tty; } 2>/dev/null; then
    die "No terminal to ask for confirmation. Re-run with --yes to accept the plan above."
  fi
  local reply=""
  printf '%s%s [Y/n] %s' "$BOLD" "$1" "$RESET"
  read -r reply <&3 || reply="n"
  exec 3<&-
  case "$reply" in ""|[Yy]|[Yy][Ee][Ss]) return 0 ;; *) return 1 ;; esac
}

usage() {
  cat <<EOF
Ruby4Lich5 installer for macOS and Linux

Usage: install.sh [options]
       curl -fsSL https://ruby4lich5.elanthia.online/install.sh | bash -s -- [options]

Options:
  --dir PATH        Lich folder (default: ~/Desktop/Lich5 on macOS, ~/Lich5 on Linux)
  --ruby VERSION    Ruby to install (default: the latest Lich's RECOMMENDED_RUBY)
  --no-gtk          Skip GTK (terminal-only setups such as Profanity; start Lich with --no-gtk)
  --no-modify-rc    Don't add rbenv to your shell startup file
  -y, --yes         Don't ask for confirmation
  --dry-run         Show what would run, change nothing
  -h, --help        Show this help

Already have Lich? Running this again updates Ruby and the gems and leaves your
Lich folder alone. Update Lich itself in the game with:  ;lich5-update --update
EOF
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --dir)          [ $# -ge 2 ] || die "--dir needs a path"; LICH_DIR="$2"; shift ;;
      --dir=*)        LICH_DIR="${1#*=}" ;;
      --ruby)         [ $# -ge 2 ] || die "--ruby needs a version"; RUBY_VERSION_WANTED="$2"; shift ;;
      --ruby=*)       RUBY_VERSION_WANTED="${1#*=}" ;;
      --no-gtk)       WITH_GTK=0 ;;
      --no-modify-rc) MODIFY_RC=0 ;;
      -y|--yes)       ASSUME_YES=1 ;;
      --dry-run)      DRY_RUN=1; ASSUME_YES=1 ;;
      -h|--help)      usage; exit 0 ;;
      *)              die "Unknown option: $1 (see --help)" ;;
    esac
    shift
  done
  if [ -n "$RUBY_VERSION_WANTED" ]; then
    echo "$RUBY_VERSION_WANTED" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' \
      || die "--ruby must look like 4.0.9 (got '$RUBY_VERSION_WANTED')"
  fi
}

# ---------------------------------------------------------------------------
# Small utilities
# ---------------------------------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }

# True if version $1 >= $2 (numeric, dot-separated).
version_ge() {
  local IFS=.
  # shellcheck disable=SC2206
  local a=($1) b=($2) i
  for i in 0 1 2; do
    [ "${a[$i]:-0}" -gt "${b[$i]:-0}" ] && return 0
    [ "${a[$i]:-0}" -lt "${b[$i]:-0}" ] && return 1
  done
  return 0
}

sha256_of() {
  if have sha256sum; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

# curl with retries; adds GITHUB_TOKEN when set, for GitHub's API rate limit.
fetch() {
  local url="$1" out="$2"
  if [ -n "${GITHUB_TOKEN:-}" ] && [ "${url#https://api.github.com/}" != "$url" ]; then
    curl -fsSL --retry 3 --retry-delay 2 -H "Authorization: Bearer $GITHUB_TOKEN" "$url" -o "$out"
  else
    curl -fsSL --retry 3 --retry-delay 2 "$url" -o "$out"
  fi
}

cleanup() { [ -n "$TMP_DIR" ] && rm -rf "$TMP_DIR"; }

# ---------------------------------------------------------------------------
# 0. Where are we?
# ---------------------------------------------------------------------------
detect_platform() {
  case "$(uname -s)" in
    Darwin)
      OS="macos"; PKG="brew"
      DISTRO="macOS $(sw_vers -productVersion 2>/dev/null || echo '') ($(uname -m))"
      ;;
    Linux)
      OS="linux"
      [ -r /etc/os-release ] || die "Can't identify this Linux distribution (/etc/os-release is missing)."
      # shellcheck disable=SC1091
      . /etc/os-release
      DISTRO="${PRETTY_NAME:-${ID:-Linux}}"
      case " ${ID:-} ${ID_LIKE:-} " in
        *" debian "*|*" ubuntu "*) PKG="apt" ;;
        *" arch "*|*" archlinux "*) PKG="pacman" ;;
        *" rhel "*|*" centos "*)   die "$DISTRO needs EPEL/CRB repositories for Lich's build packages and isn't supported by this script. Follow $WIKI/Linux (Fedora section) and adapt it." ;;
        *" fedora "*)              PKG="dnf" ;;
        *) die "$DISTRO isn't supported by this script yet. Supported: Debian, Ubuntu, Chromebook (Linux), Arch-based, Fedora. Follow $WIKI/Linux and adapt step 1 for your package manager." ;;
      esac
      ;;
    MINGW*|MSYS*|CYGWIN*)
      die "On Windows, use the Ruby4Lich5 installer: https://github.com/elanthia-online/Ruby4Lich5/releases/latest"
      ;;
    *) die "Unsupported operating system: $(uname -s)" ;;
  esac

  if [ "$(id -u)" -eq 0 ] && [ "$OS" = "macos" ]; then
    die "Don't run this with sudo on macOS. Homebrew refuses to run as root; run it as your normal user."
  elif [ "$(id -u)" -eq 0 ]; then
    warn "Running as root: Ruby and Lich will be installed for root, not for your normal user."
    SUDO=""
  elif [ "$PKG" != "brew" ]; then
    have sudo || die "This script needs sudo to install system packages."
    SUDO="sudo"
  fi

  if [ -z "$LICH_DIR" ]; then
    if [ "$OS" = "macos" ]; then LICH_DIR="$HOME/Desktop/Lich5"; else LICH_DIR="$HOME/Lich5"; fi
  fi
  case "$LICH_DIR" in /*) ;; *) LICH_DIR="$PWD/$LICH_DIR" ;; esac

  if [ -f "$LICH_DIR/lich.rbw" ]; then
    EXISTING_LICH=1
  elif [ -e "$LICH_DIR" ] && [ -n "$(ls -A "$LICH_DIR" 2>/dev/null)" ]; then
    die "$LICH_DIR already exists, isn't empty, and doesn't look like a Lich folder. Choose another place with --dir."
  fi
}

# ---------------------------------------------------------------------------
# 1. Which Lich and which Ruby?
# ---------------------------------------------------------------------------
resolve_versions() {
  step "Checking the latest Lich release"
  local api="https://api.github.com/repos/$LICH_REPO/releases/latest"
  fetch "$api" "$TMP_DIR/release.json" \
    || die "Couldn't reach GitHub's release API (it allows 60 requests an hour per network). Wait a while and try again, or set GITHUB_TOKEN."
  LICH_TAG=$(sed -n 's/^ *"tag_name": *"\([^"]*\)".*/\1/p' "$TMP_DIR/release.json" | head -n 1)
  [ -n "$LICH_TAG" ] || die "Couldn't read the latest Lich release from GitHub."
  ok "Latest Lich: $LICH_TAG"

  local recommended=""
  if fetch "https://raw.githubusercontent.com/$LICH_REPO/$LICH_TAG/lib/version.rb" "$TMP_DIR/version.rb"; then
    recommended=$(sed -n "s/^ *RECOMMENDED_RUBY *= *'\([0-9.]*\)'.*/\1/p" "$TMP_DIR/version.rb" | head -n 1)
    REQUIRED_RUBY=$(sed -n "s/^ *REQUIRED_RUBY *= *'\([0-9.]*\)'.*/\1/p" "$TMP_DIR/version.rb" | head -n 1)
  fi
  if [ -z "$RUBY_VERSION_WANTED" ]; then
    RUBY_VERSION_WANTED="${recommended:-$FALLBACK_RUBY}"
    [ -n "$recommended" ] || warn "Couldn't read Lich's recommended Ruby; using $FALLBACK_RUBY."
  fi
  if [ -n "$REQUIRED_RUBY" ] && ! version_ge "$RUBY_VERSION_WANTED" "$REQUIRED_RUBY"; then
    die "Lich $LICH_TAG needs Ruby $REQUIRED_RUBY or newer; --ruby $RUBY_VERSION_WANTED is too old."
  fi
  ok "Ruby to use: $RUBY_VERSION_WANTED${REQUIRED_RUBY:+ (Lich requires $REQUIRED_RUBY or newer)}"
}

# ---------------------------------------------------------------------------
# Package lists (from the gswiki guides; Debian names updated, see notes)
# ---------------------------------------------------------------------------
packages_for() {
  local core gtk
  case "$PKG" in
    brew)
      # libyaml: needed by Ruby 3.2+'s psych; ruby-build lists it for macOS.
      core="rbenv ruby-build openssl@3 libyaml"
      gtk="gtk+3 gobject-introspection adwaita-icon-theme" ;;
    apt)
      # The guide's libreadline6-dev, libncurses5-dev and libgdbm6 are now
      # virtual names that apt maps to these real packages; the real names
      # exist on Debian 11-13, Ubuntu 22.04-26.04 and ChromeOS (Debian).
      core="autoconf bison build-essential ca-certificates curl git libssl-dev libyaml-dev libreadline-dev zlib1g-dev libncurses-dev libffi-dev libgdbm-dev libsqlite3-dev"
      gtk="libcairo2-dev libgirepository1.0-dev libgtk-3-dev gobject-introspection" ;;
    pacman)
      core="base-devel openssl libyaml readline zlib ncurses libffi gdbm sqlite git curl"
      gtk="gtk3 gobject-introspection" ;;
    dnf)
      core="git autoconf bison curl gcc make gdbm gdbm-devel libyaml-devel libffi-devel ncurses-devel openssl-devel readline-devel redhat-rpm-config sqlite-devel zlib-devel"
      gtk="cairo-devel gdk-pixbuf2-devel glib2-devel gobject-introspection-devel gtk3-devel" ;;
  esac
  if [ "$WITH_GTK" -eq 1 ]; then echo "$core $gtk"; else echo "$core"; fi
}

# ---------------------------------------------------------------------------
# The plan, shown before anything changes
# ---------------------------------------------------------------------------
show_plan() {
  step "Plan"
  info "System:        $DISTRO"
  if [ "$EXISTING_LICH" -eq 1 ]; then
    info "Lich folder:   $LICH_DIR  (existing install: left as is, only Ruby and gems are updated)"
  else
    info "Lich folder:   $LICH_DIR  (new install of Lich $LICH_TAG)"
  fi
  info "Ruby:          $RUBY_VERSION_WANTED via rbenv ($RBENV_ROOT), set as your default Ruby (rbenv global)"
  info "GTK:           $([ "$WITH_GTK" -eq 1 ] && echo "yes" || echo "no (--no-gtk)")"
  case "$PKG" in
    brew)   info "Packages:      brew install $(packages_for)" ;;
    apt)    info "Packages:      sudo apt-get install $(packages_for)" ;;
    pacman) info "Packages:      sudo pacman -Syu --needed $(packages_for)"
            info "               (Arch requires a full system upgrade, -Syu, when installing packages)" ;;
    dnf)    info "Packages:      sudo dnf install $(packages_for)" ;;
  esac
  if [ "$MODIFY_RC" -eq 1 ]; then
    info "Shell setup:   adds rbenv to $(rc_file || echo "your shell startup file")"
  else
    info "Shell setup:   skipped (--no-modify-rc)"
  fi
  info "Time:          about 15-45 minutes; building Ruby is the slow part"
  [ "$DRY_RUN" -eq 1 ] && info "${YELLOW}Dry run: commands are printed, nothing is changed.${RESET}"
  echo
  confirm "Continue?" || die "Cancelled. Nothing was changed."
}

# ---------------------------------------------------------------------------
# 2. System packages
# ---------------------------------------------------------------------------
ensure_homebrew() {
  if have brew; then return 0; fi
  local b
  for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    if [ -x "$b" ]; then eval "$("$b" shellenv)"; return 0; fi
  done
  step "Homebrew"
  info "Homebrew (https://brew.sh) isn't installed. Lich's packages come from Homebrew."
  info "Its official installer will ask for your password and may install Apple's Command Line Tools."
  confirm "Run the official Homebrew installer now?" \
    || die "Install Homebrew from https://brew.sh, then run this script again."
  if [ "$DRY_RUN" -eq 1 ]; then
    info "\$ /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
    return 0
  fi
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" </dev/tty
  for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    if [ -x "$b" ]; then eval "$("$b" shellenv)"; return 0; fi
  done
  die "Homebrew didn't finish installing."
}

install_packages() {
  step "Installing system packages"
  # Word splitting of $SUDO (may be empty) and of the package list is intended.
  # shellcheck disable=SC2046,SC2086
  case "$PKG" in
    brew)
      ensure_homebrew
      run brew install $(packages_for)
      run brew upgrade ca-certificates || true
      ;;
    apt)
      run $SUDO apt-get update
      run $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y $(packages_for)
      ;;
    pacman)
      run $SUDO pacman -Syu --needed --noconfirm $(packages_for)
      ;;
    dnf)
      run $SUDO dnf install -y $(packages_for)
      ;;
  esac
  ok "System packages are installed"
}

# ---------------------------------------------------------------------------
# 3. rbenv + ruby-build
# ---------------------------------------------------------------------------
install_rbenv() {
  step "Setting up rbenv"
  if [ "$PKG" = "brew" ]; then
    # Installed (and kept up to date) by brew above.
    RBENV="$(command -v rbenv || echo rbenv)"
    run brew upgrade rbenv ruby-build 2>/dev/null || true
  else
    if [ -x "$RBENV_ROOT/bin/rbenv" ]; then
      info "rbenv is already installed in $RBENV_ROOT"
      run git -C "$RBENV_ROOT" pull --ff-only --quiet || warn "Couldn't update rbenv; continuing with the installed one."
    else
      run git clone --quiet https://github.com/rbenv/rbenv.git "$RBENV_ROOT"
    fi
    if [ -d "$RBENV_ROOT/plugins/ruby-build" ]; then
      # Updating ruby-build is how it learns about new Ruby releases.
      run git -C "$RBENV_ROOT/plugins/ruby-build" pull --ff-only --quiet || warn "Couldn't update ruby-build."
    else
      run git clone --quiet https://github.com/rbenv/ruby-build.git "$RBENV_ROOT/plugins/ruby-build"
    fi
    RBENV="$RBENV_ROOT/bin/rbenv"
  fi
  export RBENV_ROOT
  export PATH="$RBENV_ROOT/shims:$PATH"
  ok "rbenv is ready"
}

# The shell startup file this script edits, or nothing if it can't tell.
rc_file() {
  case "$(basename "${SHELL:-}")" in
    zsh)  echo "$HOME/.zshrc" ;;
    bash) if [ "$OS" = "macos" ]; then echo "$HOME/.bash_profile"; else echo "$HOME/.bashrc"; fi ;;
    *)    return 1 ;;
  esac
}

setup_shell() {
  [ "$MODIFY_RC" -eq 1 ] || return 0
  step "Adding rbenv to your shell"
  local rc shell_name
  shell_name="$(basename "${SHELL:-}")"
  if ! rc="$(rc_file)"; then
    warn "Your shell ($shell_name) isn't bash or zsh, so the startup file wasn't changed."
    warn "Add rbenv yourself: https://github.com/rbenv/rbenv#how-to-hook-rbenv-into-your-shell"
    return 0
  fi
  if [ -f "$rc" ] && grep -q 'rbenv init' "$rc"; then
    ok "$rc already sets up rbenv"
    return 0
  fi
  info "Appending a marked block to $rc"
  [ "$DRY_RUN" -eq 1 ] && return 0
  # These lines are written to the file literally; they expand when the shell starts.
  # shellcheck disable=SC2016
  {
    echo ""
    echo "# >>> Lich (added by the Ruby4Lich5 installer) >>>"
    if [ "$OS" = "macos" ]; then
      echo '[ -x /opt/homebrew/bin/brew ] && eval "$(/opt/homebrew/bin/brew shellenv)"'
      echo "eval \"\$(rbenv init - $shell_name)\""
      echo 'if [ -z "$DISPLAY" ]; then export DISPLAY=:0.0; fi'
    else
      echo 'export PATH="$HOME/.rbenv/bin:$PATH"'
      echo "eval \"\$(rbenv init - $shell_name)\""
    fi
    echo "# <<< Lich <<<"
  } >> "$rc"
  ok "Updated $rc (takes effect in new terminal windows)"
}

# ---------------------------------------------------------------------------
# 4. Ruby
# ---------------------------------------------------------------------------
install_ruby() {
  step "Installing Ruby $RUBY_VERSION_WANTED"
  if [ "$DRY_RUN" -eq 0 ] && "$RBENV" versions --bare 2>/dev/null | grep -qx "$RUBY_VERSION_WANTED"; then
    ok "Ruby $RUBY_VERSION_WANTED is already installed"
  else
    if [ "$DRY_RUN" -eq 0 ] && ! "$RBENV" install --list-all 2>/dev/null | grep -qx "$RUBY_VERSION_WANTED"; then
      die "ruby-build doesn't know Ruby $RUBY_VERSION_WANTED yet. It may be too new; try again in a day, or pass an older --ruby."
    fi
    info "Building Ruby from source. This usually takes 5-20 minutes."
    run "$RBENV" install --skip-existing "$RUBY_VERSION_WANTED"
  fi
  local previous
  previous="$("$RBENV" global 2>/dev/null || echo system)"
  if [ "$previous" != "$RUBY_VERSION_WANTED" ]; then
    run "$RBENV" global "$RUBY_VERSION_WANTED"
    info "Your default Ruby was '$previous'. To switch back: rbenv global $previous"
  fi
  export RBENV_VERSION="$RUBY_VERSION_WANTED"
  if [ "$DRY_RUN" -eq 0 ]; then
    ok "$("$RBENV" exec ruby -v)"
  fi
}

# ---------------------------------------------------------------------------
# 5. Lich
# ---------------------------------------------------------------------------
install_lich() {
  step "Installing Lich"
  if [ "$EXISTING_LICH" -eq 1 ]; then
    ok "Found Lich in $LICH_DIR. Leaving it as it is."
    info "To update Lich itself, enter this in the game:  ;lich5-update --update"
    return 0
  fi

  local asset="lich-5.tar.gz" url expected actual
  url="https://github.com/$LICH_REPO/releases/download/$LICH_TAG/$asset"
  # Ruby is installed by now, so let it read GitHub's JSON reliably.
  if [ "$DRY_RUN" -eq 0 ]; then
    expected=$("$RBENV" exec ruby -rjson -e '
      a = JSON.parse(File.read(ARGV[0]))["assets"].find { |x| x["name"] == ARGV[1] }
      print a ? a["digest"].to_s.sub(/\Asha256:/, "") : ""' "$TMP_DIR/release.json" "$asset")
    [ -n "$expected" ] || die "GitHub didn't publish a SHA-256 for $asset in $LICH_TAG, so it can't be verified."
  fi

  run fetch "$url" "$TMP_DIR/$asset"
  if [ "$DRY_RUN" -eq 0 ]; then
    actual=$(sha256_of "$TMP_DIR/$asset")
    [ "$actual" = "$expected" ] || die "Download check failed for $asset: expected SHA-256 $expected, got $actual. Nothing was installed. Try again."
    ok "Verified $asset ($LICH_TAG, sha256 $(printf '%.12s' "$actual")...)"
  fi

  run mkdir -p "$TMP_DIR/extract"
  run tar -xzf "$TMP_DIR/$asset" -C "$TMP_DIR/extract"
  if [ "$DRY_RUN" -eq 0 ]; then
    [ -f "$TMP_DIR/extract/Lich5/lich.rbw" ] || die "The Lich archive didn't contain Lich5/lich.rbw."
  fi
  run mkdir -p "$(dirname "$LICH_DIR")"
  [ -d "$LICH_DIR" ] && run rmdir "$LICH_DIR"     # empty folder only; checked earlier
  run mv "$TMP_DIR/extract/Lich5" "$LICH_DIR"
  ok "Lich $LICH_TAG is in $LICH_DIR"
}

# ---------------------------------------------------------------------------
# 6. Gems
# ---------------------------------------------------------------------------
install_gems() {
  step "Installing Lich's gems"
  local without="development vscode"
  [ "$WITH_GTK" -eq 1 ] || without="$without gtk"
  [ "$WITH_GTK" -eq 1 ] && info "Building the GTK gems takes several minutes."
  if [ "$DRY_RUN" -eq 0 ]; then cd "$LICH_DIR" || die "Can't open $LICH_DIR."; fi
  run "$RBENV" exec bundle config set --local without "$without" || die "bundle config failed."
  run "$RBENV" exec bundle install || die "bundle install failed. The error above names the gem that failed."
  ok "Gems are installed"
}

smoke_test() {
  [ "$DRY_RUN" -eq 0 ] || return 0
  step "Checking the install"
  (cd "$LICH_DIR" && "$RBENV" exec ruby -e 'require "bundler/setup"; require "sqlite3"') \
    || die "Ruby can't load Lich's gems. Run 'cd $LICH_DIR && bundle install' and check its output."
  ok "Lich's gems load"
  if [ "$WITH_GTK" -eq 1 ]; then
    if (cd "$LICH_DIR" && "$RBENV" exec ruby -e 'require "bundler/setup"; require "gtk3"') >/dev/null 2>&1; then
      ok "GTK loads"
    else
      warn "GTK didn't load here. That's normal over SSH or without a display."
      warn "If the Lich login window doesn't open later, ask for help."
    fi
  fi
}

summary() {
  local ruby_path start_flags=""
  ruby_path="$("$RBENV" which ruby 2>/dev/null || echo "$RBENV_ROOT/versions/$RUBY_VERSION_WANTED/bin/ruby")"
  [ "$WITH_GTK" -eq 1 ] || start_flags=" --no-gtk"
  if [ "$DRY_RUN" -eq 1 ]; then
    step "Dry run complete. Nothing was changed."
    return 0
  fi
  step "${GREEN}Done!${RESET}"
  cat <<EOF

    Lich folder:  $LICH_DIR
    Ruby:         $ruby_path

    ${BOLD}Open a new terminal window${RESET}, then start Lich with:

        ruby "$LICH_DIR/lich.rbw"$start_flags

    Next, set up a front end (Saga, Profanity, Warlock, ...):
        https://gswiki.play.net/Lich:Software/Front_ends
    If Saga asks where Ruby is, give it:  $ruby_path
    If Saga asks for your Lich folder:    $LICH_DIR

    Keep Lich up to date from inside the game:  ;lich5-update --update
    Run this script again later to move to a newer Ruby.

EOF
}

main() {
  parse_args "$@"
  have curl || die "curl is required."
  have tar  || die "tar is required."
  printf '%sRuby4Lich5 installer for macOS and Linux%s\n' "$BOLD" "$RESET"
  TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ruby4lich5.XXXXXX")"
  trap cleanup EXIT
  detect_platform
  resolve_versions
  show_plan
  install_packages
  install_rbenv
  setup_shell
  install_ruby
  install_lich
  install_gems
  smoke_test
  summary
}

main "$@"

}
