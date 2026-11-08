#!/usr/bin/env bash
# Cross-checks Forma's WHOOP 5.0 decoder against real payloads published by the goose project
# (github.com/b-nnett/goose @ ba9ae0280c9b5b9a1545baab8e944cb3b7563c62). Those files carry no license
# grant, so they are NOT copied into Forma: this script fetches them into a temporary directory at run
# time (developer machine, internet required) and compares Forma's decode to the expected values the
# goose sidecars document. Exit 0 = all match.
set -euo pipefail
cd "$(dirname "$0")/../FormaKit"
COMMIT=ba9ae0280c9b5b9a1545baab8e944cb3b7563c62
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
git clone --quiet https://github.com/b-nnett/goose.git "$WORK/goose"
git -C "$WORK/goose" checkout --quiet "$COMMIT"
F="$WORK/goose/Rust/core/fixtures/owned"
swift build --product forma-replay >/dev/null
BIN=.build/debug/forma-replay

fail=0
check() { # file, expected substring
  local out
  out=$("$BIN" --payload-hex "$F/$1")
  if grep -qF -- "$2" <<<"$out"; then echo "✔ $1: $2"; else echo "✘ $1: expected '$2'"; echo "$out" | sed 's/^/    /'; fail=1; fi
}
check history_complete_k24_normal_history_payload.hex "history K24 counter 1 t=1779000000"
check history_complete_k24_normal_history_payload.hex "HR-candidate 51 (unvalidated)"
check live_identity_k24_normal_history_payload.hex   "history K24 counter 3871 t=1779773861"
check live_identity_k24_normal_history_payload.hex   "HR-candidate 151 (unvalidated)"
check history_complete_k10_motion_payload.hex        "history K10 counter 101 t=1779039600"
check history_complete_k10_motion_payload.hex        "HR-candidate 135 (unvalidated) motion n=100"
check live_identity_k10_motion_payload.hex           "history K10 counter 3863 t=1779773851"
check history_complete_k21_motion_payload.hex        "history K21 counter 102 t=1779039600"
check live_identity_k21_motion_payload.hex           "history K21 counter 3861 t=1779773846"
check history_complete_temperature_level_event_payload.hex "event TEMPERATURE_LEVEL (17)"
exit $fail
