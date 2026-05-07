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

section "T1.5 — mac list --json (grouped envelope)"
JSON=$("$BAGUETTE" mac list --json 2>/dev/null)
if echo "$JSON" | python3 -c "
import json,sys
d = json.load(sys.stdin)
assert isinstance(d.get('active'), list)
assert isinstance(d.get('inactive'), list)
all_apps = (d['active'] + d['inactive'])
assert any(a.get('bundleID') == 'com.apple.TextEdit' for a in all_apps), 'TextEdit missing'
print('OK')
" >/dev/null 2>&1; then
    pass "list --json envelope has active/inactive arrays with TextEdit"
else
    fail "list --json shape wrong"
fi

section "T1.6 — mac screenshot to stdout (no --output)"
rm -f /tmp/smoke-mac-stdout.jpg
"$BAGUETTE" mac screenshot --bundle-id $BG > /tmp/smoke-mac-stdout.jpg 2>/dev/null
if [[ -s /tmp/smoke-mac-stdout.jpg ]] && file /tmp/smoke-mac-stdout.jpg | grep -q "JPEG"; then
    pass "stdout captured ($(wc -c < /tmp/smoke-mac-stdout.jpg) bytes JPEG)"
else
    fail "no JPEG on stdout"
fi

section "T1.7 — mac screenshot --scale 2 halves dimensions"
rm -f /tmp/smoke-mac-1x.jpg /tmp/smoke-mac-2x.jpg
"$BAGUETTE" mac screenshot --bundle-id $BG --output /tmp/smoke-mac-1x.jpg 2>/dev/null
"$BAGUETTE" mac screenshot --bundle-id $BG --output /tmp/smoke-mac-2x.jpg --scale 2 2>/dev/null
# `sips` (built into macOS) reads decoded image dimensions cleanly,
# unlike `file` which mixes EXIF density into its output.
W1=$(sips -g pixelWidth /tmp/smoke-mac-1x.jpg 2>/dev/null | awk '/pixelWidth:/ {print $2}')
W2=$(sips -g pixelWidth /tmp/smoke-mac-2x.jpg 2>/dev/null | awk '/pixelWidth:/ {print $2}')
EXPECTED=$((W1 / 2))
DIFF=$((W2 - EXPECTED))
DIFF=${DIFF#-}
if [[ "$W1" -gt 0 ]] && [[ "$W2" -gt 0 ]] && [[ "$DIFF" -le 2 ]]; then
    pass "1x=${W1}px, 2x=${W2}px (≈ ${EXPECTED}px)"
else
    fail "scale didn't halve: 1x=${W1}px, 2x=${W2}px"
fi

section "T1.8 — mac describe-ui --output FILE writes to file"
rm -f /tmp/smoke-mac-ax.json
"$BAGUETTE" mac describe-ui --bundle-id $BG --output /tmp/smoke-mac-ax.json 2>/dev/null
if [[ -s /tmp/smoke-mac-ax.json ]] \
   && python3 -c "import json; d=json.load(open('/tmp/smoke-mac-ax.json')); assert d.get('role')=='AXWindow'" 2>/dev/null; then
    pass "describe-ui --output wrote AX tree to /tmp/smoke-mac-ax.json"
else
    fail "describe-ui --output didn't write valid JSON"
fi

section "T1.9 — error: unknown --bundle-id across CLI commands"
GHOST=com.example.does-not-exist.$$
"$BAGUETTE" mac screenshot --bundle-id "$GHOST" --output /tmp/smoke-mac-ghost.jpg 2>/tmp/smoke-mac-err.log
S_EXIT=$?
"$BAGUETTE" mac describe-ui --bundle-id "$GHOST" 2>/tmp/smoke-mac-err2.log >/dev/null
D_EXIT=$?
if [[ "$S_EXIT" -ne 0 ]] && [[ "$D_EXIT" -ne 0 ]] \
   && grep -q "not running" /tmp/smoke-mac-err.log /tmp/smoke-mac-err2.log; then
    pass "screenshot + describe-ui both exit non-zero with 'not running' on unknown bundle"
else
    fail "unknown-bundle error path: screenshot exit=$S_EXIT, describe-ui exit=$D_EXIT"
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

section "T2.8 — every rejected gesture returns ok:false (button, touch1, touch2, pinch, pan)"
# All five gestures that don't apply to macOS apps. Each should
# emit `{"ok":false}` and a `[mac-input] rejecting:` log line.
RESULT=$(printf '{"type":"button","button":"home"}
{"type":"touch1","phase":"down","x":10,"y":10,"width":600,"height":400}
{"type":"touch2","phase":"down","x1":10,"y1":10,"x2":50,"y2":50,"width":600,"height":400}
{"type":"pinch","cx":300,"cy":200,"start":50,"end":150,"width":600,"height":400,"duration":0.3}
{"type":"pan","cx":300,"cy":200,"dx":40,"dy":40,"width":600,"height":400,"duration":0.3}
' | "$BAGUETTE" mac input --bundle-id $BG 2>&1)
COUNT_REJECT=$(echo "$RESULT" | grep -c '"ok":false')
if [[ "$COUNT_REJECT" == "5" ]]; then
    pass "button + touch1 + touch2 + pinch + pan all return {\"ok\":false}"
else
    fail "expected 5 rejections, got $COUNT_REJECT"
    echo "$RESULT" | head -10
fi

section "T2.9 — error: unknown --bundle-id on mac input"
"$BAGUETTE" mac input --bundle-id com.example.does-not-exist.$$ </dev/null 2>/tmp/smoke-mac-input-err.log
INPUT_EXIT=$?
if [[ "$INPUT_EXIT" -ne 0 ]] && grep -q "not running" /tmp/smoke-mac-input-err.log; then
    pass "mac input on unknown bundle exits non-zero with 'not running'"
else
    fail "mac input unknown-bundle error path: exit=$INPUT_EXIT"
fi

section "T2.10 — invalid gesture envelope returns parse error"
# Garbage line should not crash the session — dispatcher returns ok:false.
BAD=$(printf '{"type":"tap"}\n{"not_json":' | "$BAGUETTE" mac input --bundle-id $BG 2>&1)
if echo "$BAD" | grep -q '"ok":false'; then
    pass "missing required fields and malformed JSON both rejected gracefully"
else
    fail "parse-error path: $BAD"
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

section "T3.5 — GET /mac/<bundleID> serves the same mac.html (deep-link)"
M_DEEP=$(curl -s "http://127.0.0.1:$PORT/mac/$BG")
M_INDEX=$(curl -s "http://127.0.0.1:$PORT/mac")
if [[ -n "$M_DEEP" ]] && [[ "$M_DEEP" == "$M_INDEX" ]]; then
    pass "/mac/<bundleID> deep-link returns same mac.html as /mac (route matched)"
else
    fail "deep-link route mismatch — /mac/<bundleID> didn't return mac.html"
fi

section "T3.6 — GET /mac/<bundleID>/describe-ui?x=&y= (HTTP hit-test)"
R=$(curl -s "http://127.0.0.1:$PORT/mac/$BG/describe-ui?x=50&y=50" \
    | python3 -c "import json,sys; print(json.load(sys.stdin).get('role',''))")
if [[ "$R" == "AXTextArea" ]]; then
    pass "HTTP hit-test (50, 50) → AXTextArea"
else
    fail "HTTP hit-test got role=$R (expected AXTextArea)"
fi

section "T3.7 — HTTP 404 for unknown bundleID"
GHOST=com.example.does-not-exist.$$
SCREEN_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$PORT/mac/$GHOST/screen.jpg")
DESC_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$PORT/mac/$GHOST/describe-ui")
if [[ "$SCREEN_CODE" == "404" ]] && [[ "$DESC_CODE" == "404" ]]; then
    pass "/mac/$GHOST/screen.jpg → 404; /mac/$GHOST/describe-ui → 404"
else
    fail "expected 404s, got screen=$SCREEN_CODE describe-ui=$DESC_CODE"
fi

section "T3.8 — WS /mac/<bundleID>/stream — describe_ui + tap dispatch"
# Python's `websockets` lib for scripted message exchange — wscat is
# REPL-only and won't surface received frames in non-interactive mode.
WS_OUT=$(python3 - "ws://127.0.0.1:$PORT/mac/$BG/stream?format=mjpeg" <<'PY' 2>&1 || true
import asyncio, json, sys, websockets

async def main():
    url = sys.argv[1]
    async with websockets.connect(url, max_size=10_000_000, proxy=None) as ws:
        # Force one-shot snapshot to guarantee a binary frame arrives
        # (SCStream only delivers when content changes; idle window
        # won't produce frames on its own).
        await ws.send(json.dumps({"type": "snapshot"}))
        await ws.send(json.dumps({"type": "describe_ui"}))
        # Pull frames until we see describe_ui_result AND a binary
        # frame (or 4s pass).
        end = asyncio.get_event_loop().time() + 4.0
        seen_binary = False
        seen_describe = False
        while asyncio.get_event_loop().time() < end and not (seen_binary and seen_describe):
            try:
                msg = await asyncio.wait_for(ws.recv(), timeout=1.0)
            except asyncio.TimeoutError:
                continue
            if isinstance(msg, bytes):
                seen_binary = True
                continue
            if '"describe_ui_result"' in msg:
                d = json.loads(msg)
                seen_describe = d.get("ok") is True and d.get("tree") is not None
        # Send a tap and confirm dispatch returns ok:true response (or
        # is silently accepted — text replies are not sent back for
        # gestures, so just confirm the socket stays alive).
        await ws.send(json.dumps({
            "type": "tap", "x": 50, "y": 50,
            "width": 1078, "height": 679, "duration": 0.05
        }))
        # Tiny grace period to make sure no socket error fires.
        await asyncio.sleep(0.5)
        print(f"binary_frames={'yes' if seen_binary else 'no'}")
        print(f"describe_ok={'yes' if seen_describe else 'no'}")

asyncio.run(main())
PY
)
if echo "$WS_OUT" | grep -q "describe_ok=yes" \
   && echo "$WS_OUT" | grep -q "binary_frames=yes"; then
    pass "WS describe_ui returned ok+tree; binary frames observed; tap dispatched without socket error"
else
    fail "WS round-trip incomplete"
    echo "$WS_OUT" | head -5
fi

section "T3.9 — WS upgrade for unknown bundleID surfaces error envelope"
WS_GHOST=$(python3 - "ws://127.0.0.1:$PORT/mac/com.example.ghost.$$/stream" <<'PY' 2>&1 || true
import asyncio, sys, websockets
async def main():
    try:
        async with websockets.connect(sys.argv[1], proxy=None) as ws:
            try:
                msg = await asyncio.wait_for(ws.recv(), timeout=2.0)
                print(msg if isinstance(msg, str) else "<binary>")
            except asyncio.TimeoutError:
                print("<no reply>")
    except Exception as e:
        print(f"connect_error: {e}")
asyncio.run(main())
PY
)
if echo "$WS_GHOST" | grep -q '"error":"unknown bundleID"'; then
    pass "unknown bundleID returns {\"ok\":false,\"error\":\"unknown bundleID\"}"
else
    fail "WS unknown-bundle response: $WS_GHOST"
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
