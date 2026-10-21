#!/data/data/com.termux/files/usr/bin/bash
# tabden demo recorder (run in Termux, on a device with tabden installed)
#
# Records the same short demo every time, with no manual typing, as an
# asciinema file. Nothing is installed or changed: the wizard runs with
# --dry-run, and the sample project it makes is removed again.
#
#   bash tools/record-demo.sh                   record the demo
#   bash tools/record-demo.sh --check           run the checks and say what the recording
#                                               would show; record nothing
#   bash tools/record-demo.sh --wizard modify   show your own choices instead of the
#                                               Custom defaults (custom is the default)
#
# The wizard is shown with the username "demo", not yours: typed into the box
# (with a throwaway password, for the dry run), and in --wizard modify typed
# over your name while that screen is hidden from the recording.
#   bash tools/record-demo.sh --deny WORD       fail if WORD appears in the recording
#                                               (repeatable; not case-sensitive)
#   bash tools/record-demo.sh --yes             don't ask before recording
#
# Needs asciinema and tmux in Termux:  pkg install asciinema tmux
# They are recording tools only, not part of a tabden install.
#
# Writes docs/demo/demo.cast and docs/demo/demo.theme in this clone, but only if
# the privacy check finds nothing. Commit them; CI turns the cast into the GIF.
# What it leaves behind: a few lines in Ubuntu's shell history, and a rewritten
# ~/.cache/tabden/termux.log (the wizard's own log).
#
# The recording is edited in two ways before it's saved, both to its timing
# only: the wait while a program starts (the wizard, 'den', Helix) is cut to
# 0.4 s, and the recorder's own exit is cut off the end.

set -uo pipefail

COLS=100; ROWS=28                 # fixed, so the GIF is the same size on any screen
TYPE_MS=35                        # typing speed: milliseconds per character
# How long each thing stays on screen, in seconds, counted from when it appeared.
P_SCREEN=0.5; P_THEME=2; P_SUMMARY=3; P_REPORT=0.6; P_DEV=2; P_HELIX=2; P_DIFF=2
START_CAP=0.4                     # a program's start-up wait is cut to this in the recording
SOCK=tabden-demo                # the recorder's own tmux server, apart from any of yours
SESSION=demo
PANE="$SESSION:main"              # the window that's recorded (a cover window can sit over it)
DEMO_USER=demo                    # the username the wizard shows; never yours
DEMO_PASSWORD=demo-only           # typed into the dry run's password boxes; shown as asterisks, never used
DEMO_NAME=tabden-demo           # ~/projects/tabden-demo, inside Ubuntu

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$SELF_DIR")"
SEL="$HOME/.config/tabden/selections.env"
WORK="$HOME/.cache/tabden/demo"
CAST="$WORK/demo.cast"; SNAPS="$WORK/screens.txt"; STEPS="$WORK/demo.steps"; WAITS="$WORK/waits"

WIZARD=""; YES=0; CHECK_ONLY=0; DENY=()
REC_PID=""; DEV_STARTED=0; PROJECT_MADE=0; TMUX_UP=0; DONE=0

say()  { printf '%s\n' "$*"; }
die()  { printf 'record-demo: %s\n' "$*" >&2; exit 1; }
usage() { sed -n '2,/^[^#]/p' "${BASH_SOURCE[0]}" | grep '^#' | sed 's/^# \{0,1\}//'; }

while (( $# )); do
  case $1 in
    --wizard)  WIZARD=${2:-}; shift ;;
    --deny)    [[ -n ${2:-} ]] || die "--deny needs a word"; DENY+=("$2"); shift ;;
    --yes|-y)  YES=1 ;;
    --check)   CHECK_ONLY=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
  shift
done
case $WIZARD in ""|custom|modify) ;; *) die "--wizard takes custom or modify" ;; esac

# ------------------------------------------------------------ the install ----
[[ ${PREFIX:-} == *com.termux* ]] || die "run this in Termux, not inside Ubuntu."
missing=()
for t in asciinema tmux; do command -v "$t" >/dev/null 2>&1 || missing+=("$t"); done
if (( ${#missing[@]} )); then
  say "Missing: ${missing[*]}. They are only needed for recording. Install them with:"
  say "  pkg install ${missing[*]}"
  exit 1
fi
[[ -f $SEL ]] || die "tabden isn't installed here ($SEL not found)."

# Defaults for everything read from selections.env, then the real values.
DEV_USER=""; PROJECTS_MODE=termux; THEME=default; IDE_HELIX=0; CLI_EXTRAS=""
TABDEN_DIR=""; TIMEZONE=""; DOCKER_REMOTE=0; DOCKER_SSH_HOST=""
# shellcheck source=/dev/null
. "$SEL"
[[ -n $DEV_USER ]] || die "no username in $SEL."
LAUNCHER="$TABDEN_DIR/launcher.sh"
for c in tabden den; do
  [[ -x $HOME/bin/$c ]] || die "the '$c' command is missing; run 'tabden update' first."
done
[[ -f $LAUNCHER ]] || die "can't find the tabden clone ($LAUNCHER)."
# The demo's wizard must not be able to install anything.
grep -qE -- '--dry-run\) +DRY_RUN=1' "$LAUNCHER" ||
  die "the clone at $TABDEN_DIR doesn't know --dry-run yet. Update it (git pull) and try again."
[[ $IDE_HELIX == 1 ]] || die "the demo opens a file in Helix, which isn't selected here (tabden modify)."
[[ " $CLI_EXTRAS " == *" delta "* ]] ||
  die "the demo shows 'git diff' through delta, which isn't selected here (tabden modify)."

ROOTFS="$PREFIX/var/lib/proot-distro/containers/ubuntu/rootfs"
[[ -d $ROOTFS ]] || ROOTFS="$PREFIX/var/lib/proot-distro/installed-rootfs/ubuntu"
GHOME="$ROOTFS/home/$DEV_USER"                 # Ubuntu's home, seen from Termux
[[ -d $GHOME ]] || die "can't find the Ubuntu home for $DEV_USER ($GHOME)."

guest() {  # run a command in Ubuntu as the user, projects mounted, as 'ubu' does
  local bind=()
  if [[ $PROJECTS_MODE == termux ]]; then bind=(--bind "$HOME/projects:/home/$DEV_USER/projects"); fi
  proot-distro login ubuntu --user "$DEV_USER" "${bind[@]}" -- "$@"
}
dev_session_alive() { proot-distro login ubuntu --user "$DEV_USER" -- tmux has-session -t den 2>/dev/null; }

dev_session_alive &&
  die "a den session is running. This won't touch a session you're working in: 'den stop' first."
guest test ! -e "/home/$DEV_USER/projects/$DEMO_NAME" </dev/null ||
  die "projects/$DEMO_NAME already exists in Ubuntu's home. It isn't this script's to delete; move it away first."

# ------------------------------------------------------ which wizard to show ----
# Ask launcher.sh itself which components the wizard would offer to remove,
# by loading its functions (everything above the line that runs main).
would_remove() {  # custom|modify -> component names, comma-separated
  (
    n=$(grep -n '^main "\$@" </dev/tty' "$LAUNCHER" | cut -d: -f1)
    [[ -n $n ]] || exit 3
    # shellcheck source=/dev/null
    . <(head -n $(( n - 1 )) "$LAUNCHER") || exit 3
    set +eu
    set_defaults
    [[ $1 == modify ]] && load_selections "$SEL"
    DEV_USER=$2           # the wizard is given the demo username either way
    out=""
    # shellcheck disable=SC2154  # COMP_LABEL comes from launcher.sh
    while read -r id _; do [[ -n $id ]] && out+="${out:+, }${COMP_LABEL[$id]:-$id}"; done < <(removal_candidates)
    printf '%s' "$out"
  )
}

show_custom() {
  say "  --wizard custom   'tabden install custom --dry-run': \"$DEMO_USER\" typed into the empty Username box,"
  say "                    then every screen at its default, except the Theme screen, where your theme"
  say "                    ($THEME) is selected so the screen and the Summary match the colours."
  if [[ -n $1 ]]; then
    say "                    Then the \"Remove deselected components\" screen with these ticked:"
    say "                      $1"
    say "                    and a Summary with a \"Will remove\" line. Nothing is removed: it's a dry run."
  fi
}
show_modify() {
  say "  --wizard modify   'tabden modify --dry-run': \"$DEMO_USER\" in place of your username, then your own"
  say "                    choices on every screen (theme: $THEME; CLI extras: ${CLI_EXTRAS:-none})."
  if [[ -n $1 ]]; then say "                    It also shows a Remove screen, with: $1"
  else say "                    No Remove screen."; fi
}

RM_CUSTOM=$(would_remove custom "$DEMO_USER") || die "couldn't read $LAUNCHER to see which screens the wizard shows."
RM_MODIFY=$(would_remove modify "$DEMO_USER") || die "couldn't read $LAUNCHER to see which screens the wizard shows."
MODIFY_OK=1
[[ $DOCKER_REMOTE == 1 ]] && MODIFY_OK=0     # --modify would put the Docker host on screen

if [[ $WIZARD == modify && $MODIFY_OK == 0 ]]; then
  die "--wizard modify would show your Docker host ($DOCKER_SSH_HOST) on screen. Use --wizard custom."
fi
if [[ -z $WIZARD ]]; then
  if [[ -z $RM_CUSTOM ]]; then
    WIZARD=custom
  else
    say "The Custom wizard would show a \"Remove deselected components\" screen here, because these are"
    say "installed but aren't part of the Custom defaults: $RM_CUSTOM"
    say
    say "What the GIF would show in each case:"
    show_custom "$RM_CUSTOM"
    if (( MODIFY_OK )); then show_modify "$RM_MODIFY"
    else say "  --wizard modify   not offered: it would show your Docker host on screen."; fi
    say
    if [[ $YES == 1 || $CHECK_ONLY == 1 || ! -t 0 ]]; then
      say "Choose one and run again with --wizard custom$( (( MODIFY_OK )) && echo ' or --wizard modify')."
      exit 2
    fi
    while :; do
      if (( MODIFY_OK )); then read -r -p "Record which? [c]ustom, [m]odify, or [q]uit: " a
      else read -r -p "Record with --wizard custom? [c]ustom or [q]uit: " a; fi
      case $a in
        c|C|custom) WIZARD=custom; break ;;
        m|M|modify) (( MODIFY_OK )) && { WIZARD=modify; break; } ;;
        q|Q|"")     say "Nothing recorded."; exit 0 ;;
      esac
    done
  fi
fi

if [[ $WIZARD == custom ]]; then WIZ_CMD="tabden install custom --dry-run"; else WIZ_CMD="tabden modify --dry-run"; fi

# --------------------------------------------------------- privacy patterns ----
# Read here, at run time, so nothing personal is ever stored in the repo.
PAT_TOKENS=('?tkn=' 'ghp_' 'gho_' 'ghu_' 'ghs_' 'ghr_' 'github_pat_' 'sk-ant-')   # matched exactly
PAT_PERSONAL=()                                                                    # not case-sensitive
add_personal() {  # skips empty and very short strings, and ones already listed
  local p q
  for p in "$@"; do
    (( ${#p} >= 3 )) || continue
    for q in "${PAT_PERSONAL[@]}"; do [[ ${q,,} == "${p,,}" ]] && continue 2; done
    PAT_PERSONAL+=("$p")
  done
  return 0
}

command -v git >/dev/null 2>&1 && add_personal "$(git config --global user.email 2>/dev/null)"
while IFS= read -r line; do add_personal "$line"; done < <(guest bash -c '
  git config --global user.email
  for f in "$HOME"/.config/tabden/git-identities/*.gitconfig; do
    [ -f "$f" ] && git config -f "$f" user.email
  done
  cat "$HOME/.config/tabden/vscode-token" 2>/dev/null' </dev/null 2>/dev/null)
for tz in "$TIMEZONE" "$(getprop persist.sys.timezone 2>/dev/null)"; do
  case $tz in ""|UTC|Etc/*) ;; *) add_personal "$tz" "${tz##*/}" ;; esac    # e.g. Europe/Lisbon and Lisbon
done
add_personal "$DOCKER_SSH_HOST" "${DOCKER_SSH_HOST##*@}"
(( ${#DENY[@]} )) && add_personal "${DENY[@]}"
# Your Ubuntu username, as a whole word (so "al" doesn't match "local"). A
# name that is also a common word here can't be checked: the demo shows those
# words anyway (the prompt says "ubuntu", the session is "den").
USER_CHECK=1
case ${DEV_USER,,} in
  ubuntu|demo|den|dev|root|admin|user|users|tabden|termux|tmux|home|main|test|shell|edit|claude|projects|android|guest|local|bin)
    USER_CHECK=0 ;;
esac
[[ ${DEV_USER,,} == "${DEMO_USER,,}" ]] && USER_CHECK=0
(( ${#DEV_USER} >= 3 )) || USER_CHECK=0
if (( USER_CHECK == 0 )); then
  say "Warning: your username '$DEV_USER' is a common word (or very short), so the recording can't be"
  say "checked for it: it would match the demo's own text. It isn't shown by the demo itself."
fi

# ------------------------------------------------------------------ preview ----
say "The recording will show:"
say "  - '$WIZ_CMD', one screen after another, ending on the Summary"
say "  - the username '$DEMO_USER' in the wizard (yours never appears), and 'ubuntu' as the prompt"
[[ $USER_CHECK == 1 ]] || say "    (your username '$DEV_USER' is too common a word to check the recording for; it isn't checked)"
say "  - the timezone as Etc/UTC instead of yours"
say "  - 'den' opening tmux, a sample file in Helix, and 'git diff' through delta"
say "  - your theme: $THEME$( [[ $THEME == default ]] || echo ', selected on the wizard'"'"'s Theme screen (a dry run saves nothing)')"
[[ $WIZARD == custom && -n $RM_CUSTOM ]] && say "  - the Remove screen, with: $RM_CUSTOM"
[[ $WIZARD == modify && -n $RM_MODIFY ]] && say "  - the Remove screen, with: $RM_MODIFY"
say "It will be refused if any of these appear: ${#PAT_TOKENS[@]} token patterns and ${#PAT_PERSONAL[@]} of your own"
say "strings (your username$( [[ $USER_CHECK == 1 ]] || printf ' (not checked)'), git emails, timezone, VS Code token, Docker host, --deny words)."
if [[ $CHECK_ONLY == 1 ]]; then say; say "Checks passed. Nothing was recorded (--check)."; exit 0; fi
if [[ $YES != 1 ]]; then
  [[ -t 0 ]] || die "not started from a terminal; pass --yes to record without asking."
  read -r -p "Record now? [y/N] " a
  [[ $a == y || $a == Y ]] || { say "Nothing recorded."; exit 0; }
fi

# ------------------------------------------------------------- the terminal ----
tm()   { tmux -L "$SOCK" "$@"; }
SNAP_KEEP=1                        # 0 while the recorded window is hidden (it may show your username)
snap() { local s; s=$(tm capture-pane -p -t "$PANE" 2>/dev/null) || return 1
         (( SNAP_KEEP )) && printf '%s\n-----\n' "$s" >> "$SNAPS"    # every screen read is kept for the scan
         printf '%s' "$s"; }
key()  { tm send-keys -t "$PANE" "$@"; }
now_ms() { local t=${EPOCHREALTIME/[.,]/}; printf '%s' "$(( t / 1000 ))"; }
REC_T0=0                           # when the recording started
ENTER_MS=0                         # when Enter last went in
SHOWN_MS=0                         # when the thing now on screen first appeared
enter() { ENTER_MS=$(now_ms); key Enter; }
# The time from an Enter to what it brings up is the machine starting something,
# not part of the demo. Each such stretch is noted (start and end, in
# milliseconds of recording) and cut down to START_CAP afterwards; see trim_waits.
note_wait() { (( ENTER_MS )) && printf '%s %s\n' "$(( ENTER_MS - REC_T0 ))" "$(( SHOWN_MS - REC_T0 ))" >> "$WAITS"; ENTER_MS=0; }
# Short waits without starting a process: a read with a timeout on a pipe that
# never has data. On Android every process start costs tens of milliseconds,
# which a 'sleep' per typed character adds up to seconds of recording.
exec {NAP_FD}<> <(:)
nap_ms() { local ms=$1; (( ms > 0 )) || return 0; read -rt "$(( ms / 1000 )).$(printf '%03d' $(( ms % 1000 )))" -u "$NAP_FD" _ || :; }
# Every tmux call is still a new process. CALL_MS is measured before recording
# and allowed for in pauses; typing keeps its pace by the clock instead.
CALL_MS=0
measure_calls() {
  local t0 i
  t0=$(now_ms)
  for i in 1 2 3 4 5; do tm display-message -p -t "$PANE" '' >/dev/null; done
  CALL_MS=$(( ( $(now_ms) - t0 ) / 5 ))
}
hold() {  # seconds (e.g. 0.5): keep the screen up until it has been showing that long
  local want_ms
  want_ms=$(( 10#${1%.*} * 1000 )); [[ $1 == *.* ]] && want_ms=$(( want_ms + 10#$(printf '%-3s' "${1#*.}" | tr ' ' 0) ))
  # Less the two calls that follow a hold (reading the screen, sending the key).
  nap_ms $(( want_ms - ($(now_ms) - SHOWN_MS) - 2 * CALL_MS ))
}

type_text() {  # TYPE_MS per character on average, however long each tmux call takes
  local s=$1 i=0 n c t0 due
  t0=$(now_ms)
  while (( i < ${#s} )); do
    # Send everything that should be on screen by now: one character when on
    # time, a few at once when calls are slow enough to fall behind.
    due=$(( ( $(now_ms) - t0 ) / TYPE_MS + 1 ))
    n=$(( due - i )); (( n < 1 )) && n=1
    c=${s:i:n}
    [[ $c == *";" ]] && c="${c%;}\\;"      # a trailing bare ; would end the tmux command
    tm send-keys -t "$PANE" -l -- "$c"
    i=$(( i + n ))
    nap_ms $(( t0 + i * TYPE_MS - $(now_ms) ))
  done
}
type_line() { type_text "$1"; nap_ms 250; enter; }

wait_for() {  # extended regex, seconds: until it shows on screen
  local i n=$(( ${2:-20} * 10 ))
  for (( i = 0; i < n; i++ )); do
    if snap | grep -qE -- "$1"; then SHOWN_MS=$(now_ms); note_wait; return 0; fi
    nap_ms 100
  done
  return 1
}
wait_stable() {  # until the screen stops changing; prints it
  local a b i
  a=$(snap)
  for (( i = 0; i < 150; i++ )); do
    nap_ms 200; b=$(snap)
    [[ $a == "$b" ]] && { printf '%s' "$b"; return 0; }
    a=$b
  done
  return 1
}
# The title on the top border of the first dialog box on screen: ┌───Title───┐,
# or lqqqTitleqqqk when the terminal's line-drawing set is in use (tmux then
# reports the border as letters). A border with no title in it doesn't count.
box_title() {  # alternations, not brackets: correct even where the locale isn't UTF-8
  sed -nE '/^[[:space:]]*(l|┌)(q|─){2,}[A-Z].*(q|─){2,}(k|┐)/ {
    s/^[[:space:]]*(l|┌)(q|─)+//; s/(q|─)+(k|┐).*$//; p; q
  }'
}
leave_wizard() { key Escape; sleep 1.5; key Enter; sleep 0.5; }   # Esc, then Yes on "Quit the installer?"
TITLE=""
next_screen() {  # the screen before -> sets TITLE and SHOWN_MS once a new screen has settled
  local before=$1 i s t seen=0
  for (( i = 0; i < 300; i++ )); do
    s=$(snap); t=$(box_title <<<"$s")
    if [[ -n $t && $s != "$before" ]]; then
      (( seen )) || seen=$(( $(now_ms) - (100 + CALL_MS) / 2 ))    # it appeared about half a look ago
      nap_ms 150
      if [[ $(snap) == "$s" ]]; then TITLE=$t; SHOWN_MS=$seen; note_wait; return 0; fi
    else
      seen=0
    fi
    nap_ms 100
  done
  return 1
}
PROMPT_RE='[$#>❯][[:space:]]*$'
prompt_line() {  # true when the cursor sits on a shell prompt
  local y line
  y=$(tm display-message -p -t "$PANE" '#{cursor_y}') || return 1
  line=$(snap | sed -n "$(( y + 1 ))p")
  [[ $line =~ $PROMPT_RE ]]
}
# Wait for the shell to be ready for the next command. Typing sooner works,
# but the first characters land on screen ahead of the prompt.
await_prompt() {
  local i
  (( ENTER_MS )) && nap_ms 150      # an Enter is on its way: let the old prompt line go first
  for (( i = 0; i < 300; i++ )); do
    if prompt_line; then SHOWN_MS=$(now_ms); note_wait; return 0; fi
    nap_ms 100
  done
  return 1
}
run_line() { await_prompt || fail "the shell didn't come back to a prompt."; type_line "$1"; }

STEP_LOG=()
step() { STEP_LOG+=("$1"); say "  $1"; }
fail() {
  printf '\nrecord-demo: %s\n' "$*" >&2
  if (( TMUX_UP )); then printf 'The screen at that moment:\n' >&2; snap | sed 's/[[:space:]]*$//' | grep -v '^$' | sed 's/^/  | /' >&2; fi
  exit 1
}

# ------------------------------------------------------------------ cleanup ----
# Runs on every exit. Only undoes what this script started.
cleanup() {
  trap - EXIT INT TERM
  (( TMUX_UP )) && tm kill-server 2>/dev/null
  if [[ -n $REC_PID ]]; then
    for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$REC_PID" 2>/dev/null || break; sleep 0.3; done
    kill "$REC_PID" 2>/dev/null
  fi
  if (( DEV_STARTED )); then
    say "Stopping the den session the demo started."
    "$HOME/bin/den" stop >/dev/null 2>&1
  fi
  if (( PROJECT_MADE )); then
    guest rm -rf "/home/$DEV_USER/projects/$DEMO_NAME" </dev/null
  fi
  (( DONE )) || say "Nothing was written to docs/demo. Working files are in $WORK."
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# --------------------------------------------------------------- recording ----
mkdir -p "$WORK"
rm -f "$CAST" "$SNAPS" "$WAITS" "$WORK/demo.txt"
: > "$WAITS"
[[ -f $STEPS ]] && mv -f "$STEPS" "$STEPS.prev"

WATCHED=("$SEL" "$HOME/.config/tabden/installed" "$GHOME/.config/tabden/selections.env" "$GHOME/.config/tabden/installed")
sums() { sha256sum "${WATCHED[@]}" 2>&1; }
BEFORE=$(sums)

say "Making the sample project in Ubuntu (~/projects/$DEMO_NAME)."
guest bash -s -- "$DEMO_NAME" >/dev/null <<'EOF'
set -e
d="$HOME/projects/$1"
mkdir "$d" || exit 9      # not ours to touch if it can't be made fresh
cd "$d"
cat > main.rs <<'RS'
// A tiny program for the tabden demo.
fn main() {
    let device = "tablet";
    println!("Hello from my {device}!");
}
RS
git init -q -b main .
git add main.rs
git -c user.name="tabden demo" -c user.email=demo@example.invalid -c commit.gpgsign=false \
  commit -q -m "Demo project"
EOF
rc=$?
(( rc == 9 )) && fail "couldn't create ~/projects/$DEMO_NAME in Ubuntu."
PROJECT_MADE=1            # from here on, cleanup removes it
(( rc == 0 )) || fail "couldn't set up the sample project."

# A detached tmux session of fixed size, on its own server and with no config
# of yours. Its only client is asciinema, whose terminal has the same fixed
# size, so the window never resizes. (Not "window-size manual": set before the
# first session, that makes tmux 3.4 exit.) The shell in it has no TMUX
# variable (so 'den' isn't told it's already inside tmux), UTC as its timezone
# (the wizard reads TZ first), and no history file.
tm kill-server 2>/dev/null
cat > "$WORK/tmux.conf" <<EOF
set-option -g default-terminal "${TERM:-xterm-256color}"
set-option -g status off
set-option -as terminal-features ',*:RGB'
EOF
tm -f "$WORK/tmux.conf" new-session -d -s "$SESSION" -n main -x "$COLS" -y "$ROWS" -c "$HOME" \
  "env -u TMUX -u TMUX_PANE TZ=Etc/UTC HISTFILE=/dev/null COLORTERM=truecolor bash -l" ||
  fail "couldn't start tmux."
TMUX_UP=1

# asciinema is the session's only client; --headless needs no terminal of its own.
env -u TMUX -u TMUX_PANE asciinema rec --headless --window-size "${COLS}x${ROWS}" --overwrite --quiet \
  --command "tmux -L $SOCK attach-session -t $SESSION" "$CAST" </dev/null >"$WORK/asciinema.log" 2>&1 &
REC_PID=$!
REC_T0=$(now_ms)
for _ in $(seq 1 50); do [[ -n $(tm list-clients 2>/dev/null) ]] && break; sleep 0.2; done
[[ -n $(tm list-clients 2>/dev/null) ]] || fail "asciinema didn't start recording (see $WORK/asciinema.log)."
wait_stable >/dev/null
measure_calls
say "(Each tmux call takes about $CALL_MS ms here; typing and pauses allow for it.)"
ENTER_MS=$REC_T0                  # the time before the first command counts as a start-up wait too
say "Recording:"

# 1. The wizard. Each step reads the screen's title first, and only a screen it
#    knows gets a key. The Summary is confirmed only once a launcher process
#    with --dry-run on its command line is seen running.
dry_run_guard() {  # before typing anything into the wizard that matters
  pgrep -f -- 'launcher\.sh.*--dry-run' >/dev/null ||
    { leave_wizard; fail "no dry-run wizard is running; left it without going on."; }
}
# On the Theme screen, select the theme in use, so the screen and the
# Summary match the recording's colours (a dry run saves nothing). The list is
# in launcher.sh's THEMES order.
pick_theme() {
  local i idx=-1 themes ups
  read -ra themes < <(sed -n 's/^THEMES=(\(.*\))$/\1/p' "$LAUNCHER")
  for i in "${!themes[@]}"; do [[ ${themes[i]} == "$THEME" ]] && idx=$i; done
  (( idx > 0 )) || { leave_wizard; fail "theme '$THEME' isn't on the wizard's Theme screen; left the wizard."; }
  # Up to the top first, wherever the cursor starts (not Home: tmux sends it
  # in a form dialog may read as Escape, which asks to quit).
  ups=(); for i in "${themes[@]}"; do ups+=(Up); done
  key "${ups[@]}"; nap_ms 250
  for (( i = 0; i < idx; i++ )); do key Down; nap_ms 180; done
  key Space; nap_ms 300
  snap | grep -E -- "\(\*\) +$THEME( |$)" >/dev/null ||
    { leave_wizard; fail "couldn't select $THEME on the Theme screen; left the wizard."; }
}
screen=""
if [[ $WIZARD == custom ]]; then
  run_line "$WIZ_CMD"
else
  # The Username box opens with your name in it. Cover the window with a still
  # copy of itself, start the wizard behind it, replace your name with the demo
  # one, then uncover: the recording never has your name in it.
  await_prompt || fail "the shell didn't come back to a prompt."
  type_text "$WIZ_CMD"; nap_ms 250
  printf '%s' "$(tm capture-pane -e -p -t "$PANE")" > "$WORK/cover.txt"   # no trailing blank lines
  tm new-window -d -t "$SESSION:" -n cover "printf '\\033[?25l'; cat '$WORK/cover.txt'; exec tail -f /dev/null" ||
    fail "couldn't make the cover window."
  nap_ms 200
  tm select-window -t "$SESSION:cover" || fail "couldn't show the cover window."
  SNAP_KEEP=0; t_enter=$(now_ms); key Enter; ENTER_MS=0
  next_screen "" || { tm select-window -t "$PANE"; fail "the wizard didn't start."; }
  [[ $TITLE == Username ]] || { leave_wizard; tm select-window -t "$PANE"; fail "the wizard didn't open on Username (\"$TITLE\")."; }
  dry_run_guard
  bs=(); for (( i = 0; i < ${#DEV_USER} + 4; i++ )); do bs+=(BSpace); done
  key "${bs[@]}"; nap_ms 300
  if (( USER_CHECK )) && snap | grep -qiw -- "$DEV_USER"; then
    leave_wizard; tm select-window -t "$PANE"; fail "couldn't clear your username from the Username box."
  fi
  SNAP_KEEP=1
  tm select-window -t "$PANE"; tm kill-window -t "$SESSION:cover"
  wait_stable >/dev/null
  ENTER_MS=$t_enter; SHOWN_MS=$(now_ms); note_wait     # the hidden start counts as a start-up wait
  step "wizard: Username"
  type_text "$DEMO_USER"; hold "$P_SCREEN"
  screen=$(snap); enter
fi
for (( n = 0; n < 25; n++ )); do
  next_screen "$screen" || fail "the wizard didn't show a new screen."
  step "wizard: $TITLE"
  case $TITLE in
    Username)
      [[ $WIZARD == custom ]] || { leave_wizard; fail "the Username screen came back; left the wizard."; }
      type_text "$DEMO_USER"
      hold "$P_SCREEN" ;;
    "Password for $DEMO_USER")
      dry_run_guard
      type_text "$DEMO_PASSWORD"
      hold "$P_SCREEN" ;;
    "Project location"|Runtimes|Editor|"AI assistant"|"Local model"|Model|"CLI extras"|"Remote Docker"|"Remove deselected components")
      hold "$P_SCREEN" ;;
    Theme)
      [[ $THEME == default ]] || pick_theme
      hold "$P_THEME" ;;
    Summary)
      dry_run_guard
      hold "$P_SUMMARY" ;;
    *)
      leave_wizard
      fail "unexpected wizard screen \"$TITLE\"; left the wizard." ;;
  esac
  screen=$(snap)        # what this screen looked like when the key went in; the next one must differ
  enter
  [[ $TITLE == Summary ]] && break
done
[[ $TITLE == Summary ]] || fail "the wizard never reached the Summary."
wait_for 'Nothing was changed' 30 || fail "the dry run didn't finish."
step "dry-run report"
hold "$P_REPORT"

# 2. den: tabden's own tmux session opens inside this one.
run_line "den"
DEV_STARTED=1
wait_for '1:claude' 90 || fail "the den session didn't open."
step "den"
hold "$P_DEV"

# 3. The sample file in Helix.
run_line "cd $DEMO_NAME"
run_line "hx main.rs"
wait_for 'fn main' 30 || fail "Helix didn't open the file."
step "hx main.rs"
hold "$P_HELIX"
key Escape; nap_ms 300
type_text ":q"; nap_ms 200; enter

# 4. A one-line change, and git diff through delta.
run_line "sed -i s/tablet/phone/ main.rs"
run_line "git diff"
wait_for 'device = "phone"' 30 || fail "git diff didn't show the change."
wait_stable >/dev/null
step "git diff"
hold "$P_DIFF"
prompt_line || { key q; sleep 0.3; }       # delta's pager, if the diff didn't fit

# Stop recording here, so the GIF ends on the diff.
tm kill-session -t "$SESSION" 2>/dev/null; TMUX_UP=0
for _ in $(seq 1 50); do kill -0 "$REC_PID" 2>/dev/null || break; sleep 0.2; done
kill -0 "$REC_PID" 2>/dev/null && { kill "$REC_PID" 2>/dev/null; sleep 0.5; }
REC_PID=""
[[ -s $CAST ]] || fail "asciinema wrote no recording (see $WORK/asciinema.log)."
# The recording's last event is the tmux client leaving: it clears the screen
# and prints "[exited]". Cut from there, so the last frame is the diff. Only
# the client's own exit carries this sequence (the "leave alternate screen"
# code); programs inside the session never reach the client with it.
awk '/\\u001b\[\?1049l/ { exit } { print }' "$CAST" > "$CAST.tmp" && mv -f "$CAST.tmp" "$CAST"
# Cut each noted start-up wait down to START_CAP. An event line starts with
# the seconds since the event before it; that gap loses whatever part of it
# lies inside a noted wait, beyond the cap. Pauses on a screen are not waits
# and keep their length.
trim_waits() {
  awk -v cap="$START_CAP" '
    BEGIN { n = 0 }
    NR == FNR { ws[n] = $1 / 1000; we[n] = $2 / 1000; n++; next }
    !/^\[/ { print; next }
    {
      dt = substr($0, 2) + 0; t0 = t; t += dt; cut = 0
      for (i = 0; i < n; i++) {
        lo = (t0 > ws[i] ? t0 : ws[i]); hi = (t < we[i] ? t : we[i])
        if (hi - lo > cap) cut += hi - lo - cap
      }
      if (cut > 0) sub(/^\[[0-9.]+/, "[" sprintf("%.3f", dt - cut))
      print
    }' "$WAITS" "$CAST"
}
trim_waits > "$CAST.tmp" && mv -f "$CAST.tmp" "$CAST"

# Put everything back, then check that it is back.
say "Stopping the den session the demo started."
"$HOME/bin/den" stop >/dev/null 2>&1; DEV_STARTED=0
guest rm -rf "/home/$DEV_USER/projects/$DEMO_NAME" </dev/null; PROJECT_MADE=0
problems=0
[[ $(sums) == "$BEFORE" ]] ||
  { say "CHANGED: a selections file or install record is different from before the demo."; problems=1; }
guest test ! -e "/home/$DEV_USER/projects/$DEMO_NAME" </dev/null ||
  { say "LEFT BEHIND: ~/projects/$DEMO_NAME is still there."; problems=1; }
dev_session_alive && { say "STILL RUNNING: the den session."; problems=1; }
(( problems )) && fail "the demo left something changed (see above)."
say "Unchanged: selections and install records. Sample project removed. No den session left."

# ------------------------------------------------------------ privacy check ----
# Three views of the same recording: the file as written, asciinema's
# plain-text rendering of it, and the screens read while recording. A program
# that paints the screen in pieces can split a word in the first; the other
# two see it whole.
asciinema convert --output-format txt --overwrite --quiet "$CAST" "$WORK/demo.txt" >/dev/null 2>&1 ||
  fail "couldn't export the recording as text for the privacy check; not publishing it."
found=0
report() {  # pattern, grep flags
  local f hits
  for f in "$CAST" "$WORK/demo.txt" "$SNAPS"; do
    hits=$(grep -F -n $2 -- "$1" "$f" | cut -c1-160 | head -3) || continue
    (( found )) || say "PRIVACY CHECK FAILED. Found in the recording:"
    found=1
    say "  \"$1\" in $(basename "$f"):"
    sed 's/^/      /' <<<"$hits"
  done
}
for p in "${PAT_TOKENS[@]}"; do report "$p" ""; done
(( USER_CHECK )) && report "$DEV_USER" "-i -w"
(( ${#PAT_PERSONAL[@]} )) && for p in "${PAT_PERSONAL[@]}"; do report "$p" "-i"; done
(( found )) && fail "the recording was not published. Fix the cause, or record on a setup without it."
say "Privacy check: nothing found (${#PAT_TOKENS[@]} token patterns, $( (( USER_CHECK )) && echo 'your username, ')${#PAT_PERSONAL[@]} of your own strings; three views)."

# ------------------------------------------------------------------- output ----
printf '%s\n' "${STEP_LOG[@]}" > "$STEPS"
if [[ -f $STEPS.prev ]]; then
  if cmp -s "$STEPS" "$STEPS.prev"; then say "Same sequence of steps as the previous recording."
  else say "DIFFERENT sequence from the previous recording:"; diff "$STEPS.prev" "$STEPS" | sed 's/^/  /'; fi
fi
# Length as a GIF: CI cuts pauses over 2 s to 2 s and holds the last frame for 2 s.
secs=$(awk '/^\[/ { t = substr($0, 2) + 0; if (t > 2) t = 2; s += t } END { printf "%d", s + 2 + 0.5 }' "$CAST")
mkdir -p "$REPO/docs/demo" &&
  cp -f "$CAST" "$REPO/docs/demo/demo.cast" &&
  printf '%s\n' "$THEME" > "$REPO/docs/demo/demo.theme" || fail "couldn't write to $REPO/docs/demo."
DONE=1
say
say "Wrote docs/demo/demo.cast (about $secs s as a GIF) and docs/demo/demo.theme ($THEME) in $REPO."
say "Next: git -C $REPO add docs/demo && git -C $REPO commit -m 'Update the demo recording' && git -C $REPO push"
say "CI then builds docs/img/demo.gif from it."
