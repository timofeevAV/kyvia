#!/bin/bash
# Smoke test a built app: test/smoke.sh [path/to/Kyvia.app], default ./Kyvia.app. Needs port 47321 free.
set -euo pipefail
cd "$(dirname "$0")/.."
APP=${1:-Kyvia.app}
URL=http://127.0.0.1:47321/notify
fail() { echo "FAIL: $*" >&2; exit 1; }
code() { curl -s -o /dev/null -w '%{http_code}' -X POST "$@" "$URL"; }

curl -s -o /dev/null "$URL" && fail "port 47321 is busy, stop the running kyvia first"
out=$(bin/kyvia ask <<<'{}') || fail "kyvia ask must exit 0 when the app is not running"
[[ -z $out ]] || fail "kyvia ask must print nothing when the app is not running"
"$APP/Contents/MacOS/Kyvia" & pid=$!
disown
tmp=$(mktemp -d)
trap 'kill $pid 2>/dev/null; rm -rf "$tmp"' EXIT
for _ in {1..100}; do curl -s -o /dev/null "$URL" && break; sleep 0.1; done

[[ $(code -d '{"title":"x"}') == 403 ]] || fail "a request without X-Kyvia must get 403"
[[ $(code -H 'X-Kyvia: 1' -d '{"title":"smoke"}') == 204 ]] || fail "a valid toast must get 204"
[[ $(code -H 'X-Kyvia: 1' -d 'not json') == 400 ]] || fail "a bad body must get 400"
[[ $(code -H 'X-Kyvia: 1' -H 'Host: rebound.example:47321' -d '{"title":"x"}') == 403 ]] ||
    fail "a foreign Host (DNS rebinding) must get 403"
printf 'POST /notify HTTP/1.1\r\nHost: 127.0.0.1:47321\r\nX-Kyvia: 1\r\nContent-Length: -1\r\n\r\n' |
    nc -w 1 127.0.0.1 47321 >/dev/null || true
kill -0 $pid 2>/dev/null || fail "a negative Content-Length must not crash the app"
bin/kyvia -t success 'quotes " and \ backslash' $'two\nlines' || fail "the CLI must escape any text"
rc=0; bin/kyvia 2>/dev/null || rc=$?
[[ $rc == 2 ]] || fail "the CLI without a title must exit 2, got $rc"
ln -s "$PWD/bin/kyvia" "$tmp/kv"
[[ $("$tmp/kv" 2>&1) == "usage: kv "* ]] || fail "the kv link must name itself in usage"

ASK=http://127.0.0.1:47321/ask
ask() { curl -s -o /dev/null -w '%{http_code}' -m 2 -X POST "$@" "$ASK"; }
q='{"question":"Pick?","header":"P","options":[{"label":"A","description":""},{"label":"B","description":""}]'
[[ $(ask -d '{}') == 403 ]] || fail "/ask without X-Kyvia must get 403"
[[ $(ask -H 'X-Kyvia: 1' -d 'not json') == 400 ]] || fail "/ask with a bad body must get 400"
qs=; for i in 1 2 3 4 5; do qs+="${qs:+,}${q/Pick?/Pick $i?}}"; done
five="{\"tool_name\":\"AskUserQuestion\",\"tool_input\":{\"questions\":[$qs]}}"
[[ $(ask -H 'X-Kyvia: 1' -d "$five") == 204 ]] || fail "more than 4 questions must get 204 at once"
[[ $(ask -H 'X-Kyvia: 1' -d "{\"tool_name\":\"AskUserQuestion\",\"tool_input\":{\"questions\":[$q},$q}]}}") == 204 ]] ||
    fail "two questions with one text must get 204 at once"
[[ $(ask -H 'X-Kyvia: 1' -d "{\"tool_name\":\"Bash\",\"tool_input\":{\"questions\":[$q}]}}") == 204 ]] ||
    fail "another tool must get 204 at once"
out=$(bin/kyvia ask <<<"$five") ||
    fail "kyvia ask must exit 0 on an out-of-scope question"
[[ -z $out ]] || fail "kyvia ask must print nothing on an out-of-scope question"
[[ $(ask -H 'X-Kyvia: 1' -d "{\"tool_name\":\"AskUserQuestion\",\"tool_input\":{\"x\":-1e999,\"questions\":[$q}]}}") == 400 ]] ||
    fail "a question kyvia cannot write back as JSON (an infinite number) must get 400"
in_scope="{\"tool_name\":\"AskUserQuestion\",\"cwd\":\"/tmp/demo\",\"tool_input\":{\"questions\":[$q}]}}"
[[ $(ask -m 1 -H 'X-Kyvia: 1' -d "$in_scope") == 000 ]] || fail "an in-scope question must wait for the toast"
q2='{"question":"More?","header":"M","multiSelect":true,"options":[{"label":"X","description":""},{"label":"Y","description":""}]}'
[[ $(ask -m 1 -H 'X-Kyvia: 1' -d "{\"tool_name\":\"AskUserQuestion\",\"tool_input\":{\"questions\":[$q},$q2]}}") == 000 ]] ||
    fail "a single-choice and a multi-select question in one call must wait for the toast"

event() { printf '{"session_id":"%s","hook_event_name":"%s","cwd":"/tmp/demo","tool_name":"Bash","tool_input":{"command":"%s"}%s}' "$@"; }
[[ $(ask -H 'X-Kyvia: 1' -d '{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{}}') == 204 ]] ||
    fail "a permission request without a session must get 204 at once"
[[ $(ask -H 'X-Kyvia: 1' -d "$(event s0 PostToolUse ls)") == 204 ]] || fail "PostToolUse must get 204 at once"
# hold FILE BODY: a permission request waiting in the background; its status lands in FILE once kyvia answers.
hold() { curl -s -o /dev/null -w '%{http_code}' -m 5 -H 'X-Kyvia: 1' -d "$2" "$ASK" >"$1" & }
held() { sleep 0.3; [[ ! -s $1 ]]; }
hold "$tmp/p1" "$(event s1 PermissionRequest ls)"
held "$tmp/p1" || fail "a permission request must wait for the toast"
ask -H 'X-Kyvia: 1' -d "$(event s1 PostToolUse pwd)" >/dev/null
ask -H 'X-Kyvia: 1' -d "$(event s2 PostToolUse ls)" >/dev/null
held "$tmp/p1" || fail "PostToolUse of another call must leave the permission toast up"
big=$(printf '%*s' 200000 '' | tr ' ' x)
[[ $(ask -H 'X-Kyvia: 1' -d "$(event s1 PostToolUse ls ",\"tool_response\":{\"stdout\":\"$big\"}")") == 204 ]] ||
    fail "a large PostToolUse body must be read"
wait $! || true
[[ $(<"$tmp/p1") == 204 ]] || fail "PostToolUse of the same call (with a large response) must close the permission toast with 204"
hold "$tmp/p2" "$(event s3 PermissionRequest ls)"
ask -H 'X-Kyvia: 1' -d "$(event s4 UserPromptSubmit x)" >/dev/null
held "$tmp/p2" || fail "a prompt in another session must leave the permission toast up"
ask -H 'X-Kyvia: 1' -d "$(event s3 UserPromptSubmit x)" >/dev/null
wait $! || true
[[ $(<"$tmp/p2") == 204 ]] || fail "the next prompt of the session must close the permission toast with 204"
echo "smoke OK"
