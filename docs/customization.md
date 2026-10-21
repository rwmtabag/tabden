# Customization

## CLI extras

The lean set is tuned for reviewing Claude Code's diffs in a terminal. The always-installed tools are a few megabytes in total and are what make Ctrl-R history search, `z` and fast search work, so they aren't optional.

| Tool | Default | Source | Why |
| --- | --- | --- | --- |
| tmux | Always | apt | Persistent sessions and panes |
| fzf | Always | apt | History (Ctrl-R) and file search (Ctrl-T) |
| ripgrep | Always | apt | Fast search |
| zoxide | Always | apt | `z <name>` jumps to visited folders |
| bat | Always | apt | Highlighted file viewer; the binary is `batcat` on Ubuntu, aliased to `bat` |
| lazygit | On | GitHub release | Git TUI (`lg`); uses delta for diffs |
| git-delta | On | apt | Readable diffs, set as git's pager. The package is `git-delta`, the command is `delta` |
| gh | On | apt | GitHub CLI; Claude Code can use it to open PRs and read issues |
| eza | Off | apt | Cosmetic `ls` replacement; icons need a Nerd Font in Termux |
| starship | Off | install script | Fancier prompt; slower under proot (see below) |
| btop | Off | apt | Android hides most of `/proc`, so it shows little |

Change the selection with `tabden modify`. Deselecting a tool removes its aliases and prompt setup, and the wizard offers to uninstall it if tabden installed it (see [Removing components](guide.md#removing-components)).

## Themes

By default tabden sets no colours: Termux keeps its own palette and nothing below is written. A theme changes the terminal's palette and points the tools at it.

| Theme | Name to use | Palette from |
| --- | --- | --- |
| Catppuccin Mocha | `catppuccin-mocha` | [catppuccin/termux](https://github.com/catppuccin/termux) |
| Tokyo Night | `tokyonight` | [folke/tokyonight.nvim](https://github.com/folke/tokyonight.nvim) (`extras/termux`) |
| Gruvbox dark | `gruvbox-dark` | [morhetz/gruvbox](https://github.com/morhetz/gruvbox) |

Pick one on the **Theme** screen of the Custom wizard (after CLI extras), or at any time from Termux:

```bash
tabden theme tokyonight
tabden theme default      # back to no theme
```

`tabden theme` saves the choice, applies the palette and rewrites the Ubuntu dotfiles. It installs and updates nothing, so it takes a few seconds and works offline. The terminal's colours and the tmux bar change at once; `bat` and Helix follow in new shells, so run `den stop` then `den` for a clean switch. Lean doesn't ask about a theme, and choosing Lean on an existing install returns to no theme, like every other choice.

What a theme changes:

| Where | What |
| --- | --- |
| Termux | `~/.termux/colors.properties`: background, foreground, cursor and the 16 colours. The first line is `# written by tabden: theme <name>` |
| tmux | Status bar, current window and active pane border use the palette, with one accent colour per theme |
| bat | `BAT_THEME=ansi` in `env.sh`, so highlighting uses the terminal's 16 colours |
| delta | `delta.syntax-theme = ansi` in your git config. The red and green line backgrounds stay delta's own |
| Helix | `theme = "catppuccin_mocha"`, `"tokyonight"` or `"gruvbox"` (Helix's built-in themes) in a tabden block at the top of `~/.config/helix/config.toml` |
| Helix, in tmux | `COLORTERM=truecolor` if it isn't set, and tmux is told the terminal has 24-bit colour; Helix needs both to draw its theme |

The prompt, Starship, lazygit and eza already use the terminal's 16 colours, so they follow the palette without any setting. VS Code Server and Claude Code keep their own theme settings.

In Gruvbox dark the tmux bar has the same colour as the background (Gruvbox's black is its background), so it shows as text without a band. To give it one, put `set -g status-style bg=colour237,fg=colour7` in `local.tmux.conf`.

What tabden leaves alone:

- **Your own `~/.termux/colors.properties`** (one without tabden's first line). The last screen says so, and the rest of the theme still applies. To use tabden's palette, move the file away and run `tabden theme NAME` again.
- **A theme you set in Helix yourself.** If `config.toml` has its own `theme =` line, tabden doesn't add a second one and leaves a note.
- **A delta syntax theme you chose.** `delta.syntax-theme` is set only when it's empty.

To override one part of a theme, use the [local files](#local-overrides): `export BAT_THEME=...` in `local.sh`, or tmux `set` lines in `local.tmux.conf`. Both load after tabden's settings.

`tabden theme default` undoes all of it: it deletes `colors.properties` (only if tabden wrote it), removes the Helix block (and `config.toml` itself if nothing else is in it), unsets delta's syntax theme while it's still `ansi`, and restores the plain tmux bar.

## Starship: proot-safe profile

The built-in prompt stays the default. Starship starts at least one process per prompt, which is noticeably slower under proot, and its language-version modules can hang Termux ([starship#6151](https://github.com/starship/starship/issues/6151), unresolved upstream at the time of writing).

Selecting starship writes this config to `~/.config/starship.toml`. If you already have your own `starship.toml`, it's kept and the installer leaves a note instead.

```toml
# ~/.config/starship.toml (written by tabden)
add_newline = false
command_timeout = 300
scan_timeout = 10
# No username in the prompt: "ubuntu ~/projects $". To show yours, see
# ~/.config/tabden/local.sh.example.
format = "[ubuntu](bold cyan) $directory$git_branch$character"

[directory]
truncation_length = 3
```

- The explicit `format` lists only cheap modules, so language-version modules (nodejs, python, rust, dotnet) never run their `--version` commands.
- `command_timeout` caps any command a module still runs.
- `git_status` is left out. It runs `git status` on every prompt, which measured above 50 ms under proot on a MatePad 11.5S. `git_branch` reads the branch without starting git. Add `$git_status` back to `format` if you want the modified/ahead markers and the delay is acceptable on your device.

The managed `.bashrc` block also sets the workaround for the Termux hang before Starship starts:

```bash
export STARSHIP_NUM_THREADS=1
eval "$(starship init bash)"
```

Check the cost with `starship timings` inside a repo. If the prompt still lags, deselect starship with `tabden modify` and the built-in prompt comes back.

## Putting your username back in the prompt

Both prompts show `ubuntu ~/projects $` and leave your username out, so a screenshot or recording doesn't give it away. To show it, add to `~/.config/tabden/local.sh` in Ubuntu:

```bash
PS1='\[\e[1;36m\]\u@ubuntu\[\e[0m\] \[\e[32m\]\w\[\e[33m\]$(__git_br)\[\e[0m\] \$ '
```

With Starship, `local.sh` points Starship at your own copy of the profile, so tabden's rewrites don't touch it:

```bash
# once: cp ~/.config/starship.toml ~/.config/my-starship.toml
export STARSHIP_CONFIG=~/.config/my-starship.toml
```

In the copy, replace the `format` line with:

```toml
format = "$username$directory$git_branch$character"

[username]
show_always = true
format = "[$user@ubuntu](bold cyan) "
```

The same lines are in `~/.config/tabden/local.sh.example`.

## Local overrides

Put your own settings in these files. tabden loads them last, so they override its settings, and it never creates, edits or deletes them.

| File | Where | Loaded |
| --- | --- | --- |
| `~/.config/tabden/local.sh` | Ubuntu | At the end of tabden's `~/.bashrc` block: tmux windows and `ubu` shells |
| `~/.config/tabden/local.tmux.conf` | Ubuntu | At the end of tabden's `~/.tmux.conf` block |
| `~/.config/tabden/local.sh` | Termux | At the end of tabden's `~/.bashrc` block in Termux |

Termux and Ubuntu each have their own home folder, so these are two separate `local.sh` files. Each side has a `local.sh.example` next to it to copy from:

```bash
cp ~/.config/tabden/local.sh.example ~/.config/tabden/local.sh
```

For example, in Ubuntu's `local.sh`:

```bash
alias gs='git status -sb'
export EDITOR=nano
```

and in `local.tmux.conf`:

```
set -g status-position top
set -g history-limit 50000
```

Open a new shell to pick up `local.sh`; for tmux, run `tmux source ~/.tmux.conf` or restart the session with `den stop` then `den`.

- `local.sh` is read by interactive shells only. A one-off `ubu <command>` doesn't load it.
- `tabden uninstall` copies these files to `~/tabden-local-backup/` (in `termux/` and `ubuntu/` subfolders) before it removes the folders they live in, and tells you where they went. Copy them back after reinstalling.

### What tabden owns

tabden rewrites the lines between `# >>> tabden >>>` and `# <<< tabden <<<` in `~/.bashrc` (Termux and Ubuntu), `~/.profile` and `~/.tmux.conf` (Ubuntu), plus `~/.config/tabden/env.sh` and `local.sh.example`, on every install and update. With a [theme](#themes) it also owns a block at the top of Helix's `config.toml` and a `~/.termux/colors.properties` that carries its first-line mark. Anything outside those markers is left alone, but the local files above are the safer place: they load after tabden's settings wherever the block sits in the file.
