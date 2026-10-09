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
}

# Run install inside the sandbox. Sets $OUT (stdout+stderr) and $STATUS.
run_install() {
	OUT="$(cd "$SANDBOX" && HOME="$SANDBOX" "$SANDBOX/.dotfiles/install" "$@" 2>&1)"
	STATUS=$?
}

# Snapshot of everything in the sandbox (except the repo link's contents),
# used to prove a run changed nothing.
snapshot() {
	(cd "$SANDBOX" && find . -path ./.dotfiles -prune -o -print0 | sort -z | xargs -0 ls -ld 2>/dev/null)
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
