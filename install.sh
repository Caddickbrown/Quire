#!/usr/bin/env bash
# Quire installer — Linux and macOS.
#
# Installs the terminal app (quire + jnl), the desktop app, or both; finds
# jnl, Nook and Wander and the journal folders they use, offers to remove
# them, and points Quire at your journal. On Linux (x86_64, arm64) it
# downloads the latest release (checksummed) and installs the desktop app as
# the AppImage, which updates itself; elsewhere, or with --build, it builds
# from source. It never deletes a journal folder:
# removed apps go to the Trash (macOS, or Linux with `gio`) or to a dated
# folder under ~/.local/state/quire/, and every step is logged there.
#
#   ./install.sh                 ask before each step
#   ./install.sh --dry-run       show the plan and every command; change nothing
#   ./install.sh --both --yes    everything, taking each default
#   ./install.sh --uninstall     remove Quire (journal and settings kept)
#
#   curl -fsSL https://raw.githubusercontent.com/Caddickbrown/Quire/main/install.sh | bash
#
# The order is the safety: every question first, then back up the journal,
# install what it needs, download or build Quire and check it runs, set it
# up — and only then remove the old apps. A failed build never leaves you
# without a journal app.
#
# Bash 3.2 compatible (macOS's /bin/bash): no associative arrays, no mapfile.

set -o pipefail

REPO_URL=${QUIRE_REPO:-https://github.com/Caddickbrown/Quire.git}
REPO_REF=${QUIRE_REF:-main}
STAMP=$(date +%Y%m%d-%H%M%S)
STATE_DIR=${XDG_STATE_HOME:-$HOME/.local/state}/quire
LOG="$STATE_DIR/install-$STAMP.log"
STASH="$STATE_DIR/removed-$STAMP"

DRY=0
YES=0
MODE=install
FOLDER_ARG=""
SOURCE_ARG=""
PICK=""            # tui | gui | both | none, from a flag; asked otherwise
BUILD=0            # 1: build from source even where a release download exists
WANT_REMOVE=1
NO_BACKUP=0
VERBOSE=0
BUNDLE_ARG=""

usage() {
  cat <<'EOF'
Quire installer — installs the terminal app, the desktop app, or both; finds
jnl, Nook and Wander, offers to remove them, and points Quire at your journal.
Journal folders are never deleted.

  --tui            the terminal app only (quire, and jnl)
  --gui            the desktop app only
  --both           both (the default when asked)
  --tidy           nothing new: keep the Quire you have, retire the old apps
  --dry-run        show the plan and every command; change nothing
  -y, --yes        accept each default without asking
  --folder DIR     use DIR as the journal folder
  --build          build from source instead of downloading the latest release
                   (needs Rust; the desktop app needs WebKitGTK and Tauri)
  --source DIR     build from this Quire checkout instead of cloning
  --bundle KIND    Linux desktop app as deb | rpm | appimage (default: the
                   AppImage, which updates itself; a build defaults to what
                   your package manager installs)
  --keep-old       install alongside the old apps; remove nothing
  --no-backup      skip the journal backup
  --uninstall      remove Quire itself (journal and settings kept)
  -v, --verbose    show build and package-manager output (it is always logged)
  -h, --help       this text

Downloads come from the latest GitHub release of QUIRE_REPO. Builds clone
QUIRE_REF (default main); setting QUIRE_REF builds from source.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --tui|--no-desktop) PICK=tui ;;
    --gui) PICK=gui ;;
    --both) PICK=both ;;
    --tidy) PICK=none ;;
    --dry-run) DRY=1 ;;
    -y|--yes) YES=1 ;;
    --folder) shift; FOLDER_ARG=${1:-} ;;
    --build) BUILD=1 ;;
    --source) shift; SOURCE_ARG=${1:-} ;;
    --bundle) shift; BUNDLE_ARG=${1:-} ;;
    --keep-old) WANT_REMOVE=0 ;;
    --no-backup) NO_BACKUP=1 ;;
    --uninstall) MODE=uninstall ;;
    -v|--verbose) VERBOSE=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

case "$(uname -s)" in
  Linux) OS=linux ;;
  Darwin) OS=mac ;;
  *) echo "Quire's installer supports Linux and macOS." >&2; exit 1 ;;
esac

# ---------- output, prompts, and the one place commands run ----------

if [ -t 1 ]; then
  B=$'\033[1m'; D=$'\033[2m'; R=$'\033[0m'; A=$'\033[38;5;173m'; W=$'\033[33m'
else
  B=""; D=""; R=""; A=""; W=""
fi

log() { [ $DRY -eq 1 ] && return 0; mkdir -p "$STATE_DIR" && printf '%s\n' "$*" >>"$LOG"; }
say() { printf '%s\n' "$*"; log "$*"; }
head1() { printf '\n%s%s%s\n' "$B$A" "$*" "$R"; log "== $*"; }
warn() { printf '%s! %s%s\n' "$W" "$*" "$R"; log "! $*"; }
die() { printf '%s✗ %s%s\n' "$W" "$*" "$R" >&2; log "FAILED: $*"; exit 1; }

# Prompts read the terminal, not stdin, so `curl … | bash` can still ask.
TTY=/dev/tty
if ! { : <"$TTY"; } 2>/dev/null; then TTY=""; fi
if [ -z "$TTY" ] && [ $YES -eq 0 ] && [ $DRY -eq 0 ]; then
  die "no terminal to ask on — re-run with --yes to take the defaults, or --dry-run to see them"
fi

# ask "question" y|n → 0 for yes. Defaults decide under --yes and --dry-run.
ask() {
  local q=$1 def=$2 hint reply
  if [ "$def" = y ]; then hint="Y/n"; else hint="y/N"; fi
  if [ $YES -eq 1 ] || [ $DRY -eq 1 ]; then
    printf '  %s [%s] %s→ %s%s\n' "$q" "$hint" "$D" "$def" "$R"
    log "  ? $q → $def (default)"
    [ "$def" = y ]; return
  fi
  while :; do
    printf '  %s [%s] ' "$q" "$hint"
    IFS= read -r reply <"$TTY" || reply=""
    case "$reply" in
      "") reply=$def ;;
      [Yy]*) reply=y ;;
      [Nn]*) reply=n ;;
      *) continue ;;
    esac
    log "  ? $q → $reply"
    [ "$reply" = y ]; return
  done
}

# ask_line "question" default → the answer on stdout.
ask_line() {
  local q=$1 def=$2 reply
  if [ $YES -eq 1 ] || [ $DRY -eq 1 ]; then
    printf '  %s %s→ %s%s\n' "$q" "$D" "$def" "$R" >&2
    printf '%s' "$def"; return
  fi
  printf '  %s %s[%s]%s ' "$q" "$D" "$def" "$R" >&2
  IFS= read -r reply <"$TTY" || reply=""
  log "  ? $q → ${reply:-$def}"
  printf '%s' "${reply:-$def}"
}

# run cmd args… — print it, then run it unless this is a dry run. Children
# get no stdin: under `curl | bash` it is the rest of this script.
run() {
  printf '  %s$ %s%s\n' "$D" "$*" "$R"
  log "  \$ $*"
  [ $DRY -eq 1 ] && return 0
  "$@" </dev/null >>"$LOG" 2>&1 || { local rc=$?; tail -n 20 "$LOG" >&2; return $rc; }
}

# Long steps (builds, package managers): quiet unless --verbose, since a
# build prints hundreds of lines; the log has them either way, and a failure
# shows its last lines.
run_loud() {
  [ $VERBOSE -eq 1 ] || { run "$@"; return; }
  printf '  %s$ %s%s\n' "$D" "$*" "$R"
  log "  \$ $*"
  [ $DRY -eq 1 ] && return 0
  "$@" </dev/null 2>&1 | tee -a "$LOG"
}

have() { command -v "$1" >/dev/null 2>&1; }

# Root needs no sudo (and containers often have none).
if [ "$(id -u)" = 0 ]; then SUDO=""; else SUDO=sudo; fi
sudo_run() { if [ -n "$SUDO" ]; then run_loud "$SUDO" "$@"; else run_loud "$@"; fi; }

# shellcheck disable=SC2088 # a literal ~ is what these patterns match
expand_home() {
  case "$1" in
    "~") printf '%s' "$HOME" ;;
    "~/"*) printf '%s/%s' "$HOME" "${1#\~/}" ;;
    '$HOME'*) printf '%s%s' "$HOME" "${1#\$HOME}" ;;
    '${HOME}'*) printf '%s%s' "$HOME" "${1#\$\{HOME\}}" ;;
    *) printf '%s' "$1" ;;
  esac
}

realdir() { (cd "$1" 2>/dev/null && pwd -P); }

human_size() { du -sh "$1" 2>/dev/null | cut -f1; }

# A string value from a flat JSON file, without needing jq.
json_str() {
  [ -f "$1" ] || return 0
  sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" "$1" | head -n 1
}

# Is $1 the same as, or inside, $2?
inside() {
  local a b
  a=$(realdir "$1" 2>/dev/null || printf '%s' "$1")
  b=$(realdir "$2" 2>/dev/null || printf '%s' "$2")
  case "$a/" in "$b"/*) return 0 ;; esac
  return 1
}

# Out of the way, not deleted: the Trash, or a dated folder in the state dir.
move_aside() {
  local p=$1 dest
  [ -e "$p" ] || [ -L "$p" ] || return 0
  if [ $OS = mac ]; then
    dest="$HOME/.Trash/$(basename "$p") $STAMP"
  elif have gio && [ -w "$(dirname "$p")" ]; then
    run gio trash "$p"; return
  else
    dest="$STASH${p}"
  fi
  if [ -w "$(dirname "$p")" ]; then
    run mkdir -p "$(dirname "$dest")" && run mv "$p" "$dest"
  else
    run $SUDO mkdir -p "$(dirname "$dest")" && run $SUDO mv "$p" "$dest"
  fi
}

# ---------- where things live ----------

CARGO_DIR=${CARGO_HOME:-$HOME/.cargo}
BIN="$CARGO_DIR/bin"
APPS_DIR=${XDG_DATA_HOME:-$HOME/.local/share}/applications
ICON_PATH=${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/128x128/apps/quire.png
APPIMAGE="$HOME/Applications/Quire.AppImage"
if [ $OS = mac ]; then
  QUIRE_SETTINGS="$HOME/Library/Application Support/quire/settings.json"
  if [ -w /Applications ]; then MAC_APP_DIR=/Applications; else MAC_APP_DIR="$HOME/Applications"; fi
else
  QUIRE_SETTINGS="${XDG_CONFIG_HOME:-$HOME/.config}/quire/settings.json"
fi

# The system package manager, for the desktop app's build libraries and
# the media tools.
PM=""
if [ $OS = mac ]; then
  have brew && PM=brew
else
  for p in apt-get dnf pacman zypper; do have $p && { PM=$p; break; }; done
fi

# ---------- what is installed ----------

# Removable old apps, one per index:
#   ITEM_APP   jnl | Nook | Wander
#   ITEM_KIND  file | dpkg | rpm
#   ITEM_WHAT  a path, or a package name
#   ITEM_DESC  shown to the user
#   ITEM_SURE  y when we know what it is; n for a 'jnl' of unknown origin
#   ITEM_PICK  filled in once asked
ITEM_APP=(); ITEM_KIND=(); ITEM_WHAT=(); ITEM_DESC=(); ITEM_SURE=(); ITEM_PICK=()
SEEN=" "

add_item() {
  case "$SEEN" in *" $2:$3 "*) return ;; esac
  SEEN="$SEEN$2:$3 "
  ITEM_APP+=("$1"); ITEM_KIND+=("$2"); ITEM_WHAT+=("$3"); ITEM_DESC+=("$4"); ITEM_SURE+=("$5"); ITEM_PICK+=(n)
}

# Settings and data an old app leaves: offered (default no) once it goes.
CFG_APP=(); CFG_PATH=()
add_cfg() { [ -e "$2" ] && { CFG_APP+=("$1"); CFG_PATH+=("$2"); }; }

# Journal folders the apps point at: JOUR_PATH / JOUR_FROM, deduplicated.
JOUR_PATH=(); JOUR_FROM=()

add_journal() {
  local p real i
  p=$(expand_home "$1")
  [ -n "$p" ] && [ -d "$p" ] || return 0
  real=$(realdir "$p") || return 0
  i=0
  while [ $i -lt ${#JOUR_PATH[@]} ]; do
    if [ "${JOUR_PATH[$i]}" = "$real" ]; then
      case "${JOUR_FROM[$i]}" in *"$2"*) ;; *) JOUR_FROM[$i]="${JOUR_FROM[$i]}, $2" ;; esac
      return 0
    fi
    i=$((i + 1))
  done
  JOUR_PATH+=("$real"); JOUR_FROM+=("$2")
}

# Filed days plus draft days: a rough size, for the list and the default.
journal_days() {
  find "$1/journal" "$1/inbox" -name '*.md' -type f 2>/dev/null | wc -l | tr -d ' '
}

# Root .md files holding entries: jnl's one-file split journals (work.md),
# which Quire folds into split/<tag>/ the way it folds inbox.md. Reserved
# names and conflict copies are not split journals.
legacy_splits() {
  local f n stem
  for f in "$1"/*.md; do
    [ -f "$f" ] || continue
    n=$(basename "$f")
    stem=$(printf '%s' "${n%.md}" | tr 'A-Z' 'a-z')
    case "$stem" in inbox|transfer|export|readme|nook-export) continue ;; esac
    case "$n" in .*|*sync-conflict*|*"conflicted copy"*) continue ;; esac
    grep -q '^\[[0-9]\{4\}.\{1,3\}[0-9]\{2\}.\{1,3\}[0-9]\{2\} [0-9][0-9]:[0-9][0-9]:[0-9][0-9]\]' "$f" 2>/dev/null && printf '%s\n' "$n"
  done
}

looks_like_journal() {
  [ -d "$1/journal" ] || [ -f "$1/inbox.md" ] || [ -d "$1/inbox" ]
}

# Which jnl is this? Quire's own (keep), the Go CLI, the older bash script.
classify_jnl() {
  if grep -a -q -F ".quire" "$1" 2>/dev/null; then echo quire
  elif grep -a -q -F "Go build" "$1" 2>/dev/null; then echo go
  elif head -c 200 "$1" 2>/dev/null | grep -q '^#!' && grep -q JNL_DIR "$1" 2>/dev/null; then echo bash
  else echo unknown
  fi
}

pkg_installed() {  # pkg_installed name /usr/bin/binary → dpkg | rpm | ""
  if have dpkg-query && [ "$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null)" = "install ok installed" ] \
     && dpkg-query -L "$1" 2>/dev/null | grep -q "^$2\$"; then echo dpkg; return; fi
  if have rpm && rpm -q "$1" >/dev/null 2>&1 && rpm -ql "$1" 2>/dev/null | grep -q "^$2\$"; then echo rpm; fi
}

detect_jnl() {
  local p kind candidates cfg v=""
  candidates=$(
    type -ap jnl 2>/dev/null
    for p in "$HOME/.local/bin/jnl" "$HOME/bin/jnl" "$HOME/go/bin/jnl" "/usr/local/bin/jnl" "/opt/homebrew/bin/jnl"; do
      [ -e "$p" ] && echo "$p"
    done
  )
  while IFS= read -r p; do
    [ -n "$p" ] && [ -f "$p" ] || continue
    kind=$(classify_jnl "$p")
    case "$kind" in
      quire) ;;
      go) add_item jnl file "$p" "jnl (the Go CLI) — $p" y ;;
      bash) add_item jnl file "$p" "jnl (the original bash script) — $p" y ;;
      *) add_item jnl file "$p" "a 'jnl' of unknown origin — $p" n ;;
    esac
  done <<EOF
$candidates
EOF

  # jnl's config is kept: Quire reads JNL_DIR and JNL_SPLIT_TAGS from it.
  cfg=${XDG_CONFIG_HOME:-$HOME/.config}/jnl/config
  if [ -f "$cfg" ]; then
    JNL_CONFIG="$cfg"
    v=$(sed -n 's/^:[[:space:]]*"\${JNL_DIR:=\(.*\)}"[[:space:]]*$/\1/p' "$cfg" | head -n 1)
  fi
  [ -n "${JNL_DIR:-}" ] && add_journal "$JNL_DIR" "\$JNL_DIR"
  [ -n "$v" ] && add_journal "$v" "jnl config"
  [ -d "$HOME/notes" ] && looks_like_journal "$HOME/notes" && add_journal "$HOME/notes" "jnl default"
}

detect_appimages() {
  local app=$1 glob=$2 dir f
  for dir in "$HOME/Applications" "$HOME/Downloads" "$HOME/Desktop" "$HOME/.local/bin" "$HOME/bin" /opt; do
    [ -d "$dir" ] || continue
    while IFS= read -r f; do
      [ -n "$f" ] && add_item "$app" file "$f" "$app AppImage — $f" y
    done <<EOF
$(find "$dir" -maxdepth 2 -type f -iname "$glob" 2>/dev/null)
EOF
  done
  # Launcher entries an AppImage integration tool (or a hand-made one) left.
  [ -d "$APPS_DIR" ] || return 0
  while IFS= read -r f; do
    [ -n "$f" ] && add_item "$app" file "$f" "$app launcher entry — $f" y
  done <<EOF
$(grep -l -i -E "^Name=$app\$" "$APPS_DIR"/*.desktop 2>/dev/null)
EOF
}

# macOS app bundles by bundle id, where apps are installed (not Xcode's
# build folders).
find_mac_apps() {
  local id=$1 bundle
  {
    for bundle in /Applications/*.app "$HOME"/Applications/*.app; do echo "$bundle"; done
    have mdfind && mdfind "kMDItemCFBundleIdentifier == '$id'" 2>/dev/null
  } | while IFS= read -r bundle; do
    [ -n "$bundle" ] && [ -f "$bundle/Contents/Info.plist" ] || continue
    case "$bundle" in */DerivedData/*|*/.Trash/*|*/Xcode*/*) continue ;; esac
    [ "$(defaults read "$bundle/Contents/Info" CFBundleIdentifier 2>/dev/null)" = "$id" ] && echo "$bundle"
  done | sort -u
}

detect_nook() {
  local kind b
  if [ $OS = linux ]; then
    kind=$(pkg_installed nook /usr/bin/nook)
    [ -n "$kind" ] && add_item Nook "$kind" nook "Nook (.$( [ "$kind" = dpkg ] && echo deb || echo rpm) package 'nook')" y
    detect_appimages Nook 'nook*.appimage'
    local cfg=${XDG_CONFIG_HOME:-$HOME/.config}/Nook
    [ -f "$cfg/settings.json" ] && add_journal "$(json_str "$cfg/settings.json" customFolder)" "Nook"
    add_cfg Nook "$cfg"
    add_cfg Nook "${XDG_DATA_HOME:-$HOME/.local/share}/com.caddickbrown.nook"
    add_journal "$HOME/Documents/Nook" "Nook default"
  else
    while IFS= read -r b; do
      [ -n "$b" ] && add_item Nook file "$b" "Nook.app — $b" y
    done <<EOF
$(find_mac_apps com.caddickbrown.nook)
EOF
    # Nook's sandbox container may hold a local journal: never offered.
    add_journal "$HOME/Library/Mobile Documents/iCloud~com~caddickbrown~nook/Documents" "Nook (iCloud)"
    add_journal "$HOME/Library/Containers/com.caddickbrown.nook/Data/Documents/Nook" "Nook (on this Mac)"
    add_journal "$HOME/Documents/Nook" "Nook default"
  fi
}

detect_wander() {
  local kind b f
  if [ $OS = linux ]; then
    kind=$(pkg_installed wander /usr/bin/wander)
    [ -n "$kind" ] && add_item Wander "$kind" wander "Wander (.$( [ "$kind" = dpkg ] && echo deb || echo rpm) package 'wander')" y
    detect_appimages Wander 'wander*.appimage'
    f=${XDG_CONFIG_HOME:-$HOME/.config}/wander
    [ -f "$f/folder" ] && add_journal "$(head -n 1 "$f/folder")" "Wander"
    add_cfg Wander "$f"
    add_cfg Wander "${XDG_DATA_HOME:-$HOME/.local/share}/com.caddickbrown.wander"
  else
    while IFS= read -r b; do
      [ -n "$b" ] && add_item Wander file "$b" "Wander.app — $b" y
    done <<EOF
$(find_mac_apps com.caddickbrown.wander)
EOF
    f="$HOME/Library/Application Support/wander"
    [ -f "$f/folder" ] && add_journal "$(head -n 1 "$f/folder")" "Wander"
    add_journal "$(defaults read com.caddickbrown.wander journalFolderPath 2>/dev/null)" "Wander"
    add_cfg Wander "$f"
    add_cfg Wander "$HOME/Library/Application Support/com.caddickbrown.wander"
    add_cfg Wander "$HOME/Library/Preferences/com.caddickbrown.wander.plist"
  fi
  add_journal "$HOME/Documents/Wander" "Wander default"
}

# Quire's own pieces, for updating and for --uninstall: Q_KIND / Q_WHAT / Q_DESC.
Q_KIND=(); Q_WHAT=(); Q_DESC=()
add_q() {
  local i=0
  while [ $i -lt ${#Q_WHAT[@]} ]; do [ "${Q_WHAT[$i]}" = "$2" ] && return 0; i=$((i + 1)); done
  Q_KIND+=("$1"); Q_WHAT+=("$2"); Q_DESC+=("$3")
}

# HAVE_TUI / HAVE_GUI: Quire is already here. QUIRE_CLI: a quire (or Quire's
# jnl) to run `migrate` with, wherever it was put.
HAVE_TUI=0; HAVE_GUI=0; QUIRE_CLI=""

detect_quire() {
  local f kind b p
  f=$(json_str "$QUIRE_SETTINGS" folder)
  case "$f" in */sample-journal|*/sample-journal/) f="" ;; esac
  [ -n "$f" ] && add_journal "$f" "Quire"
  if [ -x "$BIN/quire" ] || { [ -x "$BIN/jnl" ] && [ "$(classify_jnl "$BIN/jnl")" = quire ]; }; then
    add_q cargo quire-tui "the terminal app — $BIN/quire and $BIN/jnl"
    HAVE_TUI=1
    if [ -x "$BIN/quire" ]; then QUIRE_CLI="$BIN/quire"; else QUIRE_CLI="$BIN/jnl"; fi
  fi
  # Quire's jnl copied somewhere else (a release binary on PATH, say).
  while IFS= read -r p; do
    [ -n "$p" ] && [ -f "$p" ] || continue
    case "$p" in "$BIN"/*) continue ;; esac
    [ "$(classify_jnl "$p")" = quire ] || continue
    add_q file "$p" "Quire's jnl — $p"
    HAVE_TUI=1
    [ -z "$QUIRE_CLI" ] && QUIRE_CLI="$p"
  done <<EOF
$(type -ap jnl quire 2>/dev/null; for p in "$HOME/.local/bin/jnl" "$HOME/.local/bin/quire" "/usr/local/bin/jnl" "/usr/local/bin/quire"; do [ -e "$p" ] && echo "$p"; done)
EOF
  if [ $OS = linux ]; then
    kind=$(pkg_installed quire /usr/bin/quire-desktop)
    [ -n "$kind" ] && { add_q "$kind" quire "the desktop app (package 'quire')"; HAVE_GUI=1; }
    [ -f "$APPIMAGE" ] && { add_q file "$APPIMAGE" "the desktop app — $APPIMAGE"; HAVE_GUI=1; }
    [ -f "$APPS_DIR/Quire.desktop" ] && add_q file "$APPS_DIR/Quire.desktop" "its launcher entry"
    [ -f "$APPS_DIR/quire.desktop" ] && add_q file "$APPS_DIR/quire.desktop" "its launcher entry (old name)"
    [ -f "$ICON_PATH" ] && add_q file "$ICON_PATH" "its icon"
  else
    while IFS= read -r b; do
      [ -n "$b" ] && { add_q file "$b" "the desktop app — $b"; HAVE_GUI=1; }
    done <<EOF
$(find_mac_apps com.caddickbrown.quire)
EOF
  fi
}

# ---------- what the desktop app needs to build ----------

gui_libs_ok() {
  [ $OS = mac ] && return 0
  have pkg-config && pkg-config --exists webkit2gtk-4.1 2>/dev/null
}

# Tauri's Linux prerequisites, per package manager.
gui_libs() {
  case "$PM" in
    apt-get) echo "libwebkit2gtk-4.1-dev build-essential curl wget file libxdo-dev libssl-dev libayatana-appindicator3-dev librsvg2-dev patchelf pkg-config" ;;
    dnf) echo "webkit2gtk4.1-devel openssl-devel curl wget file libappindicator-gtk3-devel librsvg2-devel libxdo-devel gcc gcc-c++ make pkgconf-pkg-config" ;;
    pacman) echo "webkit2gtk-4.1 base-devel curl wget file openssl appmenu-gtk-module libappindicator-gtk3 librsvg xdotool pkgconf" ;;
    zypper) echo "webkit2gtk3-devel libopenssl-devel curl wget file libappindicator3-1 librsvg-devel gcc gcc-c++ make pkg-config" ;;
  esac
}

media_tools() {
  case "$PM" in
    apt-get) echo "ffmpeg libheif-examples" ;;
    dnf) echo "ffmpeg-free libheif-tools" ;;
    pacman) echo "ffmpeg libheif" ;;
    zypper) echo "ffmpeg-7 libheif1" ;;
    brew) echo "ffmpeg libheif" ;;
  esac
}

pm_install() {
  case "$PM" in
    apt-get) sudo_run apt-get update -qq && sudo_run env DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" ;;
    dnf) sudo_run dnf install -y "$@" ;;
    pacman) sudo_run pacman -S --needed --noconfirm "$@" ;;
    zypper) sudo_run zypper --non-interactive install "$@" ;;
    brew) run_loud brew install "$@" ;;
    *) return 1 ;;
  esac
}

node_ok() {
  have npm && have node || return 1
  [ "$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)" -ge 18 ]
}

# The bundle the desktop app ships as here.
if [ $OS = mac ]; then BUNDLE=app
elif have dpkg && [ "$PM" = apt-get ]; then BUNDLE=deb
elif have rpm && { [ "$PM" = dnf ] || [ "$PM" = zypper ]; }; then BUNDLE=rpm
else BUNDLE=appimage
fi
case "$BUNDLE_ARG" in
  "") ;;
  deb|rpm|appimage) [ $OS = linux ] && BUNDLE=$BUNDLE_ARG ;;
  *) echo "--bundle takes deb, rpm or appimage" >&2; exit 2 ;;
esac

# ---------- the latest release ----------

# owner/name of the GitHub repository releases come from.
RELEASE_REPO=$(printf '%s' "$REPO_URL" | sed -n 's#^https://github\.com/\([^/]*/[^/]*\)$#\1#p' | sed 's/\.git$//')
case "$(uname -m)" in
  x86_64|amd64) ARCH=x86_64; PKG_ARCH=amd64 ;;
  aarch64|arm64) ARCH=aarch64; PKG_ARCH=arm64 ;;
  *) ARCH=""; PKG_ARCH="" ;;
esac
REL_TAG=""; REL_VER=""

# Sets REL_TAG/REL_VER from where /releases/latest redirects (no API, no token).
latest_release() {
  local url
  url=$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$RELEASE_REPO/releases/latest" 2>/dev/null) || return 1
  REL_TAG=${url##*/tag/}
  case "$REL_TAG" in v[0-9]*) REL_VER=${REL_TAG#v} ;; *) return 1 ;; esac
}

# Download or build: download unless asked to build, or no release fits.
choose_from() {
  FROM=source
  if [ $BUILD -eq 1 ]; then WHY_BUILD="--build"
  elif [ -n "$SOURCE_ARG" ]; then WHY_BUILD="--source"
  elif [ -n "${QUIRE_REF:-}" ]; then WHY_BUILD="QUIRE_REF=$QUIRE_REF"
  elif [ $OS = mac ]; then WHY_BUILD="there are no macOS release builds yet"
  elif [ -z "$ARCH" ]; then WHY_BUILD="there's no release build for $(uname -m)"
  elif [ -z "$RELEASE_REPO" ]; then WHY_BUILD="QUIRE_REPO isn't a GitHub repository"
  elif ! have curl; then WHY_BUILD="curl is needed to download"
  elif ! latest_release; then WHY_BUILD="$RELEASE_REPO's releases couldn't be reached"
  else FROM=release; WHY_BUILD=""
  fi
}

rel_url() { printf 'https://github.com/%s/releases/download/%s/%s' "$RELEASE_REPO" "$REL_TAG" "$1"; }

sha256_of() { if have sha256sum; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }

# The AppImage's runtime carries its own libfuse; it needs a fusermount.
fuse_ok() { have fusermount || have fusermount3; }
fuse_pkg() { case "$PM" in apt-get|dnf|pacman|zypper) echo fuse3 ;; esac; }

# The desktop app's release file for this machine and bundle.
gui_asset() {
  case "$BUNDLE" in
    appimage) echo "Quire_${REL_VER}_$([ $ARCH = x86_64 ] && echo amd64 || echo aarch64).AppImage" ;;
    deb) echo "Quire_${REL_VER}_${PKG_ARCH}.deb" ;;
    rpm) echo "Quire-${REL_VER}-1.${ARCH}.rpm" ;;
  esac
}

# Download $1 into $DL and check it against the SHA-256 in sums file $2
# (a `sha256sum` listing, also downloaded). Dies on a mismatch.
fetch_checked() {
  local name=$1 sums=$2 want got
  run curl -fsSL -o "$DL/$name" "$(rel_url "$name")" || die "couldn't download $name"
  [ $DRY -eq 1 ] && return 0
  [ -f "$DL/$sums" ] || { run curl -fsSL -o "$DL/$sums" "$(rel_url "$sums")" || die "couldn't download $sums"; }
  want=$(awk -v n="$name" '{ f=$2; sub(/^\*/, "", f) } f==n || NR==1 && NF==1 { print $1; exit }' "$DL/$sums")
  [ -n "$want" ] || want=$(awk 'NR==1 { print $1 }' "$DL/$sums")
  got=$(sha256_of "$DL/$name")
  [ "$got" = "$want" ] || die "$name doesn't match its published checksum — nothing was installed from it"
  say "  ${D}✓ $name matches its SHA-256${R}"
}

# The terminal app from the release tarball, into $TUI_DIR. `quire update`
# keeps it current from then on.
install_tui_release() {
  local tb="quire-$ARCH-unknown-linux-gnu.tar.gz"
  fetch_checked "$tb" "$tb.sha256"
  run tar -xzf "$DL/$tb" -C "$DL" || die "couldn't unpack $tb"
  run mkdir -p "$TUI_DIR"
  run install -m 755 "$DL/quire-$ARCH-unknown-linux-gnu/quire" "$DL/quire-$ARCH-unknown-linux-gnu/jnl" "$TUI_DIR/" \
    || die "couldn't install into $TUI_DIR"
}

# ---------- the source ----------

find_source() {
  local here
  here=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd -P)
  if [ -n "$SOURCE_ARG" ]; then
    SRC=$(expand_home "$SOURCE_ARG")
  elif [ -n "$here" ] && [ -f "$here/tui/Cargo.toml" ] && grep -q 'quire-tui' "$here/tui/Cargo.toml"; then
    SRC=$here
  else
    SRC="${XDG_DATA_HOME:-$HOME/.local/share}/quire/src"
    CLONE=1
  fi
}

fetch_source() {
  [ "${CLONE:-0}" = 1 ] || return 0
  have git || die "git is needed to fetch Quire's source"
  if [ -d "$SRC/.git" ]; then
    run git -C "$SRC" fetch --depth 1 origin "$REPO_REF" || die "couldn't fetch $REPO_URL"
    run git -C "$SRC" checkout -q FETCH_HEAD || die "couldn't check out $REPO_REF"
  else
    run mkdir -p "$(dirname "$SRC")"
    run git clone --depth 1 --branch "$REPO_REF" "$REPO_URL" "$SRC" || die "couldn't clone $REPO_URL"
  fi
}

# ---------- --uninstall ----------

uninstall_main() {
  head1 "Quire's pieces"
  detect_quire
  if [ ${#Q_KIND[@]} -eq 0 ]; then say "  Quire isn't installed."; return 0; fi
  local i=0 picks=()
  while [ $i -lt ${#Q_KIND[@]} ]; do
    if ask "Remove ${Q_DESC[$i]}?" y; then picks+=(y); else picks+=(n); fi
    i=$((i + 1))
  done
  local cfg_dir
  cfg_dir=$(dirname "$QUIRE_SETTINGS")
  local drop_cfg=0
  [ -d "$cfg_dir" ] && ask "Also remove Quire's settings ($cfg_dir)? Your journal stays either way." n && drop_cfg=1
  if [ $YES -eq 0 ] && [ $DRY -eq 0 ]; then echo; ask "Go ahead?" y || { say "  Nothing changed."; return 0; }; fi

  head1 "Removing Quire"
  i=0
  while [ $i -lt ${#Q_KIND[@]} ]; do
    if [ "${picks[$i]}" = y ]; then
      case "${Q_KIND[$i]}" in
        cargo) if have cargo && cargo install --list 2>/dev/null | grep -q '^quire-tui '; then run cargo uninstall quire-tui
               else move_aside "$BIN/quire"; move_aside "$BIN/jnl"; fi ;;
        dpkg) sudo_run apt-get remove -y quire ;;
        rpm) if have dnf; then sudo_run dnf remove -y quire; else sudo_run rpm -e quire; fi ;;
        file) move_aside "${Q_WHAT[$i]}" ;;
      esac || warn "couldn't remove ${Q_DESC[$i]} — carrying on"
    fi
    i=$((i + 1))
  done
  [ $drop_cfg -eq 1 ] && move_aside "$cfg_dir"
  head1 "Done"
  say "  Your journal folder is untouched. To bring jnl back: https://github.com/Caddickbrown/jnl"
  [ $DRY -eq 0 ] && say "  Log  $LOG"
  [ $DRY -eq 1 ] && say "  ${D}Dry run: nothing was changed.${R}"
  return 0
}

# ---------- install ----------

install_main() {
  local i n note answer others best where

  # ----- 1. look -----
  head1 "Looking for jnl, Nook, Wander and Quire"
  JNL_CONFIG=""
  detect_quire
  detect_jnl
  detect_nook
  detect_wander

  if [ ${#ITEM_APP[@]} -eq 0 ]; then
    say "  No jnl, Nook or Wander installed."
  else
    i=0
    while [ $i -lt ${#ITEM_APP[@]} ]; do say "  • ${ITEM_DESC[$i]}"; i=$((i + 1)); done
  fi
  i=0
  while [ $i -lt ${#Q_KIND[@]} ]; do say "  • Quire: ${Q_DESC[$i]} ${D}(installed)${R}"; i=$((i + 1)); done

  say ""
  say "  Journal folders:"
  if [ ${#JOUR_PATH[@]} -eq 0 ]; then
    say "    none found"
  else
    i=0
    while [ $i -lt ${#JOUR_PATH[@]} ]; do
      if looks_like_journal "${JOUR_PATH[$i]}"; then
        note="  ${D}($(journal_days "${JOUR_PATH[$i]}") days$([ -f "${JOUR_PATH[$i]}/inbox.md" ] && echo ', inbox.md'))${R}"
      else
        note="  ${D}(empty)${R}"
      fi
      say "    $((i + 1)). ${JOUR_PATH[$i]}  ${D}← ${JOUR_FROM[$i]}${R}$note"
      i=$((i + 1))
    done
  fi

  # ----- 2. ask everything, up front -----
  head1 "What to install"
  say "    1. Terminal app — quire, and jnl with every jnl command as before"
  say "    2. Desktop app  — Quire's window: write, review, browse, look back, media"
  say "    3. Both"
  local choices="1, 2 or 3"
  if [ $HAVE_TUI -eq 1 ] || [ $HAVE_GUI -eq 1 ]; then
    say "    4. Nothing new — keep the Quire you have; just retire the old apps"
    choices="1, 2, 3 or 4"
  fi
  if [ -z "$PICK" ]; then
    while :; do
      answer=$(ask_line "Which? ($choices):" 3)
      case "$answer" in
        1|t|tui|TUI) PICK=tui; break ;;
        2|g|gui|GUI) PICK=gui; break ;;
        3|b|both|Both) PICK=both; break ;;
        4|n|none) [ "$choices" = "1, 2, 3 or 4" ] && { PICK=none; break; } ;;
      esac
    done
  fi
  [ "$PICK" = none ] && [ $HAVE_TUI -eq 0 ] && [ $HAVE_GUI -eq 0 ] && die "--tidy needs Quire installed already; choose --tui, --gui or --both"
  WANT_TUI=0; WANT_GUI=0
  case "$PICK" in tui) WANT_TUI=1 ;; gui) WANT_GUI=1 ;; both) WANT_TUI=1; WANT_GUI=1 ;; esac
  if [ "$PICK" = none ]; then
    say "  → nothing new: the installed Quire stays as it is"
  else
    say "  → $( [ $WANT_TUI -eq 1 ] && echo 'terminal' )$( [ "$PICK" = both ] && echo ' + ' )$( [ $WANT_GUI -eq 1 ] && echo 'desktop' )"
  fi
  # What will be here afterwards: what's installed, plus what's chosen.
  R_TUI=$WANT_TUI; [ $HAVE_TUI -eq 1 ] && R_TUI=1
  R_GUI=$WANT_GUI; [ $HAVE_GUI -eq 1 ] && R_GUI=1
  if [ $WANT_GUI -eq 1 ] && [ $OS = mac ]; then
    say "  ${D}On the Mac the desktop app is the Linux app's build (Tauri) — a preview until${R}"
    say "  ${D}the Swift Mac app lands. No widgets, share sheet or iCloud set-up of its own.${R}"
  fi

  head1 "Your journal"
  # The default: the folder Quire already uses, else the biggest journal
  # (ties go to the first found: JNL_DIR, jnl's config, Nook, Wander).
  DEFAULT_FOLDER=""
  best=-1
  i=0
  while [ $i -lt ${#JOUR_PATH[@]} ]; do
    case "${JOUR_FROM[$i]}" in Quire*) DEFAULT_FOLDER=${JOUR_PATH[$i]}; break ;; esac
    if looks_like_journal "${JOUR_PATH[$i]}"; then
      n=$(journal_days "${JOUR_PATH[$i]}")
      if [ "$n" -gt $best ]; then best=$n; DEFAULT_FOLDER=${JOUR_PATH[$i]}; fi
    fi
    i=$((i + 1))
  done
  [ -z "$DEFAULT_FOLDER" ] && [ ${#JOUR_PATH[@]} -gt 0 ] && DEFAULT_FOLDER=${JOUR_PATH[0]}
  [ -z "$DEFAULT_FOLDER" ] && DEFAULT_FOLDER="$HOME/notes"

  if [ -n "$FOLDER_ARG" ]; then
    FOLDER=$(expand_home "$FOLDER_ARG")
    say "  Using --folder $FOLDER"
  else
    answer=$(ask_line "Journal folder for Quire (a number above, or a path):" "$DEFAULT_FOLDER")
    case "$answer" in
      ''|*[!0-9]*) FOLDER=$(expand_home "$answer") ;;
      *) if [ "$answer" -ge 1 ] && [ "$answer" -le ${#JOUR_PATH[@]} ]; then
           FOLDER=${JOUR_PATH[$((answer - 1))]}
         else
           die "no folder numbered $answer"
         fi ;;
    esac
  fi
  case "$FOLDER" in /*) ;; *) FOLDER="$PWD/$FOLDER" ;; esac
  [ -d "$FOLDER" ] && FOLDER=$(realdir "$FOLDER")
  say "  Journal: $FOLDER$([ -d "$FOLDER" ] || echo "  ${D}(new — it will be created)${R}")"

  others=0
  i=0
  while [ $i -lt ${#JOUR_PATH[@]} ]; do
    [ "${JOUR_PATH[$i]}" != "$FOLDER" ] && looks_like_journal "${JOUR_PATH[$i]}" && others=$((others + 1))
    i=$((i + 1))
  done
  if [ $others -gt 0 ]; then
    warn "$others other journal folder(s) found. Quire opens one; the others are left exactly as they are."
    say "    To bring one in later: Settings › Maintenance › Import a markdown folder (desktop app)."
  fi

  DO_BACKUP=0
  if [ $NO_BACKUP -eq 0 ] && [ -d "$FOLDER" ] && looks_like_journal "$FOLDER"; then
    ask "Back up $FOLDER first ($(human_size "$FOLDER")) to ~/quire-preinstall-$STAMP.tar.gz?" y && DO_BACKUP=1
  fi

  # Quire has opened this folder before: drafts already live in inbox/ (and
  # split journals in split/), so any old app still installed has stopped
  # seeing them. Say so plainly.
  local since="" olds splits
  olds=$(old_app_names)
  splits=$(legacy_splits "$FOLDER" | tr '\n' ' ' | sed 's/ $//; s/ /, /g')
  if [ -n "$olds" ] && { [ -d "$FOLDER/inbox" ] || [ -d "$FOLDER/split" ] || [ -d "$FOLDER/.quire/migration" ]; }; then
    since=$(ls "$FOLDER/.quire/migration" 2>/dev/null | sed -n 's/^\(inbox\|split-.*\)-\([0-9]\{4\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)-[0-9]\{6\}.*/\2-\3-\4/p' | sort | head -n 1)
    say ""
    warn "Quire already keeps this journal's drafts in inbox/$([ -d "$FOLDER/split" ] && echo ' and split journals in split/')${since:+ (since $since)}."
    say "    $olds still read only inbox.md and <tag>.md: they don't see what moved, and what"
    say "    they write there waits until Quire next opens the folder. journal/ they still see."
  fi

  DO_MIGRATE=0; MIGRATE_WHAT=""
  if [ -f "$FOLDER/inbox.md" ] && { [ -d "$FOLDER/inbox" ] || [ -d "$FOLDER/.quire/migration" ]; }; then
    say ""
    say "  inbox.md has $(grep -c '^\[' "$FOLDER/inbox.md" 2>/dev/null || echo 0) draft(s) written since, by an app still using it."
    MIGRATE_WHAT="inbox.md"
  elif [ -f "$FOLDER/inbox.md" ]; then
    say ""
    say "  This journal keeps drafts in inbox.md. Quire keeps them in inbox/YYYY/MM/DD.md"
    say "  and moves them the first time it opens the folder (inbox.md is kept, renamed,"
    say "  under .quire/migration/). Apps that still read inbox.md — the Go jnl, Nook,"
    say "  Wander, Nook on your phone — stop seeing drafts there; Quire keeps folding in"
    say "  any they write later. Filed entries are untouched."
    MIGRATE_WHAT="inbox.md"
  fi
  if [ -n "$splits" ]; then
    say ""
    say "  Split journals in one file each ($splits). Quire keeps them in"
    say "  split/<tag>/YYYY/MM/DD.md, one file per day, and moves them the same way on"
    say "  first open (originals kept under .quire/migration/). The Go jnl and Nook stop"
    say "  seeing those entries; journal/ is untouched."
    MIGRATE_WHAT="${MIGRATE_WHAT:+$MIGRATE_WHAT and }$splits"
  fi
  [ -n "$MIGRATE_WHAT" ] && ask "Move $MIGRATE_WHAT into day files now?" y && DO_MIGRATE=1

  # Download or build, and what that needs.
  NEED_XCODE=0; NEED_RUST=0; DO_LIBS=0; TAURI_VIA=""; DO_MEDIA=0; DO_PATH=0
  DO_FUSE=0; NO_FUSE=0; SWITCH_PKG=""; FROM=source; TUI_DIR=$BIN
  if [ $WANT_TUI -eq 1 ] || [ $WANT_GUI -eq 1 ]; then
  choose_from
  if [ $FROM = release ]; then
  head1 "What it needs"
  say "  Quire $REL_VER, the latest release, downloaded and checked against its SHA-256."
  say "  ${D}(--build compiles it from source instead)${R}"
  # An existing ~/.cargo/bin/quire would shadow a new one elsewhere on PATH.
  [ -x "$BIN/quire" ] || TUI_DIR="$HOME/.local/bin"
  if [ $WANT_GUI -eq 1 ]; then
    if [ -z "$BUNDLE_ARG" ]; then
      BUNDLE=appimage
      SWITCH_PKG=$(pkg_installed quire /usr/bin/quire-desktop)
      if [ -n "$SWITCH_PKG" ]; then
        say "  The desktop app is installed as a .$( [ "$SWITCH_PKG" = dpkg ] && echo deb || echo rpm ) package, which can't update itself."
        if ask "Switch it to the AppImage, which updates itself? (the package goes once the AppImage is in place)" y; then
          :
        else
          [ "$SWITCH_PKG" = dpkg ] && BUNDLE=deb || BUNDLE=rpm
          SWITCH_PKG=""
        fi
      fi
    fi
    if [ $BUNDLE = appimage ] && ! fuse_ok; then
      if [ -n "$(fuse_pkg)" ] && ask "The AppImage mounts itself with FUSE, which isn't installed. Install $(fuse_pkg)$([ -n "$SUDO" ] && echo ' (needs sudo)')?" y; then
        DO_FUSE=1
      else
        NO_FUSE=1
        say "  ${D}Without FUSE the launcher unpacks the AppImage on each start (slower to open).${R}"
      fi
    fi
    say "  The desktop app: $(gui_asset)"
    if ! have ffmpeg && [ -n "$(media_tools)" ]; then
      ask "Install ffmpeg and HEIC tools for Data Saver and iPhone photos ($(media_tools))?" y && DO_MEDIA=1
    fi
  fi
  else
  head1 "What the build needs"
  say "  Building from source: $WHY_BUILD."
  if [ $OS = mac ] && ! xcode-select -p >/dev/null 2>&1; then NEED_XCODE=1; fi
  # shellcheck disable=SC1091
  [ -f "$CARGO_DIR/env" ] && . "$CARGO_DIR/env"
  if have cargo; then
    say "  ✓ Rust $(rustc --version 2>/dev/null | cut -d' ' -f2)"
  else
    NEED_RUST=1
    ask "Rust isn't installed. Install it with rustup (into ~/.cargo)?" y || die "no Rust, no Quire: install it from https://rustup.rs and run this again"
  fi
  if [ $NEED_XCODE -eq 1 ]; then
    say "  The Xcode command-line tools are needed; their installer opens next."
  fi
  if [ $WANT_GUI -eq 1 ]; then
    if gui_libs_ok; then
      [ $OS = linux ] && say "  ✓ WebKitGTK and friends"
    elif [ -n "$(gui_libs)" ]; then
      say "  The desktop app builds against WebKitGTK. Missing; with $PM:"
      say "    ${D}$(gui_libs)${R}"
      ask "Install them$([ -n "$SUDO" ] && echo ' (needs sudo)')?" y && DO_LIBS=1
    else
      warn "No package manager I know. Install Tauri's prerequisites by hand:"
      say "    https://v2.tauri.app/start/prerequisites/#linux"
    fi
    if node_ok; then TAURI_VIA=npm; say "  ✓ Node $(node -v) for Tauri's command-line tool"
    elif have cargo-tauri; then TAURI_VIA=cargo; say "  ✓ cargo tauri"
    else TAURI_VIA=cargo; say "  Tauri's command-line tool will be built with cargo (no Node needed; a few minutes)."
    fi
    if ! have ffmpeg && [ -n "$(media_tools)" ]; then
      ask "Install ffmpeg and HEIC tools for Data Saver and iPhone photos ($(media_tools))?" y && DO_MEDIA=1
    fi
  fi
  fi
  if [ $WANT_TUI -eq 1 ]; then
    case ":$PATH:" in
      *":$TUI_DIR:"*) ;;
      *) ask "$TUI_DIR isn't on your PATH. Add it to your shell's start-up file?" y && DO_PATH=1 ;;
    esac
  fi
  fi

  # Old apps: removal defaults follow what replaces them.
  head1 "Removing the old apps"
  if [ ${#ITEM_APP[@]} -eq 0 ]; then
    say "  Nothing to remove."
  elif [ $WANT_REMOVE -eq 0 ]; then
    say "  --keep-old: leaving them installed."
  else
    say "  Apps only. Journal folders are never touched; settings are asked about after."
    local def why
    i=0
    while [ $i -lt ${#ITEM_APP[@]} ]; do
      def=n; why=""
      case "${ITEM_APP[$i]}" in
        jnl) if [ $R_TUI -eq 1 ]; then def=y; why="Quire's jnl takes its place$([ $WANT_TUI -eq 0 ] && echo ' — already installed')"
             else why="without the terminal app you'd have no jnl command"; fi ;;
        Wander) if [ $R_GUI -eq 1 ]; then def=y; why="Quire's desktop app takes its place$([ $WANT_GUI -eq 0 ] && echo ' — already installed')"
                else why="no Quire desktop app here or chosen"; fi ;;
        Nook) if [ $OS = mac ]; then why="Nook's widgets, share sheet and iCloud set-up have no Quire equivalent yet"
              elif [ $R_GUI -eq 1 ]; then def=y; why="Quire's desktop app takes its place$([ $WANT_GUI -eq 0 ] && echo ' — already installed')"
              else why="no Quire desktop app here or chosen"; fi ;;
      esac
      [ "${ITEM_SURE[$i]}" = n ] && { def=n; why="not recognised — check before removing"; }
      say "  ${D}${why}${R}"
      if ask "Remove ${ITEM_DESC[$i]}?" $def; then ITEM_PICK[$i]=y; fi
      i=$((i + 1))
    done
  fi

  # Settings of an app being removed, never one holding a journal.
  CFG_PICK=()
  i=0
  while [ $i -lt ${#CFG_APP[@]} ]; do
    CFG_PICK+=(n)
    if picked_app "${CFG_APP[$i]}" && ! holds_journal "${CFG_PATH[$i]}"; then
      ask "Also remove ${CFG_APP[$i]}'s settings/data (${CFG_PATH[$i]})?" n && CFG_PICK[$i]=y
    fi
    i=$((i + 1))
  done
  [ -n "$JNL_CONFIG" ] && say "  ${D}Keeping $JNL_CONFIG — Quire reads JNL_DIR and JNL_SPLIT_TAGS from it.${R}"

  # The plan, then one last yes.
  head1 "The plan"
  [ $DO_BACKUP -eq 1 ] && say "  • back up the journal"
  [ $NEED_XCODE -eq 1 ] && say "  • install the Xcode command-line tools"
  [ $NEED_RUST -eq 1 ] && say "  • install Rust (rustup)"
  [ $DO_LIBS -eq 1 ] && say "  • install the desktop app's build libraries ($PM)"
  [ $DO_MEDIA -eq 1 ] && say "  • install ffmpeg and HEIC tools ($PM)"
  [ $DO_FUSE -eq 1 ] && say "  • install $(fuse_pkg) for the AppImage ($PM)"
  local how=build; [ $FROM = release ] && how="download ($REL_VER)"
  [ $WANT_TUI -eq 1 ] && say "  • $how and install the terminal app → $TUI_DIR"
  [ $WANT_GUI -eq 1 ] && say "  • $how and install the desktop app ($BUNDLE)"
  [ -n "$SWITCH_PKG" ] && say "  • then remove the desktop app's old package"
  [ "$PICK" = none ] && say "  • keep the installed Quire as it is"
  say "  • point Quire at $FOLDER"
  [ $DO_MIGRATE -eq 1 ] && say "  • move $MIGRATE_WHAT into day files"
  [ $DO_PATH -eq 1 ] && say "  • add $TUI_DIR to your PATH"
  i=0
  while [ $i -lt ${#ITEM_APP[@]} ]; do
    [ "${ITEM_PICK[$i]}" = y ] && say "  • remove ${ITEM_DESC[$i]}"
    i=$((i + 1))
  done
  i=0
  while [ $i -lt ${#CFG_APP[@]} ]; do
    [ "${CFG_PICK[$i]}" = y ] && say "  • remove ${CFG_PATH[$i]}"
    i=$((i + 1))
  done
  if [ $YES -eq 0 ] && [ $DRY -eq 0 ]; then
    echo
    ask "Go ahead?" y || { say "  Nothing changed."; return 0; }
  fi

  # ----- 3. back up -----
  if [ $DO_BACKUP -eq 1 ]; then
    head1 "Backing up"
    run tar -czf "$HOME/quire-preinstall-$STAMP.tar.gz" -C "$(dirname "$FOLDER")" "$(basename "$FOLDER")" \
      || die "backup failed — nothing else was changed"
    say "  → ~/quire-preinstall-$STAMP.tar.gz"
  fi

  # ----- 4. prerequisites -----
  if [ -n "$SUDO" ] && [ $DRY -eq 0 ] && needs_sudo; then
    say "  Some steps need sudo:"
    if [ -n "$TTY" ]; then sudo -v <"$TTY"; else sudo -n true; fi 2>/dev/null \
      || die "sudo is needed for the package steps (or run as root)"
  fi
  [ $FROM = source ] && find_source
  if [ $WANT_TUI -eq 1 ] || [ $WANT_GUI -eq 1 ]; then
  head1 "Preparing"
  if [ $DO_FUSE -eq 1 ]; then
    say "  Installing $(fuse_pkg)…"
    pm_install "$(fuse_pkg)" || { warn "installing $(fuse_pkg) failed; the launcher will unpack the AppImage instead"; NO_FUSE=1; }
  fi
  if [ $NEED_XCODE -eq 1 ]; then
    run xcode-select --install
    die "finish installing the command-line tools, then run this again"
  fi
  if [ $NEED_RUST -eq 1 ]; then
    have curl || die "curl is needed to install rustup"
    say "  ${D}\$ curl https://sh.rustup.rs | sh -s -- -y --no-modify-path${R}"
    if [ $DRY -eq 0 ]; then
      curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path >>"$LOG" 2>&1 \
        || die "rustup failed — see $LOG"
      # shellcheck disable=SC1091
      . "$CARGO_DIR/env"
    fi
    say "  Rust installed."
    # rustup left PATH alone; do what it would have done.
    case ":$PATH:" in *":$BIN:"*) ;; *) DO_PATH=1 ;; esac
  fi
  if [ $DO_LIBS -eq 1 ]; then
    say "  Installing the build libraries (a minute or two)…"
    # shellcheck disable=SC2046 # the list is meant to split
    pm_install $(gui_libs) || warn "installing the build libraries failed"
  fi
  if [ $FROM = source ] && [ $WANT_GUI -eq 1 ] && [ $DRY -eq 0 ] && ! gui_libs_ok; then
    warn "WebKitGTK still isn't there; skipping the desktop app. Prerequisites:"
    say "    https://v2.tauri.app/start/prerequisites/#linux"
    WANT_GUI=0
    [ $WANT_TUI -eq 0 ] && die "nothing was installed; the old apps are still in place"
  fi
  if [ $DO_MEDIA -eq 1 ]; then
    say "  Installing ffmpeg and HEIC tools…"
    # shellcheck disable=SC2046
    pm_install $(media_tools) || warn "the media tools didn't install; Data Saver will say what's missing"
  fi
  if [ $FROM = source ]; then
    fetch_source
    say "  Source: $SRC"
  else
    if [ $DRY -eq 1 ]; then DL="${TMPDIR:-/tmp}/quire-download"
    else DL=$(mktemp -d 2>/dev/null || echo "$STATE_DIR/download-$STAMP"); mkdir -p "$DL"
    fi
  fi
  fi

  # ----- 5. download or build, and install -----
  if [ $WANT_TUI -eq 1 ]; then
    head1 "The terminal app"
    if [ $FROM = release ]; then
      say "  Downloading Quire $REL_VER…"
      install_tui_release
    else
      say "  Building (a minute or two the first time)…"
      run_loud cargo install --locked --force --path "$SRC/tui" || die "the terminal app didn't build — see $LOG"
    fi
    if [ $DRY -eq 0 ]; then
      [ -x "$TUI_DIR/quire" ] && [ -x "$TUI_DIR/jnl" ] || die "the install finished but $TUI_DIR/quire isn't there"
      # In a scratch folder: every quire run folds an inbox.md, and that is
      # the user's call (asked above), not a side effect of checking the build.
      local probe
      probe=$(mktemp -d 2>/dev/null || echo "$STATE_DIR/probe-$STAMP")
      "$TUI_DIR/quire" --folder "$probe" help >/dev/null 2>&1 </dev/null || die "$TUI_DIR/quire doesn't run"
      rm -rf "$probe"
    fi
    say "  ✓ quire and jnl → $TUI_DIR$([ $FROM = release ] && echo "  ${D}(\`quire update\` keeps them current)${R}")"
    QUIRE_CLI="$TUI_DIR/quire"
  fi

  GUI_DONE=0
  if [ $WANT_GUI -eq 1 ]; then
    head1 "The desktop app"
    local built=0
    if [ $FROM = release ]; then
      say "  Downloading $(gui_asset)…"
      fetch_checked "$(gui_asset)" "SHA256SUMS-desktop-$ARCH"
      GUI_FILE="$DL/$(gui_asset)"
      if [ $BUNDLE = appimage ]; then
        run curl -fsSL -o "$DL/quire.png" "https://raw.githubusercontent.com/$RELEASE_REPO/$REL_TAG/linux/src-tauri/icons/128x128.png" \
          || warn "couldn't fetch the icon; the launcher entry will have none"
        ICON_FILE="$DL/quire.png"
      fi
      built=1
    elif [ "$TAURI_VIA" = npm ]; then
      say "  Building (several minutes the first time)…"
      run_loud sh -c "cd \"$SRC/linux\" && npm install --no-fund --no-audit && npx tauri build --bundles $BUNDLE" && built=1
    else
      say "  Building (several minutes the first time)…"
      if have cargo-tauri || [ $DRY -eq 1 ] || run_loud cargo install tauri-cli --version '^2' --locked; then
        run_loud sh -c "cd \"$SRC/linux\" && cargo tauri build --bundles $BUNDLE" && built=1
      fi
    fi
    if [ $built -eq 0 ]; then
      warn "The desktop app didn't build (see $LOG).$([ $WANT_TUI -eq 1 ] && echo ' The terminal app is installed.')"
      [ $WANT_TUI -eq 0 ] && die "nothing was installed; the old apps are still in place"
    elif install_gui; then
      GUI_DONE=1
      # Only now the old package goes: a failed download left it in place.
      case "$SWITCH_PKG" in
        dpkg) sudo_run apt-get remove -y quire || warn "couldn't remove the old quire package — remove it with apt" ;;
        rpm) if have dnf; then sudo_run dnf remove -y quire; else sudo_run rpm -e quire; fi || warn "couldn't remove the old quire package" ;;
      esac
    elif [ $WANT_TUI -eq 0 ]; then
      die "the desktop app built but didn't install; the old apps are still in place"
    fi
  fi

  # ----- 6. point it at the journal -----
  head1 "Setting Quire up"
  if [ $DRY -eq 0 ] && [ ! -d "$FOLDER" ]; then
    mkdir -p "$FOLDER/journal" || die "can't create $FOLDER"
  fi
  write_settings
  if [ -n "${JNL_DIR:-}" ] && [ "$(realdir "$JNL_DIR" 2>/dev/null)" != "$FOLDER" ]; then
    warn "\$JNL_DIR is $JNL_DIR and wins over Quire's setting. Point it at $FOLDER, or unset it."
  fi
  if [ $DO_MIGRATE -eq 1 ]; then
    if [ -n "$QUIRE_CLI" ]; then
      run "$QUIRE_CLI" --folder "$FOLDER" migrate || die "moving the drafts failed — inbox.md is untouched; see $LOG"
    elif have python3 && [ -f "$SRC/tools/migrate_journal.py" ]; then
      run python3 -I "$SRC/tools/migrate_journal.py" "$FOLDER" --apply --keep-nook \
        || die "moving the drafts failed — inbox.md is untouched; see $LOG"
    else
      say "  The desktop app will move the drafts when it next opens the folder."
    fi
    [ $DRY -eq 0 ] && grep -E "Moved [0-9]| moved to " "$LOG" | tail -n 2 | sed 's/^ */  /'
  fi
  [ $DO_PATH -eq 1 ] && add_to_path
  say "  ✓ Quire opens $FOLDER"

  # ----- 7. remove the old apps -----
  local removed=0 pkgs=0
  i=0
  while [ $i -lt ${#ITEM_APP[@]} ]; do
    if [ "${ITEM_PICK[$i]}" = y ]; then
      [ $removed -eq 0 ] && head1 "Removing the old apps"
      removed=$((removed + 1))
      [ "${ITEM_KIND[$i]}" = file ] || pkgs=$((pkgs + 1))
      case "${ITEM_KIND[$i]}" in
        dpkg) sudo_run apt-get remove -y "${ITEM_WHAT[$i]}" ;;
        rpm) if have dnf; then sudo_run dnf remove -y "${ITEM_WHAT[$i]}"; else sudo_run rpm -e "${ITEM_WHAT[$i]}"; fi ;;
        file) move_aside "${ITEM_WHAT[$i]}" ;;
      esac || warn "couldn't remove ${ITEM_DESC[$i]} — carrying on"
    fi
    i=$((i + 1))
  done
  i=0
  while [ $i -lt ${#CFG_APP[@]} ]; do
    [ "${CFG_PICK[$i]}" = y ] && move_aside "${CFG_PATH[$i]}"
    i=$((i + 1))
  done

  # ----- 8. done -----
  head1 "Done"
  if [ $DRY -eq 0 ] && [ $WANT_TUI -eq 1 ]; then
    local first
    first=$(type -ap jnl 2>/dev/null | head -n 1)
    if [ -n "$first" ] && [ "$(classify_jnl "$first")" != quire ]; then
      warn "'jnl' still runs $first, ahead of Quire's on your PATH."
    fi
  fi
  if [ $WANT_TUI -eq 1 ] || [ $HAVE_TUI -eq 1 ]; then
    say "  quire            the Today screen; jnl works too, with the same commands"
    [ $DO_PATH -eq 1 ] && say "                   ${D}(open a new terminal first)${R}"
  fi
  if [ $GUI_DONE -eq 1 ] || { [ $WANT_GUI -eq 0 ] && [ $HAVE_GUI -eq 1 ]; }; then
    if [ $OS = mac ]; then say "  Quire.app        in $MAC_APP_DIR"
    else say "  Quire            the desktop app, from your launcher"
    fi
  fi
  [ $DO_BACKUP -eq 1 ] && say "  Backup           ~/quire-preinstall-$STAMP.tar.gz"
  if [ $removed -gt 0 ]; then
    if [ $OS = mac ] || have gio; then where="in the Trash"; else where=$STASH; fi
    [ $pkgs -gt 0 ] && where="$where; packages removed with $PM"
    say "  Removed apps     $where"
  fi
  say "  Uninstall        ./install.sh --uninstall"
  [ $DRY -eq 0 ] && say "  Log              $LOG"
  [ $DRY -eq 1 ] && say "  ${D}Dry run: nothing was changed.${R}"
  return 0
}

# Will any step need root? Package installs and removals.
needs_sudo() {
  local i=0
  [ $DO_LIBS -eq 1 ] || [ $DO_MEDIA -eq 1 ] || [ $DO_FUSE -eq 1 ] && [ "$PM" != brew ] && return 0
  [ -n "$SWITCH_PKG" ] && return 0
  [ $WANT_GUI -eq 1 ] && { [ $BUNDLE = deb ] || [ $BUNDLE = rpm ]; } && return 0
  while [ $i -lt ${#ITEM_APP[@]} ]; do
    [ "${ITEM_PICK[$i]}" = y ] && [ "${ITEM_KIND[$i]}" != file ] && return 0
    i=$((i + 1))
  done
  return 1
}

# The old apps still installed, by name: "Nook and Wander", "jnl, Nook and Wander".
old_app_names() {
  local i=0 names="" n
  while [ $i -lt ${#ITEM_APP[@]} ]; do
    n=${ITEM_APP[$i]}; [ "$n" = jnl ] && n="the old jnl"
    case ",$names," in *",$n,"*) ;; *) names="${names:+$names,}$n" ;; esac
    i=$((i + 1))
  done
  printf '%s' "$names" | sed 's/,\([^,]*\)$/ and \1/; s/,/, /g'
}

picked_app() {
  local i=0
  while [ $i -lt ${#ITEM_APP[@]} ]; do
    [ "${ITEM_APP[$i]}" = "$1" ] && [ "${ITEM_PICK[$i]}" = y ] && return 0
    i=$((i + 1))
  done
  return 1
}

# A settings/data path that is, or contains, a journal is never offered.
holds_journal() {
  local i=0
  [ -n "${FOLDER:-}" ] && inside "$FOLDER" "$1" && return 0
  while [ $i -lt ${#JOUR_PATH[@]} ]; do
    inside "${JOUR_PATH[$i]}" "$1" && return 0
    i=$((i + 1))
  done
  return 1
}

# One Exec argument as the desktop-entry spec wants it (as the app's own
# ensure_launcher writes it): % doubled; quoted when it holds a reserved
# character, with " ` $ and \ escaped inside the quotes; then every backslash
# doubled by the value's own string escaping.
desktop_exec_arg() {
  local a
  a=$(printf '%s' "$1" | sed 's/%/%%/g')
  case "$a" in
    *[[:space:]\"\'\\\<\>~\|\&\;\$\*\?\#\(\)\`]*)
      a=$(printf '%s' "$a" | sed 's/[\\"`$]/\\&/g; s/\\/\\\\/g')
      printf '"%s"' "$a" ;;
    *) printf '%s' "$a" ;;
  esac
}

# Install the bundle Tauri just built, or the one downloaded ($GUI_FILE).
install_gui() {
  local out="$SRC/target/release/bundle" f exec_line
  case "$BUNDLE" in
    deb)
      f=${GUI_FILE:-$(ls -t "$out"/deb/*.deb 2>/dev/null | head -n 1)}
      [ $DRY -eq 1 ] && f=${f:-$out/deb/Quire_amd64.deb}
      [ -n "$f" ] || { warn "no .deb in $out/deb"; return 1; }
      sudo_run env DEBIAN_FRONTEND=noninteractive apt-get install -y --reinstall "$f" || { warn "installing $f failed"; return 1; }
      [ $DRY -eq 1 ] || have quire-desktop || { warn "the package installed but quire-desktop isn't on PATH"; return 1; }
      say "  ✓ Quire (.deb) — open it from your launcher" ;;
    rpm)
      f=${GUI_FILE:-$(ls -t "$out"/rpm/*.rpm 2>/dev/null | head -n 1)}
      [ $DRY -eq 1 ] && f=${f:-$out/rpm/Quire.x86_64.rpm}
      [ -n "$f" ] || { warn "no .rpm in $out/rpm"; return 1; }
      if have dnf; then sudo_run dnf install -y "$f"; else sudo_run zypper --non-interactive install --allow-unsigned-rpm "$f"; fi \
        || { warn "installing $f failed"; return 1; }
      say "  ✓ Quire (.rpm) — open it from your launcher" ;;
    appimage)
      f=${GUI_FILE:-$(ls -t "$out"/appimage/*.AppImage 2>/dev/null | head -n 1)}
      [ $DRY -eq 1 ] && f=${f:-$out/appimage/Quire_amd64.AppImage}
      [ -n "$f" ] || { warn "no AppImage in $out/appimage"; return 1; }
      run mkdir -p "$HOME/Applications" "$APPS_DIR" "$(dirname "$ICON_PATH")"
      run install -m 755 "$f" "$APPIMAGE"
      [ -f "${ICON_FILE:-$SRC/linux/src-tauri/icons/128x128.png}" ] || [ $DRY -eq 1 ] \
        && run install -m 644 "${ICON_FILE:-$SRC/linux/src-tauri/icons/128x128.png}" "$ICON_PATH"
      # Without FUSE the AppImage can still run by unpacking itself first.
      exec_line=$(desktop_exec_arg "$APPIMAGE")
      [ "${NO_FUSE:-0}" = 1 ] && exec_line="env APPIMAGE_EXTRACT_AND_RUN=1 $exec_line"
      say "  ${D}launcher entry → $APPS_DIR/Quire.desktop${R}"
      if [ $DRY -eq 0 ]; then
        rm -f "$APPS_DIR/quire.desktop"   # the old name; it never matched the window's app id
        cat >"$APPS_DIR/Quire.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Quire
Comment=Journalling over a plain folder of markdown
Exec=$exec_line
Icon=quire
Categories=Office;
Terminal=false
StartupWMClass=Quire
EOF
        have update-desktop-database && update-desktop-database "$APPS_DIR" >/dev/null 2>&1
      fi
      say "  ✓ Quire → $APPIMAGE, with a launcher entry  ${D}(Settings › About updates it)${R}" ;;
    app)
      f="$out/macos/Quire.app"
      [ $DRY -eq 1 ] || [ -d "$f" ] || { warn "no Quire.app in $out/macos"; return 1; }
      run mkdir -p "$MAC_APP_DIR"
      [ -e "$MAC_APP_DIR/Quire.app" ] && move_aside "$MAC_APP_DIR/Quire.app"
      run ditto "$f" "$MAC_APP_DIR/Quire.app" || { warn "copying Quire.app failed"; return 1; }
      say "  ✓ Quire.app → $MAC_APP_DIR" ;;
  esac
}

# Merge "folder" into settings.json; everything else in it stays.
write_settings() {
  say "  ${D}folder → $QUIRE_SETTINGS${R}"
  [ $DRY -eq 1 ] && return 0
  mkdir -p "$(dirname "$QUIRE_SETTINGS")"
  if have python3; then
    python3 -I - "$QUIRE_SETTINGS" "$FOLDER" <<'PY' || die "couldn't write Quire's settings"
import json, os, sys
path, folder = sys.argv[1], sys.argv[2]
try:
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
except (OSError, ValueError):
    data = {}
data["folder"] = folder
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
os.replace(tmp, path)
PY
  elif [ ! -f "$QUIRE_SETTINGS" ]; then
    local esc
    esc=$(printf '%s' "$FOLDER" | sed 's/\\/\\\\/g; s/"/\\"/g')
    printf '{\n  "folder": "%s"\n}\n' "$esc" >"$QUIRE_SETTINGS"
  else
    warn "No python3 to edit $QUIRE_SETTINGS; choose the folder in Quire's Settings."
  fi
}

# ~/.cargo/bin on PATH, in the start-up file of the shell you use.
add_to_path() {
  local sh rc line
  sh=$(basename "${SHELL:-bash}")
  case "$sh" in
    zsh) rc="$HOME/.zshrc" ;;
    fish) rc="${XDG_CONFIG_HOME:-$HOME/.config}/fish/conf.d/quire.fish" ;;
    bash) if [ $OS = mac ]; then rc="$HOME/.bash_profile"; else rc="$HOME/.bashrc"; fi ;;
    *) rc="$HOME/.profile" ;;
  esac
  local dir=${TUI_DIR:-$BIN}
  if [ "$sh" = fish ]; then line="fish_add_path \"$dir\""
  else line="export PATH=\"$dir:\$PATH\""
  fi
  if [ -f "$rc" ] && grep -q -F "$dir" "$rc"; then
    say "  ${D}$rc already adds $dir${R}"
    return 0
  fi
  say "  ${D}PATH → $rc${R}"
  [ $DRY -eq 1 ] && return 0
  mkdir -p "$(dirname "$rc")"
  printf '\n# Added by Quire'"'"'s installer\n%s\n' "$line" >>"$rc"
}

# Everything runs from one function call at the very end, so bash has read
# the whole script before the first command starts — under `curl … | bash`,
# a child that read stdin would otherwise eat the rest of it. The exit on the
# same line stops bash reading on afterwards, which matters if the file is
# replaced (a `git pull`) during a long build.
main() {
  printf '%sQuire installer%s %s(%s%s%s)%s\n' "$B" "$R" "$D" "$OS" \
    "$([ $MODE = uninstall ] && echo ', uninstall')" "$([ $DRY -eq 1 ] && echo ', dry run')" "$R"
  log "Quire installer $STAMP on $OS (mode=$MODE dry=$DRY yes=$YES pick=$PICK)"
  if [ $MODE = uninstall ]; then uninstall_main; else install_main; fi
}

main; exit $?
