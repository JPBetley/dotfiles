#!/bin/bash
#
# Prune Node versions nvm no longer resolves to. Keeps, for each major, the
# newest installed version (what an `.nvmrc` of `22` or `v24`, and the `node`
# default, pick), plus the newest match for any more specific pin, e.g.
# `22.18.0` in an .nvmrc or a user nvm alias. Uninstalls the rest and clears
# nvm's download cache.
#
# Usage: prune.sh [--dry-run]
#
# NVM_DIR        nvm to prune (default: Herd's)
# NVM_PRUNE_ROOTS  space-separated folders searched for .nvmrc pins
#                  (default: ~/Code ~/orca/workspaces ~/Sites)
#
# Runs weekly from the dotfiles.nvm-prune launch agent; output is appended to
# ~/Library/Logs/nvm-prune.log.

set -euo pipefail

dry_run=0
[ "${1:-}" = "--dry-run" ] && dry_run=1

NVM_DIR="${NVM_DIR:-$HOME/Library/Application Support/Herd/config/nvm}"
roots="${NVM_PRUNE_ROOTS:-$HOME/Code $HOME/orca/workspaces $HOME/Sites}"

[ -s "$NVM_DIR/nvm.sh" ] || { echo "nvm-prune: no nvm at $NVM_DIR" >&2; exit 1; }
# --no-use: don't activate a version, so none of them is "in use" by this shell.
set +u
# shellcheck disable=SC1091
. "$NVM_DIR/nvm.sh" --no-use
set -u

# Installed versions without the leading v, oldest first.
installed() {
	local dir
	for dir in "$NVM_DIR"/versions/node/v*; do
		[ -d "$dir" ] && echo "${dir##*/v}"
	done | sort -t. -k1,1n -k2,2n -k3,3n
}

# Version pins (without v) that are more specific than a major: from .nvmrc
# files under $roots and from user aliases. Majors and names (node, lts/*)
# need no pin because the newest per major already covers them.
pins() {
	local root
	for root in $roots; do
		[ -d "$root" ] || continue
		find "$root" -maxdepth 5 \( -name node_modules -o -name vendor -o -name .git \) -prune \
			-o -name .nvmrc -type f -print 2>/dev/null | while read -r f; do head -1 "$f"; done
	done
	find "$NVM_DIR/alias" -maxdepth 1 -type f -exec head -1 {} \; 2>/dev/null
} 2>/dev/null

specific_pins() {
	pins | tr -d ' \r' | sed 's/^v//' | grep -E '^[0-9]+\.[0-9]+(\.[0-9]+)?$' | sort -u
}

all=$(installed)
[ -n "$all" ] || exit 0

keep=$(
	# Newest per major: the last of each major in the sorted list.
	echo "$all" | awk -F. '{last[$1]=$0} END {for (m in last) print last[m]}'
	for pin in $(specific_pins); do
		echo "$all" | grep -E "^${pin//./\\.}(\\.|$)" | tail -1 || true
	done
)

label="nvm-prune"
[ "$dry_run" -eq 0 ] || label="nvm-prune (dry run)"
echo "$(date '+%Y-%m-%d %H:%M') $label"
echo "keep:  $(echo "$keep" | sort -u -t. -k1,1n -k2,2n -k3,3n | sed 's/^/v/' | tr '\n' ' ')"
removed=0
for v in $all; do
	if ! echo "$keep" | grep -qxF "$v"; then
		removed=$((removed + 1))
		if [ "$dry_run" -eq 1 ]; then
			echo "would uninstall v$v"
		else
			nvm uninstall "v$v" >/dev/null && echo "uninstalled v$v"
		fi
	fi
done
[ "$removed" -gt 0 ] || echo "nothing to uninstall"
[ "$dry_run" -eq 1 ] || nvm cache clear >/dev/null
