#!/usr/bin/env bash
#
# Shared helpers for the Orca scripts. Orca runs the setup and archive hooks
# from the worktree with:
#   ORCA_ROOT_PATH       the main repo checkout
#   ORCA_WORKTREE_PATH   the worktree being created/archived
#   ORCA_WORKSPACE_NAME  the workspace name, usually derived from the branch
# Outside a hook (e.g. run.sh from a terminal) we fall back to the paths.
#
# Wire them up in Orca's repo settings → Hooks, or an app's orca.yaml:
#   scripts:
#     setup: ~/.dotfiles/orca/setup.sh
#     archive: ~/.dotfiles/orca/archive.sh

# Herd site name for this workspace, e.g. bisnow-api-moscow. Branch-style
# names like JPBetley/Fix_Thing become jpbetley-fix-thing so they're DNS-safe.
site_name() {
    local repo workspace
    repo=$(basename "${ORCA_ROOT_PATH:-$(dirname "$PWD")}" .dev)
    workspace=${ORCA_WORKSPACE_NAME:-$(basename "${ORCA_WORKTREE_PATH:-$PWD}")}
    echo "${repo}-${workspace}" |
        tr '[:upper:]' '[:lower:]' |
        sed -E 's/[^a-z0-9-]+/-/g; s/-+/-/g; s/^-//; s/-$//'
}

# PHP version to isolate the site to: herd.yml's `php:`, else the first X.Y in
# composer.json's PHP constraint (^8.4 -> 8.4). Prints nothing if neither has one.
php_version() {
    if [[ -f herd.yml ]]; then
        sed -nE "s/^php:[[:space:]]*['\"]?([0-9]+\.[0-9]+).*/\1/p" herd.yml | head -1
    elif [[ -f composer.json ]]; then
        jq -r '.require.php // empty' composer.json | grep -oE '[0-9]+\.[0-9]+' | head -1
    fi
}
