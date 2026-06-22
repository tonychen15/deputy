#!/usr/bin/env bash
# tests/test_streamjson.sh — #66: dual-mode _detect_outcome (stream-json result event vs the
# old rc check) and the shared _render_stream helper.
source "$(dirname "$0")/lib.sh"

det() { DEPUTY_ROOT="$(mktemp -d)" DEPUTY_ALLOW_ANY_BRANCH=1 bash "$DEPUTY" detect claude "$1" "$2" 2>/dev/null; }

# stream-json: success result, rc=0 -> ok
L="$(mktemp)"; printf '%s\n' '{"type":"system","subtype":"init"}' '{"type":"result","subtype":"success","is_error":false,"result":"done"}' > "$L"
assert_eq "$(det 0 "$L")" "ok" "stream-json: result is_error=false, rc=0 -> ok"

# stream-json: is_error=true EVEN WITH rc=0 + quota text -> quota_exhausted (not falsely ok)
L="$(mktemp)"; printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"hit your usage limit"}]}}' '{"type":"result","subtype":"error","is_error":true}' > "$L"
assert_eq "$(det 0 "$L")" "quota_exhausted" "stream-json: is_error=true (rc=0) + quota text -> quota_exhausted"

# stream-json: is_error=true, generic error -> hard_error
L="$(mktemp)"; printf '%s\n' '{"type":"result","subtype":"error","is_error":true}' > "$L"
assert_eq "$(det 0 "$L")" "hard_error" "stream-json: is_error=true generic -> hard_error"

# plain-text (old/mock) log: rc=1 + quota -> quota_exhausted (unchanged dual-mode fallback)
L="$(mktemp)"; printf 'You have hit your limit; resets 11pm\n' > "$L"
assert_eq "$(det 1 "$L")" "quota_exhausted" "plain-text: rc=1 + quota -> quota_exhausted (unchanged)"

# plain-text: rc=0 -> ok (unchanged)
L="$(mktemp)"; printf 'all good\n' > "$L"
assert_eq "$(det 0 "$L")" "ok" "plain-text: rc=0 -> ok (unchanged)"

# --- _render_stream: render stream-json objects, pass non-JSON lines through ---
rs() { DEPUTY_ROOT="$(mktemp -d)" DEPUTY_ALLOW_ANY_BRANCH=1 bash -c 'source "'"$DEPUTY"'" >/dev/null 2>&1; _render_stream' 2>/dev/null; }
if command -v jq >/dev/null 2>&1; then
  out="$(printf '%s\n' \
    '{"type":"assistant","message":{"content":[{"type":"text","text":"hello world"}]}}' \
    '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash"}]}}' \
    '{"type":"result","subtype":"success","is_error":false}' \
    'a plain non-json line' \
    '{"type":"system","subtype":"init"}' | rs)"
  assert_contains "$out" "hello world"          "render: assistant text is shown"
  assert_contains "$out" "[tool: Bash]"         "render: tool_use shown as [tool: name]"
  assert_contains "$out" "--- success ---"      "render: result event shown as a divider"
  assert_contains "$out" "a plain non-json line" "render: non-JSON line passed through verbatim"
  case "$out" in *init*) assert_eq leak "" "render: system/init events should be hidden" ;; esac
fi

rm -f "$L"
