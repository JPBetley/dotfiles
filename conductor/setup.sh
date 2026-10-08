#!/usr/bin/env bash
set -e

# Load env values (DB credentials, etc.) for use later in this script
set -a && source .env && set +a

branch=$(basename "$PWD")
site=$(basename "$(dirname "$PWD")" .dev)
site_name="${site}-${branch}"

sed -i '' "s|^APP_URL=.*|APP_URL=https://${site_name}.test|" .env

herd link "$site_name"
herd isolate 8.5 --site="$site_name"
herd secure "$site_name"
herd restart

herd composer install --no-interaction --prefer-dist --optimize-autoloader

herd php artisan key:generate

npm install
npm run build
