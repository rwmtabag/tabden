#!/data/data/com.termux/files/usr/bin/bash
# tabden launcher (Termux side)
#
# Runs the setup wizard, installs the Termux-side pieces, creates the Ubuntu
# proot guest and your user, then hands off to guest.sh inside the guest.
#
#   tabden                        the wizard: install, or change an install
#   tabden install [lean|custom]  install; without lean or custom, asks which
#   tabden modify                 the wizard with your current choices
#   tabden update                 git pull the clone, then update Termux and Ubuntu
#   tabden theme NAME             switch colour theme in seconds: default,
#                                 catppuccin-mocha, tokyonight, gruvbox-dark
#   tabden uninstall              remove tabden (asks what to keep)
#   tabden doctor                 one report on the device and the install, safe to share
#   tabden fix-phantom            how to stop Android 12+ killing background processes
#   tabden help | version
#
# Options:
#   --dry-run          with install, modify or the wizard: show what would be
#                      installed and removed, and stop; nothing is changed
#   --yes              with install: skip the summary (needs --user or --config)
#   --user NAME        with install: the Ubuntu username
#   --config FILE      with install: take every choice from a selections file
#   --skip-preflight   with install, modify, update or the wizard: skip the
#                      space, memory, Termux-build and network checks
#
# 'tabden' is installed in Termux's ~/bin and runs this script from your
# clone; before the first install, run it as: bash launcher.sh [command]
# (from a clone, 'bash launcher.sh update' updates without a git pull).
#
# Without a clone (works once the repo is public; 'tabden update' needs a
# clone, so cloning is the recommended install):
#   bash <(curl -fsSL https://raw.githubusercontent.com/rwmtabag/tabden/main/launcher.sh)
# TABDEN_BASE_URL overrides where guest.sh is fetched from in that case.

set -uo pipefail

VERSION="0.1.0"
DISTRO="ubuntu"
BASE_URL="${TABDEN_BASE_URL:-https://raw.githubusercontent.com/rwmtabag/tabden/main}"
CFG_DIR="$HOME/.config/tabden"
SEL="$CFG_DIR/selections.env"
LOG_DIR="$HOME/.cache/tabden"
LOG="$LOG_DIR/termux.log"
BACKTITLE="tabden $VERSION  |  Termux + Ubuntu dev environment"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-.}")" 2>/dev/null && pwd || echo .)"

# ---------------------------------------------------------------- models ----
MODEL_ORDER=(qwen-coder-1.5b gemma4-e2b phi4-mini qwen3.5-4b)
declare -A MODEL_LABEL=(
  [qwen-coder-1.5b]="Qwen2.5-Coder 1.5B - autocomplete (FIM)"
  [gemma4-e2b]="Gemma 4 E2B - chat, fastest"
  [phi4-mini]="Phi-4-mini 3.8B - chat, best reasoning"
  [qwen3.5-4b]="Qwen 3.5 4B - chat"
)
declare -A OLLAMA_TAG=(
  [qwen-coder-1.5b]="qwen2.5-coder:1.5b"
  [gemma4-e2b]="gemma4:e2b"
  [phi4-mini]="phi4-mini"
  [qwen3.5-4b]="qwen3.5:4b"
)
# GGUF repos for llama.cpp's -hf flag. Verify each repo/quant exists before release.
declare -A HF_SPEC=(
  [qwen-coder-1.5b]="Qwen/Qwen2.5-Coder-1.5B-Instruct-GGUF:Q4_K_M"
  [gemma4-e2b]="unsloth/gemma-4-E2B-it-GGUF:Q4_K_M"
  [phi4-mini]="unsloth/Phi-4-mini-instruct-GGUF:Q4_K_M"
  [qwen3.5-4b]="unsloth/Qwen3.5-4B-GGUF:Q4_K_M"
)
declare -A MODEL_MB=( [qwen-coder-1.5b]=1000 [gemma4-e2b]=1800 [phi4-mini]=2500 [qwen3.5-4b]=2800 )

# shellcheck disable=SC2034  # read indirectly via ${!k} in save_selections
SEL_KEYS=(PROFILE DEV_USER PROJECTS_MODE TIMEZONE TABDEN_DIR REMOVE RUNTIMES IDE IDE_HELIX IDE_ROSLYN IDE_VSCODE AI_CLAUDE
          AI_LOCAL LOCAL_MODEL LLAMA_HF CLI_EXTRAS DOCKER_REMOTE DOCKER_SSH_HOST THEME)

# ---------------------------------------------------------------- themes ----
# "default" means tabden sets no colours at all. For the others, the palette
# below goes to Termux, and Ubuntu's tmux bar, bat, delta and Helix follow it.
THEMES=(default catppuccin-mocha tokyonight gruvbox-dark)
declare -A THEME_LABEL=(
  [default]="No theme: Termux's colours (recommended)"
  [catppuccin-mocha]="Catppuccin Mocha"
  [tokyonight]="Tokyo Night"
  [gruvbox-dark]="Gruvbox dark"
)

# --------------------------------------------------------------- helpers ----
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
dlg()  { dialog --backtitle "$BACKTITLE" "$@" 3>&1 1>&2 2>&3; }
on()   { [[ " $1 " == *" $2 "* ]] && echo on || echo off; }   # checklist state
is()   { [[ $1 == "$2" ]] && echo on || echo off; }            # radiolist state
join_lines() { tr '\n' ' ' | sed 's/^ *//; s/ *$//'; }
valid_user() { [[ $1 =~ ^[a-z_][a-z0-9_-]{0,31}$ && $1 != root ]]; }
valid_tz()   { [[ $1 =~ ^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)*$ ]]; }
valid_host() { [[ $1 =~ ^[A-Za-z0-9._-]+@[A-Za-z0-9._-]+$ ]]; }
valid_theme() { local t; for t in "${THEMES[@]}"; do [[ $t == "$1" ]] && return 0; done; return 1; }

write_block() {  # file content — replaces the managed block, never appends twice
  local f=$1
  touch "$f"
  sed -i '/^# >>> tabden >>>$/,/^# <<< tabden <<<$/d' "$f"
  printf '# >>> tabden >>>\n%s\n# <<< tabden <<<\n' "$2" >> "$f"
}

confirm_quit() {
  if dialog --backtitle "$BACKTITLE" --title "Quit" \
       --yesno "Quit the installer?\n\nNothing has been installed yet." 8 44; then
    clear; exit 0
  fi
}

# proot-distro flags that mount Termux's ~/projects over the guest user's ~/projects
bind_args() {
  [[ ${PROJECTS_MODE:-termux} == termux ]] &&
    printf '%s\n' --bind "$HOME/projects:/home/$DEV_USER/projects"
}

# Android's timezone (e.g. Europe/Lisbon); empty if it can't be read
# ------------------------------------------------------------- preflight ----
# Checks before anything is installed. Stops: under 4 GB free on a new
# install, or GitHub unreachable. Everything else is a warning, shown on the
# summary screen. --skip-preflight skips all of it. Results go to termux.log.
PRE_WARN=()
PRE_KIND=fresh        # fresh | existing (an Ubuntu guest is already there)
MEM_GB=""             # real RAM, e.g. 7.4; empty if it can't be read
SKIP_PREFLIGHT=0

plog()    { printf 'preflight: %s\n' "$*" >> "$LOG"; }
# Free megabytes where Termux's home is; nothing if it can't be read. df -Pk,
# because the df Termux runs may not know -m ("Unknown option m" on the test
# tablet); -P and -k are POSIX. If that still gives no number, ask the
# filesystem directly with stat.
free_mb() {
  local v
  v=$(df -Pk "$HOME" 2>/dev/null | awk 'NR == 2 { printf "%d", $4 / 1024 }')
  [[ $v =~ ^[0-9]+$ ]] || v=$(stat -f -c '%a %S' "$HOME" 2>/dev/null | awk 'NF == 2 { printf "%d", $1 * $2 / 1048576 }')
  [[ $v =~ ^[0-9]+$ ]] && printf '%s' "$v"
  return 0
}
mem_mb()  { awk '/^MemTotal:/ { printf "%d", $2 / 1024 }' /proc/meminfo 2>/dev/null; }
gb()      { awk -v m="$1" 'BEGIN { printf "%.1f", m / 1024 }'; }
net_ok()  { curl -fsI --max-time 5 https://github.com >/dev/null 2>&1; }

preflight() {
  local free mem rel
  : > "$LOG"
  plog "tabden $VERSION, mode=${FLAG_MODE:-wizard}, $PRE_KIND install, $(date '+%F %T')"
  mem=$(mem_mb)
  [[ $mem =~ ^[0-9]+$ ]] && (( mem > 0 )) && MEM_GB=$(gb "$mem")
  if [[ $SKIP_PREFLIGHT == 1 ]]; then plog "skipped (--skip-preflight)"; return 0; fi

  free=$(free_mb)
  if [[ $free =~ ^[0-9]+$ ]]; then
    plog "free space: $free MB"
    if [[ $PRE_KIND == fresh ]] && (( free < 4096 )); then
      plog "STOP: under 4 GB free for a new install"
      die "Only $(gb "$free") GB free; a new install needs at least 4 GB. Free some space, or run again with --skip-preflight to go ahead anyway."
    fi
    if [[ $PRE_KIND == existing ]] && (( free < 1024 )); then
      PRE_WARN+=("- Only $(gb "$free") GB free; updates and new components may fail.")
    fi
  else
    plog "free space: could not be read"
  fi

  if [[ -n $MEM_GB ]]; then
    plog "RAM: $MEM_GB GB"
    # MemTotal is what the kernel can use, so it's below the advertised size: a
    # "6 GB" device reports about 5.3-5.6 GB and a "4 GB" one under 4. The
    # warning is for the 4 GB class, where a build next to Claude Code has
    # little room; 5000 MB separates the two.
    (( mem < 5000 )) && PRE_WARN+=("- This device has $MEM_GB GB of RAM; Android may kill builds running next to Claude Code.")
  else
    plog "RAM: could not be read"
  fi

  rel=${TERMUX_APK_RELEASE:-${TERMUX_APP__APK_RELEASE:-}}
  plog "Termux build: ${rel:-not reported}"
  case $rel in
    GOOGLE_PLAY_STORE)
      PRE_WARN+=("- This is the Play Store build of Termux, which tabden isn't tested on. Use the F-Droid or GitHub build.") ;;
    "")
      PRE_WARN+=("- Can't tell which Termux build this is (an old version, or a shell not started by the Termux app). Use a current F-Droid or GitHub build.") ;;
  esac

  if ! command -v curl >/dev/null 2>&1; then
    plog "network: curl not installed yet, check skipped"
  elif net_ok || { sleep 2; net_ok; }; then
    plog "network: github.com reachable"
  else
    plog "STOP: github.com unreachable (two tries, 5 s each)"
    die "Can't reach github.com (tried twice). tabden downloads from GitHub; check the connection, or run again with --skip-preflight."
  fi

  local w
  for w in "${PRE_WARN[@]}"; do plog "warning: ${w#- }"; done
  return 0
}

# Run an Android system tool: Termux's wrapper when there is one, otherwise
# the binary in /system/bin. Never waits more than a few seconds.
android_cmd() {
  local tool=$1; shift
  if command -v "$tool" >/dev/null 2>&1; then
    timeout 3 "$tool" "$@" 2>/dev/null
  elif [[ -x /system/bin/$tool ]]; then
    timeout 3 env -u LD_PRELOAD -u LD_LIBRARY_PATH "/system/bin/$tool" "$@" 2>/dev/null
  else
    return 127
  fi
}

android_sdk() {
  local v
  v=$(android_cmd getprop ro.build.version.sdk) && [[ $v =~ ^[0-9]+$ ]] && printf '%s' "$v"
}

# Android 12+ keeps about 32 child processes across all apps and kills the
# rest with signal 9 (the "phantom process killer"). Prints one of:
#   disabled, enabled, unknown, na (Android 11 or older).
# Reading the setting often isn't allowed from an app, so "unknown" is normal.
# This only informs; it never stops an install.
check_phantom() {
  local sdk v prop
  sdk=$(android_sdk) || { echo unknown; return 0; }
  (( sdk >= 31 )) || { echo na; return 0; }
  if (( sdk == 31 )); then
    # Android 12 has no on/off flag; the fix raises the limit instead.
    v=$(android_cmd device_config get activity_manager max_phantom_processes) || v=""
    if [[ $v =~ ^[0-9]+$ ]] && (( v > 32 )); then echo disabled
    elif [[ $v == null || $v == 32 ]]; then echo enabled
    else echo unknown; fi
    return 0
  fi
  # 12L and later: adb writes the flag to global settings; the Android 14
  # developer option writes a system property. Settings win when both are set.
  v=$(android_cmd settings get global settings_enable_monitor_phantom_procs) || v=""
  case $v in
    false) echo disabled; return 0 ;;
    true)  echo enabled;  return 0 ;;
  esac
  # An empty property means "never set", not "couldn't be read": in AOSP's
  # SELinux policy (checked for Android 12L to 16) persist.sys.* is system_prop,
  # which app domains may read. So with the setting unset too ("null"), the
  # flag is at its default, which is on. Turning Developer options off again
  # writes an explicit "true". A getprop that fails or times out says nothing.
  prop=$(android_cmd getprop persist.sys.fflag.override.settings_enable_monitor_phantom_procs) ||
    { echo unknown; return 0; }
  case $prop in
    false) echo disabled ;;
    true)  echo enabled ;;
    "")    if [[ $v == null ]]; then echo enabled; else echo unknown; fi ;;
    *)     echo unknown ;;
  esac
}

phantom_warning() {  # one line for the summary screen; empty when there's nothing to say
  case ${PHANTOM:-} in
    enabled) echo "- Android's phantom process killer appears to be on; it can end sessions with signal 9. Run: tabden fix-phantom" ;;
    unknown) echo "- Android 12+ can kill background processes (signal 9). If sessions die while idle, run: tabden fix-phantom" ;;
  esac
}

fix_phantom() {
  local sdk state adb_setup
  local -A label=([disabled]="off" [enabled]="on" [unknown]="can't tell from here" [na]="not present")
  sdk=$(android_sdk) || sdk=""
  state=$(check_phantom)
  adb_setup=$(cat <<'EOF'
  Connect adb from Termux itself (no computer needed):
    pkg install android-tools
    Settings > Developer options > Wireless debugging: turn it on (needs Wi-Fi).
    Put Settings and Termux in split screen, so the pairing code stays visible.
    Tap "Pair device with pairing code", then in Termux:
      adb pair localhost:<pairing port>        (type the code when asked)
      adb connect localhost:<port on the Wireless debugging screen>
EOF
)
  cat <<EOF
Android's phantom process killer

Android 12 and later keep about 32 child processes across all apps and kill
the rest with signal 9. tmux, Claude Code, builds and language servers are all
child processes of Termux, so a busy session can lose some: Termux shows
"[Process completed (signal 9)]", or a tmux window just disappears.

This device: Android SDK ${sdk:-unknown}; killer: ${label[$state]}
EOF
  case $state in
    disabled) echo; echo "It's already off here. If processes still die, see dontkillmyapp.com for your"
              echo "phone maker's battery settings."; return 0 ;;
    na)       echo; echo "Android 11 and older don't have it; nothing to do."; return 0 ;;
  esac
  echo
  echo "Developer options: Settings > About, tap \"Build number\" 7 times."
  if [[ -z $sdk ]] || (( sdk >= 34 )); then
    cat <<EOF

Android 14 and later:
  Settings > System > Developer options > turn on "Disable child process restrictions".
  Restart the device.
  If the toggle is missing, use the Android 12L/13 method below.
EOF
  fi
  if [[ -z $sdk ]] || (( sdk >= 32 )); then
    cat <<EOF

Android 12L and 13 (also works on 14+):
$adb_setup
  Then:
      adb shell "settings put global settings_enable_monitor_phantom_procs false"
  Restart the device.
EOF
  fi
  if [[ -z $sdk ]] || (( sdk == 31 )); then
    cat <<EOF

Android 12:
$adb_setup
  Then:
      adb shell "/system/bin/device_config set_sync_disabled_for_tests persistent"
      adb shell "/system/bin/device_config put activity_manager max_phantom_processes 2147483647"
  Restart the device.
EOF
  fi
  cat <<EOF

A system update can reset this; run 'tabden fix-phantom' again if processes
start dying after one. 'den status' shows the current state.
EOF
}

android_tz() {
  local tz p off h
  [[ -n ${TZ:-} ]] && valid_tz "$TZ" && [[ $TZ == */* ]] && { printf '%s' "$TZ"; return 0; }
  for p in getprop /system/bin/getprop; do
    tz=$("$p" persist.sys.timezone 2>/dev/null) && valid_tz "$tz" && { printf '%s' "$tz"; return 0; }
  done
  # Last resort: Termux's clock already shows local time, so turn a
  # whole-hour offset into Etc/GMT-N (POSIX reverses the sign). This has no
  # daylight-saving rules, so the summary screen flags it.
  off=$(date +%z 2>/dev/null)
  if [[ $off =~ ^([+-])([0-9]{2})00$ ]]; then
    h=$((10#${BASH_REMATCH[2]}))
    if (( h == 0 )); then printf 'UTC'
    elif [[ ${BASH_REMATCH[1]} == + ]]; then printf 'Etc/GMT-%d' "$h"
    else printf 'Etc/GMT+%d' "$h"; fi
  fi
}

# ----------------------------------------------------------- components ----
# tabden records what it installs: Ubuntu-side in the guest's
# ~/.config/tabden/installed, Termux-side (local AI) in Termux's.
# Lines are "<id> <origin> [detail]"; origin is tabden or adopted.
TMANIFEST="$CFG_DIR/installed"
declare -A COMP_LABEL=(
  [dotnet]=".NET 10 SDK" [rust]="Rust (rustup)" [bun]="Bun" [node]="Node.js"
  [claude]="Claude Code" [helix]="Helix" [roslyn]="Roslyn C# language server"
  [vscode]="VS Code CLI and server" [lazygit]="lazygit" [delta]="git-delta"
  [gh]="GitHub CLI" [eza]="eza" [btop]="btop" [starship]="Starship"
  [docker]="Docker CLI and remote context"
  [ollama]="Ollama and its models" [llamacpp]="llama.cpp and cached models"
)

guest_home() { printf '%s/home/%s' "$(rootfs_dir)" "$DEV_USER"; }

tmark()   { tunmark "$1"; mkdir -p "$CFG_DIR"; printf '%s\n' "$*" >> "$TMANIFEST"; }
tunmark() { [[ -f $TMANIFEST ]] && sed -i "/^$1 /d" "$TMANIFEST"; return 0; }

# Both records, as "<id> <origin>" lines, comments dropped.
recorded_components() {
  local f
  for f in "$(guest_home)/.config/tabden/installed" "$TMANIFEST"; do
    # "theme" records the colours file, which follows THEME; it's not a component.
    [[ -f $f ]] && awk '!/^#/ && NF && $1 != "theme" { print $1, $2 }' "$f"
  done
}

selected_ids() {
  local ids="$RUNTIMES"
  [[ $AI_CLAUDE == 1 ]] && ids+=" claude"
  case $IDE in helix|helix-roslyn|both) ids+=" helix" ;; esac
  [[ $IDE == helix-roslyn ]] && ids+=" roslyn"
  case $IDE in vscode|both) ids+=" vscode" ;; esac
  ids+=" $CLI_EXTRAS"
  [[ $DOCKER_REMOTE == 1 ]] && ids+=" docker"
  [[ $AI_LOCAL != none ]] && ids+=" $AI_LOCAL"
  printf ' %s ' "$ids"
}

# Recorded components that the current selections no longer include.
removal_candidates() {
  local sel id origin
  sel=$(selected_ids)
  while read -r id origin; do
    [[ $sel == *" $id "* ]] || printf '%s %s\n' "$id" "$origin"
  done < <(recorded_components)
}

size_of() { du -sh "$@" 2>/dev/null | awk '{ print $1 }' | head -1; }

# Ubuntu's files as seen from Termux. proot-distro keeps them in
# containers/<name>/rootfs; older versions used installed-rootfs/<name>
# (migrated automatically on login).
rootfs_dir() {
  local base="$PREFIX/var/lib/proot-distro"
  if [[ -d $base/containers/$DISTRO/rootfs ]]; then
    printf '%s' "$base/containers/$DISTRO/rootfs"
  else
    printf '%s' "$base/installed-rootfs/$DISTRO"
  fi
}

guest_installed() { proot-distro login "$DISTRO" -- true >/dev/null 2>&1; }   # exists and starts
guest_exists()    { [[ -d $(rootfs_dir) ]]; }                                  # folder is there

# Stop everything running inside Ubuntu. Current proot-distro has 'kill';
# older versions don't, so fall back to the den session alone.
guest_stop_all() {
  proot-distro kill "$DISTRO" >/dev/null 2>&1 ||
    proot-distro login "$DISTRO" -- tmux kill-server >/dev/null 2>&1
  return 0
}
guest_uid()       { proot-distro login "$DISTRO" -- id -u "$1" 2>/dev/null; }

usage() {  # the header comment: every line from line 2 up to the first non-comment line
  local out
  out=$(sed -n '2,/^[^#]/p' "${BASH_SOURCE[0]}" 2>/dev/null | grep '^#' | sed 's/^# \{0,1\}//')
  if [[ -n $out ]]; then printf '%s\n' "$out"
  else echo "Usage: tabden [install [lean|custom] | modify | update | theme NAME | uninstall | doctor | fix-phantom | help] [options]"; fi
}

# ------------------------------------------------------------ selections ----
set_defaults() {
  PROFILE=lean; DEV_USER=""; PROJECTS_MODE=termux; TIMEZONE=""; TABDEN_DIR=""; REMOVE=""; RUNTIMES="dotnet rust bun"; IDE=helix
  AI_CLAUDE=1; AI_LOCAL=none; LOCAL_MODEL=""; LLAMA_HF=""
  CLI_EXTRAS="lazygit delta gh"; DOCKER_REMOTE=0; DOCKER_SSH_HOST=""; THEME=default
}

load_selections() {
  [[ -f $1 ]] || die "Selections file not found: $1"
  # shellcheck source=/dev/null
  . "$1"
  : "${IDE:=helix}" "${PROJECTS_MODE:=termux}" "${THEME:=default}"
  REMOVE=""   # removal is chosen afresh each run, never carried over
}

# shellcheck disable=SC2034  # values are written out by save_selections
finalize_selections() {
  [[ $MODE == lean ]] && PROFILE=lean || PROFILE=custom
  IDE_HELIX=1; IDE_ROSLYN=0; IDE_VSCODE=0
  case $IDE in
    helix-roslyn) IDE_ROSLYN=1 ;;
    vscode)       IDE_HELIX=0; IDE_VSCODE=1 ;;
    both)         IDE_VSCODE=1 ;;
  esac
  if [[ $AI_LOCAL == none ]]; then
    LOCAL_MODEL=""; LLAMA_HF=""
  else
    [[ -n $LOCAL_MODEL ]] || LOCAL_MODEL=qwen-coder-1.5b
    [[ $AI_LOCAL == llamacpp ]] && LLAMA_HF=${HF_SPEC[$LOCAL_MODEL]} || LLAMA_HF=""
  fi
  [[ $DOCKER_REMOTE == 1 ]] || DOCKER_SSH_HOST=""
}

save_selections() {
  mkdir -p "$CFG_DIR"
  {
    echo "# tabden selections - written by launcher.sh $VERSION on $(date +%F)"
    local k
    for k in "${SEL_KEYS[@]}"; do printf '%s="%s"\n' "$k" "${!k}"; done
  } > "$SEL"
}

# --------------------------------------------------------------- screens ----
# Return codes: 0 next, 1 back, 3 skip (not applicable).

screen_welcome() {
  local items=(lean "Lean (recommended)" custom "Custom - choose each component")
  [[ -f $SEL && ${INSTALL_CHOICE:-0} != 1 ]] && items+=(modify "Modify existing install")
  local text="Lean installs Claude Code, Helix, tmux, .NET 10, Rust, Bun
and git tools. No local LLM and no browser IDE.

Custom lets you pick the editor, AI setup, runtimes and extras."
  local c rc
  while :; do
    c=$(dlg --title "Welcome" --cancel-label "Quit" --default-item "${MODE:-lean}" \
          --menu "$text" 16 66 3 "${items[@]}"); rc=$?
    if (( rc == 0 )); then MODE=$c; return 0; fi
    confirm_quit
  done
}

screen_password() {
  local p1 p2 rc
  while :; do
    p1=$(dlg --title "Password for $DEV_USER" --cancel-label "Back" --insecure --passwordbox \
          "Password for $DEV_USER.\n\nsudo stays passwordless; this is for login and su." 11 60); rc=$?
    case $rc in 0) ;; 1) return 1 ;; *) confirm_quit; continue ;; esac
    if [[ -z $p1 ]]; then dlg --title "Password" --msgbox "Password can't be empty." 6 40; continue; fi
    p2=$(dlg --title "Password for $DEV_USER" --cancel-label "Back" --insecure --passwordbox \
          "Confirm password:" 8 60); rc=$?
    case $rc in 0) ;; 1) continue ;; *) confirm_quit; continue ;; esac
    if [[ $p1 == "$p2" ]]; then PASSWORD=$p1; return 0; fi
    dlg --title "Password" --msgbox "Passwords don't match." 6 40
  done
}

screen_user() {
  local u rc uid
  while :; do
    if [[ $YES == 1 ]]; then
      u=$DEV_USER
    else
      u=$(dlg --title "Username" --cancel-label "Back" --inputbox \
            "Linux username for the Ubuntu guest.\n\nLowercase letters, digits, - and _. Must start with a letter or _." \
            11 64 "$DEV_USER"); rc=$?
      case $rc in 0) ;; 1) return 1 ;; *) confirm_quit; continue ;; esac
    fi

    if ! valid_user "$u"; then
      [[ $YES == 1 ]] && die "Invalid username: $u"
      dlg --title "Username" --msgbox "\"$u\" is not a valid username." 7 50
      continue
    fi

    USER_EXISTS=0
    if (( GUEST_READY )); then
      uid=$(guest_uid "$u")
      if [[ -n $uid ]]; then
        if (( uid < 1000 )); then
          [[ $YES == 1 ]] && die "$u is a system account in the guest"
          dlg --title "Username" --msgbox "\"$u\" is a system account in the guest. Pick another name." 7 64
          continue
        fi
        USER_EXISTS=1
      fi
    fi

    DEV_USER=$u
    if (( USER_EXISTS )) || [[ $YES == 1 ]]; then PASSWORD=""; return 0; fi
    screen_password && return 0
    # Back from the password screen re-asks the username.
  done
}

screen_projects() {
  local out rc
  while :; do
    out=$(dlg --title "Project location" --cancel-label "Back" --radiolist \
          "Where ~/projects lives. Either way Ubuntu sees it at /home/$DEV_USER/projects.\n\nTermux home survives resetting or rebuilding the Ubuntu guest.\nBoth are deleted if Termux is uninstalled: push to a git remote." 16 74 2 \
          termux "Termux home, mounted into Ubuntu (recommended)" "$(is "$PROJECTS_MODE" termux)" \
          guest  "Ubuntu home only"                               "$(is "$PROJECTS_MODE" guest)"); rc=$?
    case $rc in
      0) [[ -n $out ]] && PROJECTS_MODE=$out; return 0 ;;
      1) return 1 ;;
      *) confirm_quit ;;
    esac
  done
}

screen_runtimes() {
  local out rc
  while :; do
    out=$(dlg --title "Runtimes" --cancel-label "Back" --separate-output --checklist \
          "Space toggles, Enter continues." 13 64 4 \
          dotnet ".NET 10 SDK"                        "$(on "$RUNTIMES" dotnet)" \
          rust   "Rust (rustup, minimal profile)"     "$(on "$RUNTIMES" rust)" \
          bun    "Bun"                                "$(on "$RUNTIMES" bun)" \
          node   "Node.js (only if a project needs it)" "$(on "$RUNTIMES" node)"); rc=$?
    case $rc in
      0) RUNTIMES=$(join_lines <<<"$out"); return 0 ;;
      1) return 1 ;;
      *) confirm_quit ;;
    esac
  done
}

screen_editor() {
  local out rc
  while :; do
    out=$(dlg --title "Editor" --cancel-label "Back" --radiolist \
          "Space selects, Enter continues.\n\nVS Code Server runs Roslyn via C# Dev Kit (1-4GB RAM)." 15 70 4 \
          helix        "Helix (recommended)"               "$(is "$IDE" helix)" \
          helix-roslyn "Helix + Roslyn C# language server" "$(is "$IDE" helix-roslyn)" \
          vscode       "VS Code Server in the browser"     "$(is "$IDE" vscode)" \
          both         "Helix and VS Code Server"          "$(is "$IDE" both)"); rc=$?
    case $rc in
      0) [[ -n $out ]] && IDE=$out; return 0 ;;
      1) return 1 ;;
      *) confirm_quit ;;
    esac
  done
}

screen_claude() {
  local out rc
  while :; do
    out=$(dlg --title "AI assistant" --cancel-label "Back" --separate-output --checklist \
          "Claude Code runs in the Ubuntu guest (official linux-arm64 build)." 10 70 1 \
          claude "Claude Code" "$( [[ $AI_CLAUDE == 1 ]] && echo on || echo off )"); rc=$?
    case $rc in
      0) [[ $out == *claude* ]] && AI_CLAUDE=1 || AI_CLAUDE=0; return 0 ;;
      1) return 1 ;;
      *) confirm_quit ;;
    esac
  done
}

screen_local() {
  local out rc
  while :; do
    out=$(dlg --title "Local model" --cancel-label "Back" --radiolist \
          "Optional offline model, run natively in Termux.\nCPU-only: keep to 1-4B models." 14 70 3 \
          none     "None (recommended)"                        "$(is "$AI_LOCAL" none)" \
          ollama   "Ollama - easier model management"          "$(is "$AI_LOCAL" ollama)" \
          llamacpp "llama.cpp - lighter, OpenAI-compatible API" "$(is "$AI_LOCAL" llamacpp)"); rc=$?
    case $rc in
      0) [[ -n $out ]] && AI_LOCAL=$out; return 0 ;;
      1) return 1 ;;
      *) confirm_quit ;;
    esac
  done
}

screen_model() {
  [[ $AI_LOCAL == none ]] && return 3
  local out rc m items=() cur=${LOCAL_MODEL:-qwen-coder-1.5b}
  for m in "${MODEL_ORDER[@]}"; do items+=("$m" "${MODEL_LABEL[$m]}" "$(is "$cur" "$m")"); done
  while :; do
    out=$(dlg --title "Model" --cancel-label "Back" --radiolist \
          "Q4 quantized. You can pull others later." 14 70 4 "${items[@]}"); rc=$?
    case $rc in
      0) [[ -n $out ]] && LOCAL_MODEL=$out; return 0 ;;
      1) return 1 ;;
      *) confirm_quit ;;
    esac
  done
}

screen_cli() {
  local out rc
  while :; do
    out=$(dlg --title "CLI extras" --cancel-label "Back" --separate-output --checklist \
          "Always installed: tmux, fzf, ripgrep, zoxide, bat." 15 70 6 \
          lazygit  "lazygit - git TUI"                          "$(on "$CLI_EXTRAS" lazygit)" \
          delta    "git-delta - readable diffs"                 "$(on "$CLI_EXTRAS" delta)" \
          gh       "gh - GitHub CLI"                            "$(on "$CLI_EXTRAS" gh)" \
          eza      "eza - ls replacement (icons need a Nerd Font)" "$(on "$CLI_EXTRAS" eza)" \
          starship "starship prompt (proot-safe config)"       "$(on "$CLI_EXTRAS" starship)" \
          btop     "btop (sees little under Android)"           "$(on "$CLI_EXTRAS" btop)"); rc=$?
    case $rc in
      0) CLI_EXTRAS=$(join_lines <<<"$out"); return 0 ;;
      1) return 1 ;;
      *) confirm_quit ;;
    esac
  done
}

screen_theme() {
  local out rc t items=()
  for t in "${THEMES[@]}"; do items+=("$t" "${THEME_LABEL[$t]}" "$(is "$THEME" "$t")"); done
  while :; do
    out=$(dlg --title "Theme" --cancel-label "Back" --radiolist \
          "Colours for the terminal, the tmux bar, bat, delta and Helix.\n\nSwitch later in a few seconds with: tabden theme NAME" 15 70 4 \
          "${items[@]}"); rc=$?
    case $rc in
      0) [[ -n $out ]] && THEME=$out; return 0 ;;
      1) return 1 ;;
      *) confirm_quit ;;
    esac
  done
}

screen_docker() {
  local out rc h
  while :; do
    out=$(dlg --title "Remote Docker" --cancel-label "Back" \
          --default-item "$( [[ $DOCKER_REMOTE == 1 ]] && echo yes || echo no )" --menu \
          "proot can't run containers. The Docker CLI can drive a remote\narm64 VM over SSH (e.g. via Tailscale)." 13 70 2 \
          no  "No remote Docker (recommended)" \
          yes "Install Docker CLI and point it at a VM"); rc=$?
    case $rc in 0) ;; 1) return 1 ;; *) confirm_quit; continue ;; esac
    if [[ $out == no ]]; then DOCKER_REMOTE=0; return 0; fi
    while :; do
      h=$(dlg --title "Remote Docker" --cancel-label "Back" --inputbox \
            "SSH target for the Docker host, as user@host:" 9 64 "$DOCKER_SSH_HOST"); rc=$?
      case $rc in 0) ;; 1) continue 2 ;; *) confirm_quit; continue ;; esac
      if valid_host "$h"; then DOCKER_REMOTE=1; DOCKER_SSH_HOST=$h; return 0; fi
      dlg --title "Remote Docker" --msgbox "Use the form user@host." 6 40
    done
  done
}

screen_remove() {
  [[ $YES == 1 ]] && { REMOVE=""; return 3; }
  local items=() id origin label sz out rc
  while read -r id origin; do
    [[ -n $id ]] || continue
    label=${COMP_LABEL[$id]:-$id}
    case $id in
      ollama)   sz=$(size_of "$HOME/.ollama") ;;
      llamacpp) sz=$(size_of "$HOME/.cache/llama.cpp") ;;
      *)        sz="" ;;
    esac
    [[ -n $sz ]] && label+=" ($sz)"
    if [[ $origin == adopted ]]; then
      items+=("$id" "$label, from before tracking" off)
    else
      items+=("$id" "$label" on)
    fi
  done < <(removal_candidates)
  (( ${#items[@]} )) || { REMOVE=""; return 3; }
  while :; do
    out=$(dlg --title "Remove deselected components" --cancel-label "Back" --separate-output --checklist \
          "These are installed but no longer selected.\nTicked items will be uninstalled; untick anything you want to keep.\n\nItems \"from before tracking\" were already there when tabden\nstarted keeping a record, so they start unticked." \
          19 74 $(( ${#items[@]} / 3 )) "${items[@]}"); rc=$?
    case $rc in
      0) REMOVE=$(join_lines <<<"$out"); return 0 ;;
      1) return 1 ;;
      *) confirm_quit ;;
    esac
  done
}

summary_text() {
  local mb=1200 rt t ide ai loc warn=""
  for rt in $RUNTIMES; do
    case $rt in dotnet) ((mb+=900)) ;; rust) ((mb+=600)) ;; bun) ((mb+=100)) ;; node) ((mb+=150)) ;; esac
  done
  case $IDE in
    helix)        ide="Helix";                   ((mb+=120)) ;;
    helix-roslyn) ide="Helix + Roslyn LS";       ((mb+=470)) ;;
    vscode)       ide="VS Code Server";          ((mb+=450)) ;;
    both)         ide="Helix + VS Code Server";  ((mb+=570)) ;;
  esac
  [[ $AI_CLAUDE == 1 ]] && { ai="Claude Code"; ((mb+=250)); } || ai="none"
  case $AI_LOCAL in
    none)     loc="none" ;;
    ollama)   loc="Ollama, ${MODEL_LABEL[${LOCAL_MODEL:-qwen-coder-1.5b}]%% - *}"; ((mb+=150 + ${MODEL_MB[${LOCAL_MODEL:-qwen-coder-1.5b}]})) ;;
    llamacpp) loc="llama.cpp, ${MODEL_LABEL[${LOCAL_MODEL:-qwen-coder-1.5b}]%% - *}"; ((mb+=60 + ${MODEL_MB[${LOCAL_MODEL:-qwen-coder-1.5b}]})) ;;
  esac
  for t in $CLI_EXTRAS; do
    case $t in lazygit) ((mb+=20)) ;; delta) ((mb+=10)) ;; gh) ((mb+=50)) ;; *) ((mb+=10)) ;; esac
  done
  [[ $DOCKER_REMOTE == 1 ]] && ((mb+=150))

  if [[ $AI_LOCAL != none && $IDE != helix ]]; then
    warn+="- Local model plus VS Code/Roslyn compete for the same ${MEM_GB:+$MEM_GB GB of }RAM."$'\n'
  fi
  if [[ $IDE == helix-roslyn && " $RUNTIMES " != *" dotnet "* ]]; then
    warn+="- Roslyn LS needs .NET: add .NET 10 or pick plain Helix."$'\n'
  fi
  if [[ $AI_CLAUDE == 0 && $AI_LOCAL == none ]]; then
    warn+="- No AI assistant selected."$'\n'
  fi
  local pw free
  pw=$(phantom_warning)
  [[ -n $pw ]] && warn+="$pw"$'\n'
  for pw in "${PRE_WARN[@]}"; do warn+="$pw"$'\n'; done
  # On a new install, want the estimate plus 1 GB spare.
  free=$(free_mb)
  if [[ $SKIP_PREFLIGHT != 1 && $PRE_KIND == fresh && $free =~ ^[0-9]+$ ]] && (( free < mb + 1024 )); then
    warn+="- About $(gb "$mb") GB needed and only $(gb "$free") GB free; leave at least 1 GB spare or pick fewer components."$'\n'
  fi

  printf 'Username:      %s%s\n' "$DEV_USER" "$( ((USER_EXISTS)) && echo " (existing)" || echo " (new)")"
  if [[ $TIMEZONE == Etc/GMT* ]]; then
    printf 'Timezone:      %s (from the clock offset; no daylight saving)\n' "$TIMEZONE"
  else
    printf 'Timezone:      %s\n' "${TIMEZONE:-UTC (could not read Android timezone)}"
  fi
  printf 'Projects:      %s\n' "$( [[ $PROJECTS_MODE == termux ]] && echo "Termux ~/projects, mounted into Ubuntu" || echo "Ubuntu home")"
  printf 'Runtimes:      %s\n' "${RUNTIMES:-none}"
  printf 'Editor:        %s\n' "$ide"
  printf 'AI assistant:  %s\n' "$ai"
  printf 'Local model:   %s\n' "$loc"
  printf 'CLI extras:    %s\n' "${CLI_EXTRAS:-none}"
  printf 'Remote Docker: %s\n' "$( [[ $DOCKER_REMOTE == 1 ]] && echo "$DOCKER_SSH_HOST" || echo no)"
  [[ $THEME != default ]] && printf 'Theme:         %s\n' "${THEME_LABEL[$THEME]}"
  if [[ -n $REMOVE ]]; then
    local r names=""
    for r in $REMOVE; do names+="${names:+, }${COMP_LABEL[$r]:-$r}"; done
    printf 'Will remove:   %s\n' "$names"
  fi
  printf '\nEstimated disk: ~%s GB   (free now: %s)\n' "$(gb "$mb")" \
    "$( [[ $free =~ ^[0-9]+$ ]] && echo "$(gb "$free") GB" || echo unknown )"
  [[ -n $warn ]] && printf '\nWarnings:\n%s' "$warn"
}

screen_summary() {
  local rc text h
  while :; do
    text=$(summary_text)
    # Size the box to the text (68 columns inside a 72-wide box, plus borders
    # and the button row). Not height 0: with a fixed width, dialog
    # 1.3-20240101 then draws the buttons and none of the text. A box taller
    # than the screen is cut to fit and scrolls.
    h=$(( $(fold -s -w 68 <<<"$text" | wc -l) + 5 ))
    dialog --backtitle "$BACKTITLE" --title "Summary" --yes-label "Install" --no-label "Back" \
      --no-collapse --yesno "$text" "$h" 72; rc=$?   # --no-collapse keeps the columns aligned
    case $rc in 0) return 0 ;; 1) return 1 ;; *) confirm_quit ;; esac
  done
}

run_steps() {  # name of an array of screen functions
  local -n _steps=$1
  local i=0 dir=1 rc
  while (( i < ${#_steps[@]} )); do
    "${_steps[$i]}"; rc=$?
    case $rc in
      0) dir=1;  ((i++)) ;;
      1) dir=-1; ((i--)) ;;
      3) ((i += dir)) ;;
    esac
    (( i < 0 )) && return 1
  done
  return 0
}

# Facts about this run rather than choices. Re-applied after anything that
# resets or reloads the selections (set_defaults, load_selections), which
# would otherwise wipe them.
run_context() {
  local tz
  # Remember this clone so the 'tabden' command can find it later.
  # shellcheck disable=SC2034  # saved via save_selections
  [[ -f $SCRIPT_DIR/launcher.sh && -f $SCRIPT_DIR/guest.sh ]] && TABDEN_DIR=$SCRIPT_DIR
  # Follow Android's timezone each run; only a --config file can pin one.
  [[ -n $CONFIG_FILE && -n $TIMEZONE ]] && valid_tz "$TIMEZONE" && return 0
  tz=$(android_tz)
  [[ -n $tz ]] && TIMEZONE=$tz
  return 0
}

wizard() {
  local steps keep
  while :; do
    [[ -z $FLAG_MODE ]] && screen_welcome
    keep=$DEV_USER
    case $MODE in
      modify)      load_selections "$SEL" ;;
      lean|custom) set_defaults; DEV_USER=$keep ;;
    esac
    run_context
    case $MODE in
      lean|config) steps=(screen_user screen_remove) ;;
      *) steps=(screen_user screen_projects screen_runtimes screen_editor screen_claude screen_local
                screen_model screen_cli screen_theme screen_docker screen_remove) ;;
    esac
    [[ $YES == 1 ]] || steps+=(screen_summary)
    run_steps steps && return 0
    [[ $YES == 1 ]] && die "Cancelled"
    FLAG_MODE=""   # Back past the first screen returns to Welcome
  done
}

# ---------------------------------------------------------- Termux phase ----
TFAILED=()
tstep() {
  local name=$1; shift
  info "$name"
  "$@" 2>&1 | tee -a "$LOG"
  local rc=${PIPESTATUS[0]}
  if (( rc != 0 )); then
    printf '\033[1;31m   failed (see %s)\033[0m\n' "$LOG"
    TFAILED+=("$name")
  fi
  return "$rc"
}

t_packages() {
  apt-get update &&
  apt-get -y -o Dpkg::Options::=--force-confold upgrade &&
  apt-get -y install proot-distro dialog curl
}

t_extra_keys() {
  local f="$HOME/.termux/termux.properties"
  mkdir -p "$HOME/.termux"
  if grep -q '^[[:space:]]*extra-keys[[:space:]]*=' "$f" 2>/dev/null; then
    echo "extra-keys already set in $f; leaving it alone"
    return 0
  fi
  cat >> "$f" <<'EOF'
extra-keys = [['ESC','/','-','HOME','UP','END','PGUP'], \
              ['TAB','CTRL','ALT','LEFT','DOWN','RIGHT','PGDN']]
EOF
  command -v termux-reload-settings >/dev/null && termux-reload-settings
  return 0
}

# Termux reads its 16 colours, background, foreground and cursor from
# ~/.termux/colors.properties. tabden owns that file only when its first
# line carries the mark below; anyone else's file is never changed or deleted.
COLORS_FILE="$HOME/.termux/colors.properties"
THEME_MARK="# written by tabden: theme"
colors_marked() { [[ -f $COLORS_FILE ]] && head -1 "$COLORS_FILE" 2>/dev/null | grep -q "^$THEME_MARK "; }
theme_step_needed() { [[ $THEME != default ]] || colors_marked; }
theme_reload() { command -v termux-reload-settings >/dev/null && termux-reload-settings; return 0; }

# Checked against upstream: catppuccin/termux (themes/catppuccin-mocha.properties),
# folke/tokyonight.nvim (extras/termux/tokyonight_night.properties) and
# morhetz/gruvbox (the dark palette and its terminal mapping in colors/gruvbox.vim).
# Columns: background foreground cursor color0..color15.
theme_palette() {
  local v i=0 c
  case $1 in
    catppuccin-mocha) v="1e1e2e cdd6f4 f5e0dc 45475a f38ba8 a6e3a1 f9e2af 89b4fa f5c2e7 94e2d5 bac2de 585b70 f38ba8 a6e3a1 f9e2af 89b4fa f5c2e7 94e2d5 a6adc8" ;;
    tokyonight)       v="1a1b26 c0caf5 c0caf5 15161e f7768e 9ece6a e0af68 7aa2f7 bb9af7 7dcfff a9b1d6 414868 ff899d 9fe044 faba4a 8db0ff c7a9ff a4daff c0caf5" ;;
    gruvbox-dark)     v="282828 ebdbb2 ebdbb2 282828 cc241d 98971a d79921 458588 b16286 689d6a a89984 928374 fb4934 b8bb26 fabd2f 83a598 d3869b 8ec07c ebdbb2" ;;
    *) return 1 ;;
  esac
  for c in $v; do
    case $i in
      0) printf 'background=#%s\n' "$c" ;;
      1) printf 'foreground=#%s\n' "$c" ;;
      2) printf 'cursor=#%s\n' "$c" ;;
      *) printf 'color%d=#%s\n' $((i - 3)) "$c" ;;
    esac
    ((i++))
  done
}

t_theme() {
  mkdir -p "$HOME/.termux" "$CFG_DIR"
  if [[ -e $COLORS_FILE ]] && ! colors_marked; then
    if [[ $THEME != default ]]; then
      echo "$COLORS_FILE is your own; leaving it alone"
      tnote "Theme: kept your own ~/.termux/colors.properties, so the terminal's colours were not changed. To use tabden's palette, move that file away and run: tabden theme $THEME"
    fi
    return 0
  fi
  if [[ $THEME == default ]]; then
    rm -f "$COLORS_FILE" || return 1
    tunmark theme
    echo "Removed tabden's $COLORS_FILE; Termux is back on its own colours"
  else
    { printf '%s %s\n' "$THEME_MARK" "$THEME"; theme_palette "$THEME"; } > "$COLORS_FILE.tmp" &&
      mv -f "$COLORS_FILE.tmp" "$COLORS_FILE" || return 1
    tmark theme tabden "$THEME"
    echo "Wrote the ${THEME_LABEL[$THEME]} palette to $COLORS_FILE"
  fi
  theme_reload
}

t_distro() {
  guest_installed && { echo "Ubuntu guest already installed"; return 0; }
  if guest_exists; then
    echo "An Ubuntu guest exists at $(rootfs_dir) but won't start."
    echo "If you don't need anything in it, remove it and run the installer again:"
    echo "  proot-distro remove $DISTRO"
    return 1
  fi
  proot-distro install "$DISTRO"
}

t_guest_user() {
  proot-distro login "$DISTRO" -- bash -s -- "$DEV_USER" <<'EOF'
set -e
u=$1
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y sudo ca-certificates curl
id -u "$u" >/dev/null 2>&1 || useradd -m -s /bin/bash "$u"
echo "$u ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/$u"
chmod 440 "/etc/sudoers.d/$u"
echo "user $u ready"
EOF
}

t_ollama() {
  local tag=${OLLAMA_TAG[$LOCAL_MODEL]} started=0 rc _
  if ! command -v ollama >/dev/null; then
    apt-get -y install ollama || return 1
    tmark ollama tabden
  fi
  if ! pgrep -f 'ollama serve' >/dev/null; then
    (ollama serve >/dev/null 2>&1 &)
    started=1
  fi
  for _ in $(seq 1 30); do curl -fs http://127.0.0.1:11434/ >/dev/null && break; sleep 1; done
  ollama pull "$tag"; rc=$?
  (( started )) && pkill -f 'ollama serve'
  return "$rc"
}

t_llamacpp() {
  if ! command -v llama-server >/dev/null; then
    apt-get -y install llama-cpp || return 1
    tmark llamacpp tabden
  fi
  echo "Model $LLAMA_HF downloads on the first 'den' run and is cached after that."
}

# tabden's own commands carry this line right after the #! line. A file in
# ~/bin without it isn't tabden's and is never overwritten.
TB_MARK="# tabden-managed"
is_ours() { [[ -f $1 ]] && sed -n 2p "$1" | grep -q "^$TB_MARK"; }
# Other commands of this name on PATH, outside ~/bin, that tabden's would hide.
hidden_by() {
  local d out="" IFS=:
  for d in $PATH; do
    [[ -z $d || $d == "$HOME/bin" ]] && continue
    [[ -f $d/$1 && -x $d/$1 ]] && out+="${out:+, }$d/$1"
  done
  printf '%s' "$out"
}
put_cmd() {  # name, with the script on stdin
  local f="$HOME/bin/$1" other
  if [[ -e $f ]] && ! is_ours "$f"; then
    cat >/dev/null
    tnote "Commands: ~/bin/$1 isn't tabden's, so it was left alone and tabden's '$1' isn't installed. Rename or move yours, then run: tabden update"
    return 0
  fi
  cat > "$f" && chmod 755 "$f" || return 1
  other=$(hidden_by "$1")
  [[ -n $other ]] && tnote "Commands: tabden's '$1' comes first on PATH, so it hides $other. Run that one by its full path."
  return 0
}

t_termux_files() {
  local lib="$HOME/.local/share/tabden"
  mkdir -p "$HOME/bin" "$LOG_DIR" "$lib"

  # Shared by the Termux-side commands below.
  cat > "$lib/termux-common.sh" <<'EOF'
# tabden: helpers for the Termux-side commands (sourced, not run).
. "$HOME/.config/tabden/selections.env" 2>/dev/null ||
  { echo "tabden isn't installed yet: run launcher.sh from your clone."; exit 1; }
DS_CACHE="$HOME/.cache/tabden"; mkdir -p "$DS_CACHE"

ds_login() {  # run a command in Ubuntu as your user, with projects mounted
  local bind=()
  if [ "${PROJECTS_MODE:-termux}" = termux ]; then
    mkdir -p "$HOME/projects"
    bind=(--bind "$HOME/projects:/home/$DEV_USER/projects")
  fi
  proot-distro login ubuntu --user "$DEV_USER" "${bind[@]}" -- "$@"
}

ds_session_alive() {
  proot-distro login ubuntu --user "$DEV_USER" -- tmux has-session -t den 2>/dev/null
}

ds_start_ai() {
  case "${AI_LOCAL:-none}" in
    ollama)
      pgrep -f 'ollama serve' >/dev/null ||
        (nohup ollama serve >"$DS_CACHE/ollama.log" 2>&1 &) ;;
    llamacpp)
      pgrep -f llama-server >/dev/null ||
        (nohup llama-server -hf "$LLAMA_HF" --host 127.0.0.1 --port 8081 -c 4096 -t 4 \
           >"$DS_CACHE/llama-server.log" 2>&1 &) ;;
  esac
}

ds_release() {  # stop any local model and let the tablet sleep
  pkill -f 'ollama serve' 2>/dev/null
  pkill -f llama-server 2>/dev/null
  command -v termux-wake-unlock >/dev/null && termux-wake-unlock
  return 0
}

ds_after_exit() {  # called when you come back to Termux
  if ds_session_alive; then
    echo "Detached: the den session keeps running and the tablet stays awake."
    echo "'den' to return, 'den stop' to end it."
  else
    ds_release
    echo "Den session ended; wake lock released."
  fi
}

ds_rootfs() {
  local base="$PREFIX/var/lib/proot-distro"
  if [ -d "$base/containers/ubuntu/rootfs" ]; then echo "$base/containers/ubuntu/rootfs"
  else echo "$base/installed-rootfs/ubuntu"; fi
}
EOF

  put_cmd den <<'EOF'
#!/data/data/com.termux/files/usr/bin/bash
# tabden-managed: written by tabden and rewritten on every update; edits are lost.
# den: the den session in Ubuntu (tmux), from Termux. 'den help' lists everything.
. "$HOME/.local/share/tabden/termux-common.sh"
case ${1:-} in
  "")
    command -v termux-wake-lock >/dev/null && termux-wake-lock
    ds_start_ai
    ds_login bash -lc '"$HOME/bin/den"'
    ds_after_exit ;;
  stop)
    proot-distro login ubuntu --user "$DEV_USER" -- \
      env TABDEN_QUIET=1 bash -lc '"$HOME/bin/den" stop 2>/dev/null || tmux kill-session -t den' 2>/dev/null
    ds_release
    echo "Stopped: the den session, any local model, and the wake lock." ;;
  status)
    # The report comes from Ubuntu; projects are mounted, so its mount line is right.
    ds_login bash -lc '"$HOME/bin/den" status'; rc=$?
    ds_session_alive || ds_release
    exit "$rc" ;;
  update)
    echo "In Termux, 'tabden update' updates everything: Termux packages, your clone and Ubuntu."
    echo "('den update' inside Ubuntu updates only the Ubuntu side.)"
    exit 1 ;;
  help|-h|--help)
    f="$(ds_rootfs)/home/$DEV_USER/.config/tabden/cheatsheet.txt"
    [ -f "$f" ] || { echo "No cheat sheet yet: finish the install first."; exit 1; }
    if command -v less >/dev/null; then exec less -RFX "$f"; else cat "$f"; fi ;;
  *)
    echo "Usage: den [stop|status|help]   ('den' alone opens the den session)"
    exit 2 ;;
esac
EOF

  put_cmd ubu <<'EOF'
#!/data/data/com.termux/files/usr/bin/bash
# tabden-managed: written by tabden and rewritten on every update; edits are lost.
# ubu: plain Ubuntu shell (or 'ubu <command>'), projects mounted.
. "$HOME/.local/share/tabden/termux-common.sh"
# A login shell loads tabden's environment (~/bin on PATH, .NET limit, TZ).
if [ $# -gt 0 ]; then ds_login bash -lc 'exec "$@"' ubu "$@"; else ds_login bash -l; fi
rc=$?
ds_session_alive || ds_release
exit "$rc"
EOF

  put_cmd tabden <<'EOF'
#!/data/data/com.termux/files/usr/bin/bash
# tabden-managed: written by tabden and rewritten on every update; edits are lost.
# tabden: run the installer from your clone. 'tabden update' pulls the clone first.
. "$HOME/.config/tabden/selections.env" 2>/dev/null
dir=${TABDEN_DIR:-}
if [ -z "$dir" ] || [ ! -f "$dir/launcher.sh" ]; then
  echo "Can't find your tabden clone. Run 'bash launcher.sh' from it once to register it."
  exit 1
fi
# Pull only for a valid update ('update' or 'update --skip-preflight'), so a
# mistyped option is refused before anything changes.
case "$*" in
  update|"update --skip-preflight") pull=1 ;;
  *) pull=0 ;;
esac
if [ "$pull" = 1 ] && git -C "$dir" rev-parse --git-dir >/dev/null 2>&1; then
  echo "==> Updating $dir"
  git -C "$dir" pull --ff-only || {
    echo "git pull failed; fix the clone, then retry."
    echo "If the repo's history was rewritten, re-clone it (only if you have no local changes there):"
    echo "  cd ~ && rm -rf tabden && git clone https://github.com/rwmtabag/tabden ~/tabden"
    exit 1
  }
fi
exec bash "$dir/launcher.sh" "$@"
EOF

  # The block keeps ~/bin on PATH and, as its last line, loads the user's own
  # settings. (An if, not "[ -f ] &&", which would leave a failed status.)
  write_block "$HOME/.bashrc" 'export PATH="$HOME/bin:$PATH"

# Your own settings; tabden never creates or changes this file.
if [ -f "$HOME/.config/tabden/local.sh" ]; then . "$HOME/.config/tabden/local.sh"; fi'

  # tabden's example, refreshed each run. local.sh itself is never written.
  cat > "$CFG_DIR/local.sh.example" <<'EOF'
# Your own shell settings for Termux. To use this file:
#   cp ~/.config/tabden/local.sh.example ~/.config/tabden/local.sh
#
# tabden loads ~/.config/tabden/local.sh at the end of its ~/.bashrc block.
# tabden never creates, edits or deletes local.sh, and 'tabden uninstall'
# backs it up to ~/tabden-local-backup/ first.
#
# alias p='cd ~/projects'
# alias d='den'
#
# Ubuntu has its own local.sh (and local.tmux.conf) in its own
# ~/.config/tabden/; see local.sh.example there.
EOF
}

# Notes for the final screen. A file, not a variable: tstep runs each step in
# a pipeline (a subshell), so a variable set inside a step would be lost.
TNOTES="$LOG_DIR/termux-notes"
tnote() { printf '%s\n' "$*" >> "$TNOTES"; }
has_projects() {  # dir — true if it holds anything besides the mount marker
  [[ -n $(find "$1" -mindepth 1 -maxdepth 1 ! -name .tabden-mount -print -quit 2>/dev/null) ]]
}

t_projects() {
  local tdir="$HOME/projects"
  local ghome gdir
  ghome="$(rootfs_dir)/home/$DEV_USER"
  gdir="$ghome/projects"
  mkdir -p "$tdir"
  if [[ ! -d $ghome ]]; then
    echo "Ubuntu home for $DEV_USER not found at $ghome; skipping the projects move"
    return 0
  fi
  mkdir -p "$gdir"
  if [[ $PROJECTS_MODE == guest ]]; then
    if has_projects "$tdir"; then
      tnote "Projects: files remain in Termux ~/projects; they are no longer mounted into Ubuntu. Move them yourself if needed."
    fi
    rm -f "$tdir/.tabden-mount"
    echo "Projects stay in the Ubuntu home"
    return 0
  fi
  if has_projects "$gdir"; then
    if ! has_projects "$tdir"; then
      echo "Moving existing projects from the Ubuntu home to $tdir"
      find "$gdir" -mindepth 1 -maxdepth 1 -exec mv -t "$tdir" {} + || return 1
    else
      tnote "Projects: both Termux ~/projects and the Ubuntu-home copy have files. The Ubuntu copy is hidden by the mount, not deleted: $gdir"
    fi
  fi
  : > "$tdir/.tabden-mount"   # lets 'den status' confirm the mount inside Ubuntu
  echo "Termux ~/projects will be mounted at /home/$DEV_USER/projects"
}

guest_put() {  # src dest-relative-to-guest-home mode
  proot-distro login "$DISTRO" --user "$DEV_USER" -- bash -c \
    'mkdir -p "$(dirname "$HOME/$1")" && cat > "$HOME/$1" && chmod "$2" "$HOME/$1"' _ "$2" "$3" < "$1"
}

t_copy_guest() {
  local src="$SCRIPT_DIR/guest.sh"
  if [[ ! -f $src ]]; then
    src="$LOG_DIR/guest.sh"
    echo "Fetching guest.sh from $BASE_URL"
    curl -fsSL "$BASE_URL/guest.sh" -o "$src" || return 1
  fi
  guest_put "$src" .local/share/tabden/guest.sh 755 &&
  guest_put "$SEL" .config/tabden/selections.env 644
}

final_report() {
  local out status failures notes msg
  out=$(proot-distro login "$DISTRO" --user "$DEV_USER" -- bash -c \
    'cat "$HOME/.cache/tabden/result" 2>/dev/null; echo "@@notes@@"; cat "$HOME/.cache/tabden/notes" 2>/dev/null' 2>/dev/null)
  status=$(sed -n '1p' <<<"$out")
  # Lines 2.. up to the marker are failures; everything after it is notes.
  failures=$(awk 'NR == 1 { next } /^@@notes@@$/ { exit } NF' <<<"$out")
  notes=$(awk 'seen && NF; /^@@notes@@$/ { seen = 1 }' <<<"$out")

  msg="tabden finished."$'\n\n'
  (( ${#TFAILED[@]} )) && msg+="Termux-side failures: ${TFAILED[*]}"$'\n'
  if [[ $status != "done" ]]; then
    msg+="The guest phase did not finish. Re-run: tabden modify"$'\n'
  elif [[ -n $failures ]]; then
    msg+="Guest failures:"$'\n'"$failures"$'\n'"Re-run tabden modify to retry them."$'\n'
  fi
  [[ -s $TNOTES ]] && msg+="$(cat "$TNOTES")"$'\n'
  msg+=$'\n'"Next steps:"$'\n'"- Restart Termux, then run 'den'."$'\n'
  [[ -n $notes ]] && msg+="$(sed 's/^/- /' <<<"$notes")"$'\n'
  msg+=$'\n'"Logs: $LOG (Termux), ~/.cache/tabden/install.log (guest)"

  dialog --backtitle "$BACKTITLE" --title "Done" --msgbox "$msg" 22 74
  clear
  printf '%s\n' "$msg"
}

# First run with tracking on an existing install: record a local AI runtime
# that's already here as "adopted" (offered for removal unticked).
t_seed_manifest() {
  [[ -f $TMANIFEST ]] && return 0
  mkdir -p "$CFG_DIR"
  echo "# Termux-side components installed by tabden: <id> <origin>" > "$TMANIFEST"
  command -v ollama >/dev/null && tmark ollama adopted
  command -v llama-server >/dev/null && tmark llamacpp adopted
  return 0
}

t_remove_ollama() {
  pkill -f 'ollama serve' 2>/dev/null
  apt-get -y remove ollama && rm -rf "$HOME/.ollama"
}
t_remove_llamacpp() {
  pkill -f llama-server 2>/dev/null
  apt-get -y remove llama-cpp && rm -rf "$HOME/.cache/llama.cpp"
}
t_removals() {
  local id
  for id in $REMOVE; do
    case $id in
      ollama|llamacpp)
        [[ $AI_LOCAL == "$id" ]] && continue          # selected again: keep
        grep -q "^$id " "$TMANIFEST" 2>/dev/null || continue
        tstep "Remove ${COMP_LABEL[$id]}" "t_remove_$id" && tunmark "$id" ;;
    esac
  done
  return 0
}

install_all() {
  mkdir -p "$LOG_DIR"
  : > "$TNOTES"
  tstep "Termux packages" t_packages
  tstep "Extra-keys row" t_extra_keys
  theme_step_needed && tstep "Theme: $THEME" t_theme
  tstep "Ubuntu guest" t_distro         || { final_report; exit 1; }
  tstep "User $DEV_USER" t_guest_user   || { final_report; exit 1; }
  if [[ -n ${PASSWORD:-} ]]; then
    info "Setting password for $DEV_USER"
    printf '%s:%s\n' "$DEV_USER" "$PASSWORD" | proot-distro login "$DISTRO" -- chpasswd ||
      TFAILED+=("password")
  fi
  PASSWORD=""
  t_seed_manifest
  t_removals
  case $AI_LOCAL in
    ollama)   tstep "Ollama + ${OLLAMA_TAG[$LOCAL_MODEL]}" t_ollama ;;
    llamacpp) tstep "llama.cpp" t_llamacpp ;;
  esac
  tstep "Project location" t_projects
  tstep "Termux commands" t_termux_files
  tstep "Copy guest installer" t_copy_guest || { final_report; exit 1; }
  info "Guest phase (Ubuntu, as $DEV_USER)"
  local bind=()
  mapfile -t bind < <(bind_args)
  proot-distro login "$DISTRO" --user "$DEV_USER" "${bind[@]}" -- \
    bash -l "/home/$DEV_USER/.local/share/tabden/guest.sh" --install
  final_report
}

update_all() {
  mkdir -p "$LOG_DIR"
  t_seed_manifest
  tstep "Termux packages" t_packages
  theme_step_needed && tstep "Theme: $THEME" t_theme
  tstep "Termux commands" t_termux_files
  tstep "Copy guest installer" t_copy_guest || exit 1
  info "Ubuntu updates (as $DEV_USER)"
  local bind=()
  mapfile -t bind < <(bind_args)
  proot-distro login "$DISTRO" --user "$DEV_USER" "${bind[@]}" -- \
    bash -l "/home/$DEV_USER/.local/share/tabden/guest.sh" --update
  echo
  if (( ${#TFAILED[@]} )); then
    printf '\033[1;31mTermux-side failures:\033[0m %s (log: %s)\n' "${TFAILED[*]}" "$LOG"
  fi
  echo "tabden update finished. If a den session is running, 'den stop' then 'den' picks up changes."
}

# ------------------------------------------------------------ --dry-run ----
# What confirming the Summary would have done. Called instead of
# save_selections and install_all, so nothing here may write anything.
dry_run_report() {
  local id r sel="" rem=""
  for id in $(selected_ids); do sel+="${sel:+, }${COMP_LABEL[$id]:-$id}"; done
  for r in $REMOVE; do rem+="${rem:+, }${COMP_LABEL[$r]:-$r}"; done
  printf '\033[1;36mDry run: this is what an install would do.\033[0m\n\n'
  summary_text | sed -n '1,/^$/p' | grep -v '^Will remove:'
  printf 'Would install (anything already present is skipped):\n  %s\n' "${sel:-nothing}"
  printf 'Would remove:\n  %s\n\n' "${rem:-nothing}"
  printf '\033[1;32mNothing was changed:\033[0m no choices were saved, and nothing was installed or removed.\n'
  printf 'Run the same command without --dry-run to do it.\n'
}

# ------------------------------------------------------------ --theme ----
# Switch theme on an existing install: save the choice, apply the Termux
# palette, then have guest.sh rewrite Ubuntu's dotfiles (--dotfiles: no apt,
# no downloads). The current guest.sh is copied first, since the installed
# copy may predate themes.
theme_flow() {
  valid_theme "$THEME_FLAG" ||
    die "Unknown theme '${THEME_FLAG}'. Choose one of: ${THEMES[*]}"
  [[ -f $SEL ]] || die "No existing install found ($SEL). Run the installer first."
  command -v proot-distro >/dev/null || die "proot-distro isn't installed. Run the installer first."
  set_defaults
  load_selections "$SEL"
  run_context
  [[ -n $DEV_USER ]] && guest_installed ||
    die "The Ubuntu guest isn't installed or won't start. Run the installer first."
  THEME=$THEME_FLAG
  save_selections
  printf 'theme: tabden %s, switching to %s, %s\n' "$VERSION" "$THEME" "$(date '+%F %T')" >> "$LOG"
  : > "$TNOTES"
  t_seed_manifest
  theme_step_needed && tstep "Theme: $THEME" t_theme
  tstep "Copy guest installer" t_copy_guest || exit 1
  info "Ubuntu dotfiles (as $DEV_USER)"
  local bind=() rc
  mapfile -t bind < <(bind_args)
  proot-distro login "$DISTRO" --user "$DEV_USER" "${bind[@]}" -- \
    bash -l "/home/$DEV_USER/.local/share/tabden/guest.sh" --dotfiles; rc=$?
  echo
  [[ -s $TNOTES ]] && cat "$TNOTES"
  if (( rc != 0 || ${#TFAILED[@]} )); then
    printf '\033[1;31mThe theme was only partly applied\033[0m (logs: %s, and ~/.cache/tabden/install.log in Ubuntu).\n' "$LOG"
    return 1
  fi
  if [[ $THEME == default ]]; then echo "Theme: default. tabden sets no colours now."
  else echo "Theme: ${THEME_LABEL[$THEME]}."; fi
  echo "Shells that are already open keep the old settings: 'den stop', then 'den', for a clean switch."
}

# ---------------------------------------------------------------- doctor ----
# One report on the device and the install, for a quick check or a bug report.
# It's meant to be pasted in public, so it never prints the username, git
# names or emails, the VS Code token or the timezone's name: only whether each
# is set. It reads; it changes nothing (no log, no packages, no preflight stop).
DOC_PROBLEMS=0
doc_line() { printf '  %-20s %s\n' "$1" "$2"; }
doc_bad()  { doc_line "$1" "$2"; DOC_PROBLEMS=$(( DOC_PROBLEMS + 1 )); }

# Runs inside Ubuntu as the user, with projects mounted as 'den' would.
# Prints "key<TAB>value" lines for doctor_flow. Nothing personal in the values.
DOC_PROBE=$(cat <<'EOS'
s() { printf '%s\t%s\n' "$1" "$2"; }
if [ -e "$HOME/projects/.tabden-mount" ]; then s mount yes; else s mount no; fi
if tmux has-session -t den 2>/dev/null; then s session running; else s session none; fi
if [ -f "$HOME/.cache/tabden/result" ]; then
  s result "$(head -1 "$HOME/.cache/tabden/result")"
  s failures "$(tail -n +2 "$HOME/.cache/tabden/result" | tr '\n' ' ')"
else s result none; fi
case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in *[Uu][Tt][Ff]-8*|*[Uu][Tt][Ff]8*) s utf8 yes ;; *) s utf8 no ;; esac
if [ -n "$(git config --global user.email 2>/dev/null)" ]; then s gitid set; else s gitid unset; fi
for c in den git-id git-credential-gh-account; do
  f="$HOME/bin/$c"
  if [ ! -e "$f" ]; then s "cmd:$c" missing
  elif sed -n 2p "$f" | grep -q '^# tabden-managed'; then s "cmd:$c" ok
  else s "cmd:$c" "not tabden's"; fi
  other=""; IFS=:; for d in $PATH; do [ -z "$d" ] || [ "$d" = "$HOME/bin" ] || { [ -f "$d/$c" ] && [ -x "$d/$c" ] && { p="$d/$c"; case $p in "$HOME"/*) p='~'"${p#"$HOME"}" ;; esac; other="$other${other:+, }$p"; }; }; done; unset IFS
  [ -n "$other" ] && s "hidden:$c" "$other"
done
v() { command -v "$1" >/dev/null 2>&1 && s "ver:$1" "$("$@" 2>&1 | head -1)"; }
v dotnet --version; v rustc --version; v bun --version; v node --version; v claude --version
v hx --version; v code --version; v tmux -V; v lazygit --version; v delta --version; v gh --version
s os "$(. /etc/os-release; echo "$PRETTY_NAME")"
EOS
)

doctor_flow() {
  local sdk rel mem free v c f other probe key val uid ok_guest=0 tz
  echo "tabden doctor (tabden $VERSION). Safe to paste: no username, emails or timezone name."
  echo
  echo "Device"
  sdk=$(android_sdk) || sdk=""
  doc_line "Android" "SDK ${sdk:-unknown}, $(uname -m)"
  rel=${TERMUX_APK_RELEASE:-${TERMUX_APP__APK_RELEASE:-}}
  case $rel in
    GOOGLE_PLAY_STORE) doc_bad "Termux build" "Play Store build: untested; use the F-Droid or GitHub build" ;;
    "")                doc_bad "Termux build" "not reported (old Termux, or not started by the app)" ;;
    *)                 doc_line "Termux build" "$rel" ;;
  esac
  mem=$(mem_mb)
  if [[ $mem =~ ^[0-9]+$ ]] && (( mem > 0 )); then
    if (( mem < 5000 )); then doc_bad "RAM" "$(gb "$mem") GB: builds next to Claude Code may be killed"
    else doc_line "RAM" "$(gb "$mem") GB"; fi
  else doc_line "RAM" "couldn't be read"; fi
  free=$(free_mb)
  if [[ $free =~ ^[0-9]+$ ]]; then
    if (( free < 1024 )); then doc_bad "Free space" "$(gb "$free") GB: updates may fail"
    else doc_line "Free space" "$(gb "$free") GB"; fi
  else doc_bad "Free space" "couldn't be read"; fi
  if ! command -v curl >/dev/null 2>&1; then doc_bad "github.com" "curl isn't installed"
  elif net_ok; then doc_line "github.com" "reachable"
  else doc_bad "github.com" "not reachable"; fi
  case $(check_phantom) in
    disabled) doc_line "Phantom killer" "off" ;;
    enabled)  doc_bad  "Phantom killer" "on: sessions can end with signal 9. See: tabden fix-phantom" ;;
    unknown)  doc_line "Phantom killer" "can't tell from here. If sessions die with signal 9: tabden fix-phantom" ;;
    na)       doc_line "Phantom killer" "not present (Android 11 or older)" ;;
  esac

  echo
  echo "Install"
  if [[ ! -f $SEL ]]; then
    doc_bad "Selections" "none: tabden isn't installed (run: bash launcher.sh)"
    echo; echo "Problems: $DOC_PROBLEMS"; return 0
  fi
  set_defaults; load_selections "$SEL"
  doc_line "Selections" "profile $PROFILE, theme $THEME, projects in $( [[ $PROJECTS_MODE == termux ]] && echo "Termux (mounted)" || echo "Ubuntu home")"
  if [[ -n $TABDEN_DIR && -f $TABDEN_DIR/launcher.sh ]]; then
    if git -C "$TABDEN_DIR" rev-parse --git-dir >/dev/null 2>&1; then
      v="$(git -C "$TABDEN_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null) at $(git -C "$TABDEN_DIR" log -1 --format='%h, %cs' 2>/dev/null)"
      [[ -n $(git -C "$TABDEN_DIR" status --porcelain 2>/dev/null) ]] && v+=", with local changes"
      doc_line "Clone" "$v"
    else doc_line "Clone" "found (not a git clone: 'tabden update' can't pull)"; fi
  else doc_bad "Clone" "not found: 'tabden update' can't run (run launcher.sh from a clone once)"; fi
  if [[ -n $TIMEZONE ]]; then doc_line "Timezone" "set"; else doc_line "Timezone" "not set: Ubuntu uses UTC"; fi
  if ! command -v proot-distro >/dev/null 2>&1; then doc_bad "proot-distro" "not installed"
  elif ! guest_exists; then doc_bad "Ubuntu guest" "not installed"
  elif ! guest_installed; then doc_bad "Ubuntu guest" "installed but won't start"
  else
    doc_line "Ubuntu guest" "starts"
    uid=$(guest_uid "$DEV_USER")
    if [[ -n $DEV_USER && $uid =~ ^[0-9]+$ ]]; then doc_line "User" "set, exists in Ubuntu"; ok_guest=1
    else doc_bad "User" "set, but missing in Ubuntu"; fi
  fi
  for c in den ubu tabden; do
    f="$HOME/bin/$c"
    if [[ ! -e $f ]]; then doc_bad "Termux: $c" "missing"
    elif is_ours "$f"; then doc_line "Termux: $c" "ok"
    else doc_bad "Termux: $c" "not tabden's (a file of yours in ~/bin), so tabden's isn't installed"; fi
    other=$(hidden_by "$c")
    other=${other//"$HOME"\//\~/}       # ~ for the home folder, as on the Ubuntu side
    [[ -n $other ]] && doc_line "" "hides $other"
  done

  (( ok_guest )) || { echo; echo "Problems: $DOC_PROBLEMS"; return 0; }
  echo
  echo "Ubuntu"
  local bind=()
  mapfile -t bind < <(bind_args)
  probe=$(proot-distro login "$DISTRO" --user "$DEV_USER" "${bind[@]}" -- bash -l -s <<<"$DOC_PROBE" 2>/dev/null)
  local -A P=()
  while IFS=$'\t' read -r key val; do [[ -n $key ]] && P[$key]=$val; done <<<"$probe"
  doc_line "System" "${P[os]:-unknown}"
  if [[ $PROJECTS_MODE == termux ]]; then
    if [[ ${P[mount]:-} == yes ]]; then doc_line "Projects mount" "works"
    else doc_bad "Projects mount" "Termux ~/projects isn't visible in Ubuntu"; fi
  fi
  doc_line "Den session" "${P[session]:-unknown}"
  case ${P[result]:-none} in
    done) if [[ -n ${P[failures]// /} ]]; then doc_bad "Last install" "failed steps: ${P[failures]}"; else doc_line "Last install" "completed"; fi ;;
    none) doc_bad "Last install" "no record (the guest phase never finished)" ;;
    *)    doc_bad "Last install" "didn't finish" ;;
  esac
  if [[ ${P[utf8]:-} == yes ]]; then doc_line "UTF-8 locale" "yes"
  else doc_bad "UTF-8 locale" "no: symbols show as _ in tmux (tabden update, then den stop and den)"; fi
  doc_line "Git identity" "$( [[ ${P[gitid]:-} == set ]] && echo set || echo "not set: run git-id default")"
  for c in den git-id git-credential-gh-account; do
    case ${P[cmd:$c]:-missing} in
      ok)      doc_line "Ubuntu: $c" "ok" ;;
      missing) doc_bad "Ubuntu: $c" "missing" ;;
      *)       doc_bad "Ubuntu: $c" "not tabden's (a file of yours in ~/bin), so tabden's isn't installed" ;;
    esac
    [[ -n ${P[hidden:$c]:-} ]] && doc_line "" "hides ${P[hidden:$c]}"
  done
  echo
  echo "Versions"
  for key in dotnet rustc bun node claude hx code tmux lazygit delta gh; do
    [[ -n ${P[ver:$key]:-} ]] && doc_line "$key" "${P[ver:$key]}"
  done
  echo
  if (( DOC_PROBLEMS )); then echo "Problems: $DOC_PROBLEMS (marked above)"; else echo "No problems found."; fi
  return 0
}

# ------------------------------------------------------------- uninstall ----
# Copy the user's local.sh / local.tmux.conf out of a folder that is about to
# be deleted. Fails only if a file exists and can't be copied.
BACKUP_DIR="$HOME/tabden-local-backup"
BACKED_UP=()
backup_local() {  # source-folder label
  local src=$1 dest="$BACKUP_DIR/$2" f
  for f in local.sh local.tmux.conf; do
    [[ -f $src/$f ]] || continue
    mkdir -p "$dest" && cp -f "$src/$f" "$dest/$f" || return 1
    BACKED_UP+=("$2/$f")
  done
  return 0
}

uninstall_flow() {
  [[ -f $SEL ]] || die "No tabden install found ($SEL)."
  load_selections "$SEL"
  local items out chosen has_ai=0 has_theme=0 warn="" msg kept c
  colors_marked && has_theme=1
  grep -qE '^(ollama|llamacpp) ' "$TMANIFEST" 2>/dev/null && has_ai=1
  items=(commands "Termux commands and shell setup (den, ubu, tabden)" on
         guest    "Ubuntu guest and everything installed in it" off)
  (( has_ai )) && items+=(localai "Local model runtime and its models" on)
  items+=(projects "Termux ~/projects: your project files" off)

  out=$(dlg --title "Uninstall tabden" --cancel-label "Cancel" --separate-output --checklist \
        "Ticked items are removed; everything else is kept." 14 76 $(( ${#items[@]} / 3 )) "${items[@]}") ||
    { clear; echo "Cancelled; nothing was removed."; return 0; }
  chosen=" $(join_lines <<<"$out") "
  [[ -n ${chosen// /} ]] || { clear; echo "Nothing selected; nothing was removed."; return 0; }

  msg="This will remove:"$'\n'
  [[ $chosen == *" commands "* ]] && msg+="- den, ubu, tabden and tabden's shell block"$'\n'
  [[ $chosen == *" commands "* ]] && (( has_theme )) && msg+="- the theme's terminal colours (~/.termux/colors.properties)"$'\n'
  [[ $chosen == *" localai "* ]]  && msg+="- the local model runtime and downloaded models"$'\n'
  if [[ $chosen == *" guest "* ]]; then
    msg+="- the Ubuntu guest: every tool, setting and login inside it (including ~/.claude)"$'\n'
    [[ $PROJECTS_MODE == guest ]] && warn+="Your projects live in the Ubuntu home and will be deleted with it."$'\n'
  fi
  if [[ $chosen == *" projects "* ]]; then
    msg+="- Termux ~/projects and every file in it"$'\n'
    warn+="Your project files in Termux ~/projects will be deleted."$'\n'
  fi
  [[ -n $warn ]] && msg+=$'\n'"$warn"
  dialog --backtitle "$BACKTITLE" --title "Confirm" --yes-label "Remove" --no-label "Cancel" \
    --defaultno --yesno "$msg" 16 76 || { clear; echo "Cancelled; nothing was removed."; return 0; }
  if [[ $chosen == *" guest "* || $chosen == *" projects "* ]]; then
    out=$(dlg --title "Confirm" --inputbox "This deletes data that can't be recovered.\nType DELETE to continue:" 9 60) || out=""
    [[ $out == DELETE ]] || { clear; echo "Not confirmed; nothing was removed."; return 0; }
  fi
  clear

  info "Stopping the den session"
  if is_ours "$HOME/bin/den"; then "$HOME/bin/den" stop; else command -v termux-wake-unlock >/dev/null && termux-wake-unlock; fi
  if [[ $chosen == *" localai "* ]]; then
    grep -q '^ollama ' "$TMANIFEST" 2>/dev/null && { info "Removing Ollama"; t_remove_ollama && tunmark ollama; }
    grep -q '^llamacpp ' "$TMANIFEST" 2>/dev/null && { info "Removing llama.cpp"; t_remove_llamacpp && tunmark llamacpp; }
  fi
  if [[ $chosen == *" guest "* ]]; then
    info "Removing the Ubuntu guest"
    guest_stop_all
    if ! backup_local "$(guest_home)/.config/tabden" ubuntu; then
      GUEST_REMOVE_FAILED=1
      echo "Couldn't copy your Ubuntu local.sh / local.tmux.conf to $BACKUP_DIR; leaving the Ubuntu guest in place."
    elif proot-distro remove "$DISTRO" && ! guest_exists; then
      echo "Ubuntu guest removed."
    else
      GUEST_REMOVE_FAILED=1
      echo "Couldn't fully remove the Ubuntu guest ($(rootfs_dir) is still there)."
      echo "Check nothing is running in it with 'proot-distro ps', then: proot-distro remove $DISTRO"
    fi
  fi
  if [[ $chosen == *" projects "* ]]; then
    info "Removing Termux ~/projects"
    rm -rf "$HOME/projects"
  fi
  if [[ $chosen == *" commands "* ]]; then
    info "Removing Termux commands and shell setup"
    for c in den ubu tabden; do is_ours "$HOME/bin/$c" && rm -f "$HOME/bin/$c"; done   # only tabden's own
    rm -rf "$HOME/.local/share/tabden" "$LOG_DIR"
    sed -i '/^# >>> tabden >>>$/,/^# <<< tabden <<<$/d' "$HOME/.bashrc" 2>/dev/null
    if colors_marked; then rm -f "$COLORS_FILE"; tunmark theme; theme_reload; fi
    if backup_local "$CFG_DIR" termux; then
      rm -rf "$CFG_DIR"
    else
      echo "Couldn't copy your Termux local.sh to $BACKUP_DIR; leaving $CFG_DIR in place."
    fi
  fi

  echo
  if [[ ${GUEST_REMOVE_FAILED:-0} == 1 ]]; then echo "Done, except removing the Ubuntu guest (see above)."; else echo "Done."; fi
  if (( ${#BACKED_UP[@]} )); then
    echo "Your own settings were saved to $BACKUP_DIR: ${BACKED_UP[*]}"
    echo "After reinstalling, copy them back into ~/.config/tabden/ (Termux's and Ubuntu's)."
  fi
  kept="Kept: the extra-keys row in ~/.termux/termux.properties, and the proot-distro and dialog packages."
  if colors_marked; then
    kept+=$'\n'"The theme's terminal colours are still in ~/.termux/colors.properties ('tabden theme default' removes them)."
  fi
  [[ -n $TABDEN_DIR && -d $TABDEN_DIR ]] && kept+=$'\n'"The tabden clone is still at $TABDEN_DIR; delete it with: rm -rf $TABDEN_DIR"
  [[ $chosen != *" guest "* ]] && kept+=$'\n'"The Ubuntu guest is still installed (proot-distro remove $DISTRO deletes it)."
  [[ $chosen != *" commands "* && $chosen == *" guest "* ]] &&
    kept+=$'\n'"The Termux commands still point at the removed guest; run 'tabden' to reinstall it."
  printf '%s\n' "$kept"
}

# ------------------------------------------------------------------ main ----
parse_args() {
  FLAG_MODE=""; CMD=""; YES=0; CONFIG_FILE=""; USER_FLAG=""; THEME_FLAG=""; DRY_RUN=0; INSTALL_CHOICE=0
  if (( $# )) && [[ $1 != -* ]]; then
    CMD=$1; shift
    case $CMD in
      install)
        INSTALL_CHOICE=1          # ask Lean or Custom first
        if (( $# )) && [[ $1 != -* ]]; then
          case $1 in
            lean|custom) FLAG_MODE=$1; INSTALL_CHOICE=0 ;;
            *) die "tabden install takes lean or custom, not '$1' (see tabden help)." ;;
          esac
          shift
        fi ;;
      modify|update|uninstall|doctor|fix-phantom) FLAG_MODE=$CMD ;;
      theme)
        FLAG_MODE=theme; THEME_FLAG=${1:-}
        [[ -n $THEME_FLAG && $THEME_FLAG != -* ]] || die "Which theme? tabden theme NAME, one of: ${THEMES[*]}"
        shift ;;
      help)    usage; exit 0 ;;
      version) echo "$VERSION"; exit 0 ;;
      stop|status) die "That's a den command: den $CMD" ;;
      *) die "Unknown command: $CMD (see tabden help)" ;;
    esac
  fi
  while (( $# )); do
    case $1 in
      --dry-run)        DRY_RUN=1 ;;
      -y|--yes)         YES=1 ;;
      --user)           USER_FLAG=${2:-}; [[ -n $USER_FLAG ]] || die "--user needs a name."; shift ;;
      --config)         CONFIG_FILE=${2:-}; [[ -n $CONFIG_FILE ]] || die "--config needs a file."; shift ;;
      --skip-preflight) SKIP_PREFLIGHT=1 ;;
      --version)        echo "$VERSION"; exit 0 ;;
      -h|--help)        usage; exit 0 ;;
      --lean|--custom)  die "$1 is a command now: tabden install ${1#--}" ;;
      --modify|--update|--uninstall|--theme|--fix-phantom|--doctor)
                        die "$1 is a command now: tabden ${1#--}" ;;
      *) die "Unknown option or extra word: $1 (see tabden help)" ;;
    esac
    shift
  done
  # Which options go with which command.
  if [[ $DRY_RUN == 1 ]]; then
    case $CMD in ""|install|modify) ;; *) die "--dry-run goes with install, modify or the wizard, not with $CMD." ;; esac
  fi
  if [[ $YES == 1 || -n $USER_FLAG || -n $CONFIG_FILE ]] && [[ $CMD != install ]]; then
    die "--yes, --user and --config go with: tabden install"
  fi
  if [[ $SKIP_PREFLIGHT == 1 ]]; then
    case $CMD in ""|install|modify|update) ;; *) die "--skip-preflight goes with install, modify, update or the wizard, not with $CMD." ;; esac
  fi
  # 'install --yes' or 'install --config' can't stop to ask Lean or Custom.
  if (( INSTALL_CHOICE )) && [[ -n $CONFIG_FILE ]]; then INSTALL_CHOICE=0; fi
  if (( INSTALL_CHOICE )) && [[ $YES == 1 ]]; then FLAG_MODE=lean; INSTALL_CHOICE=0; fi
  return 0
}

ensure_termux() {
  [[ ${PREFIX:-} == *com.termux* ]] || die "Run this in Termux, not inside the Ubuntu guest."
  [[ $(uname -m) == aarch64 ]] || printf 'warning: expected aarch64, got %s\n' "$(uname -m)"
}

bootstrap() {
  local missing=() p
  for p in dialog proot-distro curl; do command -v "$p" >/dev/null || missing+=("$p"); done
  (( ${#missing[@]} )) || return 0
  info "Installing wizard prerequisites: ${missing[*]}"
  apt-get update && apt-get -y install "${missing[@]}" || die "Could not install ${missing[*]}"
}

main() {
  parse_args "$@"
  ensure_termux
  if [[ $FLAG_MODE == fix-phantom ]]; then fix_phantom; return; fi
  if [[ $FLAG_MODE == doctor ]]; then doctor_flow; return; fi    # reads only; installs nothing
  mkdir -p "$CFG_DIR" "$LOG_DIR"
  if [[ $FLAG_MODE == theme ]]; then theme_flow; return; fi   # no preflight: works offline
  if [[ $FLAG_MODE != uninstall ]]; then
    if guest_exists; then PRE_KIND=existing; else PRE_KIND=fresh; fi
    preflight
  fi
  bootstrap
  set_defaults
  if [[ $FLAG_MODE == uninstall ]]; then uninstall_flow; return; fi
  if [[ -n $CONFIG_FILE ]]; then load_selections "$CONFIG_FILE"; FLAG_MODE=config; fi
  [[ $FLAG_MODE == modify || $FLAG_MODE == update ]] && [[ ! -f $SEL ]] &&
    die "No existing install found ($SEL). Run the installer first."
  [[ $FLAG_MODE == modify || $FLAG_MODE == update ]] && load_selections "$SEL"
  valid_theme "$THEME" || die "Unknown THEME \"$THEME\" in the selections. Choose one of: ${THEMES[*]}"
  run_context
  [[ -n $USER_FLAG ]] && DEV_USER=$USER_FLAG
  [[ $YES == 1 && -z $DEV_USER ]] && die "--yes needs --user NAME (or a --config file with DEV_USER)."
  MODE=$FLAG_MODE
  USER_EXISTS=0; PASSWORD=""
  if [[ $FLAG_MODE == update ]]; then
    (( ${#PRE_WARN[@]} )) && printf '%s\n' "Warnings:" "${PRE_WARN[@]}" ""
    save_selections
    update_all
    return
  fi
  if guest_installed; then GUEST_READY=1; else GUEST_READY=0; fi
  PHANTOM=$(check_phantom)

  wizard
  clear
  finalize_selections
  summary_text | sed -n '/^Warnings:/,$p' | sed 's/^/summary: /' >> "$LOG"
  if [[ $DRY_RUN == 1 ]]; then dry_run_report; return 0; fi
  if [[ $YES == 1 ]]; then summary_text; echo; fi
  save_selections
  install_all
}

main "$@" </dev/tty; exit $?
