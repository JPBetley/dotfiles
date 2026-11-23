#!/bin/bash
#
# Tests for nvm/prune.sh. Each test runs the real script against a throwaway
# NVM_DIR whose versions/node/ holds empty version folders and whose nvm.sh
# defines a fake `nvm` that logs its arguments to $NVM_DIR/nvm.log.
#
# Usage: tests/nvm-prune.test.sh [test_name_filter]

REPO="$(cd "$(dirname "$0")/.." && pwd -P)"
failures=0
passes=0

# --- harness -----------------------------------------------------------------

# new_nvm <version>... — fresh sandbox with these versions installed.
new_nvm() {
	SANDBOX="$(mktemp -d)"
	NVM="$SANDBOX/nvm"
	PROJECTS="$SANDBOX/projects"
	mkdir -p "$NVM/alias" "$PROJECTS"
	cat > "$NVM/nvm.sh" <<'NVM'
nvm() {
	echo "$*" >> "$NVM_DIR/nvm.log"
	[ "$1" = uninstall ] && rm -rf "$NVM_DIR/versions/node/$2"
	return 0
}
NVM
	local v
	for v in "$@"; do mkdir -p "$NVM/versions/node/v$v"; done
}

# pin <project> <.nvmrc contents>
pin() {
	mkdir -p "$PROJECTS/$1"
	printf '%s\n' "$2" > "$PROJECTS/$1/.nvmrc"
}

# run_prune [args]. Sets $OUT and $STATUS.
run_prune() {
	OUT="$(HOME="$SANDBOX" NVM_DIR="$NVM" NVM_PRUNE_ROOTS="$PROJECTS" bash "$REPO/nvm/prune.sh" "$@" 2>&1)"
	STATUS=$?
}

fail() {
	echo "    $*"
	test_failed=1
}

assert_status() {
	[ "$STATUS" -eq "$1" ] || fail "expected exit $1, got $STATUS. Output:"$'\n'"$OUT"
}

assert_kept() {
	local v
	for v in "$@"; do
		[ -d "$NVM/versions/node/v$v" ] || fail "expected v$v to be kept. Output:"$'\n'"$OUT"
	done
}

assert_removed() {
	local v
	for v in "$@"; do
		[ ! -d "$NVM/versions/node/v$v" ] || fail "expected v$v to be uninstalled. Output:"$'\n'"$OUT"
	done
}

assert_nvm_not_called_with() {
	grep -qF -- "$1" "$NVM/nvm.log" 2>/dev/null && fail "expected nvm not to be run with '$1'"
}

# --- tests -------------------------------------------------------------------

test_keeps_the_newest_version_of_each_major() {
	new_nvm 16.20.2 22.9.0 22.10.0 22.23.4 22.23.5 24.16.0 24.22.3
	run_prune
	assert_status 0
	assert_kept 16.20.2 22.23.5 24.22.3
	assert_removed 22.9.0 22.10.0 22.23.4 24.16.0
}

test_sorts_versions_numerically_not_alphabetically() {
	new_nvm 22.9.0 22.10.0
	run_prune
	assert_status 0
	assert_kept 22.10.0
	assert_removed 22.9.0
}

test_keeps_an_exact_nvmrc_pin() {
	new_nvm 22.18.0 22.19.0 22.23.5
	pin storyblok-plugin 22.18.0
	run_prune
	assert_status 0
	assert_kept 22.18.0 22.23.5
	assert_removed 22.19.0
}

test_keeps_the_newest_match_for_a_minor_pin() {
	new_nvm 22.17.0 22.17.1 22.23.5
	pin app v22.17
	run_prune
	assert_status 0
	assert_kept 22.17.1 22.23.5
	assert_removed 22.17.0
}

test_major_pins_need_nothing_extra() {
	new_nvm 22.22.0 22.23.5
	pin app v22
	run_prune
	assert_status 0
	assert_kept 22.23.5
	assert_removed 22.22.0
}

test_keeps_a_version_a_user_alias_points_at() {
	new_nvm 20.10.0 20.20.2
	echo 20.10.0 > "$NVM/alias/legacy"
	echo node > "$NVM/alias/default"
	run_prune
	assert_status 0
	assert_kept 20.10.0 20.20.2
}

test_dry_run_changes_nothing() {
	new_nvm 22.9.0 22.23.5
	run_prune --dry-run
	assert_status 0
	assert_kept 22.9.0 22.23.5
	assert_nvm_not_called_with uninstall
	assert_nvm_not_called_with cache
	case "$OUT" in *"would uninstall v22.9.0"*) ;; *) fail "expected the dry run to list v22.9.0. Output:"$'\n'"$OUT" ;; esac
}

test_clears_the_download_cache() {
	new_nvm 22.23.5
	run_prune
	assert_status 0
	grep -qxF "cache clear" "$NVM/nvm.log" || fail "expected nvm cache clear"
}

test_fails_without_nvm() {
	new_nvm 22.23.5
	rm "$NVM/nvm.sh"
	run_prune
	assert_status 1
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
