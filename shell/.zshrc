# Shared zsh config, pulled in by the Managed line in the ~/.zshrc Stub.
# Machine-local setup (Herd, etc.) lives in the Stub itself.

# Load the shell dotfiles, and then some:
# * ~/.dotfiles-custom can be used for other settings you don’t want to commit.
for file in "$HOME"/.dotfiles/shell/.{exports,aliases,functions}; do
	[ -r "$file" ] && [ -f "$file" ] && source "$file"
done
source "$HOME/.dotfiles/shell/.zsh-options"

for file in "$HOME"/.dotfiles-custom/shell/.{exports,aliases,functions,zshrc}; do
	[ -r "$file" ] && [ -f "$file" ] && source "$file"
done
unset file

# Sudoless npm https://github.com/sindresorhus/guides/blob/master/npm-global-without-sudo.md
# NPM_PACKAGES="${HOME}/.npm-packages"
# export PATH="$PATH:$NPM_PACKAGES/bin"
# # Preserve MANPATH if you already defined it somewhere in your config.
# # Otherwise, fall back to `manpath` so we can inherit from `/etc/manpath`.
# export MANPATH="${MANPATH-$(manpath)}:$NPM_PACKAGES/share/man"

export PATH=$HOME/.dotfiles/bin:$PATH
# [[ -e ~/.phpbrew/bashrc ]] && source ~/.phpbrew/bashrc

# Setup xdebug
export XDEBUG_CONFIG="idekey=VSCODE"

# Extra paths
export PATH="$HOME/.composer/vendor/bin:$PATH"
export PATH=/usr/local/bin:$PATH
export PATH=.:$PATH

# pnpm
export PNPM_HOME="$HOME/Library/pnpm"
export PATH="$PNPM_HOME:$PATH"

# bun completions
[ -s "$HOME/.bun/_bun" ] && source "$HOME/.bun/_bun"

# bun
export BUN_INSTALL="$HOME/.bun"
export PATH="$BUN_INSTALL/bin:$PATH"

# Prompt
command -v starship > /dev/null && eval "$(starship init zsh)"
