# Stubs, not symlinks, for files other tools write to

`~/.zshrc`, `~/.zprofile` and `~/.gitconfig` are edited by tools outside this repo (Herd injects PHP/nvm blocks, the Homebrew installer appends `shellenv`, `git config --global` writes settings). If Link symlinked them, those writes would land in the repo. So they are Stubs: machine-owned files where Link only guarantees one Managed line (marked `# dotfiles:link`) that sources or includes the repo's version, and leaves everything else alone. Every other linked file is a plain symlink.

## Considered Options

- **Symlink them like everything else**: rejected; tool writes dirty the repo and would be committed by accident or need constant reverting.
- **`ZDOTDIR` pointing at a repo directory**: rejected; Herd and Homebrew still write to `~/.zshrc`/`~/.zprofile`, which zsh would then silently stop reading, and it does nothing for `~/.gitconfig`.
- **A marked block (`# >>> dotfiles >>>` … `<<<`) instead of a single line**: rejected; each Stub only ever needs one line from the repo.

## Consequences

- Machine-specific config (Herd blocks, git `[user]` identity) lives in the Stubs and is never versioned.
- Link must edit files in place rather than just create symlinks, and must recognise the Managed line by its marker so renames don't leave stale lines.
