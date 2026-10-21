#!/usr/bin/env bash
# tabden guest phase - runs inside the Ubuntu proot guest as your user.
#
#   guest.sh --install           install everything in selections.env (default)
#   guest.sh --update            apt upgrade + update every installed component
#   guest.sh --update-binaries   re-fetch Helix, lazygit, VS Code CLI, starship
#   guest.sh --dotfiles          rewrite dotfiles, scripts and the cheat sheet only
#                                (what 'tabden theme' runs; no apt, no downloads)
#
# --install also removes components listed in REMOVE (set by the wizard), but
# only ones tabden recorded as installed and that aren't selected.
#
# Idempotent: installed components are skipped; managed blocks in dotfiles
# are rewritten between "# >>> tabden >>>" markers, never appended twice.

set -uo pipefail

SEL="$HOME/.config/tabden/selections.env"
LOG_DIR="$HOME/.cache/tabden"
LOG="$LOG_DIR/install.log"
RESULT="$LOG_DIR/result"
NOTES="$LOG_DIR/notes"
TOKEN="$HOME/.config/tabden/vscode-token"
MANIFEST="$HOME/.config/tabden/installed"

export PATH="$HOME/bin:$HOME/.local/bin:$HOME/.cargo/bin:$HOME/.bun/bin:$HOME/.dotnet:$HOME/.dotnet/tools:$PATH"
export DOTNET_GCHeapHardLimit=1C0000000   # hex = 7 GiB; required under proot
export DOTNET_CLI_TELEMETRY_OPTOUT=1

mkdir -p "$LOG_DIR" "$HOME/bin" "$HOME/projects" "$HOME/.config/tabden" "$HOME/.local/bin"
[[ -f $SEL ]] || { echo "No selections file at $SEL - run launcher.sh from Termux first." >&2; exit 1; }
# shellcheck source=/dev/null
. "$SEL"
: "${RUNTIMES:=}" "${IDE_HELIX:=1}" "${IDE_ROSLYN:=0}" "${IDE_VSCODE:=0}" "${AI_CLAUDE:=1}"
: "${CLI_EXTRAS:=}" "${DOCKER_REMOTE:=0}" "${DOCKER_SSH_HOST:=}" "${PROJECTS_MODE:=termux}" "${TIMEZONE:=}"
: "${REMOVE:=}" "${THEME:=default}"
case $THEME in catppuccin-mocha|tokyonight|gruvbox-dark) ;; *) THEME=default ;; esac

# --------------------------------------------------------------- helpers ----
FAILED=()
has()      { command -v "$1" >/dev/null 2>&1; }
want_rt()  { [[ " $RUNTIMES " == *" $1 "* ]]; }
note()     { printf '%s\n' "$*" >> "$NOTES"; }
apt_get()  { sudo DEBIAN_FRONTEND=noninteractive apt-get -y -o Dpkg::Options::=--force-confold "$@"; }
gh_latest(){ curl -fsSL "https://api.github.com/repos/$1/releases/latest" | grep -Po '"tag_name":\s*"\K[^"]+'; }

write_block() {  # file content
  local f=$1
  touch "$f"
  sed -i '/^# >>> tabden >>>$/,/^# <<< tabden <<<$/d' "$f"
  printf '# >>> tabden >>>\n%s\n# <<< tabden <<<\n' "$2" >> "$f"
}
remove_block() {
  [[ -f $1 ]] && sed -i '/^# >>> tabden >>>$/,/^# <<< tabden <<<$/d' "$1"
  return 0
}
# Like write_block, but the block goes at the top of the file. For TOML, where
# a top-level key has to come before the first [table]: appended, it would
# become part of whichever table the file ends with.
prepend_block() {  # file content
  local f=$1 rest
  touch "$f"
  rest=$(sed '/^# >>> tabden >>>$/,/^# <<< tabden <<<$/d' "$f")
  {
    printf '# >>> tabden >>>\n%s\n# <<< tabden <<<\n' "$2"
    if [[ -n $rest ]]; then printf '%s\n' "$rest"; fi
  } > "$f.tabden-tmp" && mv -f "$f.tabden-tmp" "$f"
}

run() {  # name command... — logs, shows output, records failures
  local name=$1; shift
  printf '\n\033[1;36m==> %s\033[0m\n' "$name" | tee -a "$LOG"
  "$@" 2>&1 | tee -a "$LOG"
  if (( PIPESTATUS[0] == 0 )); then
    printf '\033[32m    ok\033[0m\n'
  else
    printf '\033[1;31m    failed (see %s)\033[0m\n' "$LOG"
    FAILED+=("$name")
  fi
}

# -------------------------------------------------------------- manifest ----
# One line per component tabden installed: "<id> <origin> [detail]".
# origin is "tabden", or "adopted" for installs that predate the record.
mark()      { unmark "$1"; printf '%s\n' "$*" >> "$MANIFEST"; }
unmark()    { [[ -f $MANIFEST ]] && sed -i "/^$1 /d" "$MANIFEST"; return 0; }
tracked()   { [[ -f $MANIFEST ]] && grep -q "^$1 " "$MANIFEST"; }
detail_of() { awk -v id="$1" '$1 == id { print $3 }' "$MANIFEST" 2>/dev/null; }
dpkg_has()  { dpkg -s "$1" >/dev/null 2>&1; }

is_selected() {
  case $1 in
    dotnet|rust|bun|node) want_rt "$1" ;;
    claude)  [[ $AI_CLAUDE == 1 ]] ;;
    helix)   [[ $IDE_HELIX == 1 ]] ;;
    roslyn)  [[ $IDE_ROSLYN == 1 ]] ;;
    vscode)  [[ $IDE_VSCODE == 1 ]] ;;
    docker)  [[ $DOCKER_REMOTE == 1 ]] ;;
    *)       [[ " $CLI_EXTRAS " == *" $1 "* ]] ;;
  esac
}

# First run with tracking on an existing install: record what is present at
# the places tabden installs to, as "adopted". The wizard offers these for
# removal unticked, since tabden can't tell whether it put them there.
seed_manifest() {
  [[ -f $MANIFEST ]] && return 0
  echo "# Components installed by tabden: <id> <origin> [detail]" > "$MANIFEST"
  if dpkg_has dotnet-sdk-10.0; then mark dotnet adopted apt
  elif [[ -x $HOME/.dotnet/dotnet ]]; then mark dotnet adopted script; fi
  [[ -x $HOME/.cargo/bin/rustup ]]       && mark rust adopted
  [[ -x $HOME/.bun/bin/bun ]]            && mark bun adopted
  dpkg_has nodejs                        && mark node adopted
  [[ -e $HOME/.local/bin/claude ]]       && mark claude adopted
  [[ -x /usr/local/bin/hx ]]             && mark helix adopted
  has roslyn-language-server             && mark roslyn adopted
  [[ -x /usr/local/bin/code ]]           && mark vscode adopted
  [[ -x /usr/local/bin/lazygit ]]        && mark lazygit adopted
  dpkg_has git-delta                     && mark delta adopted
  dpkg_has gh                            && mark gh adopted
  dpkg_has eza                           && mark eza adopted
  dpkg_has btop                          && mark btop adopted
  [[ -x $HOME/.local/bin/starship ]]     && mark starship adopted
  dpkg_has docker-ce-cli                 && mark docker adopted
  echo "Recorded existing components: $(grep -vc '^#' "$MANIFEST")"
}

# ------------------------------------------------------------ components ----
install_base() {
  apt_get update &&
  apt_get install git build-essential curl wget ca-certificates unzip xz-utils \
    openssh-client tmux fzf ripgrep zoxide bat less
}

setup_timezone() {
  if [[ -z $TIMEZONE ]]; then
    note "Timezone: Android's timezone couldn't be read, so Ubuntu stays on UTC."
    return 0
  fi
  if [[ ! -f /usr/share/zoneinfo/$TIMEZONE ]]; then
    sudo DEBIAN_FRONTEND=noninteractive apt-get -y install tzdata || return 1
  fi
  [[ -f /usr/share/zoneinfo/$TIMEZONE ]] || { echo "Unknown timezone: $TIMEZONE"; return 1; }
  sudo ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime &&
  echo "$TIMEZONE" | sudo tee /etc/timezone >/dev/null || return 1
  echo "Timezone set to $TIMEZONE ($(TZ=$TIMEZONE date +%z))"
}

install_dotnet_script() {
  curl -fsSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh &&
  bash /tmp/dotnet-install.sh --channel 10.0 --install-dir "$HOME/.dotnet"
}

install_dotnet() {
  has dotnet && { echo "already installed: $(dotnet --version)"; return 0; }
  if apt-cache show dotnet-sdk-10.0 >/dev/null 2>&1; then
    apt_get install dotnet-sdk-10.0 && mark dotnet tabden apt
  else
    echo "dotnet-sdk-10.0 not in apt for this release; using dotnet-install.sh"
    install_dotnet_script && mark dotnet tabden script
  fi
}

install_rust() {
  has rustup && { echo "already installed"; return 0; }
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs |
    sh -s -- -y --profile minimal --no-modify-path && mark rust tabden
}

install_bun() {
  has bun && { echo "already installed"; return 0; }
  curl -fsSL https://bun.sh/install | bash && mark bun tabden
}

install_node() {
  has node && { echo "already installed"; return 0; }
  apt_get install nodejs npm && mark node tabden
}

install_claude() {
  has claude && { echo "already installed"; return 0; }
  curl -fsSL https://claude.ai/install.sh | bash || return 1
  mark claude tabden
  note "Claude Code: run 'claude' once to log in; open the printed URL in the tablet browser."
}

install_helix() {
  [[ ${1:-} != force ]] && has hx && { echo "already installed"; return 0; }
  local v d
  v=$(gh_latest helix-editor/helix) && [[ -n $v ]] || { echo "could not resolve Helix release"; return 1; }
  d="helix-${v}-aarch64-linux"
  curl -fL -o /tmp/hx.tar.xz "https://github.com/helix-editor/helix/releases/download/${v}/${d}.tar.xz" &&
  tar -xf /tmp/hx.tar.xz -C /tmp &&
  sudo install "/tmp/$d/hx" /usr/local/bin/hx &&
  mkdir -p "$HOME/.config/helix" &&
  rm -rf "$HOME/.config/helix/runtime" &&
  cp -r "/tmp/$d/runtime" "$HOME/.config/helix/" || return 1
  rm -rf /tmp/hx.tar.xz "/tmp/$d"
  [[ ${1:-} == force ]] || mark helix tabden
  hx --version
}

install_roslyn() {
  has dotnet || { echo "Roslyn LS needs .NET - select .NET 10 in Runtimes"; return 1; }
  if ! has roslyn-language-server; then
    dotnet tool install --global roslyn-language-server --prerelease || return 1
    mark roslyn tabden
  fi
  mkdir -p "$HOME/.config/helix"
  write_block "$HOME/.config/helix/languages.toml" '[language-server.roslyn-language-server]
command = "roslyn-language-server"
args = ["--stdio"]

[[language]]
name = "c-sharp"
language-servers = ["roslyn-language-server"]'
}

install_vscode() {
  if has code; then
    if [[ ${1:-} == force ]]; then code update || return 1; else echo "already installed"; fi
  else
    curl -fL -o /tmp/vscode-cli.tar.gz \
      'https://code.visualstudio.com/sha/download?build=stable&os=cli-alpine-arm64' &&
    tar -xf /tmp/vscode-cli.tar.gz -C /tmp &&
    sudo install /tmp/code /usr/local/bin/code || return 1
    rm -f /tmp/code /tmp/vscode-cli.tar.gz
    mark vscode tabden
  fi
  if [[ ! -s $TOKEN ]]; then
    head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$TOKEN"
    chmod 600 "$TOKEN"
  fi
  note "VS Code Server: bookmark http://127.0.0.1:8080/?tkn=$(cat "$TOKEN")"
}

install_lazygit() {
  [[ ${1:-} != force ]] && has lazygit && { echo "already installed"; return 0; }
  local v
  v=$(gh_latest jesseduffield/lazygit) && [[ -n $v ]] || { echo "could not resolve lazygit release"; return 1; }
  v=${v#v}
  curl -fL -o /tmp/lazygit.tar.gz \
    "https://github.com/jesseduffield/lazygit/releases/download/v${v}/lazygit_${v}_Linux_arm64.tar.gz" &&
  tar -xf /tmp/lazygit.tar.gz -C /tmp lazygit &&
  sudo install /tmp/lazygit /usr/local/bin/lazygit || return 1
  rm -f /tmp/lazygit /tmp/lazygit.tar.gz
  [[ ${1:-} == force ]] || mark lazygit tabden
}

install_delta() {
  has delta || { apt_get install git-delta && mark delta tabden; } || return 1
  git config --global core.pager delta
  git config --global interactive.diffFilter 'delta --color-only'
  git config --global delta.navigate true
  git config --global merge.conflictStyle zdiff3
}

install_gh() {
  has gh || { apt_get install gh && mark gh tabden; } || return 1
  gh auth status >/dev/null 2>&1 || note "GitHub CLI: run 'gh auth login' inside Ubuntu (separate from any Termux login). Pick the web browser option and open the URL yourself."
}

install_eza()  { has eza  || { apt_get install eza  && mark eza tabden; }; }
install_btop() { has btop || { apt_get install btop && mark btop tabden; }; }

install_starship() {
  [[ ${1:-} != force ]] && has starship && { echo "already installed"; return 0; }
  curl -sS https://starship.rs/install.sh | sh -s -- --yes --bin-dir "$HOME/.local/bin" || return 1
  [[ ${1:-} == force ]] || mark starship tabden
}

install_docker() {
  if ! has docker; then
    local codename
    codename=$(. /etc/os-release; echo "$VERSION_CODENAME")
    if ! curl -fsI "https://download.docker.com/linux/ubuntu/dists/$codename/Release" >/dev/null; then
      note "Docker's repo has no '$codename' yet; used 'noble' packages instead."
      codename=noble
    fi
    sudo install -m 0755 -d /etc/apt/keyrings &&
    sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc &&
    echo "deb [arch=arm64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $codename stable" |
      sudo tee /etc/apt/sources.list.d/docker.list >/dev/null &&
    apt_get update &&
    apt_get install docker-ce-cli docker-compose-plugin || return 1
    mark docker tabden
  fi
  [[ -f $HOME/.ssh/id_ed25519 ]] || ssh-keygen -t ed25519 -N '' -q -f "$HOME/.ssh/id_ed25519"
  if [[ -n $DOCKER_SSH_HOST ]]; then
    if docker context inspect remote >/dev/null 2>&1; then
      docker context update remote --docker "host=ssh://$DOCKER_SSH_HOST"
    else
      docker context create remote --docker "host=ssh://$DOCKER_SSH_HOST"
    fi
    docker context use remote
    note "Remote Docker: run 'ssh-copy-id $DOCKER_SSH_HOST' once (Tailscale connected), then 'docker ps'."
  fi
}

# -------------------------------------------------------------- removal ----
# Each removes what the matching install_x put in place, plus its config.
# User data (logins, settings, projects) is kept and mentioned in a note.
# run() executes steps in a pipeline subshell, so use a file, not a variable.
APT_FLAG="$LOG_DIR/apt-removed"
apt_remove() { apt_get remove "$@" && : > "$APT_FLAG"; }

remove_dotnet() {
  case $(detail_of dotnet) in
    apt)    apt_remove dotnet-sdk-10.0 ;;
    script) rm -rf "$HOME/.dotnet" && unmark roslyn ;;
    *)      echo "Unknown .NET install method; not removing"; return 1 ;;
  esac
}
remove_rust()  { if has rustup; then rustup self uninstall -y; else rm -rf "$HOME/.cargo" "$HOME/.rustup"; fi; }
remove_bun()   { rm -rf "$HOME/.bun"; }
remove_node()  { apt_remove nodejs npm; }
remove_claude() {
  rm -f "$HOME/.local/bin/claude" && rm -rf "$HOME/.local/share/claude" || return 1
  note "Claude Code removed; your settings and history in ~/.claude were kept."
}
remove_helix() { sudo rm -f /usr/local/bin/hx && rm -rf "$HOME/.config/helix/runtime"; }
remove_roslyn() {
  if has dotnet; then dotnet tool uninstall --global roslyn-language-server
  else rm -rf "$HOME/.dotnet/tools/roslyn-language-server" "$HOME/.dotnet/tools/.store/roslyn-language-server"; fi
  remove_block "$HOME/.config/helix/languages.toml"
}
remove_vscode() {
  pkill -f 'code serve-web' 2>/dev/null
  sudo rm -f /usr/local/bin/code && rm -rf "$HOME/.vscode/cli" "$HOME/.vscode-server" && rm -f "$TOKEN"
}
remove_lazygit() { sudo rm -f /usr/local/bin/lazygit; }
remove_delta() {
  apt_remove git-delta || return 1
  # Undo only the git settings tabden set, if still at tabden's values.
  [[ $(git config --global core.pager) == delta ]] && git config --global --unset core.pager
  [[ $(git config --global interactive.diffFilter) == 'delta --color-only' ]] && git config --global --unset interactive.diffFilter
  git config --global --unset delta.navigate 2>/dev/null
  [[ $(git config --global delta.syntax-theme) == ansi ]] && git config --global --unset delta.syntax-theme
  return 0
}
remove_gh() {
  apt_remove gh || return 1
  note "GitHub CLI removed; its login in ~/.config/gh was kept."
}
remove_eza()  { apt_remove eza; }
remove_btop() { apt_remove btop; }
remove_starship() {
  rm -f "$HOME/.local/bin/starship"
  if head -1 "$HOME/.config/starship.toml" 2>/dev/null | grep -qxF "$STARSHIP_MARK"; then
    rm -f "$HOME/.config/starship.toml"
  fi
  return 0
}
remove_docker() {
  if has docker && docker context inspect remote >/dev/null 2>&1; then
    docker context use default >/dev/null && docker context rm remote
  fi
  apt_remove docker-ce-cli docker-compose-plugin || return 1
  sudo rm -f /etc/apt/sources.list.d/docker.list /etc/apt/keyrings/docker.asc
}

remove_component() {
  local id=$1
  if is_selected "$id"; then echo "$id is selected; not removing"; return 0; fi
  if ! tracked "$id"; then echo "$id isn't in tabden's record; not removing"; return 0; fi
  "remove_$id" || return 1
  unmark "$id"
}

do_removals() {
  local id
  [[ -n $REMOVE ]] || return 0
  rm -f "$APT_FLAG"
  for id in $REMOVE; do
    if declare -F "remove_$id" >/dev/null; then run "Remove $id" remove_component "$id"
    else FAILED+=("remove $id (unknown)"); fi
  done
  [[ -f $APT_FLAG ]] && { run "Remove unused packages" apt_get autoremove; rm -f "$APT_FLAG"; }
  return 0
}

# ----------------------------------------------------------------- theme ----
# THEME=default changes nothing: every function here then only removes what a
# theme added. Otherwise Termux carries the palette (launcher.sh) and the tools
# below are pointed at the terminal's 16 colours, so they follow it. The PS1,
# Starship, lazygit and eza already use those colours and need nothing.
themed()       { [[ $THEME != default ]]; }
theme_accent() { case $THEME in catppuccin-mocha) echo 5 ;; tokyonight) echo 4 ;; gruvbox-dark) echo 3 ;; esac; }
helix_theme()  { case $THEME in catppuccin-mocha) echo catppuccin_mocha ;; tokyonight) echo tokyonight ;; gruvbox-dark) echo gruvbox ;; esac; }

# Helix: one line, 'theme = "..."', in a block at the top of config.toml.
# Skipped when the user's own config already sets a theme (a second 'theme'
# key would make the file invalid); any block from earlier is removed then.
theme_helix() {
  local f="$HOME/.config/helix/config.toml" own=0
  if [[ -f $f ]] && sed '/^# >>> tabden >>>$/,/^# <<< tabden <<<$/d' "$f" |
       grep -qE '^[[:space:]]*theme[[:space:]]*='; then own=1; fi
  if themed && [[ $IDE_HELIX == 1 ]] && (( ! own )); then
    mkdir -p "$HOME/.config/helix" && prepend_block "$f" "theme = \"$(helix_theme)\""
    return
  fi
  if [[ -f $f ]]; then
    remove_block "$f"
    [[ -n $(tr -d '[:space:]' < "$f") ]] || rm -f "$f"   # nothing left: it was only tabden's
  fi
  if themed && [[ $IDE_HELIX == 1 ]]; then
    note "Theme: your ~/.config/helix/config.toml sets its own theme, so Helix keeps it. For the matching one: theme = \"$(helix_theme)\""
  fi
  return 0
}

# delta: the 'ansi' syntax theme, unless the user has picked one. Removed
# again only while it is still 'ansi'.
theme_delta() {
  local cur
  cur=$(git config --global delta.syntax-theme 2>/dev/null)
  if themed && want_cli delta && has delta; then
    [[ -z $cur ]] && delta --list-syntax-themes 2>/dev/null | grep -qw ansi &&
      git config --global delta.syntax-theme ansi
  elif [[ $cur == ansi ]]; then
    git config --global --unset delta.syntax-theme
  fi
  return 0
}

# A running tmux server keeps options that the new config no longer sets, so
# put the two a theme adds back to tmux's defaults, then read the config again.
reload_tmux() {
  tmux set -gu pane-active-border-style \; set -gwu window-status-current-style \; \
    source-file "$HOME/.tmux.conf"
}

# -------------------------------------------------------------- dotfiles ----
# Proot-safe starship profile: only cheap modules, so no language-version
# commands run on each prompt. Rewritten only if tabden owns the file.
STARSHIP_MARK="# ~/.config/starship.toml (written by tabden)"
write_starship_config() {
  local f="$HOME/.config/starship.toml"
  if [[ -f $f ]] && ! head -1 "$f" | grep -qxF "$STARSHIP_MARK" &&
     ! grep -qx "format = \"\[$USER@ubuntu\](bold cyan) \$all\"" "$f"; then
    note "Starship: kept your own ~/.config/starship.toml. The proot-safe profile is in the guide."
    return 0
  fi
  mkdir -p "$HOME/.config"
  cat > "$f" <<EOF
$STARSHIP_MARK
add_newline = false
command_timeout = 300
scan_timeout = 10
# No username in the prompt: "ubuntu ~/projects \$". To show yours, see
# ~/.config/tabden/local.sh.example.
format = "[ubuntu](bold cyan) \$directory\$git_branch\$character"

[directory]
truncation_length = 3
EOF
}

# Environment for every shell, interactive or not: ~/.profile (login shells,
# including 'ubu <command>') and ~/.bashrc (tmux windows) both source it.
ENV_FILE="$HOME/.config/tabden/env.sh"
write_env() {
  local e
  e=$(cat <<'EOF'
# tabden environment (rewritten on every install and update; don't edit)
case ":$PATH:" in
  *":$HOME/bin:"*) ;;
  *) export PATH="$HOME/bin:$HOME/.local/bin:$HOME/.cargo/bin:$HOME/.bun/bin:$HOME/.dotnet/tools:$PATH" ;;
esac
if [ -x "$HOME/.dotnet/dotnet" ]; then
  export DOTNET_ROOT="$HOME/.dotnet"
  case ":$PATH:" in *":$DOTNET_ROOT:"*) ;; *) export PATH="$DOTNET_ROOT:$PATH" ;; esac
fi
export DOTNET_GCHeapHardLimit=1C0000000   # hex = 7 GiB; required under proot
export DOTNET_CLI_TELEMETRY_OPTOUT=1
# A UTF-8 locale, unless one is set. Without it tmux draws every non-ASCII
# character as "_" (only box lines survive), and proot-distro sets none.
case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
  *[Uu][Tt][Ff]-8*|*[Uu][Tt][Ff]8*) ;;
  *) export LANG=C.UTF-8 ;;
esac
[ -f "$HOME/.config/tabden/selections.env" ] && TZ_SEL=$(. "$HOME/.config/tabden/selections.env"; echo "$TIMEZONE")
[ -n "${TZ_SEL:-}" ] && export TZ="$TZ_SEL"; unset TZ_SEL
EOF
)
  [[ $IDE_HELIX == 1 ]] && e+=$'\n''export EDITOR=hx VISUAL=hx'
  if themed; then
    e+=$'\n'"$(cat <<'EOF'
# Theme: bat (and delta) use the terminal's 16 colours, so they follow the palette.
export BAT_THEME=ansi
# Helix loads a full-colour theme only when the terminal reports 24-bit colour.
[ -n "${COLORTERM:-}" ] || export COLORTERM=truecolor
EOF
)"
  fi
  printf '%s\n' "$e" > "$ENV_FILE" &&
  write_block "$HOME/.profile" '[ -f "$HOME/.config/tabden/env.sh" ] && . "$HOME/.config/tabden/env.sh"'
}

write_bashrc() {
  local b
  b=$(cat <<'EOF'
[ -f "$HOME/.config/tabden/env.sh" ] && . "$HOME/.config/tabden/env.sh"

alias bat='batcat'

if fzf --bash >/dev/null 2>&1; then eval "$(fzf --bash)"
elif [ -f /usr/share/doc/fzf/examples/key-bindings.bash ]; then . /usr/share/doc/fzf/examples/key-bindings.bash; fi
command -v zoxide >/dev/null && eval "$(zoxide init bash)"
EOF
)
  [[ " $CLI_EXTRAS " == *" lazygit "* ]] && b+=$'\n'"alias lg='lazygit'"
  [[ " $CLI_EXTRAS " == *" eza "* ]] && b+=$'\n'"alias ls='eza'"$'\n'"alias ll='eza -la --git'"
  if [[ " $CLI_EXTRAS " == *" starship "* ]]; then
    b+=$'\n''export STARSHIP_NUM_THREADS=1   # Termux hang workaround, starship#6151'
    b+=$'\n''command -v starship >/dev/null && eval "$(starship init bash)"'
    write_starship_config
  else
    b+=$'\n'"$(cat <<'EOF'
__git_br() { local b; b=$(git branch --show-current 2>/dev/null) && [ -n "$b" ] && printf ' (%s)' "$b"; }
PS1='\[\e[1;36m\]ubuntu\[\e[0m\] \[\e[32m\]\w\[\e[33m\]$(__git_br)\[\e[0m\] \$ '
EOF
)"
  fi
  b+=$'\n\n'"$(cat <<'EOF'
# ws <name>: go to a git identity's folder and switch gh to its GitHub account.
# A function, because a script can't change this shell's folder. See git-id --help.
ws() {
  [ $# -gt 0 ] || { git-id list; return; }
  local d
  d=$(git-id path "$1") || return
  cd "$d" && git-id switch "$1"
}
_ws() { COMPREPLY=($(compgen -W "$(git-id names 2>/dev/null)" -- "${COMP_WORDS[COMP_CWORD]}")); }
complete -F _ws ws
EOF
)"
  # Last line of the block, so the user's settings override everything above.
  # (An if, not "[ -f ] &&": that would leave a failed status at the first prompt.)
  b+=$'\n\n''# Your own settings; tabden never creates or changes this file.'
  b+=$'\n''if [ -f "$HOME/.config/tabden/local.sh" ]; then . "$HOME/.config/tabden/local.sh"; fi'
  write_block "$HOME/.bashrc" "$b"
}

# The example is tabden's file and is refreshed on every run; local.sh and
# local.tmux.conf are the user's and are never created or touched.
write_local_example() {
  cat > "$HOME/.config/tabden/local.sh.example" <<'EOF'
# Your own shell settings for Ubuntu. To use this file:
#   cp ~/.config/tabden/local.sh.example ~/.config/tabden/local.sh
#
# tabden loads ~/.config/tabden/local.sh at the end of its ~/.bashrc block,
# in interactive shells (tmux windows, 'ubu'), so anything here overrides
# tabden's settings. tabden never creates, edits or deletes local.sh, and
# 'tabden uninstall' backs it up before removing Ubuntu.
#
# alias gs='git status -sb'
# export EDITOR=nano
#
# The prompt leaves your username out ("ubuntu ~/projects $"), so screenshots
# and recordings don't show it. To put it back (same colours):
#   PS1='\[\e[1;36m\]\u@ubuntu\[\e[0m\] \[\e[32m\]\w\[\e[33m\]$(__git_br)\[\e[0m\] \$ '
# With Starship, use your own copy of tabden's profile:
#   cp ~/.config/starship.toml ~/.config/my-starship.toml   (once)
#   export STARSHIP_CONFIG=~/.config/my-starship.toml       (here)
# and in the copy replace the format line with these four:
#   format = "$username$directory$git_branch$character"
#   [username]
#   show_always = true
#   format = "[$user@ubuntu](bold cyan) "
#
# tmux settings go in ~/.config/tabden/local.tmux.conf, which is loaded after
# tabden's tmux settings. For example:
#   set -g status-position top
#   set -g history-limit 50000
EOF
}

write_tmux() {
  local style a
  if themed; then
    # Palette indexes, not hex colours, so the bar follows the terminal's
    # palette. [99] is a fixed slot: reading this file again replaces the
    # entry instead of adding another one.
    a=$(theme_accent)
    style="set -g status-style bg=colour0,fg=colour7
set -g status-right '#[fg=colour$a]%H:%M'
setw -g window-status-current-style fg=colour0,bg=colour$a
set -g pane-active-border-style fg=colour$a
# Termux draws 24-bit colour; tell tmux, so Helix's theme isn't rounded to 256 colours.
set -s terminal-features[99] 'xterm-256color:RGB'"
  else
    style="set -g status-style bg=black,fg=white
set -g status-right '#[fg=green]%H:%M'"
  fi
  write_block "$HOME/.tmux.conf" "$(cat <<'EOF'
unbind C-b
set -g prefix C-a
bind C-a send-prefix

set -g base-index 1
setw -g pane-base-index 1
set -g renumber-windows on
set -g mouse on
set -g history-limit 10000
set -g default-terminal "tmux-256color"
set -sg escape-time 10
set -g focus-events on

bind | split-window -h -c "#{pane_current_path}"
bind - split-window -v -c "#{pane_current_path}"
bind h select-pane -L
bind j select-pane -D
bind k select-pane -U
bind l select-pane -R

EOF
)

$style

$(cat <<'EOF'
# Ctrl-a / shows the cheat sheet over the current pane (q closes it)
bind / display-popup -E -w 90% -h 90% "less -R ~/.config/tabden/cheatsheet.txt"

# Your own tmux settings, loaded last so they override the ones above.
# tabden never creates or changes this file; -q: fine if it doesn't exist.
source-file -q ~/.config/tabden/local.tmux.conf
EOF
)"
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
    note "Commands: ~/bin/$1 in Ubuntu isn't tabden's, so it was left alone and tabden's '$1' isn't installed. Rename or move yours, then run: tabden update"
    return 0
  fi
  cat > "$f" && chmod 755 "$f" || return 1
  other=$(hidden_by "$1")
  [[ -n $other ]] && note "Commands: in Ubuntu, tabden's '$1' comes first on PATH, so it hides $other. Run that one by its full path."
  return 0
}

write_scripts() {
  put_cmd den <<'EOF'
#!/usr/bin/env bash
# tabden-managed: written by tabden and rewritten on every update; edits are lost.
# den: the den session (tmux) and its helpers. 'den help' lists everything.
S=den
usage() { echo "Usage: den [stop|status|update|help]   ('den' alone opens the den session)"; }

den_open() {
  if [ -n "${TMUX:-}" ]; then
    echo "You're already in the den session. Ctrl-a d detaches; 'den stop' ends it."
    exit 0
  fi
  [ -f "$HOME/.config/tabden/selections.env" ] && . "$HOME/.config/tabden/selections.env"
  [ -n "${TIMEZONE:-}" ] && export TZ="$TIMEZONE"
  if ! tmux has-session -t "$S" 2>/dev/null; then
    tmux new-session -d -s "$S" -n claude -c "$HOME/projects"
    tmux new-window  -t "$S" -n edit  -c "$HOME/projects"
    tmux new-window  -t "$S" -n shell -c "$HOME/projects"
    if [ "${IDE_VSCODE:-0}" = 1 ]; then
      tmux new-window -t "$S" -n vscode \
        "code serve-web --host 127.0.0.1 --port 8080 --accept-server-license-terms --connection-token-file $HOME/.config/tabden/vscode-token"
    fi
    tmux select-window -t "$S:claude"
  fi
  exec tmux attach -t "$S"
}

# Ends the session. Back in Termux, 'den' (or 'ubu') sees it has gone and
# releases the wake lock and any local model.
den_stop() {
  pkill -f 'code serve-web' 2>/dev/null
  if tmux has-session -t "$S" 2>/dev/null; then
    [ -n "${TABDEN_QUIET:-}" ] ||
      echo "Ending the den session. Back in Termux, the wake lock and any local model are released."
    tmux kill-session -t "$S"
  else
    [ -n "${TABDEN_QUIET:-}" ] || echo "No den session running."
  fi
}

den_status() {
  ver() {
    if command -v "$1" >/dev/null 2>&1; then printf '  ok  %-9s %s\n' "$1" "$("$@" 2>&1 | head -1)"
    else printf '  --  %s (not installed)\n' "$1"; fi
  }
  echo "User: $(whoami)   $(. /etc/os-release; echo "$PRETTY_NAME")"
  ver dotnet --version
  ver rustc --version
  ver bun --version
  ver node --version
  ver claude --version
  ver hx --version
  ver code --version
  ver tmux -V
  ver lazygit --version
  ver delta --version
  ver gh --version
  . "$HOME/.config/tabden/selections.env" 2>/dev/null
  if [ "${PROJECTS_MODE:-termux}" = termux ]; then
    if [ -e "$HOME/projects/.tabden-mount" ]; then echo "projects: Termux ~/projects mounted"
    else echo "projects: NOT mounted - you are seeing the Ubuntu-home copy; enter with 'den' or 'ubu'"; fi
  else
    echo "projects: Ubuntu home"
  fi
  if [ -n "$(git config --global user.email 2>/dev/null)" ]; then
    ids=$(ls "$HOME/.config/tabden/git-identities"/*.gitconfig 2>/dev/null | wc -l)
    echo "git: $(git config --global user.name) <$(git config --global user.email)>$([ "$ids" -gt 0 ] && echo ", plus $ids by folder (git-id)")"
  else
    echo "git: no name and email set - run 'git-id default'"
  fi
  if tmux has-session -t "$S" 2>/dev/null; then echo "tmux: den session running"; else echo "tmux: no den session"; fi
  case $(phantom_state) in
    disabled) echo "phantom killer: off" ;;
    enabled)  echo "phantom killer: ON - Android may end sessions with signal 9; run 'tabden fix-phantom' in Termux" ;;
    unknown)  echo "phantom killer: unknown - if sessions die with signal 9, run 'tabden fix-phantom' in Termux" ;;
  esac
  curl -fs http://127.0.0.1:11434/ >/dev/null && echo "Ollama: running"
  curl -fs http://127.0.0.1:8081/health >/dev/null && echo "llama.cpp: running"
  free -h | head -2
}

# Android 12+ phantom process killer (same logic as launcher.sh's check_phantom).
acmd() { local t=$1; shift; [ -x "/system/bin/$t" ] || return 127
  timeout 3 env -u LD_PRELOAD -u LD_LIBRARY_PATH "/system/bin/$t" "$@" 2>/dev/null; }
phantom_state() {
  local sdk v prop
  sdk=$(acmd getprop ro.build.version.sdk) && [[ $sdk =~ ^[0-9]+$ ]] || { echo unknown; return; }
  (( sdk >= 31 )) || { echo na; return; }
  if (( sdk == 31 )); then
    v=$(acmd device_config get activity_manager max_phantom_processes) || v=""
    if [[ $v =~ ^[0-9]+$ ]] && (( v > 32 )); then echo disabled
    elif [[ $v == null || $v == 32 ]]; then echo enabled; else echo unknown; fi
    return
  fi
  v=$(acmd settings get global settings_enable_monitor_phantom_procs) || v=""
  case $v in false) echo disabled; return ;; true) echo enabled; return ;; esac
  # Empty = never set (apps may read it; see check_phantom in launcher.sh).
  # A getprop that fails or times out says nothing.
  prop=$(acmd getprop persist.sys.fflag.override.settings_enable_monitor_phantom_procs) ||
    { echo unknown; return; }
  case $prop in
    false) echo disabled ;;
    true)  echo enabled ;;
    "")    if [[ $v == null ]]; then echo enabled; else echo unknown; fi ;;
    *)     echo unknown ;;
  esac
}

den_help() {
  f="$HOME/.config/tabden/cheatsheet.txt"
  [ -f "$f" ] || { echo "No cheat sheet yet: run 'tabden update' in Termux."; exit 1; }
  if command -v less >/dev/null; then exec less -RFX "$f"; else cat "$f"; fi
}

case ${1:-} in
  "")             den_open ;;
  stop)           den_stop ;;
  status)         den_status ;;
  update)         exec "$HOME/.local/share/tabden/guest.sh" --update ;;   # Ubuntu side only
  help|-h|--help) den_help ;;
  *)              usage; exit 2 ;;
esac
EOF
}

# git-id: git identities chosen by folder, each with an optional GitHub
# account. The identities themselves are the user's data, created only by
# running git-id; tabden installs just the two commands below.
write_git_id() {
  put_cmd git-credential-gh-account <<'EOF'
#!/usr/bin/env bash
# tabden-managed: written by tabden and rewritten on every update; edits are lost.
# tabden: git credential helper that answers with one named gh account's
# token, whichever account is active in gh. Set up by git-id; usage:
#   git-credential-gh-account <github-login> get
login=${1:-}; op=${2:-}
[ "$op" = get ] && [ -n "$login" ] || exit 0
cat >/dev/null   # the request; this helper is only configured for github.com
if token=$(gh auth token --hostname github.com --user "$login" 2>/dev/null) && [ -n "$token" ]; then
  printf 'username=%s\npassword=%s\n' "$login" "$token"
else
  echo "git-id: GitHub account '$login' isn't logged in here. Run: gh auth login   (sign in as $login)" >&2
  echo "quit=1"   # stop here instead of asking for a username and password
fi
EOF

  put_cmd git-id <<'EOF'
#!/usr/bin/env bash
# tabden-managed: written by tabden and rewritten on every update; edits are lost.
# tabden: git identities chosen by folder, each with an optional GitHub account.
#
#   git-id                 list identities; * marks the one for the current folder
#   git-id default         set the name, email and GitHub account used everywhere else
#   git-id add [name]      add or change the identity for one folder (default ~/projects/<name>)
#   git-id remove <name>   remove an identity; its folder and repos are left alone
#   ws <name>              go to an identity's folder and make its GitHub account
#                          the active one for gh ('ws default' goes back; 'ws' lists)
#
# Options for add and default, instead of the questions:
#   --name "Full Name"   --email you@example.com   --gh <github-login>   --no-gh
#   add only:  --dir <folder>   --ssh-key <private key file>   --no-ssh-key
#
# Each identity is a file in ~/.config/tabden/git-identities/, pulled into
# ~/.gitconfig with includeIf "gitdir:<folder>/": a repo gets the identity of
# the folder it's cloned under. With a GitHub account set, git over HTTPS in
# that folder always uses that account's gh login, whichever one is active.

# shellcheck disable=SC2088,SC2016,SC2015  # literal ~ and $HOME are stored in git config on purpose
set -u
DIR="$HOME/.config/tabden/git-identities"
HOST=github.com
CRED="credential.https://$HOST.helper"

die()   { printf 'git-id: %s\n' "$*" >&2; exit 1; }
usage() { awk 'NR > 2 { if (!/^#/) exit; sub(/^# ?/, ""); print }' "$0"; }
has_gh()  { command -v gh >/dev/null 2>&1; }
gcfg()    { git config --global "$@"; }
gval()    { git config --global "$1" 2>/dev/null; }
file_of() { printf '%s/%s.gitconfig' "$DIR" "$1"; }
get()     { git config -f "$(file_of "$1")" "$2" 2>/dev/null; }          # identity key
expand()  { case $1 in '~') printf '%s' "$HOME" ;; '~/'*) printf '%s/%s' "$HOME" "${1#'~/'}" ;; *) printf '%s' "$1" ;; esac; }
tilde()   { case $1 in "$HOME"/*) printf '~/%s' "${1#"$HOME"/}" ;; *) printf '%s' "$1" ;; esac; }
exists()  { [[ -f $(file_of "$1") ]]; }
names()   { local f; for f in "$DIR"/*.gitconfig; do [[ -f $f ]] && basename "$f" .gitconfig; done; return 0; }

valid_name()  { [[ $1 =~ ^[a-z0-9][a-z0-9_-]*$ && $1 != default ]]; }
valid_login() { [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,38}$ ]]; }
valid_email() { [[ $1 =~ ^[^[:space:]@]+@[^[:space:]@]+$ ]]; }

logged_in()    { has_gh && gh auth token --hostname "$HOST" --user "$1" >/dev/null 2>&1; }
active_login() { has_gh && gh config get user --host "$HOST" 2>/dev/null; }
helper_for()   { printf '!"$HOME/bin/git-credential-gh-account" %s' "$1"; }
set_helper() {  # login, then where: --global, or -f <file>
  local login=$1; shift
  git config "$@" --unset-all "$CRED" 2>/dev/null
  # The empty value clears helpers set earlier, so only this account answers.
  git config "$@" --add "$CRED" "" && git config "$@" --add "$CRED" "$(helper_for "$login")"
}

# Outside identity folders, pin git to the default account too; otherwise it
# would follow whichever account 'ws' last made active. 'gh auth login' puts
# gh's own helper back, so this is re-checked on every change and every 'ws'.
pin_global() {
  local d; d=$(gval tabden.ghuser) && [[ -n $d ]] || return 0
  [[ $(gcfg --get-all "$CRED" 2>/dev/null | tail -1) == "$(helper_for "$d")" ]] || set_helper "$d" --global
}
unpin_global() {  # back to gh's own helper, which follows the active account
  [[ $(gcfg --get-all "$CRED" 2>/dev/null | tail -1) == '!"$HOME/bin/git-credential-gh-account" '* ]] &&
    gcfg --unset-all "$CRED"
  gh_for_git
}
gh_for_git() {  # what answering yes to "Authenticate Git with your GitHub credentials?" does
  has_gh && gh auth token --hostname "$HOST" >/dev/null 2>&1 || return 0
  [[ -n $(gcfg --get-all "$CRED" 2>/dev/null) ]] || gh auth setup-git --hostname "$HOST" >/dev/null 2>&1
  return 0
}

# Git reads ~/.gitconfig top to bottom and the last value wins, so the identity
# includes have to come after [user], [core] and [credential]. Deeper folders
# are added last, so an identity nested inside another one wins there.
unlink_id() { local d; d=$(get "$1" tabden.dir) && gcfg --remove-section "includeIf.gitdir:$d/" 2>/dev/null; return 0; }
relink() {
  local n d
  while read -r _ n; do
    d=$(get "$n" tabden.dir) || continue
    gcfg --remove-section "includeIf.gitdir:$d/" 2>/dev/null
    gcfg "includeIf.gitdir:$d/.path" "$(tilde "$(file_of "$n")")"
  done < <(for n in $(names); do d=$(get "$n" tabden.dir) && printf '%d %s\n' "${#d}" "$n"; done | sort -n)
}
order_ok() {
  local g="$HOME/.gitconfig"
  [[ -f $g ]] || g="${XDG_CONFIG_HOME:-$HOME/.config}/git/config"
  [[ -f $g ]] || return 0
  awk '/^\[/ && seen && /^\[(user|core|credential)/ { bad = 1 }
       /^[ \t]*path[ \t]*=/ && index($0, "/tabden/git-identities/") { seen = 1 }
       END { exit bad }' "$g"
}
repair() { pin_global; order_ok || relink; }

current() {  # the identity that applies in $PWD: the deepest matching folder
  local n d best=default len=0
  for n in $(names); do
    d=$(expand "$(get "$n" tabden.dir)")
    [[ -n $d && $PWD/ == "$d"/* ]] && (( ${#d} > len )) && { best=$n; len=${#d}; }
  done
  printf '%s' "$best"
}

ask() {  # question default -> REPLY. Without a terminal, the default is the answer.
  local a
  [[ -t 0 ]] || { REPLY=${2:-}; return 0; }
  read -rp "$1${2:+ [$2]}: " a || exit 1
  REPLY=${a:-${2:-}}
}

parse() {
  POS=(); unset O_NAME O_EMAIL O_GH O_DIR O_KEY
  while (( $# )); do
    case $1 in
      --name|--email|--gh|--dir|--ssh-key) (( $# >= 2 )) || die "$1 needs a value" ;;&
      --name)       O_NAME=$2;  shift 2 ;;
      --email)      O_EMAIL=$2; shift 2 ;;
      --gh)         O_GH=$2;    shift 2 ;;
      --no-gh)      O_GH="";    shift ;;
      --dir)        O_DIR=$2;   shift 2 ;;
      --ssh-key)    O_KEY=$2;   shift 2 ;;
      --no-ssh-key) O_KEY="";   shift ;;
      -*)           die "unknown option '$1' (git-id --help)" ;;
      *)            POS+=("$1"); shift ;;
    esac
  done
}

# Name, email and GitHub account: from the options, else asked, with the
# current values as the defaults. Sets NAME, EMAIL and GH.
collect() {  # default-name default-email default-gh gh-question
  if [[ -v O_NAME ]]; then NAME=$O_NAME; else ask "Name for commits" "$1"; NAME=$REPLY; fi
  [[ -n $NAME && $NAME != *$'\n'* ]] || die "a name for commits is needed (--name)"
  if [[ -v O_EMAIL ]]; then EMAIL=$O_EMAIL; else ask "Email for commits" "$2"; EMAIL=$REPLY; fi
  valid_email "$EMAIL" || die "'$EMAIL' doesn't look like an email address (--email)"
  if [[ -v O_GH ]]; then GH=$O_GH; else ask "$4" "$3"; GH=$REPLY; fi
  [[ $GH == - ]] && GH=""
  [[ -z $GH ]] || valid_login "$GH" || die "'$GH' isn't a GitHub username (--gh takes the login, not an email)"
}

gh_note() {  # login -> text for the account column
  [[ -n $1 ]] || return 0
  if ! has_gh; then printf 'GitHub: %s (gh not installed)' "$1"
  elif logged_in "$1"; then printf 'GitHub: %s' "$1"
  else printf 'GitHub: %s (not logged in)' "$1"; fi
}
login_hint() {  # login, command to run afterwards
  logged_in "$1" && return 0
  has_gh || { echo "The GitHub CLI isn't installed, so the account can't be used: select gh in 'tabden modify'."; return 0; }
  gh auth switch --help >/dev/null 2>&1 ||
    { echo "This gh is too old to hold more than one account (needs 2.40 or newer): sudo apt update && sudo apt install gh"; return 0; }
  echo "GitHub account '$1' isn't logged in here yet. Run:"
  echo "  gh auth login      # sign in as $1; use a private browser tab if the browser is signed in as someone else"
  echo "  $2"
}

cmd_default() {
  parse "$@"
  (( ${#POS[@]} == 0 )) || die "default takes no name (git-id --help)"
  [[ ! -v O_DIR && ! -v O_KEY ]] || die "--dir and --ssh-key only apply to 'git-id add'"
  collect "$(gval user.name)" "$(gval user.email)" "$(gval tabden.ghuser)" \
    "GitHub login for everywhere else (only needed with more than one account; - for none)"
  gcfg user.name "$NAME" && gcfg user.email "$EMAIL" || die "couldn't write ~/.gitconfig"
  if [[ -n $GH ]]; then
    gcfg tabden.ghuser "$GH"; pin_global
  else
    gcfg --unset tabden.ghuser 2>/dev/null; unpin_global
  fi
  relink
  echo "Default identity: $NAME <$EMAIL>${GH:+   GitHub: $GH}"
  [[ -z $GH ]] || login_hint "$GH" "ws default"
}

cmd_add() {
  parse "$@"
  (( ${#POS[@]} <= 1 )) || die "add takes one name (git-id --help)"
  local n=${POS[0]:-} f dir key other d
  [[ -n $n ]] || { ask "Identity name (for example labs or work)" ""; n=$REPLY; }
  valid_name "$n" || die "'$n' can't be used as a name: lowercase letters, digits, - and _ ('default' is taken)"
  f=$(file_of "$n")

  if [[ -v O_DIR ]]; then dir=$O_DIR; else ask "Folder" "$(get "$n" tabden.dir || echo "~/projects/$n")"; dir=$REPLY; fi
  dir=$(expand "$dir"); [[ $dir == /* ]] || dir="$PWD/$dir"
  dir=$(realpath -ms "$dir") || die "can't use that folder"
  [[ $dir != / && $dir != "$HOME" && $dir != "$HOME/projects" ]] ||
    die "pick a folder of its own, such as ~/projects/$n: $(tilde "$dir") is where the default identity applies"
  [[ $dir != *[\"\\\*\?\[$'\n']* ]] || die "the folder name can't contain quotes, backslashes, * ? or ["
  for other in $(names); do
    [[ $other == "$n" ]] && continue
    d=$(expand "$(get "$other" tabden.dir)")
    [[ $d != "$dir" ]] || die "$(tilde "$dir") already belongs to the identity '$other'"
  done

  collect "$(get "$n" user.name || gval user.name)" "$(get "$n" user.email)" "$(get "$n" tabden.ghuser)" \
    "GitHub login for this folder (Enter for the same as everywhere else; - for none)"
  if [[ -v O_KEY ]]; then key=$O_KEY; else key=$(get "$n" tabden.sshkey); fi
  if [[ -n $key ]]; then
    [[ $key == /* || $key == '~/'* ]] && [[ $key != *[[:space:]\'\"\\]* ]] ||
      die "--ssh-key takes a path starting with / or ~/, without spaces or quotes"
    key=$(tilde "$(expand "$key")")
    [[ -f $(expand "$key") ]] || echo "Note: $key doesn't exist yet (ssh-keygen -t ed25519 -f $key)."
  fi

  mkdir -p "$DIR" "$dir" || die "couldn't create $(tilde "$dir")"
  exists "$n" && unlink_id "$n"
  printf '# tabden git identity "%s". Change it with: git-id add %s\n' "$n" "$n" > "$f" &&
  git config -f "$f" user.name "$NAME" &&
  git config -f "$f" user.email "$EMAIL" &&
  git config -f "$f" tabden.dir "$(tilde "$dir")" || die "couldn't write $f"
  if [[ -n $GH ]]; then
    git config -f "$f" tabden.ghuser "$GH"
    set_helper "$GH" -f "$f"
    # 'ws default' needs an account to go back to: take the one gh is using now.
    if [[ -z $(gval tabden.ghuser) ]]; then
      other=$(active_login)
      if [[ -n $other && $other != "$GH" ]]; then
        gcfg tabden.ghuser "$other"
        echo "Everywhere else keeps using GitHub account '$other' (the one gh is using now)."
      else
        echo "Set the GitHub account for everywhere else with: git-id default --gh <login>"
      fi
    fi
  fi
  if [[ -n $key ]]; then
    git config -f "$f" tabden.sshkey "$key"
    git config -f "$f" core.sshCommand "ssh -i $key -o IdentitiesOnly=yes"
  fi
  pin_global; relink

  echo "Identity '$n': $NAME <$EMAIL>${GH:+   GitHub: $GH}"
  echo "Repos cloned under $(tilde "$dir")/ use it. Go there with: ws $n"
  [[ -n $(gval user.email) ]] || echo "No default identity yet: 'git-id default' sets the one for everywhere else."
  [[ -z $GH ]] || login_hint "$GH" "ws $n"
}

cmd_remove() {
  local n=${1:-}
  [[ -n $n ]] || die "which one? git-id remove <name>"
  exists "$n" || die "no identity named '$n' (git-id lists them)"
  local d; d=$(get "$n" tabden.dir)
  unlink_id "$n"; rm -f "$(file_of "$n")"
  echo "Removed '$n'. $d and the repos in it are untouched."
}

cmd_list() {
  repair
  local cur n mark email
  cur=$(current)
  row() { printf '%s %-9s %-36s %-22s %s\n' "$1" "$2" "$3" "$4" "$5"; }
  email=$(gval user.email)
  mark=' '; [[ $cur == default ]] && mark='*'
  if [[ -n $email ]]; then
    row "$mark" default "$(gval user.name) <$email>" "everywhere else" "$(gh_note "$(gval tabden.ghuser)")"
  else
    row "$mark" default "(not set: run 'git-id default')" "everywhere else" ""
  fi
  for n in $(names); do
    mark=' '; [[ $cur == "$n" ]] && mark='*'
    row "$mark" "$n" "$(get "$n" user.name) <$(get "$n" user.email)>" "$(get "$n" tabden.dir)/" "$(gh_note "$(get "$n" tabden.ghuser)")"
  done
  n=$(active_login) && [[ -n $n ]] && echo "gh is acting as: $n"
  [[ -n $(names) ]] || echo "Add an identity for a folder with: git-id add <name>"
}

cmd_path() {
  local n=${1:-} d
  [[ -n $n ]] || die "which one? git-id path <name>"
  if [[ $n == default ]]; then d="$HOME/projects"; [[ -d $d ]] || d=$HOME
  else
    exists "$n" || die "no identity named '$n' (git-id lists them; git-id add $n creates it)"
    d=$(expand "$(get "$n" tabden.dir)"); mkdir -p "$d"
  fi
  printf '%s\n' "$d"
}

cmd_switch() {
  local n=${1:-} name email gh own d acct=""
  [[ -n $n ]] || die "which one? git-id switch <name>"
  if [[ $n == default ]]; then
    name=$(gval user.name); email=$(gval user.email); own=""
  else
    exists "$n" || die "no identity named '$n' (git-id lists them)"
    name=$(get "$n" user.name); email=$(get "$n" user.email); own=$(get "$n" tabden.ghuser)
  fi
  repair
  gh=${own:-$(gval tabden.ghuser)}
  if [[ -n $gh ]]; then
    if ! has_gh; then acct="   GitHub: $gh (gh not installed)"
    elif gh auth switch --hostname "$HOST" --user "$gh" >/dev/null 2>&1; then acct="   gh is now acting as: $gh"
    else acct="   GitHub: $gh (not logged in)"; fi
  fi
  [[ -n $gh || -z $(for d in $(names); do get "$d" tabden.ghuser; done) ]] ||
    echo "No GitHub account is set for the default identity, so gh stays as it is: git-id default --gh <login>"
  if [[ -n $email ]]; then echo "$n: $name <$email>$acct"
  else echo "$n: no name and email set; run 'git-id default'$acct"; fi
  [[ $acct != *"not logged in"* ]] || login_hint "$gh" "ws $n"
}

command -v git >/dev/null 2>&1 || die "git isn't installed"
cmd=${1:-list}; (( $# )) && shift
case $cmd in
  list|ls)        cmd_list ;;
  default)        cmd_default "$@" ;;
  add)            cmd_add "$@" ;;
  remove|rm)      cmd_remove "$@" ;;
  path)           cmd_path "$@" ;;
  switch)         cmd_switch "$@" ;;
  names)          echo default; names ;;
  relink)         pin_global; relink ;;
  -h|--help|help) usage ;;
  *)              die "unknown command '$cmd' (git-id --help)" ;;
esac
EOF

}

setup_projects() {
  mkdir -p "$HOME/projects"
  [[ $PROJECTS_MODE == termux ]] || { echo "Projects live in the Ubuntu home"; return 0; }
  # Mounted files are really owned by the Termux user; stop git's ownership check tripping on them.
  git config --global --get-all safe.directory 2>/dev/null | grep -qxF "$HOME/projects/*" ||
    git config --global --add safe.directory "$HOME/projects/*"
  if [[ -e $HOME/projects/.tabden-mount ]]; then
    echo "Termux ~/projects is mounted at $HOME/projects"
  else
    note "Projects: Termux ~/projects is not mounted in this session. Enter Ubuntu with 'den' or 'ubu', not plain proot-distro login."
  fi
}

# shellcheck disable=SC2088  # '~/projects' is display text in the cheat sheet
want_cli() { [[ " $CLI_EXTRAS " == *" $1 "* ]]; }

# shellcheck disable=SC2088
write_cheatsheet() {
  local f="$HOME/.config/tabden/cheatsheet.txt" B=$'\e[1;36m' R=$'\e[0m'
  h()  { printf '\n%s%s%s\n' "$B" "$1" "$R"; }
  l()  { printf '  %-22s %s\n' "$1" "$2"; }
  {
    printf '%stabden cheat sheet%s   den help, or Ctrl-a / in tmux. q closes.\n' "$B" "$R"

    h "The den session (den works in Termux and in Ubuntu)"
    l "den"            "open or return to the tmux session: claude, edit, shell"
    l "Ctrl-a d"       "detach: keeps running and keeps the tablet awake"
    l "den stop"       "end the session, release the wake lock$( [[ $AI_LOCAL != none ]] && echo ", stop the model")"
    l "den status"     "versions, project mount, git identity, tmux, memory"
    l "den help"       "this cheat sheet"
    l "ubu"            "plain Ubuntu shell (from Termux); 'exit' leaves it"

    h "tmux (prefix Ctrl-a)"
    l "1 2 3  n p"     "switch window / next / previous"
    l "c"              "new window"
    l "|  -"           "split side by side / top and bottom"
    l "h j k l  z"     "move between panes / zoom the current pane"
    l "d"              "detach; 'den' to return"
    l "[  q"           "scroll back (copy mode) / leave it"
    l "/"              "this cheat sheet"

    h "Maintenance"
    l "tabden update"  "Termux: update everything (Termux, this repo, Ubuntu)"
    l "tabden modify" "Termux: change your choices"
    l "tabden doctor" "Termux: check the device and the install"
    l "tabden theme NAME" "Termux: default, catppuccin-mocha, tokyonight, gruvbox-dark"
    l "den update"       "Ubuntu: Ubuntu-side updates only"
    l "free -h"        "memory headroom"

    if [[ $AI_CLAUDE == 1 ]]; then
      h "Claude Code"
      l "claude"             "start in the current folder"
      l "claude -c"          "continue the last session here"
      l "claude -r"          "pick a session to resume"
      l "Shift+Tab"          "cycle modes, including plan mode"
      l "Esc"                "interrupt Claude"
      l "/clear  /compact"   "fresh context / shrink context"
      l "/login"             "log in again"
    fi

    if [[ $IDE_HELIX == 1 ]]; then
      h "Helix (full guide: hx --tutor, or Space ? for commands)"
      l "hx ."               "open with the file picker"
      l "Space f  Space /"   "find file / search across files"
      l "i  a  Esc"          "insert before / after, back to normal mode"
      l "x  d  y  p"         "select line, delete, copy, paste"
      l "u  U"               "undo / redo"
      l ":w  :q  :wq"        "save / quit / both"
      [[ $IDE_ROSLYN == 1 ]] && l "gd  gr  Space a" "definition / references / code actions"
    fi

    if [[ $IDE_VSCODE == 1 ]]; then
      h "VS Code Server"
      l "vscode window"      "started by dev (Ctrl-a then its number)"
      [[ -s $TOKEN ]] && l "URL" "http://127.0.0.1:8080/?tkn=$(cat "$TOKEN")"
    fi

    h "Git and search"
    want_cli lazygit && l "lg"          "lazygit (? for keys)"
    want_cli delta   && l "git diff"    "shown through delta automatically"
    want_cli gh      && l "gh pr create" "open a PR (gh auth status to check login)"
    l "git-id"            "git identities by folder; git-id add <name> creates one"
    l "ws <name>"         "go to an identity's folder and switch gh to its account"
    l "z <name>"          "jump to a folder you've visited"
    l "Ctrl-R  Ctrl-T"    "fzf: search history / insert a file path"
    l "rg <text>"         "search file contents"
    l "bat <file>"        "view a file with highlighting"

    if [[ $DOCKER_REMOTE == 1 ]]; then
      h "Remote Docker"
      l "docker ps"          "runs on $DOCKER_SSH_HOST (context remote)"
      l "docker context ls"  "list contexts; 'docker context use default' leaves the VM"
    fi

    h "Projects"
    if [[ $PROJECTS_MODE == termux ]]; then
      l "~/projects"         "Termux folder mounted into Ubuntu; survives a guest reset"
    else
      l "~/projects"         "Ubuntu home; removed if the guest is reset"
    fi
    l "backup"               "push to a git remote: nothing survives uninstalling Termux"

    h "First time only"
    l "git-id default" "name and email for your commits"
    want_cli gh && l "gh auth login" "inside Ubuntu; open the printed URL yourself"
    [[ $AI_CLAUDE == 1 ]] && l "claude" "log in via the printed URL, then /exit"
  } > "$f"
}

write_dotfiles() {
  write_env && write_bashrc && write_tmux && write_scripts && write_git_id && write_cheatsheet && write_local_example || return 1
  # Roslyn deselected: drop the Helix LSP override so Helix doesn't try to start it.
  [[ $IDE_ROSLYN == 1 ]] || remove_block "$HOME/.config/helix/languages.toml"
  theme_helix
  theme_delta
}

# ----------------------------------------------------------------- modes ----
finish() {
  { echo "done"; (( ${#FAILED[@]} )) && printf '%s\n' "${FAILED[@]}"; } > "$RESULT"
  echo
  if (( ${#FAILED[@]} )); then
    printf '\033[1;31mFailed:\033[0m %s\n' "${FAILED[*]}"
  else
    printf '\033[1;32mAll steps completed.\033[0m\n'
  fi
  [[ -s $NOTES ]] && { echo; cat "$NOTES"; }
  return 0
}

do_install() {
  : > "$NOTES"; rm -f "$RESULT"
  seed_manifest
  do_removals
  run "Base packages" install_base
  run "Timezone" setup_timezone
  want_rt dotnet && run ".NET 10" install_dotnet
  want_rt rust   && run "Rust" install_rust
  want_rt bun    && run "Bun" install_bun
  want_rt node   && run "Node.js" install_node
  [[ $AI_CLAUDE == 1 ]]  && run "Claude Code" install_claude
  [[ $IDE_HELIX == 1 ]]  && run "Helix" install_helix
  [[ $IDE_ROSLYN == 1 ]] && run "Roslyn language server" install_roslyn
  [[ $IDE_VSCODE == 1 ]] && run "VS Code CLI" install_vscode
  local t
  for t in $CLI_EXTRAS; do
    if declare -F "install_$t" >/dev/null; then run "$t" "install_$t"; else FAILED+=("$t (unknown)"); fi
  done
  [[ $DOCKER_REMOTE == 1 ]] && run "Docker CLI (remote)" install_docker
  run "Project location" setup_projects
  run "Dotfiles and scripts" write_dotfiles
  [[ -n $(git config --global user.email 2>/dev/null) ]] ||
    note "Git: run 'git-id default' inside Ubuntu to set the name and email for your commits."
  finish
}

update_binaries() {
  has hx       && run "Helix"       install_helix force
  has lazygit  && run "lazygit"     install_lazygit force
  has code     && run "VS Code CLI" install_vscode force
  has starship && run "starship"    install_starship force
  return 0
}

apt_upgrade() { apt_get update && apt_get upgrade; }

do_update() {
  : > "$NOTES"; rm -f "$RESULT"
  seed_manifest
  run "apt upgrade" apt_upgrade
  run "Timezone" setup_timezone
  has rustup && run "Rust" rustup update
  has bun    && run "Bun" bun upgrade
  has claude && run "Claude Code" claude update
  [[ -x $HOME/.dotnet/dotnet ]] && run ".NET 10 (script install)" install_dotnet_script
  has roslyn-language-server && run "Roslyn language server" \
    dotnet tool update --global roslyn-language-server --prerelease
  update_binaries
  run "Dotfiles and scripts" write_dotfiles
  finish
}

do_update_binaries() {
  : > "$NOTES"; rm -f "$RESULT"
  update_binaries
  finish
}

do_dotfiles() {
  : > "$NOTES"; rm -f "$RESULT"
  run "Dotfiles and scripts" write_dotfiles
  # Only here: an install or update leaves a running session as it is.
  tmux list-sessions >/dev/null 2>&1 && run "Running tmux session" reload_tmux
  finish
  (( ${#FAILED[@]} == 0 ))
}

case "${1:---install}" in
  --install)         do_install ;;
  --update)          do_update ;;
  --update-binaries) do_update_binaries ;;
  --dotfiles)        do_dotfiles ;;
  -h|--help)         sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) echo "Unknown option: $1" >&2; exit 1 ;;
esac
