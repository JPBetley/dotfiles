#!/usr/bin/env bash
set -e

npx concurrently -k \
    -n "queue,schedule,logs,vite" \
    -c "#93c5fd,#c4b5fd,#fb7185,#fdba74" \
    "herd php artisan queue:listen --tries=1 --timeout=0" \
    "herd php artisan schedule:work" \
    "herd php artisan pail --timeout=0" \
    "npm run dev"
