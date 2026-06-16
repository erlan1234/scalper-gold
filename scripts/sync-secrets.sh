#!/usr/bin/env bash
# Sync secrets from .env into MetaTrader 5's sandbox so the EA can read them.
# MQL5 file I/O is restricted to MQL5/Files, so the token lives in .env (the
# source of truth, gitignored) and gets copied here.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[ -f "$ROOT/.env" ] || { echo "No .env found. Copy .env.example to .env and fill it in."; exit 1; }
# shellcheck disable=SC1090
source "$ROOT/.env"

MT5_FILES="$HOME/Library/Application Support/net.metaquotes.wine.metatrader5/drive_c/Program Files/MetaTrader 5/MQL5/Files"
[ -d "$MT5_FILES" ] || { echo "MT5 Files folder not found: $MT5_FILES"; exit 1; }

printf '%s' "${TELEGRAM_TOKEN:-}" > "$MT5_FILES/gs_telegram_token.txt"
echo "Synced token -> $MT5_FILES/gs_telegram_token.txt"
echo "Restart the EA (or MT5) so it reloads the token."
