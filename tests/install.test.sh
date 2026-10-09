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
