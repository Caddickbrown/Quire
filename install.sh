#!/usr/bin/env bash
# Quire installer — Linux and macOS.
#
# Finds jnl, Nook and Wander, offers to remove them, installs Quire, and points
# it at your journal. It never deletes a journal folder: removed apps go to the
# Trash (macOS, or Linux with `gio`) or to a dated folder under
# ~/.local/state/quire/, and every step is written to a log there.
#
#   ./install.sh                 ask before each step
#   ./install.sh --dry-run       show what it would do; change nothing
#   ./install.sh --yes           take every default without asking
#
#   curl -fsSL https://raw.githubusercontent.com/Caddickbrown/Quire/main/install.sh | bash
#
# Order matters: everything is asked up front, then the journal is backed up,
# Quire is installed and checked, and only then are the old apps removed — so
# a failed build never leaves you with no journal app at all.
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
FOLDER_ARG=""
SOURCE_ARG=""
WANT_DESKTOP=1
WANT_REMOVE=1

usage() {
  cat <<'EOF'
Quire installer — finds jnl, Nook and Wander, offers to remove them, installs
Quire, and points it at your journal. Journal folders are never deleted.

  --dry-run        show the plan and every command; change nothing
  -y, --yes        accept each default without asking
  --folder DIR     use DIR as the journal folder
  --source DIR     build from this Quire checkout instead of cloning
  --no-desktop     terminal app only (skip the Linux desktop app)
  --keep-old       install Quire alongside the old apps; remove nothing
  -h, --help       this text

Environment: QUIRE_REPO, QUIRE_REF (default main) pick what gets cloned.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    -y|--yes) YES=1 ;;
    --folder) shift; FOLDER_ARG=${1:-} ;;
    --source) shift; SOURCE_ARG=${1:-} ;;
    --no-desktop) WANT_DESKTOP=0 ;;
    --keep-old) WANT_REMOVE=0 ;;
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
  if [ $YES -eq 1 ] || [ $DRY -eq 1 ]; then printf '%s' "$def"; return; fi
  printf '  %s %s[%s]%s ' "$q" "$D" "$def" "$R" >&2
  IFS= read -r reply <"$TTY" || reply=""
  printf '%s' "${reply:-$def}"
}

# run cmd args… — print it, then run it unless this is a dry run.
run() {
  printf '  %s$ %s%s\n' "$D" "$*" "$R"
  log "  \$ $*"
  [ $DRY -eq 1 ] && return 0
  "$@" </dev/null >>"$LOG" 2>&1 || { local rc=$?; tail -n 20 "$LOG" >&2; return $rc; }
}

# The same, but the output goes to the screen (builds, sudo prompts).
run_loud() {
  printf '  %s$ %s%s\n' "$D" "$*" "$R"
  log "  \$ $*"
  [ $DRY -eq 1 ] && return 0
  "$@" </dev/null 2>&1 | tee -a "$LOG"
}

have() { command -v "$1" >/dev/null 2>&1; }

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

# ---------- what is installed ----------

# Removable things, one per index:
#   ITEM_APP   jnl | Nook | Wander
#   ITEM_KIND  file | dpkg | rpm
#   ITEM_WHAT  a path, or a package name
#   ITEM_DESC  shown to the user
#   ITEM_DEF   y | n — the default answer
#   ITEM_PICK  filled in once asked
ITEM_APP=(); ITEM_KIND=(); ITEM_WHAT=(); ITEM_DESC=(); ITEM_DEF=(); ITEM_PICK=()
SEEN=" "

add_item() {
  case "$SEEN" in *" $2:$3 "*) return ;; esac
  SEEN="$SEEN$2:$3 "
  ITEM_APP+=("$1"); ITEM_KIND+=("$2"); ITEM_WHAT+=("$3"); ITEM_DESC+=("$4"); ITEM_DEF+=("$5"); ITEM_PICK+=(n)
}

# Journal folders the old apps point at: JOUR_PATH / JOUR_FROM, deduplicated.
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

detect_jnl() {
  local p kind real
  local candidates
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
      quire) QUIRE_JNL_FOUND="$p" ;;
      go) add_item jnl file "$p" "jnl (the Go CLI) — $p  ${D}Quire installs its own jnl${R}" y ;;
      bash) add_item jnl file "$p" "jnl (the original bash script) — $p" y ;;
      *) add_item jnl file "$p" "a 'jnl' of unknown origin — $p" n ;;
    esac
  done <<EOF
$candidates
EOF

  # jnl's config is kept: Quire reads JNL_DIR and JNL_SPLIT_TAGS from it.
  local cfg=${XDG_CONFIG_HOME:-$HOME/.config}/jnl/config v=""
  if [ -f "$cfg" ]; then
    JNL_CONFIG="$cfg"
    v=$(sed -n 's/^:[[:space:]]*"\${JNL_DIR:=\(.*\)}"[[:space:]]*$/\1/p' "$cfg" | head -n 1)
  fi
  [ -n "${JNL_DIR:-}" ] && add_journal "$JNL_DIR" "\$JNL_DIR"
  [ -n "$v" ] && add_journal "$v" "jnl config"
  [ -d "$HOME/notes" ] && looks_like_journal "$HOME/notes" && add_journal "$HOME/notes" "jnl default"
}

# Linux packages built by Tauri: name = productName lowercased.
detect_linux_pkg() {
  local app=$1 pkg=$2 bin=$3
  if have dpkg-query && [ "$(dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null)" = "install ok installed" ]; then
    if dpkg-query -L "$pkg" 2>/dev/null | grep -q "^$bin\$"; then
      add_item "$app" dpkg "$pkg" "$app (.deb package '$pkg')" y
    fi
  fi
  if have rpm && rpm -q "$pkg" >/dev/null 2>&1; then
    if rpm -ql "$pkg" 2>/dev/null | grep -q "^$bin\$"; then
      add_item "$app" rpm "$pkg" "$app (.rpm package '$pkg')" y
    fi
  fi
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
  local apps=${XDG_DATA_HOME:-$HOME/.local/share}/applications
  [ -d "$apps" ] || return 0
  while IFS= read -r f; do
    [ -n "$f" ] && add_item "$app" file "$f" "$app launcher entry — $f" y
  done <<EOF
$(grep -l -i -E "^Name=$app\$" "$apps"/*.desktop 2>/dev/null)
EOF
}

# A macOS app bundle by bundle id, in the places apps are installed.
detect_mac_app() {
  local app=$1 id=$2 bundle cand
  cand=$(
    for bundle in /Applications/*.app "$HOME"/Applications/*.app; do echo "$bundle"; done
    have mdfind && mdfind "kMDItemCFBundleIdentifier == '$id'" 2>/dev/null
  )
  while IFS= read -r bundle; do
    [ -n "$bundle" ] && [ -f "$bundle/Contents/Info.plist" ] || continue
    case "$bundle" in */DerivedData/*|*/.Trash/*|*/Xcode*/*) continue ;; esac
    if [ "$(defaults read "$bundle/Contents/Info" CFBundleIdentifier 2>/dev/null)" = "$id" ]; then
      # No Quire for the Mac desktop yet, so keeping these is the default.
      add_item "$app" file "$bundle" "$app.app — $bundle" n
    fi
  done <<EOF
$cand
EOF
}

detect_nook() {
  if [ $OS = linux ]; then
    detect_linux_pkg Nook nook /usr/bin/nook
    detect_appimages Nook 'nook*.appimage'
    local cfg=${XDG_CONFIG_HOME:-$HOME/.config}/Nook/settings.json
    if [ -f "$cfg" ]; then
      NOOK_CONFIG="$cfg"
      add_journal "$(json_str "$cfg" customFolder)" "Nook"
    fi
    add_journal "$HOME/Documents/Nook" "Nook default"
  else
    detect_mac_app Nook com.caddickbrown.nook
    add_journal "$HOME/Library/Mobile Documents/iCloud~com~caddickbrown~nook/Documents" "Nook (iCloud)"
    add_journal "$HOME/Library/Containers/com.caddickbrown.nook/Data/Documents/Nook" "Nook (local)"
    add_journal "$HOME/Documents/Nook" "Nook default"
  fi
}

detect_wander() {
  if [ $OS = linux ]; then
    detect_linux_pkg Wander wander /usr/bin/wander
    detect_appimages Wander 'wander*.appimage'
    local f=${XDG_CONFIG_HOME:-$HOME/.config}/wander/folder
    [ -f "$f" ] && { WANDER_CONFIG="$f"; add_journal "$(head -n 1 "$f")" "Wander"; }
  else
    detect_mac_app Wander com.caddickbrown.wander
    local f="$HOME/Library/Application Support/wander/folder"
    [ -f "$f" ] && add_journal "$(head -n 1 "$f")" "Wander"
    add_journal "$(defaults read com.caddickbrown.wander journalFolderPath 2>/dev/null)" "Wander"
  fi
  add_journal "$HOME/Documents/Wander" "Wander default"
}

if [ $OS = mac ]; then
  QUIRE_SETTINGS="$HOME/Library/Application Support/quire/settings.json"
else
  QUIRE_SETTINGS="${XDG_CONFIG_HOME:-$HOME/.config}/quire/settings.json"
fi

detect_quire() {
  local f
  f=$(json_str "$QUIRE_SETTINGS" folder)
  case "$f" in */sample-journal|*/sample-journal/) f="" ;; esac
  [ -n "$f" ] && add_journal "$f" "Quire"
  if have dpkg-query && [ "$(dpkg-query -W -f='${Status}' quire 2>/dev/null)" = "install ok installed" ]; then
    QUIRE_DESKTOP_FOUND="the quire .deb"
  fi
}

# Everything below runs from one function, so bash has read the whole script
# before the first command starts — under `curl … | bash`, a child that read
# stdin would otherwise eat the rest of it.
main() {

# ---------- 1. look ----------

printf '%sQuire installer%s %s(%s%s)%s\n' "$B" "$R" "$D" "$OS" "$([ $DRY -eq 1 ] && echo ', dry run')" "$R"
log "Quire installer $STAMP on $OS (dry=$DRY yes=$YES)"

head1 "Looking for jnl, Nook and Wander"
QUIRE_JNL_FOUND=""; QUIRE_DESKTOP_FOUND=""
JNL_CONFIG=""; NOOK_CONFIG=""; WANDER_CONFIG=""
detect_quire
detect_jnl
detect_nook
detect_wander

if [ ${#ITEM_APP[@]} -eq 0 ]; then
  say "  None found."
else
  i=0
  while [ $i -lt ${#ITEM_APP[@]} ]; do say "  • ${ITEM_DESC[$i]}"; i=$((i + 1)); done
fi
[ -n "$QUIRE_JNL_FOUND" ] && say "  • Quire is already installed — $QUIRE_JNL_FOUND (it will be updated)"
[ -n "$QUIRE_DESKTOP_FOUND" ] && say "  • Quire desktop — $QUIRE_DESKTOP_FOUND"

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

# ---------- 2. ask everything, up front ----------

head1 "Your journal"
# The default: the folder Quire already uses, else the biggest journal (ties
# go to the first found: JNL_DIR, jnl's config, Nook, Wander).
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
  say "  Journal: $FOLDER"
fi

# Several real journals is worth a sentence: Quire opens one at a time.
others=0
i=0
while [ $i -lt ${#JOUR_PATH[@]} ]; do
  if [ "${JOUR_PATH[$i]}" != "$(realdir "$FOLDER" 2>/dev/null || echo "$FOLDER")" ] && looks_like_journal "${JOUR_PATH[$i]}"; then
    others=$((others + 1))
  fi
  i=$((i + 1))
done
if [ $others -gt 0 ]; then
  warn "$others other journal folder(s) found. Quire opens one; the others are left exactly as they are."
  say "    To bring one in later: Settings › Maintenance › Import a markdown folder."
fi

DO_BACKUP=0
if [ -d "$FOLDER" ] && looks_like_journal "$FOLDER"; then
  ask "Back up $FOLDER first ($(human_size "$FOLDER")) to ~/quire-preinstall-$STAMP.tar.gz?" y && DO_BACKUP=1
fi

DO_MIGRATE=0
if [ -f "$FOLDER/inbox.md" ]; then
  say ""
  say "  This journal keeps drafts in inbox.md. Quire keeps them in inbox/YYYY/MM/DD.md"
  say "  and moves them the first time it opens the folder (inbox.md is kept, renamed,"
  say "  under .quire/migration/). Apps that still read inbox.md — the Go jnl, Nook,"
  say "  Wander — will stop seeing drafts there. Filed entries are untouched."
  ask "Move the drafts now?" y && DO_MIGRATE=1
fi

head1 "Installing Quire"
DO_DESKTOP=0
if [ $OS = linux ] && [ $WANT_DESKTOP -eq 1 ]; then
  ask "Install the desktop app too? (a longer build: Tauri, WebKitGTK, Node)" y && DO_DESKTOP=1
fi
if [ $OS = mac ]; then
  say "  On the Mac, Quire is the terminal app for now (quire, and jnl). The Mac app"
  say "  is next: Nook's Swift shell rebuilt over Quire's core."
fi

head1 "Removing the old apps"
if [ ${#ITEM_APP[@]} -eq 0 ]; then
  say "  Nothing to remove."
elif [ $WANT_REMOVE -eq 0 ]; then
  say "  --keep-old: leaving them installed."
else
  say "  Apps only. Journal folders are never touched; settings are asked about separately."
  [ $OS = mac ] && say "  ${D}Mac apps default to keep, since Quire has no Mac app yet.${R}"
  i=0
  while [ $i -lt ${#ITEM_APP[@]} ]; do
    if ask "Remove ${ITEM_DESC[$i]}?" "${ITEM_DEF[$i]}"; then ITEM_PICK[$i]=y; fi
    i=$((i + 1))
  done
fi

# Settings of an app being removed: off by default, since Nook's holds the
# folder you chose there and is harmless to keep.
CFG_REMOVE=()
picked_app() {
  local i=0
  while [ $i -lt ${#ITEM_APP[@]} ]; do
    [ "${ITEM_APP[$i]}" = "$1" ] && [ "${ITEM_PICK[$i]}" = y ] && return 0
    i=$((i + 1))
  done
  return 1
}
if [ -n "$NOOK_CONFIG" ] && picked_app Nook; then
  ask "Also remove Nook's settings ($(dirname "$NOOK_CONFIG"))?" n && CFG_REMOVE+=("$(dirname "$NOOK_CONFIG")")
fi
if [ -n "$WANDER_CONFIG" ] && picked_app Wander; then
  ask "Also remove Wander's settings ($(dirname "$WANDER_CONFIG"))?" n && CFG_REMOVE+=("$(dirname "$WANDER_CONFIG")")
fi
[ -n "$JNL_CONFIG" ] && say "  ${D}Keeping $JNL_CONFIG — Quire reads JNL_DIR and JNL_SPLIT_TAGS from it.${R}"

if [ $YES -eq 0 ] && [ $DRY -eq 0 ]; then
  echo
  ask "Go ahead?" y || { say "  Nothing changed."; exit 0; }
fi

# ---------- 3. back up ----------

if [ $DO_BACKUP -eq 1 ]; then
  head1 "Backing up"
  parent=$(dirname "$FOLDER"); base=$(basename "$FOLDER")
  run tar -czf "$HOME/quire-preinstall-$STAMP.tar.gz" -C "$parent" "$base" || die "backup failed — nothing else was changed"
  say "  → ~/quire-preinstall-$STAMP.tar.gz"
fi

# ---------- 4. install ----------

head1 "Building Quire"

# The source: --source, this checkout, or a clone.
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd -P)
if [ -n "$SOURCE_ARG" ]; then
  SRC=$(expand_home "$SOURCE_ARG")
elif [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/tui/Cargo.toml" ] && grep -q 'quire-tui' "$SCRIPT_DIR/tui/Cargo.toml"; then
  SRC=$SCRIPT_DIR
else
  SRC="${XDG_DATA_HOME:-$HOME/.local/share}/quire/src"
  have git || die "git is needed to fetch Quire's source"
  if [ -d "$SRC/.git" ]; then
    run git -C "$SRC" fetch --depth 1 origin "$REPO_REF" || die "couldn't fetch $REPO_URL"
    run git -C "$SRC" checkout -q FETCH_HEAD || die "couldn't check out $REPO_REF"
  else
    run mkdir -p "$(dirname "$SRC")"
    run git clone --depth 1 --branch "$REPO_REF" "$REPO_URL" "$SRC" || die "couldn't clone $REPO_URL"
  fi
fi
say "  Source: $SRC"

if [ $OS = mac ] && ! xcode-select -p >/dev/null 2>&1; then
  warn "The Xcode command-line tools are needed to build. Starting their installer —"
  warn "run this script again once it finishes."
  run xcode-select --install
  exit 1
fi

# Rust, from rustup, if there is none.
CARGO_DIR=${CARGO_HOME:-$HOME/.cargo}
[ -f "$CARGO_DIR/env" ] && . "$CARGO_DIR/env"
if ! have cargo; then
  say "  Rust isn't installed. Quire builds with it (rustup, into ~/.cargo)."
  if ask "Install Rust with rustup?" y; then
    have curl || die "curl is needed to install rustup"
    say "  ${D}\$ curl https://sh.rustup.rs | sh -s -- -y${R}"
    if [ $DRY -eq 0 ]; then
      curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y >>"$LOG" 2>&1 || die "rustup failed — see $LOG"
      . "$CARGO_DIR/env"
    fi
  else
    die "no Rust, no Quire: install it from https://rustup.rs and run this again"
  fi
fi

# The terminal app: quire and jnl into ~/.cargo/bin.
run_loud cargo install --locked --force --path "$SRC/tui" || die "the terminal app didn't build — see $LOG"
BIN="$CARGO_DIR/bin"
if [ $DRY -eq 0 ]; then
  [ -x "$BIN/quire" ] && [ -x "$BIN/jnl" ] || die "the build finished but $BIN/quire isn't there"
  # In a scratch folder: every quire run folds an inbox.md, and that is the
  # user's call (asked above), not a side effect of checking the build.
  probe=$(mktemp -d 2>/dev/null || echo "$STATE_DIR/probe-$STAMP")
  "$BIN/quire" --folder "$probe" help >/dev/null 2>&1 </dev/null || die "$BIN/quire doesn't run"
  rm -rf "$probe"
fi
say "  ✓ quire and jnl → $BIN"

# The desktop app (Linux).
if [ $DO_DESKTOP -eq 1 ]; then
  head1 "Building the desktop app"
  missing=""
  have pkg-config && pkg-config --exists webkit2gtk-4.1 2>/dev/null || missing="$missing webkit2gtk-4.1"
  have npm || missing="$missing node/npm"
  if [ -n "$missing" ]; then
    warn "Missing:$missing. On Debian/Ubuntu:"
    say "    sudo apt install libwebkit2gtk-4.1-dev build-essential libssl-dev libayatana-appindicator3-dev librsvg2-dev patchelf nodejs npm"
    say "    then: $0 --source \"$SRC\""
    warn "Skipping the desktop app; the terminal app is installed."
    DO_DESKTOP=0
  fi
fi
if [ $DO_DESKTOP -eq 1 ]; then
  if have dpkg; then BUNDLE=deb; else BUNDLE=appimage; fi
  run_loud sh -c "cd \"$SRC/linux\" && npm install --no-fund --no-audit && npx tauri build --bundles $BUNDLE" \
    || { warn "The desktop build failed (see $LOG); the terminal app is installed."; DO_DESKTOP=0; }
fi
if [ $DO_DESKTOP -eq 1 ]; then
  if [ $BUNDLE = deb ]; then
    DEB=$(ls -t "$SRC"/target/release/bundle/deb/*.deb "$SRC"/linux/src-tauri/target/release/bundle/deb/*.deb 2>/dev/null | head -n 1)
    if [ $DRY -eq 1 ]; then DEB=${DEB:-$SRC/target/release/bundle/deb/Quire_amd64.deb}; fi
    [ -n "$DEB" ] || die "the .deb isn't where Tauri leaves it"
    if have apt-get; then run_loud sudo apt-get install -y "$DEB"; else run_loud sudo dpkg -i "$DEB"; fi \
      || die "installing $DEB failed"
    say "  ✓ Quire desktop (.deb) — open it from your launcher"
  else
    IMG=$(ls -t "$SRC"/target/release/bundle/appimage/*.AppImage "$SRC"/linux/src-tauri/target/release/bundle/appimage/*.AppImage 2>/dev/null | head -n 1)
    if [ $DRY -eq 1 ]; then IMG=${IMG:-$SRC/target/release/bundle/appimage/Quire_amd64.AppImage}; fi
    [ -n "$IMG" ] || die "the AppImage isn't where Tauri leaves it"
    APPS_DIR=${XDG_DATA_HOME:-$HOME/.local/share}/applications
    ICON_DIR=${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/128x128/apps
    run mkdir -p "$HOME/Applications" "$APPS_DIR" "$ICON_DIR"
    run install -m 755 "$IMG" "$HOME/Applications/Quire.AppImage"
    run install -m 644 "$SRC/linux/src-tauri/icons/128x128.png" "$ICON_DIR/quire.png"
    if [ $DRY -eq 0 ]; then
      cat >"$APPS_DIR/quire.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Quire
Comment=Journalling over a plain folder of markdown
Exec=$HOME/Applications/Quire.AppImage
Icon=quire
Categories=Office;
Terminal=false
EOF
    fi
    say "  ✓ Quire desktop → ~/Applications/Quire.AppImage (and a launcher entry)"
  fi
fi

# ---------- 5. point it at the journal ----------

head1 "Setting Quire up"
if [ $DRY -eq 0 ] && [ ! -d "$FOLDER" ]; then
  mkdir -p "$FOLDER/journal" || die "can't create $FOLDER"
fi

# Merge "folder" into settings.json; everything else in it stays.
say "  ${D}folder → $QUIRE_SETTINGS${R}"
if [ $DRY -eq 0 ]; then
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
    esc=$(printf '%s' "$FOLDER" | sed 's/\\/\\\\/g; s/"/\\"/g')
    printf '{\n  "folder": "%s"\n}\n' "$esc" >"$QUIRE_SETTINGS"
  else
    warn "No python3 to edit $QUIRE_SETTINGS; choose the folder in Quire's Settings."
  fi
fi

# $JNL_DIR in the environment outranks the setting; say so if they differ.
if [ -n "${JNL_DIR:-}" ] && [ "$(realdir "$JNL_DIR" 2>/dev/null)" != "$(realdir "$FOLDER" 2>/dev/null)" ]; then
  warn "\$JNL_DIR is $JNL_DIR and wins over Quire's setting. Point it at $FOLDER, or unset it."
fi

if [ $DO_MIGRATE -eq 1 ]; then
  run "$BIN/quire" --folder "$FOLDER" migrate || die "moving the drafts failed — inbox.md is untouched; see $LOG"
  [ $DRY -eq 0 ] && tail -n 1 "$LOG" | sed 's/^ */  /'
fi
say "  ✓ Quire opens $FOLDER"

# ---------- 6. remove the old apps ----------

# Out of the way, not deleted: the Trash, or a dated folder in the state dir.
move_aside() {
  local p=$1 dest
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
    run sudo mkdir -p "$(dirname "$dest")" && run sudo mv "$p" "$dest"
  fi
}

removed=0
i=0
while [ $i -lt ${#ITEM_APP[@]} ]; do
  if [ "${ITEM_PICK[$i]}" = y ]; then
    [ $removed -eq 0 ] && head1 "Removing the old apps"
    removed=$((removed + 1))
    case "${ITEM_KIND[$i]}" in
      dpkg) if have apt-get; then run_loud sudo apt-get remove -y "${ITEM_WHAT[$i]}"; else run_loud sudo dpkg -r "${ITEM_WHAT[$i]}"; fi ;;
      rpm) if have dnf; then run_loud sudo dnf remove -y "${ITEM_WHAT[$i]}"; else run_loud sudo rpm -e "${ITEM_WHAT[$i]}"; fi ;;
      file) move_aside "${ITEM_WHAT[$i]}" ;;
    esac || warn "couldn't remove ${ITEM_DESC[$i]} — carrying on"
  fi
  i=$((i + 1))
done
for d in ${CFG_REMOVE[@]+"${CFG_REMOVE[@]}"}; do move_aside "$d"; done

# ---------- 7. done ----------

head1 "Done"
case ":$PATH:" in
  *":$BIN:"*) ;;
  *) warn "$BIN isn't on your PATH. Add it (rustup's ~/.cargo/env does), then open a new terminal." ;;
esac
if [ $DRY -eq 0 ]; then
  first=$(type -ap jnl 2>/dev/null | head -n 1)
  if [ -n "$first" ] && [ "$first" != "$BIN/jnl" ] && [ "$(classify_jnl "$first")" != quire ]; then
    warn "'jnl' still runs $first, ahead of Quire's on your PATH."
  fi
fi
say "  quire            the Today screen (jnl works too: same commands as before)"
[ $DO_DESKTOP -eq 1 ] && say "  Quire            the desktop app, from your launcher"
[ $DO_BACKUP -eq 1 ] && say "  Backup           ~/quire-preinstall-$STAMP.tar.gz"
if [ $removed -gt 0 ]; then
  if [ $OS = mac ]; then say "  Removed apps     in the Trash"
  elif have gio; then say "  Removed apps     in the Trash (packages via the package manager)"
  else say "  Removed apps     $STASH (packages via the package manager)"
  fi
fi
[ $DRY -eq 0 ] && say "  Log              $LOG"
[ $DRY -eq 1 ] && say "  ${D}Dry run: nothing was changed.${R}"
return 0
}

main
