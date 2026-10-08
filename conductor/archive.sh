#!/usr/bin/env bash
set -e

# Derive site name (same logic as setup.sh)
branch=$(basename "$PWD")
site=$(basename "$(dirname "$PWD")" .dev)
site_name="${site}-${branch}"

# Unsecure and unlink from Laravel Herd
if herd links | grep -q "$site_name"; then
    herd unsecure "$site_name" 2>/dev/null || true
    herd unlink "$site_name"
fi
