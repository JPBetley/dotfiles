#!/usr/bin/env bash
#
# Shared helpers for the Conductor scripts. Sourced from the workspace
# directory, which Conductor lays out as <workspaces>/<repo>/<workspace>.

# Herd site name for this workspace, e.g. bisnow-api-moscow.
site_name() {
    echo "$(basename "$(dirname "$PWD")" .dev)-$(basename "$PWD")"
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
