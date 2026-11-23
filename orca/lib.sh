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

# local_databases <env file>... — the MySQL database names these files point at
# on this machine: each *DATABASE= value whose matching *HOST= (DB_DATABASE ->
# DB_HOST) is unset, localhost, 127.0.0.1 or a ${VAR} reference. SQLite paths
# and :memory: are skipped because they aren't plain names.
local_databases() {
    local f key value host
    for f in "$@"; do
        [[ -f "$f" ]] || continue
        while IFS='=' read -r key value; do
            value=$(printf '%s' "${value%%#*}" | tr -d "\"' \r")
            [[ "$value" =~ ^[A-Za-z0-9_-]+$ ]] || continue
            host=$(sed -nE "s/^${key/DATABASE/HOST}=[\"']?([^\"'[:space:]]*).*/\1/p" "$f" | tail -1)
            case "$host" in
                ''|localhost|127.0.0.1|'${'*) echo "$value" ;;
            esac
        done < <(grep -E '^[A-Z0-9_]*DATABASE[A-Z0-9_]*=' "$f")
    done | sort -u
}

# drop_workspace_databases <main checkout> — drop the local MySQL databases this
# workspace's .env* files use that the main checkout's don't, along with their
# parallel-testing copies (<name>_test_<n>). Databases the main checkout also
# uses are shared with every other workspace, so they're always kept. Skips the
# cleanup (without failing the archive) when it can't tell what's safe.
drop_workspace_databases() {
    local root=$1 ours shared existing db name
    if [[ -z "$root" || ! -d "$root" || "$root" -ef "$PWD" ]]; then
        echo "Skipping database cleanup: no main checkout to compare against"
        return 0
    fi
    if ! command -v mysql >/dev/null; then
        echo "Skipping database cleanup: mysql not found"
        return 0
    fi
    if ! existing=$(mysql -uroot -N -e 'SHOW DATABASES' 2>/dev/null); then
        echo "Skipping database cleanup: can't connect to the local MySQL"
        return 0
    fi

    ours=$(local_databases .env*)
    shared=$(local_databases "$root"/.env*)
    for db in $(comm -23 <(echo "$ours") <(echo "$shared")); do
        case "$db" in mysql|sys|information_schema|performance_schema) continue ;; esac
        for name in $(grep -xE "${db}(_test_[0-9]+)?" <<<"$existing"); do
            echo "Dropping database $name"
            mysql -uroot -e "DROP DATABASE \`$name\`"
        done
    done
}
