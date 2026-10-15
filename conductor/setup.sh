#!/usr/bin/env bash
set -e

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

site_name=$(site_name)

# Conductor copies .env* from the repo root; fall back to the example file.
if [[ ! -f .env ]]; then
    [[ -f .env.example ]] || { echo "No .env or .env.example in $PWD" >&2; exit 1; }
    cp .env.example .env
fi

# set_env KEY VALUE — replace the KEY= line in .env, or append it.
set_env() {
    if grep -q "^$1=" .env; then
        sed -i '' "s|^$1=.*|$1=$2|" .env
    else
        printf '\n%s=%s\n' "$1" "$2" >> .env
    fi
}

set_env APP_URL "https://${site_name}.test"

herd link "$site_name"
php=$(php_version)
if [[ -n "$php" ]]; then
    herd isolate "$php" --site="$site_name"
fi
herd secure "$site_name"
herd restart

herd composer install --no-interaction --prefer-dist --optimize-autoloader

# Keep the key copied from the root .env; only generate one when it's empty.
if ! grep -qE "^APP_KEY=[\"']?[^\"'[:space:]]" .env; then
    grep -q '^APP_KEY=' .env || set_env APP_KEY ""
    herd php artisan key:generate
fi

if [[ -f package.json ]]; then
    npm install
    # Vite apps build with `build`; Laravel Mix apps with a one-off `dev`.
    if jq -e '.scripts.build' package.json >/dev/null; then
        npm run build
    elif jq -e '.scripts.watch' package.json >/dev/null; then
        npm run dev
    fi
fi
