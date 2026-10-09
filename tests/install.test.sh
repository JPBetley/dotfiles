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
	# shellcheck disable=SC2088 # literal text in the error message
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
	run_install link
	local before
	before="$(snapshot; cat "$SANDBOX/.zshrc" "$SANDBOX/.zprofile")"
	run_install link
	assert_status 0
	assert_output_contains "Nothing to do"
	[ "$(snapshot; cat "$SANDBOX/.zshrc" "$SANDBOX/.zprofile")" = "$before" ] || fail "second run changed the sandbox"
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
