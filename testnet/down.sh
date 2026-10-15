#!/usr/bin/env bash
# Stops the nodes started by up.sh, keeping their state.
set -euo pipefail
DATA="${DATA:-$(cd "$(dirname "$0")" && pwd)/.data}"
for pidfile in "$DATA"/node*/pid; do
	[[ -f "$pidfile" ]] || continue
	kill "$(cat "$pidfile")" 2>/dev/null || true
	rm -f "$pidfile"
done
