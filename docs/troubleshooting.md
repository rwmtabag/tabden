# Troubleshooting

Start with `tabden doctor` in Termux: it checks the device, the install and Ubuntu in one go and marks what's wrong. Its report leaves out your username, git identity and timezone, so it's safe to paste into an issue.

| Symptom | Fix |
| --- | --- |
| Termux, tmux or Claude Code dies in the background | Android killed Termux. Follow your phone maker's steps on [dontkillmyapp.com](https://dontkillmyapp.com) for Termux, and start work with `den` (it takes a wake lock) |
| Processes die with "signal 9", Termux shows "[Process completed (signal 9)]", or a tmux window vanishes while idle | Android 12+'s phantom process killer. Run `tabden fix-phantom` in Termux for the steps for your Android version. A system update can reset the setting, so you may need to redo it |
| Battery drains after you've stopped working | A session or wake lock is still on. Run `den stop` (Termux or Ubuntu); detaching with Ctrl-a d keeps both on by design |
| Installer stops with "a new install needs at least 4 GB" | Free some space. For a small custom selection that fits anyway, run again with `--skip-preflight` |
| Installer stops with "Can't reach github.com" | Check the connection (a VPN or captive portal can block it). If GitHub really is reachable, run again with `--skip-preflight` |
| The installer's last screen lists "next steps" | Not failures: the one-time steps to run inside Ubuntu, `gh auth login`, `claude` and `git-id default` |
| `git commit` says "Please tell me who you are" | No name and email set. Run `git-id default` in Ubuntu |
| A commit has the wrong name or email | The repo isn't under that identity's folder. `git-id` lists the folders and marks the identity for the current one; move the repo, or `git-id add <name> --dir <folder>`. Fix the last commit with `git commit --amend --reset-author` |
| `git push` says "Repository not found" or 403 in an identity's folder | The folder's GitHub account can't see the repo. `git-id` shows which account the folder uses and whether it's logged in; `gh auth login` adds a missing one |
| `gh pr create` or `gh repo clone` uses the wrong GitHub account | `gh` has one active account for all windows. `ws <name>` switches it to that identity's account |
| `git pull` in Termux asks for a username | `gh` was set up before git was installed. Run `pkg install git` then `gh auth setup-git` |
| `git pull` in Termux refuses to merge after the repo history was rewritten | Re-clone: `cd ~ && rm -rf tabden && git clone https://github.com/rwmtabag/tabden ~/tabden` (only if you have no local changes there) |
| `~/projects` is empty inside Ubuntu | You entered without the mount. Exit and use `den` or `ubu`; `den status` confirms |
| git reports "dubious ownership" in `~/projects` | `git config --global --add safe.directory "$HOME/projects/*"` (the installer normally sets this) |
| `ubu` seems to do nothing | You are in Ubuntu: the prompt starts with `ubuntu` in cyan |
| `den` says you're already in the den session | You ran it inside tmux. Ctrl-a d detaches; `den stop` ends the session |
| `tabden: command not found` | It's added on first install. From your clone: `git pull && bash launcher.sh update` |
| .NET fails with memory or GC errors | Check `echo $DOTNET_GCHeapHardLimit` prints `1C0000000`; open a new shell |
| `dotnet-sdk-10.0` not found in apt | Expected on some Ubuntu releases; the installer falls back to `dotnet-install.sh` |
| `claude: command not found` | Check `~/.local/bin` is on `PATH`; run `hash -r` |
| Claude Code killed partway through a task | Android's low-memory killer: stop the local model, VS Code Server or Roslyn LS, then retry |
| Clock or `date` is hours off in Ubuntu | Timezone not applied. Run `tabden modify` and check the Timezone line on the summary screen |
| Helix ESC feels slow in tmux | The managed `~/.tmux.conf` sets `escape-time 10`; if you changed it, `tmux source ~/.tmux.conf` |
| `hx --health c-sharp` shows an LSP error | `roslyn-language-server` is prerelease; check `roslyn-language-server --help` for changed flags |
| After `tabden theme`, Helix or `bat` still show the old colours | Shells that were already open keep their old settings. `den stop`, then `den` |
| Helix shows its default theme instead of the chosen one | Helix was started from a shell opened before the switch. `den stop`, then `den`; `echo $COLORTERM` should then print `truecolor` |
| The terminal's colours didn't change with a theme | You have your own `~/.termux/colors.properties`, which tabden leaves alone. Move it away and run `tabden theme NAME` again |
| Symbols show as `_` inside the den session (Claude Code's bullets, delta's `Δ`, lazygit's arrows) | Ubuntu had no UTF-8 locale, so tmux replaced them. `tabden update`, then `den stop` and `den`; `echo $LANG` should print `C.UTF-8` |
| The Summary says "free now: unknown" | The free space couldn't be read, so the 4 GB check is skipped; installing still works. `tabden update` brings the fix for devices whose `df` has no `-m` option. Otherwise, send the output of `df -Pk "$HOME"` with a bug report |
| Prompt is slow or hangs with Starship | See the [proot-safe profile](customization.md#starship-proot-safe-profile); deselect starship if it persists |
| VS Code page refuses the connection | Open the URL including `?tkn=`; `den help` shows it |
| `docker` can't reach the host | Check the host is reachable (VPN connected, if you use one) and `ssh <user>@<host>` works without a password prompt |
| `den` shows an old window layout | `den stop`, then `den` |
| Install fails with "container ubuntu already exists", or the installer says the Ubuntu guest won't start | A previous removal didn't finish. Check `proot-distro ps` for running sessions (`proot-distro kill ubuntu` stops them), then `proot-distro remove ubuntu` and run the installer again. This deletes everything inside Ubuntu |

Logs: `~/.cache/tabden/termux.log` in Termux, `~/.cache/tabden/install.log` in Ubuntu.
