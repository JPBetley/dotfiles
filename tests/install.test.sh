#!/bin/bash
#
# End-to-end tests for ./install. Each test runs the real script with $HOME
# pointed at a throwaway sandbox whose .dotfiles is a symlink to this repo.
#
# Usage: tests/install.test.sh [test_name_filter]

REPO="$(cd "$(dirname "$0")/.." && pwd -P)"
failures=0
passes=0

# --- harness -----------------------------------------------------------------

# Fresh sandbox HOME with ~/.dotfiles -> repo. Sets $SANDBOX.
new_sandbox() {
	SANDBOX="$(mktemp -d)"
	SANDBOX="$(cd "$SANDBOX" && pwd -P)"
	ln -s "$REPO" "$SANDBOX/.dotfiles"
	install_fakes
}

# Like new_sandbox, but ~/.dotfiles is a directory of links to the repo with
# macos/set-defaults.sh replaced by a fake that only records that it ran (the
# real one needs sudo and can't be undone).
new_sandbox_with_fake_defaults() {
	SANDBOX="$(mktemp -d)"
	SANDBOX="$(cd "$SANDBOX" && pwd -P)"
	mkdir -p "$SANDBOX/.dotfiles/macos"
	local entry
	for entry in "$REPO"/* "$REPO"/.[!.]*; do
		case "$(basename "$entry")" in .git | macos) continue ;; esac
		ln -s "$entry" "$SANDBOX/.dotfiles/$(basename "$entry")"
	done
	printf '#!/bin/sh\ntouch "$HOME/defaults-ran"\n' > "$SANDBOX/.dotfiles/macos/set-defaults.sh"
	chmod +x "$SANDBOX/.dotfiles/macos/set-defaults.sh"
	install_fakes
}

# Fakes for the tools Provision drives, on a PATH without the real Homebrew.
# Each logs its arguments to ~/fakebin/<tool>.log; files in the sandbox steer them.
# A profile Brewfile is missing slack; the base one firefox and fzf. Cleanup
# reports arc and ack when ~/brew-extras exists, and slack when ~/slack-installed
# does and the Brewfile it was given doesn't list it.
FAKE_BREW='#!/bin/bash
echo "$*" >> "$HOME/fakebin/brew.log"
env | grep "^HOMEBREW_BUNDLE_.*CLEANUP" >> "$HOME/fakebin/brew.log"
for arg; do case "$arg" in --file=*) file="${arg#--file=}" ;; esac; done
case "$1 $2" in
	"bundle install")
		[ -e "$HOME/base-bundle-fails" ] && [ "${file#*/profiles/}" = "$file" ] && exit 1
		exit 0 ;;
	"bundle check")
		[ -e "$HOME/brew-satisfied" ] && exit 0
		echo "brew bundle can'"'"'t satisfy your Brewfile'"'"'s dependencies." >&2
		case "$file" in
			*/profiles/*) echo "→ Cask slack needs to be installed." >&2 ;;
			*)
				echo "→ Cask firefox needs to be installed." >&2
				echo "→ Formula fzf needs to be installed." >&2 ;;
		esac
		exit 1 ;;
	"bundle cleanup")
		casks="" formulae=""
		[ -e "$HOME/brew-extras" ] && casks="arc" formulae="ack"
		[ -e "$HOME/slack-installed" ] && ! grep -q "cask \"slack\"" "$file" && casks="$casks slack"
		[ -n "$casks$formulae" ] || exit 0
		printf "%s\n" "Would uninstall casks:" $casks
		[ -z "$formulae" ] || printf "%s\n" "Would uninstall formulae:" $formulae
		printf "%s\n" "Would \`brew cleanup\`:" "Would remove: $HOME/Library/Caches/Homebrew/old.tar.gz (1MB)" \
			"Run \`brew bundle cleanup --force\` to make these changes."
		exit 1 ;;
esac'
FAKE_XCODE_SELECT='#!/bin/bash
echo "$*" >> "$HOME/fakebin/xcode-select.log"
[ "$1" != -p ] || [ ! -e "$HOME/no-clt" ]'
# The Homebrew installer: curl hands bash a script that installs a fake brew
# at the off-PATH location Provision checks.
FAKE_CURL='#!/bin/bash
echo "$*" >> "$HOME/fakebin/curl.log"
echo "mkdir -p \"\$HOME/homebrew/bin\" && cp \"\$HOME/fakebin/brew-to-install\" \"\$HOME/homebrew/bin/brew\""'

add_fake() {
	printf '%s\n' "$2" > "$SANDBOX/fakebin/$1"
	chmod +x "$SANDBOX/fakebin/$1"
}

install_fakes() {
	mkdir -p "$SANDBOX/fakebin"
	add_fake brew "$FAKE_BREW"
	add_fake xcode-select "$FAKE_XCODE_SELECT"
	add_fake curl "$FAKE_CURL"
	add_fake brew-to-install "$FAKE_BREW"
	touch "$SANDBOX/brew-satisfied"
}

# Run install inside the sandbox. Sets $OUT (stdout+stderr) and $STATUS.
run_install() {
	OUT="$(cd "$SANDBOX" && HOME="$SANDBOX" PATH="$SANDBOX/fakebin:/usr/bin:/bin:/usr/sbin:/sbin" \
		DOTFILES_BREW_PATHS="$SANDBOX/homebrew/bin/brew" "$SANDBOX/.dotfiles/install" "$@" 2>&1)"
	STATUS=$?
}

# Snapshot of everything in the sandbox (except the repo link's contents),
# used to prove a run changed nothing.
snapshot() {
	(cd "$SANDBOX" && find . \( -path ./.dotfiles -o -path ./fakebin \) -prune -o -print0 | sort -z | xargs -0 ls -ld 2>/dev/null)
}

fail() {
	echo "    $*"
	test_failed=1
}

assert_status() {
	[ "$STATUS" -eq "$1" ] || fail "expected exit $1, got $STATUS. Output:"$'\n'"$OUT"
}

assert_output_contains() {
	case "$OUT" in
		*"$1"*) ;;
		*) fail "expected output to contain '$1'. Output:"$'\n'"$OUT" ;;
	esac
}

assert_output_not_contains() {
	case "$OUT" in
		*"$1"*) fail "expected output not to contain '$1'. Output:"$'\n'"$OUT" ;;
	esac
}

# assert_link <path relative to $HOME> <repo-relative target>
assert_link() {
	local path="$SANDBOX/$1" want="$SANDBOX/.dotfiles/$2"
	[ -L "$path" ] || { fail "expected ~/$1 to be a symlink"; return; }
	[ "$(readlink "$path")" = "$want" ] || fail "expected ~/$1 -> $want, got $(readlink "$path")"
}

assert_missing() {
	[ ! -e "$SANDBOX/$1" ] && [ ! -L "$SANDBOX/$1" ] || fail "expected ~/$1 not to exist"
}

# assert_file <path relative to $HOME> <expected contents, without final newline>
assert_file() {
	local path="$SANDBOX/$1"
	[ -f "$path" ] || { fail "expected ~/$1 to be a file"; return; }
	[ ! -L "$path" ] || { fail "expected ~/$1 not to be a symlink"; return; }
	local want
	want="$(printf '%s\n' "$2")"
	if [ "$(cat "$path"; echo x)" != "$want"$'\n'"x" ]; then
		fail "unexpected contents of ~/$1:"$'\n'"$(diff <(printf '%s\n' "$2") "$path")"
	fi
}

ZSHRC_LINE='source "$HOME/.dotfiles/shell/.zshrc" # dotfiles:link'
ZPROFILE_LINE='source "$HOME/.dotfiles/shell/.zprofile" # dotfiles:link'

GITCONFIG_LINE='[include] path = ~/.dotfiles/git/config # dotfiles:link'

# git as seen by the sandbox: its ~/.gitconfig, no system config.
sandbox_git() {
	(cd "$SANDBOX" && HOME="$SANDBOX" XDG_CONFIG_HOME="$SANDBOX/.config" GIT_CONFIG_NOSYSTEM=1 git "$@")
}

# --- tests -------------------------------------------------------------------

test_refuses_to_run_outside_home_dotfiles() {
	new_sandbox
	rm "$SANDBOX/.dotfiles"
	local elsewhere
	elsewhere="$(mktemp -d)"
	cp "$REPO/install" "$elsewhere/"
	OUT="$(HOME="$SANDBOX" "$elsewhere/install" link 2>&1)"
	STATUS=$?
	assert_status 1
	assert_output_contains "~/.dotfiles"
	assert_missing .vimrc
	rm -rf "$elsewhere"
}

test_link_links_vim_and_tmux_config() {
	new_sandbox
	run_install link
	assert_status 0
	assert_link .vimrc shell/.vimrc
	assert_link .vim shell/.vim
	assert_link .tmux.conf shell/.tmux.conf
}

test_link_links_starship_config_creating_dot_config() {
	new_sandbox
	run_install link
	assert_status 0
	assert_link .config/starship.toml shell/starship.toml
}

# A fake starship whose prompt is a fixed string.
FAKE_STARSHIP='#!/bin/bash
[ "$1 $2" = "init zsh" ] && echo "PROMPT=starship-prompt"'

test_new_shell_starts_with_starship_and_shell_options() {
	new_sandbox
	add_fake starship "$FAKE_STARSHIP"
	run_install link
	OUT="$(cd "$SANDBOX" && HOME="$SANDBOX" PATH="$SANDBOX/fakebin:/usr/bin:/bin" ZDOTDIR="$SANDBOX" \
		zsh -i -c 'print -r -- "prompt=$PROMPT"
			[[ -o sharehistory ]] && echo share_history
			[[ -o autocd ]] && echo auto_cd
			bindkey "^[[A"
			(( $+functions[compdef] )) && echo compinit
			alias "..."' 2>&1)"
	assert_output_contains "prompt=starship-prompt"
	assert_output_contains "share_history"
	assert_output_contains "auto_cd"
	assert_output_contains "up-line-or-beginning-search"
	assert_output_contains "compinit"
	assert_output_contains "...=../.."
	[ "$(printf '%s\n' "$OUT" | wc -l)" -eq 6 ] || fail "expected no other shell output"
}

test_repo_does_not_reference_the_old_prompt_setup() {
	local hits
	hits="$(cd "$REPO" && git grep -Iil -e 'oh-my-''zsh' -e 'agno''ster' -e 'DEFAULT_''USER')"
	[ -z "$hits" ] || fail "still referenced in: $hits"
}

test_t_is_executable() {
	[ -x "$REPO/bin/t" ] || fail "bin/t must be executable to be on the PATH"
}

test_second_link_run_changes_nothing() {
	new_sandbox
	run_install link
	local before
	before="$(snapshot)"
	run_install link
	assert_status 0
	assert_output_contains "Nothing to do"
	[ "$(snapshot)" = "$before" ] || fail "second run changed the sandbox"
}

test_conflicting_file_is_moved_to_backup() {
	new_sandbox
	echo "my old vimrc" > "$SANDBOX/.vimrc"
	run_install link
	assert_status 0
	assert_link .vimrc shell/.vimrc
	local backups
	backups=("$SANDBOX"/.dotfiles-backup/*/.vimrc)
	[ -f "${backups[0]}" ] || { fail "expected ~/.dotfiles-backup/<timestamp>/.vimrc"; return; }
	[ "$(cat "${backups[0]}")" = "my old vimrc" ] || fail "backup lost the original contents"
	assert_output_contains "backup"
}

test_wrong_symlink_is_replaced() {
	new_sandbox
	ln -s /nowhere "$SANDBOX/.tmux.conf"
	run_install link
	assert_status 0
	assert_link .tmux.conf shell/.tmux.conf
}

assert_dry_run_changes_nothing() {
	new_sandbox
	echo "my old vimrc" > "$SANDBOX/.vimrc"
	local before
	before="$(snapshot)"
	run_install "$@"
	assert_status 0
	[ "$(snapshot)" = "$before" ] || fail "dry run changed the sandbox"
	assert_output_contains "backup  ~/.vimrc -> ~/.dotfiles-backup/"
	assert_output_contains "link    ~/.tmux.conf"
}

test_dry_run_prints_plan_and_changes_nothing() {
	assert_dry_run_changes_nothing --dry-run
}

test_link_dry_run_prints_plan_and_changes_nothing() {
	assert_dry_run_changes_nothing link --dry-run
}

test_unknown_step_prints_usage() {
	new_sandbox
	run_install bogus
	assert_status 2
	assert_output_contains "Usage:"
	assert_missing .vimrc
}

test_link_creates_missing_stubs_with_only_the_managed_line() {
	new_sandbox
	run_install link
	assert_status 0
	assert_file .zshrc "$ZSHRC_LINE"
	assert_file .zprofile "$ZPROFILE_LINE"
}

HERD_BLOCKS='# Herd injected PHP binary.
export PATH="/Users/someone/Library/Application Support/Herd/bin/":$PATH


# Herd injected NVM configuration
export NVM_DIR="/Users/someone/Library/Application Support/Herd/config/nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"  # This loads nvm

alias k="kubectl"'

test_link_adopts_existing_unmarked_source_line_in_zshrc() {
	new_sandbox
	printf '%s\n' 'source $HOME/.dotfiles/shell/.zshrc' '' '' "$HERD_BLOCKS" > "$SANDBOX/.zshrc"
	run_install link
	assert_status 0
	assert_file .zshrc "$ZSHRC_LINE"$'\n\n\n'"$HERD_BLOCKS"
}

test_link_replaces_stale_marked_lines_with_one_managed_line() {
	new_sandbox
	printf '%s\n' 'source "$HOME/.dotfiles/shell/.old-zshrc" # dotfiles:link' "$HERD_BLOCKS" \
		'source "$HOME/.dotfiles/shell/.older-zshrc" # dotfiles:link' > "$SANDBOX/.zshrc"
	run_install link
	assert_status 0
	assert_file .zshrc "$ZSHRC_LINE"$'\n'"$HERD_BLOCKS"
}

test_link_adds_managed_line_to_stub_without_one() {
	new_sandbox
	printf '%s\n' "$HERD_BLOCKS" > "$SANDBOX/.zshrc"
	run_install link
	assert_status 0
	assert_file .zshrc "$ZSHRC_LINE"$'\n'"$HERD_BLOCKS"
}

test_link_leaves_one_brew_shellenv_in_zprofile() {
	new_sandbox
	local shellenv='eval "$(/opt/homebrew/bin/brew shellenv)"'
	printf '%s\n' "$shellenv" "$shellenv" "$shellenv" "$shellenv" > "$SANDBOX/.zprofile"
	run_install link
	assert_status 0
	assert_file .zprofile "$ZPROFILE_LINE"$'\n'"$shellenv"
}

# A sandbox shaped like this Mac before Stubs existed.
seed_legacy_stubs() {
	printf '%s\n' 'source $HOME/.dotfiles/shell/.zshrc' "$HERD_BLOCKS" > "$SANDBOX/.zshrc"
	local shellenv='eval "$(/opt/homebrew/bin/brew shellenv)"'
	printf '%s\n' "$shellenv" "$shellenv" > "$SANDBOX/.zprofile"
}

test_second_link_run_on_migrated_stubs_changes_nothing() {
	new_sandbox
	seed_legacy_stubs
	seed_legacy_git
	run_install link
	local before
	before="$(snapshot; cat "$SANDBOX/.zshrc" "$SANDBOX/.zprofile" "$SANDBOX/.gitconfig")"
	run_install link
	assert_status 0
	assert_output_contains "Nothing to do"
	[ "$(snapshot; cat "$SANDBOX/.zshrc" "$SANDBOX/.zprofile" "$SANDBOX/.gitconfig")" = "$before" ] || fail "second run changed the sandbox"
}

test_dry_run_shows_stub_edits_without_making_them() {
	new_sandbox
	seed_legacy_stubs
	local before
	before="$(cat "$SANDBOX/.zshrc" "$SANDBOX/.zprofile")"
	run_install link --dry-run
	assert_status 0
	assert_output_contains "stub    ~/.zshrc"
	assert_output_contains "stub    ~/.zprofile"
	[ "$(cat "$SANDBOX/.zshrc" "$SANDBOX/.zprofile")" = "$before" ] || fail "dry run edited a Stub"
}

test_symlinked_stub_is_backed_up_not_written_through() {
	new_sandbox
	local target
	target="$(mktemp)"
	echo "repo-owned zshrc" > "$target"
	ln -s "$target" "$SANDBOX/.zshrc"
	run_install link
	assert_status 0
	assert_file .zshrc "$ZSHRC_LINE"
	[ "$(cat "$target")" = "repo-owned zshrc" ] || fail "Link wrote through the symlink"
	[ -L "$(echo "$SANDBOX"/.dotfiles-backup/*/.zshrc)" ] || fail "expected the old symlink in a Backup"
	rm -f "$target"
}

test_install_notes_missing_custom_folder_at_the_end() {
	new_sandbox
	run_install --dry-run
	assert_status 0
	assert_output_contains "~/.dotfiles-custom"
	[ "$(printf '%s\n' "$OUT" | tail -1 | grep -c dotfiles-custom)" -eq 1 ] || fail "expected the note on the last line"
	assert_missing .dotfiles-custom
}

test_install_is_quiet_about_existing_custom_folder() {
	new_sandbox
	mkdir "$SANDBOX/.dotfiles-custom"
	run_install
	assert_status 0
	assert_output_not_contains "dotfiles-custom"
}

test_link_creates_gitconfig_stub_that_includes_repo_config() {
	new_sandbox
	run_install link
	assert_status 0
	assert_file .gitconfig "$GITCONFIG_LINE"
	[ "$(sandbox_git config --get pull.rebase)" = "true" ] || fail "repo git config not included"
	[ "$(sandbox_git config --get core.excludesfile)" = "~/.dotfiles/git/ignore" ] || fail "excludesfile should point at the repo ignore"
	sandbox_git config --get-regexp '^user\.' && fail "repo git config must not set [user]"
}

LEGACY_GITCONFIG='[core]
	excludesfile = ~/.gitignore
	autocrlf = input
[user]
	name = Some One
	email = someone@example.com
[pull]
	rebase = true'

seed_legacy_git() {
	printf '%s\n' "$LEGACY_GITCONFIG" > "$SANDBOX/.gitconfig"
	printf '%s\n' '.idea/' 'node_modules/' > "$SANDBOX/.gitignore"
	ln -s "$SANDBOX/.dotfiles/shell/.global-gitignore" "$SANDBOX/.global-gitignore"
}

test_link_adopts_legacy_gitconfig_keeping_only_user() {
	new_sandbox
	seed_legacy_git
	run_install link
	assert_status 0
	assert_file .gitconfig "$GITCONFIG_LINE"$'\n''[user]
	name = Some One
	email = someone@example.com'
	local backups
	backups=("$SANDBOX"/.dotfiles-backup/*/.gitconfig)
	[ "$(cat "${backups[0]}" 2>/dev/null)" = "$LEGACY_GITCONFIG" ] || fail "expected the old ~/.gitconfig in a Backup"
	[ "$(sandbox_git config --get core.excludesfile)" = "~/.dotfiles/git/ignore" ] || fail "old excludesfile still wins"
}

test_link_retires_old_global_ignore_files() {
	new_sandbox
	seed_legacy_git
	run_install link
	assert_status 0
	assert_missing .global-gitignore
	assert_missing .gitignore
	local backups
	backups=("$SANDBOX"/.dotfiles-backup/*/.gitignore)
	[ -f "${backups[0]}" ] || fail "expected the old ~/.gitignore in a Backup"
}

test_global_ignore_honours_both_former_lists() {
	new_sandbox
	run_install link
	sandbox_git init -q work
	local path
	# from the old ~/.gitignore, then from the old repo global-gitignore
	for path in .idea/x .phpunit.cache/x foo.swp .claude/settings.local.json \
		.foo.swo app.sublime-project .phpunit-watcher-cache.php sub/node_modules; do
		sandbox_git -C work check-ignore -q "$path" || fail "expected $path to be ignored"
	done
	sandbox_git -C work check-ignore -q src/app.php && fail "src/app.php should not be ignored"
}

test_plain_install_never_runs_defaults() {
	new_sandbox_with_fake_defaults
	run_install
	assert_status 0
	assert_missing defaults-ran
	assert_output_not_contains "defaults"
}

test_defaults_step_runs_the_defaults_script_only() {
	new_sandbox_with_fake_defaults
	run_install defaults
	assert_status 0
	[ -e "$SANDBOX/defaults-ran" ] || fail "expected the defaults script to run"
	assert_missing .vimrc
}

test_defaults_dry_run_changes_nothing() {
	new_sandbox_with_fake_defaults
	run_install defaults --dry-run
	assert_status 0
	assert_missing defaults-ran
	assert_output_contains "defaults  macos/set-defaults.sh"
}

test_link_adoption_keeps_machine_only_git_settings() {
	new_sandbox
	printf '%s\n' "$LEGACY_GITCONFIG" '[credential]' '	helper = osxkeychain' \
		'[url "git@github.com:"]' '	insteadOf = https://github.com/' > "$SANDBOX/.gitconfig"
	run_install link
	assert_status 0
	[ "$(sandbox_git config --get credential.helper)" = "osxkeychain" ] || fail "lost [credential]"
	[ "$(sandbox_git config --get url.git@github.com:.insteadof)" = "https://github.com/" ] || fail "lost [url]"
	[ "$(sandbox_git config --get user.name)" = "Some One" ] || fail "lost [user]"
	[ "$(sandbox_git config --get core.excludesfile)" = "~/.dotfiles/git/ignore" ] || fail "old excludesfile still wins"
	grep -q 'rebase\|autocrlf' "$SANDBOX/.gitconfig" && fail "settings the repo owns should leave the Stub"
	[ "$(head -1 "$SANDBOX/.gitconfig")" = "$GITCONFIG_LINE" ] || fail "Managed line should come first"
}

test_dry_run_shows_line_level_stub_changes() {
	new_sandbox
	seed_legacy_stubs
	seed_legacy_git
	run_install link --dry-run
	assert_status 0
	assert_output_contains '      - source $HOME/.dotfiles/shell/.zshrc'
	assert_output_contains "      + $ZSHRC_LINE"
	assert_output_contains '      - eval "$(/opt/homebrew/bin/brew shellenv)"'
	assert_output_contains "      + $GITCONFIG_LINE"
	assert_output_contains '      - 	excludesfile = ~/.gitignore'
	assert_output_not_contains '      - 	name = Some One'
}

# assert_logged <fake tool> <expected line in its log>
assert_logged() {
	grep -qxF -- "$2" "$SANDBOX/fakebin/$1.log" 2>/dev/null ||
		fail "expected $1 to be run with '$2'. Log:"$'\n'"$(cat "$SANDBOX/fakebin/$1.log" 2>/dev/null)"
}

assert_not_logged() {
	grep -qF -- "$2" "$SANDBOX/fakebin/$1.log" 2>/dev/null &&
		fail "expected $1 not to be run with '$2'"
}


test_brewfile_includes_what_the_shell_config_needs() {
	local pkg
	for pkg in tmux fzf starship; do
		grep -qx "brew \"$pkg\"" "$REPO/Brewfile" || fail "Brewfile is missing $pkg"
	done
}

test_provision_runs_brew_bundle_on_the_repo_brewfile() {
	new_sandbox
	rm "$SANDBOX/brew-satisfied"
	run_install provision
	assert_status 0
	assert_logged brew "bundle install --no-upgrade --file=$SANDBOX/.dotfiles/Brewfile"
	assert_output_contains "brew    bundle ~/.dotfiles/Brewfile"
	assert_output_contains "      + Cask firefox"
	assert_output_contains "      + Formula fzf"
	assert_output_not_contains "→"
	assert_missing .vimrc
}

test_provision_skips_brew_bundle_when_brewfile_is_satisfied() {
	new_sandbox
	run_install provision
	assert_status 0
	assert_not_logged brew "bundle install"
	assert_output_contains "Nothing to do"
}

test_provision_reports_unlisted_packages_and_uninstalls_nothing() {
	new_sandbox
	touch "$SANDBOX/brew-extras"
	run_install provision
	assert_status 0
	assert_output_contains "Installed but not in the Brewfile"
	assert_output_contains "  casks: arc"
	assert_output_contains "  formulae: ack"$'\n'
	assert_output_not_contains "Would"
	assert_output_not_contains "--force"
	assert_not_logged brew "--force"
	assert_not_logged brew "uninstall"
	assert_not_logged brew "--cleanup"
}

test_provision_ignores_cleanup_settings_from_the_environment() {
	new_sandbox
	rm "$SANDBOX/brew-satisfied"
	OUT="$(cd "$SANDBOX" && HOME="$SANDBOX" PATH="$SANDBOX/fakebin:/usr/bin:/bin:/usr/sbin:/sbin" \
		DOTFILES_BREW_PATHS="$SANDBOX/homebrew/bin/brew" HOMEBREW_BUNDLE_INSTALL_CLEANUP=1 \
		HOMEBREW_BUNDLE_FORCE_INSTALL_CLEANUP=1 "$SANDBOX/.dotfiles/install" provision 2>&1)"
	STATUS=$?
	assert_status 0
	assert_not_logged brew "CLEANUP"
}

test_provision_does_not_reinstall_homebrew() {
	new_sandbox
	run_install provision
	assert_status 0
	assert_missing fakebin/curl.log
	assert_output_not_contains "Homebrew"
}

test_provision_finds_homebrew_off_the_path() {
	new_sandbox
	mkdir -p "$SANDBOX/homebrew/bin"
	mv "$SANDBOX/fakebin/brew" "$SANDBOX/homebrew/bin/brew"
	rm "$SANDBOX/brew-satisfied"
	run_install provision
	assert_status 0
	assert_missing fakebin/curl.log
	assert_logged brew "bundle install --no-upgrade --file=$SANDBOX/.dotfiles/Brewfile"
}

test_provision_installs_missing_homebrew_then_bundles() {
	new_sandbox
	rm "$SANDBOX/fakebin/brew" "$SANDBOX/brew-satisfied"
	run_install provision
	assert_status 0
	assert_output_contains "install Homebrew"
	[ -x "$SANDBOX/homebrew/bin/brew" ] || fail "expected the Homebrew installer to run"
	assert_logged brew "bundle install --no-upgrade --file=$SANDBOX/.dotfiles/Brewfile"
}

test_provision_installs_missing_command_line_tools() {
	new_sandbox
	touch "$SANDBOX/no-clt"
	run_install provision
	assert_status 1
	assert_logged xcode-select "--install"
	assert_output_contains "rerun ./install"
	assert_not_logged brew "bundle install"
}

test_provision_leaves_installed_command_line_tools_alone() {
	new_sandbox
	run_install provision
	assert_not_logged xcode-select "--install"
}

test_provision_dry_run_shows_plan_and_changes_nothing() {
	new_sandbox
	touch "$SANDBOX/no-clt"
	rm "$SANDBOX/fakebin/brew" "$SANDBOX/brew-satisfied"
	local before
	before="$(snapshot)"
	run_install provision --dry-run
	assert_status 0
	[ "$(snapshot)" = "$before" ] || fail "dry run changed the sandbox"
	assert_missing fakebin/curl.log
	assert_not_logged xcode-select "--install"
	assert_output_contains "install Xcode Command Line Tools"
	assert_output_contains "install Homebrew"
	assert_output_contains "brew    bundle ~/.dotfiles/Brewfile"
}

test_provision_dry_run_lists_packages_it_would_install() {
	new_sandbox
	rm "$SANDBOX/brew-satisfied"
	run_install provision --dry-run
	assert_status 0
	assert_not_logged brew "bundle install"
	assert_output_contains "      + Formula fzf"
}

test_plain_install_runs_provision_then_link() {
	new_sandbox
	rm "$SANDBOX/brew-satisfied"
	run_install
	assert_status 0
	assert_logged brew "bundle install --no-upgrade --file=$SANDBOX/.dotfiles/Brewfile"
	assert_link .vimrc shell/.vimrc
	local bundle_at link_at
	bundle_at="$(printf '%s\n' "$OUT" | grep -n 'brew    bundle' | head -1 | cut -d: -f1)"
	link_at="$(printf '%s\n' "$OUT" | grep -n '^link ' | head -1 | cut -d: -f1)"
	[ -n "$bundle_at" ] && [ "$bundle_at" -lt "$link_at" ] || fail "expected provision before link"
}

# --- Profiles ----------------------------------------------------------------

test_profile_work_bundles_base_then_work_brewfile_and_saves_it() {
	new_sandbox
	rm "$SANDBOX/brew-satisfied"
	run_install provision --profile work
	assert_status 0
	assert_logged brew "bundle install --no-upgrade --file=$SANDBOX/.dotfiles/Brewfile"
	assert_logged brew "bundle install --no-upgrade --file=$SANDBOX/.dotfiles/profiles/work/Brewfile"
	assert_output_contains "brew    bundle ~/.dotfiles/profiles/work/Brewfile"$'\n'"      + Cask slack"
	local base_at work_at
	base_at="$(grep -n "file=$SANDBOX/.dotfiles/Brewfile" "$SANDBOX/fakebin/brew.log" | grep install | cut -d: -f1)"
	work_at="$(grep -n "profiles/work/Brewfile" "$SANDBOX/fakebin/brew.log" | grep install | cut -d: -f1)"
	[ "$base_at" -lt "$work_at" ] || fail "expected the base Brewfile before the profile's"
	assert_file .dotfiles-profile work
	assert_output_not_contains "no Profile"
}

test_plain_install_reuses_the_saved_profile() {
	new_sandbox
	echo work > "$SANDBOX/.dotfiles-profile"
	rm "$SANDBOX/brew-satisfied"
	run_install provision
	assert_status 0
	assert_logged brew "bundle install --no-upgrade --file=$SANDBOX/.dotfiles/profiles/work/Brewfile"
	assert_output_not_contains "no Profile"
}

test_second_run_with_saved_profile_installs_nothing() {
	new_sandbox
	rm "$SANDBOX/brew-satisfied"
	run_install --profile work
	touch "$SANDBOX/brew-satisfied"
	rm "$SANDBOX/fakebin/brew.log"
	run_install
	assert_status 0
	assert_output_contains "Nothing to do"
	assert_not_logged brew "bundle install"
	assert_file .dotfiles-profile work
}

test_switching_profile_reports_old_profile_packages_without_uninstalling() {
	new_sandbox
	echo work > "$SANDBOX/.dotfiles-profile"
	touch "$SANDBOX/slack-installed"
	run_install provision --profile personal
	assert_status 0
	assert_file .dotfiles-profile personal
	assert_output_contains "profile personal"
	assert_output_contains "Installed but not in the Brewfile or the personal Profile's"
	assert_output_contains "  casks: slack"
	assert_not_logged brew "uninstall"
	assert_not_logged brew "--force"
}

test_unlisted_report_compares_against_base_plus_profile() {
	new_sandbox
	echo work > "$SANDBOX/.dotfiles-profile"
	touch "$SANDBOX/slack-installed"
	run_install provision
	assert_status 0
	assert_output_not_contains "Installed but not"
	local file
	file="$(grep '^bundle cleanup' "$SANDBOX/fakebin/brew.log" | sed 's/.*--file=//')"
	[ ! -e "$file" ] || fail "left the combined Brewfile behind at $file"
}

test_profile_none_clears_the_saved_profile_and_notes_it() {
	new_sandbox
	echo work > "$SANDBOX/.dotfiles-profile"
	run_install provision --profile none
	assert_status 0
	assert_missing .dotfiles-profile
	assert_output_contains "profile none"
	assert_output_contains "Note: no Profile"
	assert_not_logged brew "profiles/"
}

test_no_profile_applies_base_only_and_prints_a_note() {
	new_sandbox
	rm "$SANDBOX/brew-satisfied"
	mkdir "$SANDBOX/.dotfiles-custom"
	run_install provision
	assert_status 0
	assert_not_logged brew "profiles/"
	assert_output_contains "Note: no Profile"
	assert_output_contains "--profile <name> (personal, work)"
}

test_unknown_profile_errors_and_lists_profiles() {
	new_sandbox
	run_install --profile wrok
	assert_status 2
	assert_output_contains "unknown profile 'wrok'"
	assert_output_contains "personal, work"
	assert_missing .dotfiles-profile
	assert_missing .vimrc
	assert_missing fakebin/brew.log
}

test_profile_must_be_a_folder_name() {
	new_sandbox
	local name
	for name in "" .. "work/.."; do
		run_install --profile "$name"
		assert_status 2
	done
	run_install --profile
	assert_status 2
	assert_missing .dotfiles-profile
}

test_saved_unknown_profile_errors() {
	new_sandbox
	echo gone > "$SANDBOX/.dotfiles-profile"
	run_install provision
	assert_status 2
	assert_output_contains "unknown profile 'gone'"
	assert_output_contains "--profile none"
}

test_dry_run_with_profile_shows_both_plans_and_saves_nothing() {
	new_sandbox
	rm "$SANDBOX/brew-satisfied"
	local before
	before="$(snapshot)"
	run_install --dry-run --profile work
	assert_status 0
	[ "$(snapshot)" = "$before" ] || fail "dry run changed the sandbox"
	assert_missing .dotfiles-profile
	assert_output_contains "profile work"
	assert_output_contains "brew    bundle ~/.dotfiles/Brewfile"
	assert_output_contains "brew    bundle ~/.dotfiles/profiles/work/Brewfile"
	assert_not_logged brew "bundle install"
}

test_dry_run_without_homebrew_lists_both_brewfiles() {
	new_sandbox
	rm "$SANDBOX/fakebin/brew"
	run_install provision --dry-run --profile=work
	assert_status 0
	assert_output_contains "brew    bundle ~/.dotfiles/Brewfile"
	assert_output_contains "brew    bundle ~/.dotfiles/profiles/work/Brewfile"
}

test_work_profile_lists_its_packages_and_trusts_its_taps() {
	local file="$REPO/profiles/work/Brewfile" pkg tap
	for pkg in 'cask "notion-calendar"' 'cask "docker-desktop"' 'cask "slack"' 'cask "zoom"' \
		'brew "kubernetes-cli"' 'brew "helm"' 'brew "k9s"' 'brew "kubeseal"' 'brew "kustomize"' \
		'brew "localstack"' 'brew "awscli-local"' 'brew "fluxcd/tap/flux"' 'brew "txn2/tap/kubefwd"' \
		'brew "common-fate/granted/granted"' 'brew "atlassian/acli/acli"'; do
		grep -qxF "$pkg" "$file" || fail "work Brewfile is missing $pkg"
	done
	for tap in $(cat "$REPO/Brewfile" "$REPO"/profiles/*/Brewfile | sed -n 's/^brew "\([^/"]*\/[^/"]*\)\/.*/\1/p' | sort -u); do
		grep -qxF "tap \"$tap\", trusted: true" "$file" || fail "tap $tap is not listed as trusted"
	done
	for pkg in notion-calendar docker-desktop; do
		grep -q "\"$pkg\"" "$REPO/Brewfile" && fail "$pkg belongs in the work profile, not the base"
	done
	for pkg in tableplus tailscale-app spotify; do
		grep -qxF "cask \"$pkg\"" "$REPO/Brewfile" || fail "base Brewfile is missing $pkg"
	done
}

test_failed_bundle_still_runs_the_rest_then_exits_non_zero() {
	new_sandbox
	rm "$SANDBOX/brew-satisfied"
	touch "$SANDBOX/base-bundle-fails"
	run_install --profile work
	assert_status 1
	assert_logged brew "bundle install --no-upgrade --file=$SANDBOX/.dotfiles/profiles/work/Brewfile"
	assert_link .vimrc shell/.vimrc
	assert_output_contains "brew bundle failed for: ~/.dotfiles/Brewfile"
	assert_output_not_contains "profiles/work/Brewfile (see above)"
}

# --- runner ------------------------------------------------------------------

for t in $(declare -F | awk '{print $3}' | grep '^test_' | grep -- "${1:-}"); do
	test_failed=0
	"$t"
	[ -n "$SANDBOX" ] && rm -rf "$SANDBOX"
	SANDBOX=""
	if [ "$test_failed" -eq 0 ]; then
		passes=$((passes + 1))
		echo "ok   $t"
	else
		failures=$((failures + 1))
		echo "FAIL $t"
	fi
done

echo
echo "$passes passed, $failures failed"
[ "$failures" -eq 0 ]
