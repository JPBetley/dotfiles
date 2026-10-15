#!/usr/bin/env bash
set -e

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

site_name=$(site_name)

# Unsecure and unlink from Laravel Herd. Match the whole Site cell so
# bisnow-zagreb doesn't also match bisnow-zagreb-v1.
if herd links | grep -qE "^\|[[:space:]]*${site_name}[[:space:]]*\|"; then
    herd unsecure "$site_name" 2>/dev/null || true
    herd unlink "$site_name"
fi
