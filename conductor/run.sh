#!/usr/bin/env bash
set -e

# Start only the processes this app uses; Herd serves the site itself.
names=() colors=() commands=()
add() { names+=("$1"); colors+=("$2"); commands+=("$3"); }

if [[ ! -f vendor/autoload.php ]]; then
    echo "No vendor/ in $PWD — run the setup script first." >&2
    exit 1
fi

# PHP warnings (e.g. deprecations) can land on stdout ahead of the JSON.
queue=$(herd php artisan about --only=drivers --json | grep '^{' | jq -r '.drivers.queue')
if [[ "$queue" != sync ]]; then
    add queue "#93c5fd" "herd php artisan queue:listen --tries=1 --timeout=0"
fi

if ! herd php artisan schedule:list | grep -q "No scheduled tasks"; then
    add schedule "#c4b5fd" "herd php artisan schedule:work"
fi

if [[ -d vendor/laravel/pail ]]; then
    add logs "#fb7185" "herd php artisan pail --timeout=0"
fi

if [[ -f package.json ]] && jq -e '.scripts.dev' package.json >/dev/null; then
    add vite "#fdba74" "npm run dev"
fi

if [[ ${#names[@]} -eq 0 ]]; then
    echo "Nothing to run — site is served by Herd at $(sed -n 's/^APP_URL=//p' .env)"
    exit 0
fi

join() { local IFS=,; echo "$*"; }

npx concurrently -k \
    -n "$(join "${names[@]}")" \
    -c "$(join "${colors[@]}")" \
    "${commands[@]}"
