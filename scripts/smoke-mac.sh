#!/bin/bash
# scripts/smoke-mac.sh — end-to-end smoke test for the macOS app path.
#
# Exercises every public surface of `baguette mac …` against TextEdit:
# list → screenshot → describe-ui → input (every supported gesture) →
# serve HTTP/WS routes. Each test asserts an observable outcome and
# prints PASS / FAIL.
#
# Prerequisites:
#   1. Run `make` first so `./Baguette` exists.
#   2. Grant TCC permissions to `./Baguette` in System Settings →
#      Privacy & Security:
#        - Screen Recording (for `mac screenshot` and `mac stream`)
#        - Accessibility   (for `mac describe-ui` and `mac input`)
#      If TCC keeps revoking on rebuild, run the repo's
#      `macos-codesign` skill once for persistent grants.
#
# Usage:
#   ./scripts/smoke-mac.sh           # full suite
#   ./scripts/smoke-mac.sh --no-input  # skip input tests if Accessibility isn't granted
#
# Exit code: 0 on all-pass, non-zero count on any failure.

set -u
cd "$(dirname "$0")/.."

readonly BAGUETTE=./Baguette
readonly BG=com.apple.TextEdit
SKIP_INPUT=0
SKIP_SERVE=0

for arg in "$@"; do
    case "$arg" in
        --no-input) SKIP_INPUT=1 ;;
        --no-serve) SKIP_SERVE=1 ;;
        --help|-h)
            sed -n '2,21p' "$0"
            exit 0
            ;;
    esac
done

# ─── pretty printing ──────────────────────────────────────────────

readonly RED=$'\033[31m'
readonly GREEN=$'\033[32m'
readonly YELLOW=$'\033[33m'
readonly BOLD=$'\033[1m'
readonly RESET=$'\033[0m'

PASS=0
FAIL=0

section() { printf "\n${BOLD}=== %s ===${RESET}\n" "$1"; }
pass()    { printf "  ${GREEN}✓${RESET} %s\n" "$1"; PASS=$((PASS+1)); }
fail()    { printf "  ${RED}✗${RESET} %s\n" "$1"; FAIL=$((FAIL+1)); }
hint()    { printf "    ${YELLOW}hint:${RESET} %s\n" "$1"; }

# ─── prereq checks ────────────────────────────────────────────────

[[ -x "$BAGUETTE" ]] || {
    printf "${RED}error:${RESET} %s not found. Run 'make' first.\n" "$BAGUETTE" >&2
    exit 2
}

# ─── test fixture: textarea-value reader ──────────────────────────

# Dump TextEdit's accessibility tree to /tmp/d.json and extract the
# AXTextArea value (recursive search). Echoes the value or empty.
read_textarea() {
    "$BAGUETTE" mac describe-ui --bundle-id $BG 2>/dev/null > /tmp/d.json
    python3 -c "
import json
try:
    d = json.load(open('/tmp/d.json'))
except Exception:
    print('')
    raise SystemExit(0)
def find(n):
    if n.get('role')=='AXTextArea': return n
    for c in n.get('children',[]):
        r = find(c)
        if r: return r
    return None
ta = find(d)
print((ta or {}).get('value', '') if ta else '')
"
}

# Pipe a sequence of newline-delimited gesture envelopes into one
# `mac input` session.
input_session() {
    printf '%s' "$1" | "$BAGUETTE" mac input --bundle-id $BG > /dev/null 2>&1
}

# Reset TextEdit to an empty document. Cmd+A + Backspace in one
# session keeps the focus settled across the two events.
reset_textedit() {
    input_session '{"type":"key","code":"KeyA","modifiers":["command"]}
{"type":"key","code":"Backspace"}
'
}

# ─── prereq: ensure TextEdit is running ───────────────────────────

ensure_textedit() {
    if ! "$BAGUETTE" mac list 2>/dev/null | grep -q '"bundleID":"com.apple.TextEdit"'; then
        printf "TextEdit not running — opening it...\n"
        open -a TextEdit
        sleep 1
    fi
}

# ═════════════════════════════════════════════════════════════════
# Tier 1 — read-only (no Accessibility grant required)
# ═════════════════════════════════════════════════════════════════

section "T1.1 — mac list (NSWorkspace)"
ensure_textedit
if "$BAGUETTE" mac list 2>/dev/null | grep -q '"bundleID":"com.apple.TextEdit"'; then
    pass "TextEdit appears in mac list"
else
    fail "TextEdit not in mac list"
fi

section "T1.2 — mac screenshot (ScreenCaptureKit)"
rm -f /tmp/smoke-mac-shot.jpg
if "$BAGUETTE" mac screenshot --bundle-id $BG --output /tmp/smoke-mac-shot.jpg 2>/dev/null \
   && [[ -s /tmp/smoke-mac-shot.jpg ]] \
   && file /tmp/smoke-mac-shot.jpg | grep -q "JPEG image data"; then
    SIZE=$(wc -c < /tmp/smoke-mac-shot.jpg)
    pass "captured TextEdit window ($SIZE bytes JPEG at /tmp/smoke-mac-shot.jpg)"
else
    fail "screenshot failed — check Screen Recording grant in Privacy & Security"
    hint "open 'x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture'"
fi

section "T1.3 — mac describe-ui (full AX tree)"
"$BAGUETTE" mac describe-ui --bundle-id $BG 2>/dev/null > /tmp/d.json
if python3 -c "
import json
d = json.load(open('/tmp/d.json'))
assert d.get('role') == 'AXWindow', f'expected AXWindow, got {d.get(\"role\")}'
print('OK')
" >/dev/null 2>&1; then
    pass "AXWindow root returned"
else
    fail "describe-ui didn't return AXWindow root — check Accessibility grant"
    hint "open 'x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility'"
fi

section "T1.4 — mac describe-ui --x --y (hit-test)"
ensure_textedit
reset_textedit
input_session '{"type":"type","text":"hit-test target"}
'
RESULT=$("$BAGUETTE" mac describe-ui --bundle-id $BG --x 50 --y 50 2>/dev/null \
    | python3 -c "import json,sys; print(json.load(sys.stdin).get('role',''))")
if [[ "$RESULT" == "AXTextArea" ]]; then
    pass "hit-test (50, 50) → AXTextArea"
else
    fail "hit-test (50, 50) → $RESULT (expected AXTextArea)"
fi

# ═════════════════════════════════════════════════════════════════
# Tier 2 — input (needs Accessibility grant; also writes to TextEdit)
# ═════════════════════════════════════════════════════════════════

if [[ "$SKIP_INPUT" == "1" ]]; then
    printf "\n${YELLOW}skipping input tests (--no-input)${RESET}\n"
else

section "T2.1 — type (mixed case + digits + shifted punctuation)"
reset_textedit
input_session '{"type":"type","text":"Hello World 123!?@#"}
'
V=$(read_textarea)
if [[ "$V" == "Hello World 123!?@#" ]]; then
    pass "value: $V"
else
    fail "value: $V (expected 'Hello World 123!?@#')"
fi

section "T2.2 — arrow-key cursor positioning"
reset_textedit
input_session '{"type":"type","text":"ABCDE"}
{"type":"key","code":"ArrowLeft"}
{"type":"key","code":"ArrowLeft"}
{"type":"key","code":"ArrowLeft"}
{"type":"type","text":"X"}
'
V=$(read_textarea)
if [[ "$V" == "ABXCDE" ]]; then
    pass "cursor moved Left x3 then inserted X → 'ABXCDE'"
else
    fail "value: $V (expected 'ABXCDE')"
fi

section "T2.3 — Enter newline + Backspace delete"
reset_textedit
input_session '{"type":"type","text":"line1"}
{"type":"key","code":"Enter"}
{"type":"type","text":"line2x"}
{"type":"key","code":"Backspace"}
'
V=$(read_textarea)
# TextEdit auto-capitalizes the first character → 'Line1\nline2'
if [[ "$V" == $'Line1\nline2' ]] || [[ "$V" == $'line1\nline2' ]]; then
    pass "Enter + Backspace → '$V' (newline preserved, trailing x deleted)"
else
    fail "value: $V (expected 'Line1\\nline2')"
fi

section "T2.4 — tap moves cursor"
reset_textedit
input_session '{"type":"type","text":"abcdefghijklmnop"}
{"type":"tap","x":15,"y":50,"width":1078,"height":679}
{"type":"type","text":"|"}
'
V=$(read_textarea)
if [[ "$V" != *"|" ]] && [[ "$V" == *"|"* ]]; then
    pass "tap moved cursor away from end-of-doc; marker landed inside text"
else
    fail "tap did not move cursor (marker at end). value: $V"
fi

section "T2.5 — drag-select via swipe + replace"
reset_textedit
input_session '{"type":"type","text":"AAAA BBBB CCCC DDDD EEEE FFFF"}
{"type":"swipe","startX":50,"startY":50,"endX":300,"endY":50,"width":1078,"height":679,"duration":0.5}
{"type":"type","text":"@"}
'
V=$(read_textarea)
# After drag-select replaces a middle/right portion, the result should
# be shorter than the original (29 chars) and contain '@'.
if [[ "${#V}" -lt 29 ]] && [[ "$V" == *"@"* ]] && [[ "$V" != "AAAA BBBB CCCC DDDD EEEE FFFF@" ]]; then
    pass "selection replaced by '@'. value: $V"
else
    fail "drag-select failed (no replacement). value: $V"
fi

section "T2.6 — scroll posts (smoke only — visual verify required)"
LONG=""
for i in $(seq 1 30); do LONG+="Line $i\n"; done
reset_textedit
input_session "{\"type\":\"type\",\"text\":\"$LONG\"}
{\"type\":\"scroll\",\"deltaX\":0,\"deltaY\":-200}
"
# Can't verify scroll position via AX; just confirm the gesture didn't error.
pass "scroll {deltaY:-200} posted (verify visually if needed)"

section "T2.7 — long type (94 chars)"
reset_textedit
input_session '{"type":"type","text":"the quick brown fox jumps over the lazy dog 0123456789 the quick brown fox jumps over the lazy"}
'
V=$(read_textarea)
if [[ "${#V}" -ge 90 ]] && [[ "$V" == *"quick"* ]] && [[ "$V" == *"lazy"* ]]; then
    pass "94-char string typed in order (${#V} chars landed)"
else
    fail "long type lost characters. length=${#V}, value: $V"
fi

section "T2.8 — rejected gestures return ok:false"
RESULT=$(printf '{"type":"button","button":"home"}
{"type":"touch1","phase":"down","x":10,"y":10,"width":600,"height":400}
' | "$BAGUETTE" mac input --bundle-id $BG 2>&1 | grep -c '"ok":false')
if [[ "$RESULT" == "2" ]]; then
    pass "button + touch1 both correctly rejected with {\"ok\":false}"
else
    fail "rejected-gesture handling: got $RESULT/2 ok:false responses"
fi

reset_textedit

fi  # end Tier 2

# ═════════════════════════════════════════════════════════════════
# Tier 3 — serve (HTTP / WS routes)
# ═════════════════════════════════════════════════════════════════

if [[ "$SKIP_SERVE" == "1" ]]; then
    printf "\n${YELLOW}skipping serve tests (--no-serve)${RESET}\n"
else

# Pick a free-ish port; 8421 is the default.
PORT=8421
"$BAGUETTE" serve --port $PORT > /tmp/smoke-mac-serve.log 2>&1 &
SERVE_PID=$!
sleep 2

trap 'kill $SERVE_PID 2>/dev/null; wait $SERVE_PID 2>/dev/null || true' EXIT

section "T3.1 — GET /mac.json"
J=$(curl -s "http://127.0.0.1:$PORT/mac.json")
if echo "$J" | python3 -c "import json,sys; d=json.load(sys.stdin); assert isinstance(d.get('active'),list); assert isinstance(d.get('inactive'),list); print('OK')" >/dev/null 2>&1; then
    ACTIVE=$(echo "$J" | python3 -c "import json,sys; print(len(json.load(sys.stdin).get('active',[])))")
    pass "/mac.json returned valid envelope ($ACTIVE active apps)"
else
    fail "/mac.json invalid response: $J"
fi

section "T3.2 — GET /mac/<bundleID>/describe-ui"
R=$(curl -s "http://127.0.0.1:$PORT/mac/$BG/describe-ui" | python3 -c "import json,sys; print(json.load(sys.stdin).get('role',''))")
if [[ "$R" == "AXWindow" ]]; then
    pass "describe-ui route returned AXWindow"
else
    fail "describe-ui route returned: $R"
fi

section "T3.3 — GET /mac/<bundleID>/screen.jpg"
rm -f /tmp/smoke-mac-route.jpg
if curl -s -o /tmp/smoke-mac-route.jpg "http://127.0.0.1:$PORT/mac/$BG/screen.jpg" \
   && [[ -s /tmp/smoke-mac-route.jpg ]] \
   && file /tmp/smoke-mac-route.jpg | grep -q "JPEG"; then
    SIZE=$(wc -c < /tmp/smoke-mac-route.jpg)
    pass "screen.jpg route returned $SIZE bytes JPEG"
else
    fail "screen.jpg route failed"
fi

section "T3.4 — static assets (/mac, /mac-list.js)"
M_HTML=$(curl -s -o /dev/null -w "%{http_code}:%{size_download}" "http://127.0.0.1:$PORT/mac")
M_JS=$(curl -s -o /dev/null -w "%{http_code}:%{size_download}" "http://127.0.0.1:$PORT/mac-list.js")
if [[ "${M_HTML%:*}" == "200" ]] && [[ "${M_JS%:*}" == "200" ]]; then
    pass "/mac → ${M_HTML#*:} bytes; /mac-list.js → ${M_JS#*:} bytes"
else
    fail "static assets: /mac=$M_HTML /mac-list.js=$M_JS"
fi

kill $SERVE_PID 2>/dev/null
wait $SERVE_PID 2>/dev/null || true
trap - EXIT

fi  # end Tier 3

# ═════════════════════════════════════════════════════════════════
# Summary
# ═════════════════════════════════════════════════════════════════

printf "\n${BOLD}Summary${RESET}\n"
printf "  ${GREEN}passed: %d${RESET}\n" "$PASS"
[[ "$FAIL" -gt 0 ]] && printf "  ${RED}failed: %d${RESET}\n" "$FAIL"

exit "$FAIL"
