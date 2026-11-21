#!/usr/bin/env bash
# Ruby4Lich5 installer for macOS and Linux.
#
# Installs everything Lich5 needs and then Lich5 itself:
#   1. system packages (Homebrew on macOS; apt, pacman or dnf on Linux)
#   2. the Ruby version the latest Lich release recommends:
#        prebuilt, with rv (https://rv.dev), on macOS 14+ and on Linux with
#        glibc 2.39+ (Ubuntu 24.04, Debian 13, Fedora 40 or newer);
#        compiled with rbenv everywhere else (Debian 12 and Chromebooks,
#        Ubuntu 22.04, older macOS), or with --use-rbenv
#   3. the latest Lich5 release, verified by SHA-256
#   4. Lich's gems, via Bundler
#
# Run it again at any time: it skips what is already done. On an existing Lich
# folder it never overwrites anything; it only makes sure Ruby and the gems
# are current.
#
# Usage:
#   curl -fsSL https://ruby4lich5.elanthia.online/install.sh | bash
#   curl -fsSL https://ruby4lich5.elanthia.online/install.sh | bash -s -- --no-gtk
#
# Windows: irm https://ruby4lich5.elanthia.online/install.ps1 | iex
#   (or Ruby4Lich5.exe: https://github.com/elanthia-online/Ruby4Lich5/releases/latest)

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
NO_GTK_FLAG=0
BUNDLE_WITHOUT_KEPT=""
STAGE_DIR=""
MODIFY_RC=1
ASSUME_YES=0
DRY_RUN=0
ALLOW_INTEL_MAC=0
FORCE_RBENV=0

OS=""; PKG=""; DISTRO=""; SUDO=""; INTEL_MAC=0
RUBY_MANAGER=""      # rv (prebuilt Ruby) or rbenv (compiled Ruby)
RUBY_MANAGER_WHY=""
RUBY_BIN=""          # bin directory of the Ruby Lich uses
RBENV_ROOT="${RBENV_ROOT:-$HOME/.rbenv}"
RBENV=""
RV=""
RV_RUBY_REPO="spinel-coop/rv-ruby"
# rv mode: a stable path to the Ruby Lich uses. Upgrades re-point it, so a
# front end (Saga) configured with this path keeps working.
RUBY_LINK="$HOME/.local/share/lich5/ruby"
LICH_ASSET="lich-5.tar.gz"
LICH_TAG=""; LICH_DIGEST=""; REQUIRED_RUBY=""
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
  --no-gtk          Skip GTK (terminal-only setups such as Profanity; start Lich with --no-gtk).
                    Remembered in the Lich folder's Bundler settings, so later runs keep it.
  --no-modify-rc    Don't change your shell startup file
  --use-rbenv       Compile Ruby with rbenv instead of installing it prebuilt with rv
  -y, --yes         Don't ask for confirmation
  --dry-run         Show what would run, change nothing
  --allow-intel-mac Try anyway on an Intel Mac (see below)
  -h, --help        Show this help

Already have Lich? Running this again updates Ruby and the gems and leaves your
Lich folder alone. Update Lich itself in the game with:  ;lich5-update --update

Ruby comes prebuilt from rv (https://rv.dev) on macOS 14+ and on Linux with
glibc 2.39+, and is compiled with rbenv elsewhere (Debian 12, Chromebooks,
Ubuntu 22.04, older macOS).

Intel Macs: Homebrew no longer supports them, so GTK's dependencies must be
compiled from source, which failed or ran for hours in testing. With GTK, the
script stops on an Intel Mac unless you pass --allow-intel-mac; --no-gtk works.
Windows in Parallels with Ruby4Lich5.exe is the supported GTK route there.
EOF
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --dir)          [ $# -ge 2 ] || die "--dir needs a path"; LICH_DIR="$2"; shift ;;
      --dir=*)        LICH_DIR="${1#*=}" ;;
      --ruby)         [ $# -ge 2 ] || die "--ruby needs a version"; RUBY_VERSION_WANTED="$2"; shift ;;
      --ruby=*)       RUBY_VERSION_WANTED="${1#*=}" ;;
      --no-gtk)       WITH_GTK=0; NO_GTK_FLAG=1 ;;
      --no-modify-rc) MODIFY_RC=0 ;;
      -y|--yes)       ASSUME_YES=1 ;;
      --dry-run)      DRY_RUN=1; ASSUME_YES=1 ;;
      --allow-intel-mac) ALLOW_INTEL_MAC=1 ;;
      --use-rbenv)    FORCE_RBENV=1 ;;
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

# A value quoted for pasting into a shell (paths with spaces, for example).
q() { printf '%q' "$1"; }

cleanup() {
  [ -z "$STAGE_DIR" ] || rm -rf "$STAGE_DIR"
  [ -z "$TMP_DIR" ] || rm -rf "$TMP_DIR"
}

# ---------------------------------------------------------------------------
# 0. Where are we?
# ---------------------------------------------------------------------------
detect_platform() {
  case "$(uname -s)" in
    Darwin)
      OS="macos"; PKG="brew"
      DISTRO="macOS $(sw_vers -productVersion 2>/dev/null || echo '') ($(uname -m))"
      # An Apple Silicon Mac running this under Rosetta also reports x86_64.
      if [ "$(uname -m)" = "x86_64" ] && [ "$(sysctl -n sysctl.proc_translated 2>/dev/null || echo 0)" != "1" ]; then
        INTEL_MAC=1
      fi
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
      die "On Windows, run this in PowerShell instead: irm https://ruby4lich5.elanthia.online/install.ps1 | iex  (or use Ruby4Lich5.exe: https://github.com/elanthia-online/Ruby4Lich5/releases/latest)"
      ;;
    *) die "Unsupported operating system: $(uname -s)" ;;
  esac

  choose_ruby_manager

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
    # Keep the groups this Lich folder already leaves out (a terminal-only
    # setup excludes gtk), rather than resetting them on every run.
    if [ -f "$LICH_DIR/.bundle/config" ]; then
      BUNDLE_WITHOUT_KEPT=$(sed -n 's/^BUNDLE_WITHOUT: *"\{0,1\}\([^"]*\)"\{0,1\} *$/\1/p' "$LICH_DIR/.bundle/config" | head -n 1 | tr ':' ' ')
      case " $BUNDLE_WITHOUT_KEPT " in *" gtk "*) WITH_GTK=0 ;; esac
    fi
  elif [ -e "$LICH_DIR" ] && [ -n "$(ls -A "$LICH_DIR" 2>/dev/null)" ]; then
    die "$LICH_DIR already exists, isn't empty, and doesn't look like a Lich folder. Choose another place with --dir."
  fi

  # Checked after the Lich folder's own settings are read: a folder set up
  # with --no-gtk needs no GTK on a plain rerun.
  if [ "$INTEL_MAC" -eq 1 ] && [ "$WITH_GTK" -eq 1 ] && [ "$ALLOW_INTEL_MAC" -eq 0 ]; then
    die "This is an Intel Mac. Homebrew stopped supporting Intel Macs in September 2026 and no longer publishes ready-made packages for them, so GTK's dependencies must be compiled from source. In testing that either failed or was still compiling after six hours. Run Windows in Parallels and use Ruby4Lich5.exe instead: $WIKI/macOS#Windows_in_Parallels  (Terminal-only setups such as Profanity work on Intel Macs: re-run with --no-gtk. To try GTK anyway: --allow-intel-mac.)"
  fi
}

# rv installs prebuilt Ruby, which runs on macOS 14+ and on Linux (x86_64 or
# arm64) with glibc 2.39+: rv-ruby's Linux builds link GLIBC_2.38/2.39
# symbols, although rv's own binary needs only 2.35. Everything else compiles
# Ruby with rbenv, as the gswiki guides do.
choose_ruby_manager() {
  RUBY_MANAGER="rbenv"
  if [ "$FORCE_RBENV" -eq 1 ]; then
    RUBY_MANAGER_WHY="--use-rbenv"
    return 0
  fi
  if [ "$OS" = "macos" ]; then
    local major
    major=$(sw_vers -productVersion 2>/dev/null | cut -d. -f1)
    if [ -n "$major" ] && [ "$major" -ge 14 ]; then
      RUBY_MANAGER="rv"
    else
      RUBY_MANAGER_WHY="prebuilt Ruby needs macOS 14 or newer"
    fi
    return 0
  fi
  local glibc arch
  arch="$(uname -m)"
  glibc=$(ldd --version 2>/dev/null | head -n 1 | grep -oE '[0-9]+\.[0-9]+$' || true)
  case "$arch" in
    x86_64|aarch64|arm64) ;;
    *) RUBY_MANAGER_WHY="no prebuilt Ruby for $arch"; return 0 ;;
  esac
  if [ -z "$glibc" ]; then
    RUBY_MANAGER_WHY="prebuilt Ruby needs glibc, and this system's C library isn't glibc"
  elif version_ge "$glibc" "2.39"; then
    RUBY_MANAGER="rv"
  else
    RUBY_MANAGER_WHY="prebuilt Ruby needs glibc 2.39 or newer; this system has $glibc"
  fi
}

# ---------------------------------------------------------------------------
# 1. Which Lich and which Ruby?
# ---------------------------------------------------------------------------
# The latest release's tag and the asset's SHA-256, from GitHub's API. The API
# answers with minified JSON, so split on commas and braces rather than lines.
release_from_api() {
  local json="$TMP_DIR/release.json"
  fetch "https://api.github.com/repos/$LICH_REPO/releases/latest" "$json" 2>/dev/null || return 1
  LICH_TAG=$(tr ',' '\n' < "$json" | sed -n 's/^[{[ ]*"tag_name": *"\([^"]*\)".*/\1/p' | head -n 1)
  # Each of , { } becomes a newline.
  # shellcheck disable=SC2020
  LICH_DIGEST=$(tr ',{}' '\n\n\n' < "$json" \
    | awk -v name="\"$LICH_ASSET\"" 'index($0, "\"name\"") && index($0, name) { found = 1 } found && index($0, "\"digest\"") { print; exit }' \
    | grep -o 'sha256:[0-9a-f]\{64\}' | head -n 1)
  [ -n "$LICH_TAG" ] && [ -n "$LICH_DIGEST" ]
}

# The same, from github.com's release pages. Used when the API refuses
# (60 requests an hour per network, which shared, VPN and campus networks use
# up): /releases/latest redirects to /releases/tag/<tag>, and the assets
# fragment shows each asset's digest. Like the Windows installer's fallback,
# it accepts exactly one digest labelled for exactly this asset.
release_from_web() {
  local url digests
  url=$(curl -fsSL --retry 3 --retry-delay 2 -o /dev/null -w '%{url_effective}' \
    "https://github.com/$LICH_REPO/releases/latest") || return 1
  LICH_TAG="${url##*/releases/tag/}"
  [ "$LICH_TAG" != "$url" ] || return 1
  fetch "https://github.com/$LICH_REPO/releases/expanded_assets/$LICH_TAG" "$TMP_DIR/assets.html" || return 1
  digests=$(tr '<' '\n' < "$TMP_DIR/assets.html" \
    | grep "^clipboard-copy .*aria-label=\"Copy to clipboard digest for $LICH_ASSET\"" \
    | grep -o 'value="sha256:[0-9a-f]\{64\}"' | sort -u)
  [ "$(printf '%s\n' "$digests" | grep -c .)" -eq 1 ] || return 1
  LICH_DIGEST="${digests#value=\"}"; LICH_DIGEST="${LICH_DIGEST%\"}"
}

resolve_versions() {
  step "Checking the latest Lich release"
  if ! release_from_api; then
    LICH_TAG=""; LICH_DIGEST=""
    release_from_web \
      || die "Couldn't look up the latest Lich release on GitHub. Check your internet connection and try again in a few minutes."
  fi
  echo "$LICH_TAG" | grep -Eq '^v?[0-9]+\.[0-9]+\.[0-9]+' || die "GitHub returned an unexpected Lich release tag: '$LICH_TAG'."
  LICH_DIGEST="${LICH_DIGEST#sha256:}"
  echo "$LICH_DIGEST" | grep -Eq '^[0-9a-f]{64}$' \
    || die "GitHub didn't publish a SHA-256 for $LICH_ASSET in Lich $LICH_TAG, so the download can't be verified."
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
# Package lists
# ---------------------------------------------------------------------------
# rv: Ruby arrives prebuilt, so only what Lich's native gems compile against is
# needed: a C compiler, pkg-config, ncurses (curses) and, for the login window,
# GTK. sqlite3 and ffi install as prebuilt gems.
# rbenv: also everything Ruby itself compiles against (the gswiki guides' lists;
# the guide's Debian libreadline6-dev, libncurses5-dev and libgdbm6 are virtual
# names for the real packages used here).
packages_for() {
  local core gtk
  case "$RUBY_MANAGER:$PKG" in
    rv:brew)      core=""   # Apple's Command Line Tools provide the compiler
                  gtk="gtk+3 gobject-introspection adwaita-icon-theme" ;;
    rv:apt)       core="build-essential pkg-config ca-certificates curl libncurses-dev"
                  gtk="libgtk-3-dev libgirepository1.0-dev gobject-introspection" ;;
    rv:pacman)    core="base-devel curl ncurses"
                  gtk="gtk3 gobject-introspection" ;;
    rv:dnf)       core="gcc make redhat-rpm-config pkgconf-pkg-config curl ncurses-devel"
                  gtk="gtk3-devel gobject-introspection-devel" ;;
    # Homebrew's ruby-build brings libyaml and autoconf with it.
    rbenv:brew)   core="rbenv ruby-build openssl@3"
                  gtk="gtk+3 gobject-introspection adwaita-icon-theme" ;;
    rbenv:apt)    core="autoconf bison build-essential ca-certificates curl git libssl-dev libyaml-dev libreadline-dev zlib1g-dev libncurses-dev libffi-dev libgdbm-dev libsqlite3-dev"
                  gtk="libcairo2-dev libgirepository1.0-dev libgtk-3-dev gobject-introspection" ;;
    rbenv:pacman) core="base-devel openssl libyaml readline zlib ncurses libffi gdbm sqlite git curl"
                  gtk="gtk3 gobject-introspection" ;;
    rbenv:dnf)    core="git autoconf bison curl gcc make gdbm gdbm-devel libyaml-devel libffi-devel ncurses-devel openssl-devel readline-devel redhat-rpm-config sqlite-devel zlib-devel"
                  gtk="cairo-devel gdk-pixbuf2-devel glib2-devel gobject-introspection-devel gtk3-devel" ;;
  esac
  local out="$core"
  if [ "$WITH_GTK" -eq 1 ]; then out="${out:+$out }$gtk"; fi
  echo "$out"
}

# ---------------------------------------------------------------------------
# The plan, shown before anything changes
# ---------------------------------------------------------------------------
show_plan() {
  step "Plan"
  info "System:        $DISTRO"
  if [ "$EXISTING_LICH" -eq 1 ]; then
    info "Lich folder:   $LICH_DIR  (existing install: left as is, only Ruby and gems are updated)"
    [ -z "$BUNDLE_WITHOUT_KEPT" ] || info "               keeps its Bundler setting: without $BUNDLE_WITHOUT_KEPT"
  else
    info "Lich folder:   $LICH_DIR  (new install of Lich $LICH_TAG)"
  fi
  if [ "$RUBY_MANAGER" = "rv" ]; then
    info "Ruby:          $RUBY_VERSION_WANTED, prebuilt, installed with rv; Lich uses $RUBY_LINK"
  else
    info "Ruby:          $RUBY_VERSION_WANTED, compiled with rbenv ($RUBY_MANAGER_WHY)"
    info "               in $RBENV_ROOT, set as your default Ruby (rbenv global)"
  fi
  if [ "$WITH_GTK" -eq 1 ]; then
    info "GTK:           yes"
  elif [ "$NO_GTK_FLAG" -eq 1 ]; then
    info "GTK:           no (--no-gtk)"
  else
    info "GTK:           no (this Lich folder is set up without GTK)"
  fi
  case "$PKG" in
    brew)   if [ -n "$(packages_for)" ]; then info "Packages:      brew install $(packages_for)"
            else info "Packages:      none (Apple's Command Line Tools provide the compiler)"; fi ;;
    apt)    info "Packages:      sudo apt-get install $(packages_for)" ;;
    pacman) info "Packages:      sudo pacman -Syu --needed $(packages_for)"
            info "               (Arch requires a full system upgrade, -Syu, when installing packages)" ;;
    dnf)    info "Packages:      sudo dnf install $(packages_for)" ;;
  esac
  if [ "$MODIFY_RC" -eq 1 ]; then
    info "Shell setup:   puts Lich's Ruby on PATH in $(rc_file || echo "your shell startup file")"
  else
    info "Shell setup:   skipped (--no-modify-rc)"
  fi
  if [ "$RUBY_MANAGER" = "rv" ]; then
    info "Time:          about 2-10 minutes; building the GTK gems is the slow part"
  else
    info "Time:          about 15-45 minutes; building Ruby is the slow part"
  fi
  if [ "$INTEL_MAC" -eq 1 ] && [ "$WITH_GTK" -eq 1 ]; then
    echo
    warn "Intel Mac (--allow-intel-mac): Homebrew will compile GTK's dependencies from"
    warn "source, possibly including LLVM and Rust. In testing this failed or ran for"
    warn "more than six hours. Windows in Parallels with Ruby4Lich5.exe is the supported route:"
    warn "$WIKI/macOS#Windows_in_Parallels"
  fi
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

# The compiler for native gems. Homebrew installs these itself; without
# Homebrew (rv with --no-gtk on macOS) ask macOS to install them.
ensure_command_line_tools() {
  xcode-select -p >/dev/null 2>&1 && return 0
  if [ "$DRY_RUN" -eq 1 ]; then info "\$ xcode-select --install"; return 0; fi
  xcode-select --install >/dev/null 2>&1 || true
  die "Apple's Command Line Tools are needed to build Lich's gems. A window should have opened to install them; finish that install, then run this script again."
}

install_packages() {
  step "Installing system packages"
  # Word splitting of $SUDO (may be empty) and of the package list is intended.
  # shellcheck disable=SC2046,SC2086
  case "$PKG" in
    brew)
      if [ -z "$(packages_for)" ]; then
        ensure_command_line_tools
        ok "Nothing needed from Homebrew"
        return 0
      fi
      ensure_homebrew
      # Refresh Homebrew's formula list first. With a stale list (auto-update
      # turned off, or not run for a while), brew installs an old ruby-build
      # that doesn't know the newest Ruby.
      run brew update
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
  if [ "$PKG" = "brew" ] && [ "$DRY_RUN" -eq 0 ]; then RBENV_ROOT="$("$RBENV" root)"; fi
  export RBENV_ROOT
  export PATH="$RBENV_ROOT/shims:$PATH"
  ok "rbenv is ready"
}

install_rv() {
  step "Setting up rv"
  if have rv; then
    RV="$(command -v rv)"
  elif [ -x "$HOME/.local/bin/rv" ]; then
    RV="$HOME/.local/bin/rv"
  else
    info "Installing rv (https://rv.dev). It installs prebuilt Ruby, so nothing is compiled."
    if [ "$DRY_RUN" -eq 1 ]; then
      info "\$ curl -LsSf https://rv.dev/install | RV_NO_MODIFY_PATH=1 sh"
      RV="rv"
      return 0
    fi
    fetch "https://rv.dev/install" "$TMP_DIR/rv-install.sh" || die "Couldn't download rv's installer from rv.dev."
    RV_NO_MODIFY_PATH=1 sh "$TMP_DIR/rv-install.sh" >/dev/null || die "rv's installer failed."
    RV="$HOME/.local/bin/rv"
    [ -x "$RV" ] || RV="$(command -v rv || true)"
    if [ -z "$RV" ] || [ ! -x "$RV" ]; then die "rv installed, but this script can't find it."; fi
  fi
  ok "$("$RV" --version)"
}

# The shell startup file this script edits, or nothing if it can't tell.
rc_file() {
  case "$(basename "${SHELL:-}")" in
    zsh)  echo "$HOME/.zshrc" ;;
    bash) if [ "$OS" = "macos" ]; then echo "$HOME/.bash_profile"; else echo "$HOME/.bashrc"; fi ;;
    *)    return 1 ;;
  esac
}

RC_BEGIN="# >>> Lich (added by the Ruby4Lich5 installer) >>>"
RC_END="# <<< Lich <<<"

setup_shell() {
  [ "$MODIFY_RC" -eq 1 ] || return 0
  step "Putting Lich's Ruby on your PATH"
  local rc shell_name
  shell_name="$(basename "${SHELL:-}")"
  if ! rc="$(rc_file)"; then
    warn "Your shell ($shell_name) isn't bash or zsh, so the startup file wasn't changed."
    if [ "$RUBY_MANAGER" = "rv" ]; then
      warn "Add this to it yourself:  export PATH=$(q "$RUBY_LINK/bin"):\$PATH"
    else
      warn "Add rbenv yourself: https://github.com/rbenv/rbenv#how-to-hook-rbenv-into-your-shell"
    fi
    return 0
  fi
  # rbenv set up by hand (the gswiki guides) needs nothing more from us.
  if [ "$RUBY_MANAGER" = "rbenv" ] && [ -f "$rc" ] && ! grep -qF "$RC_BEGIN" "$rc" && grep -q 'rbenv init' "$rc"; then
    ok "$rc already sets up rbenv"
    return 0
  fi
  info "Writing a marked block at the end of $rc"
  [ "$DRY_RUN" -eq 1 ] && return 0
  touch "$rc" || die "Couldn't write to $rc."
  # Drop an earlier block from this installer (it may be for the other Ruby
  # manager), then append the current one, so it comes after anything else
  # that sets PATH.
  if ! awk -v b="$RC_BEGIN" -v e="$RC_END" '$0 == b { skip = 1; next } skip && $0 == e { skip = 0; next } !skip' "$rc" > "$rc.lich-tmp" \
     || ! mv "$rc.lich-tmp" "$rc"; then
    die "Couldn't update $rc."
  fi
  # These lines are written to the file literally; they expand when the shell starts.
  # shellcheck disable=SC2016
  {
    echo "$RC_BEGIN"
    if [ "$OS" = "macos" ]; then
      echo '[ -x /opt/homebrew/bin/brew ] && eval "$(/opt/homebrew/bin/brew shellenv)"'
      echo 'if [ -z "$DISPLAY" ]; then export DISPLAY=:0.0; fi'
    fi
    if [ "$RUBY_MANAGER" = "rv" ]; then
      echo 'export PATH="$HOME/.local/share/lich5/ruby/bin:$PATH"'
    else
      # The rbenv this script used, when it isn't the default ~/.rbenv.
      [ "$RBENV_ROOT" = "$HOME/.rbenv" ] || echo "export RBENV_ROOT=$(q "$RBENV_ROOT")"
      if [ "$OS" != "macos" ]; then
        if [ "$RBENV_ROOT" = "$HOME/.rbenv" ]; then
          echo 'export PATH="$HOME/.rbenv/bin:$PATH"'
        else
          echo 'export PATH="$RBENV_ROOT/bin:$PATH"'
        fi
      fi
      echo "eval \"\$(rbenv init - $shell_name)\""
    fi
    echo "$RC_END"
  } >> "$rc" || die "Couldn't write to $rc."
  ok "Updated $rc (takes effect in new terminal windows)"
}

# ---------------------------------------------------------------------------
# 4. Ruby
# ---------------------------------------------------------------------------
install_ruby() {
  if [ "$RUBY_MANAGER" = "rv" ]; then install_ruby_rv; else install_ruby_rbenv; fi
}

install_ruby_rbenv() {
  step "Installing Ruby $RUBY_VERSION_WANTED (compiled with rbenv)"
  if [ "$DRY_RUN" -eq 0 ] && "$RBENV" versions --bare 2>/dev/null | grep -qx "$RUBY_VERSION_WANTED"; then
    ok "Ruby $RUBY_VERSION_WANTED is already installed"
  else
    if [ "$DRY_RUN" -eq 0 ] && ! "$RBENV" install --list-all 2>/dev/null | grep -qx "$RUBY_VERSION_WANTED"; then
      if [ "$PKG" = "brew" ]; then
        die "ruby-build doesn't know Ruby $RUBY_VERSION_WANTED. Run 'brew update && brew upgrade ruby-build', then run this script again."
      fi
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
  RUBY_BIN="$RBENV_ROOT/versions/$RUBY_VERSION_WANTED/bin"
  if [ "$DRY_RUN" -eq 0 ]; then
    ok "$("$RUBY_BIN/ruby" -v)"
  fi
}

# Picks this platform's asset from the names on rv-ruby's assets page.
ruby_asset_for() {
  local names="$1" v="$2" arch
  arch="$(uname -m)"
  if [ "$OS" = "linux" ]; then
    case "$arch" in
      x86_64)        echo "ruby-$v.x86_64_linux.tar.gz" ;;
      aarch64|arm64) echo "ruby-$v.arm64_linux.tar.gz" ;;
    esac
  elif [ "$INTEL_MAC" -eq 0 ]; then
    printf '%s\n' "$names" | grep -E "^ruby-${v//./\\.}\.arm64_[a-z]+\.tar\.gz$" | grep -v '_linux' | head -n 1
  else
    printf '%s\n' "$names" | grep -E "^ruby-${v//./\\.}\.[a-z]+\.tar\.gz$" | head -n 1
  fi
}

# Downloads rv-ruby's prebuilt tarball, checks it against the SHA-256 GitHub
# publishes for it (rv itself doesn't verify downloads), and has rv install it.
# The version is passed explicitly: rv 0.7.2 mislabels a --tarball-path
# install without one.
install_ruby_rv() {
  step "Installing Ruby $RUBY_VERSION_WANTED (prebuilt, with rv)"
  RUBY_BIN="$RUBY_LINK/bin"
  if [ "$DRY_RUN" -eq 1 ]; then
    info "\$ $RV ruby install $RUBY_VERSION_WANTED --tarball-path <verified rv-ruby tarball>"
    return 0
  fi
  local rubies dir
  rubies="$("$RV" ruby dir 2>/dev/null)" || die "rv didn't report its Ruby directory."
  dir="$rubies/ruby-$RUBY_VERSION_WANTED"
  if [ -x "$dir/bin/ruby" ]; then
    ok "Ruby $RUBY_VERSION_WANTED is already installed"
  else
    local url tag names asset digests expected actual
    url=$(curl -fsSL --retry 3 --retry-delay 2 -o /dev/null -w '%{url_effective}' "https://github.com/$RV_RUBY_REPO/releases/latest") \
      || die "Couldn't reach GitHub to find prebuilt Ruby."
    tag="${url##*/releases/tag/}"
    fetch "https://github.com/$RV_RUBY_REPO/releases/expanded_assets/$tag" "$TMP_DIR/rv-assets.html" \
      || die "Couldn't read the prebuilt Ruby list from GitHub."
    names=$(tr '<' '\n' < "$TMP_DIR/rv-assets.html" | grep '^clipboard-copy ' \
      | sed -n 's/.*aria-label="Copy to clipboard digest for \([^"]*\)".*/\1/p' | sort -u)
    asset=$(ruby_asset_for "$names" "$RUBY_VERSION_WANTED")
    if [ -z "$asset" ] || ! printf '%s\n' "$names" | grep -qx "$asset"; then
      die "No prebuilt Ruby $RUBY_VERSION_WANTED for this system in rv-ruby $tag. Re-run with --use-rbenv to compile it."
    fi
    digests=$(tr '<' '\n' < "$TMP_DIR/rv-assets.html" \
      | grep "^clipboard-copy .*aria-label=\"Copy to clipboard digest for $asset\"" \
      | grep -o 'sha256:[0-9a-f]\{64\}' | sort -u)
    [ "$(printf '%s\n' "$digests" | grep -c .)" -eq 1 ] || die "GitHub didn't publish one SHA-256 for $asset, so it can't be verified."
    expected="${digests#sha256:}"
    fetch "https://github.com/$RV_RUBY_REPO/releases/download/$tag/$asset" "$TMP_DIR/$asset" || die "Couldn't download $asset."
    actual=$(sha256_of "$TMP_DIR/$asset")
    [ "$actual" = "$expected" ] || die "Download check failed for $asset: expected SHA-256 $expected, got $actual."
    ok "Verified $asset (rv-ruby $tag, sha256 $(printf '%.12s' "$actual")...)"
    run "$RV" ruby install "$RUBY_VERSION_WANTED" --tarball-path "$TMP_DIR/$asset" || die "rv couldn't install Ruby $RUBY_VERSION_WANTED."
    [ -x "$dir/bin/ruby" ] || die "rv reported success, but $dir/bin/ruby is missing."
  fi
  if ! mkdir -p "$(dirname "$RUBY_LINK")" || ! ln -sfn "$dir" "$RUBY_LINK"; then die "Couldn't create $RUBY_LINK."; fi
  export PATH="$RUBY_BIN:$PATH"
  ok "$("$RUBY_BIN/ruby" -v)"
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

  local asset="$LICH_ASSET" url expected="$LICH_DIGEST" actual
  url="https://github.com/$LICH_REPO/releases/download/$LICH_TAG/$asset"
  run fetch "$url" "$TMP_DIR/$asset"
  if [ "$DRY_RUN" -eq 0 ]; then
    actual=$(sha256_of "$TMP_DIR/$asset")
    [ "$actual" = "$expected" ] || die "Download check failed for $asset: expected SHA-256 $expected, got $actual. Nothing was installed. Try again."
    ok "Verified $asset ($LICH_TAG, sha256 $(printf '%.12s' "$actual")...)"
  fi

  # Unpack next to the destination, on the same filesystem, and rename the
  # finished folder into place. An interrupted run then leaves either no Lich
  # folder or a complete one, never a partial folder that a rerun would
  # mistake for an existing install.
  local parent
  parent="$(dirname "$LICH_DIR")"
  run mkdir -p "$parent"
  STAGE_DIR="$parent/.lich5-install.$$"
  run mkdir "$STAGE_DIR"
  run tar -xzf "$TMP_DIR/$asset" -C "$STAGE_DIR"
  if [ "$DRY_RUN" -eq 0 ]; then
    [ -f "$STAGE_DIR/Lich5/lich.rbw" ] || die "The Lich archive didn't contain Lich5/lich.rbw."
  fi
  [ -d "$LICH_DIR" ] && run rmdir "$LICH_DIR"     # empty folder only; checked earlier
  run mv "$STAGE_DIR/Lich5" "$LICH_DIR"
  run rmdir "$STAGE_DIR"
  STAGE_DIR=""
  ok "Lich $LICH_TAG is in $LICH_DIR"
}

# ---------------------------------------------------------------------------
# 6. Gems
# ---------------------------------------------------------------------------
install_gems() {
  step "Installing Lich's gems"
  # A new folder leaves out the development groups. An existing folder keeps
  # whatever it already leaves out; --no-gtk adds gtk to that.
  local without="${BUNDLE_WITHOUT_KEPT:-development vscode}"
  if [ "$WITH_GTK" -eq 0 ]; then
    case " $without " in *" gtk "*) ;; *) without="$without gtk" ;; esac
  fi
  [ "$WITH_GTK" -eq 1 ] && info "Building the GTK gems takes several minutes."
  if [ "$DRY_RUN" -eq 0 ]; then cd "$LICH_DIR" || die "Can't open $LICH_DIR."; fi
  run "$RUBY_BIN/bundle" config set --local without "$without" || die "bundle config failed."
  # --prefer-local: the Gemfile lists gems Ruby already ships (openssl, json,
  # fiddle, ...) without versions and Lich ships no lockfile, so a plain
  # bundle install would fetch and compile newer copies, which needs OpenSSL
  # headers. Ruby's own copies satisfy Lich.
  run "$RUBY_BIN/bundle" install --prefer-local || die "bundle install failed. The error above names the gem that failed."
  ok "Gems are installed"
}

smoke_test() {
  [ "$DRY_RUN" -eq 0 ] || return 0
  step "Checking the install"
  (cd "$LICH_DIR" && "$RUBY_BIN/ruby" -e 'require "bundler/setup"; require "sqlite3"') \
    || die "Ruby can't load Lich's gems. Run: cd $(q "$LICH_DIR") && $(q "$RUBY_BIN/bundle") install"
  ok "Lich's gems load"
  if [ "$WITH_GTK" -eq 1 ]; then
    if (cd "$LICH_DIR" && "$RUBY_BIN/ruby" -e 'require "bundler/setup"; require "gtk3"') >/dev/null 2>&1; then
      ok "GTK loads"
    else
      warn "GTK didn't load here. That's normal over SSH or without a display."
      warn "If the Lich login window doesn't open later, ask for help."
    fi
  fi
}

summary() {
  local ruby_path start_flags=""
  ruby_path="$RUBY_BIN/ruby"
  [ "$WITH_GTK" -eq 1 ] || start_flags=" --no-gtk"
  if [ "$DRY_RUN" -eq 1 ]; then
    step "Dry run complete. Nothing was changed."
    return 0
  fi
  step "${GREEN}Done!${RESET}"
  cat <<EOF

    Lich folder:  $LICH_DIR
    Ruby:         $ruby_path

    Start Lich with:

        $(q "$ruby_path") $(q "$LICH_DIR/lich.rbw")$start_flags

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
  trap 'exit 130' INT TERM
  detect_platform
  resolve_versions
  show_plan
  install_packages
  if [ "$RUBY_MANAGER" = "rv" ]; then install_rv; else install_rbenv; fi
  install_ruby
  setup_shell
  install_lich
  install_gems
  smoke_test
  summary
}

main "$@"

}
