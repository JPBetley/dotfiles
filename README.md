# dotfiles

Shell and tool configuration for my Macs, plus `./install`, the one command that brings a machine in line with this repo. Install is safe to run any number of times: it only changes what's out of line, and `--dry-run` shows the plan first.

## New Mac

Clone over HTTPS, so no SSH key is needed yet, into `~/.dotfiles` (Install refuses to run from anywhere else):

```sh
git clone https://github.com/JPBetley/dotfiles.git ~/.dotfiles
~/.dotfiles/install --profile work   # or personal, or leave it out
```

On a brand-new Mac, the first `git` asks to install the Command Line Tools. Accept, wait for it to finish, then run the clone again. If they're still missing when Install runs, Install starts their installer and asks you to rerun it. Install also installs Homebrew if it isn't there.

Open a new terminal when it's done. Starship gives you the prompt, and no patched font is needed.

Optionally, once your SSH key is on GitHub, switch the remote to SSH:

```sh
git -C ~/.dotfiles remote set-url origin git@github.com:JPBetley/dotfiles.git
```

## Install

```sh
./install [step...] [--profile <name>] [--dry-run]
```

With no step, Install runs `provision` then `link`.

| Step | What it does |
| --- | --- |
| `provision` | Installs the Command Line Tools and Homebrew if missing, then runs `brew bundle` on the [`Brewfile`](Brewfile) and the Profile's Brewfile. It never uninstalls: installed packages missing from both are listed so you can add them or remove them yourself. |
| `link` | Wires repo files into `$HOME`: symlinks for files only this repo writes, and Stubs for files other tools also write (see below). Anything in the way is moved to a Backup in `~/.dotfiles-backup/<timestamp>/`, never deleted. |
| `defaults` | Runs [`macos/set-defaults.sh`](macos/set-defaults.sh). **Opt-in only**: it never runs unless you name it. It needs sudo, wipes the Dock, sets the timezone and changes hibernation, and none of it can be undone. |

`--dry-run` prints every change Install would make (packages to install, links, Backups, line-by-line Stub edits) and changes nothing.

### Profiles

A Profile is an optional named layer, `work` or `personal`, that a machine adds on top of the base config. It lives in [`profiles/<name>/`](profiles). Right now a Profile only adds a Brewfile.

- `./install --profile work` chooses it and remembers it in `~/.dotfiles-profile`, so a later plain `./install` uses it again.
- `./install --profile none` clears it. Without a Profile, Install applies only the base and prints a note saying so.
- Switching Profiles uninstalls nothing. Packages that only the old Profile listed show up in Provision's report.

## Stubs and the Custom folder

Most of what Link manages is a plain symlink into this repo. But `~/.zshrc`, `~/.zprofile` and `~/.gitconfig` are also written by other tools (Herd adds PHP and nvm blocks, the Homebrew installer adds `shellenv`, `git config --global` adds settings). Symlinked, those writes would land in the repo. So these files are **Stubs**: machine-owned files where Link only makes sure there is one **Managed line**, marked `# dotfiles:link`, that sources or includes the repo's version. Link leaves everything else in a Stub alone, so it stays **Machine-local**. That includes your git `[user]` identity, which belongs in the `~/.gitconfig` Stub. See [ADR 0001](docs/adr/0001-stubs-for-tool-written-files.md) for why.

The **Custom folder**, `~/.dotfiles-custom`, holds config and scripts you write yourself but keep out of git. The shell loads `~/.dotfiles-custom/shell/.exports`, `.aliases`, `.functions` and `.zshrc` if they exist. Install never creates or copies this folder; it only reminds you when it's missing.

The terms used here are defined in [`CONTEXT.md`](CONTEXT.md).

## Layout

| Path | Contents |
| --- | --- |
| `install` | The Install command |
| `Brewfile`, `profiles/` | Packages for Provision: the base, then each Profile's |
| `shell/` | zsh config, aliases and functions, Starship, vim and tmux config |
| `git/` | Shared git config and global ignore, included by the `~/.gitconfig` Stub |
| `bin/` | Scripts on the `PATH`, such as `t` (an fzf picker over `~/Code` that opens or switches tmux sessions) |
| `macos/` | The opt-in macOS defaults |
| `tests/install.test.sh` | End-to-end tests for Install, run in a throwaway `$HOME` with a fake `brew` |
