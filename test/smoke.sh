#!/bin/bash
# Smoke test a built app: test/smoke.sh [path/to/Kyvia.app], default ./Kyvia.app. Needs port 47321 free.
set -euo pipefail
cd "$(dirname "$0")/.."
APP=${1:-Kyvia.app}
URL=http://127.0.0.1:47321/notify
fail() { echo "FAIL: $*" >&2; exit 1; }
code() { curl -s -o /dev/null -w '%{http_code}' -X POST "$@" "$URL"; }

curl -s -o /dev/null "$URL" && fail "port 47321 is busy, stop the running kyvia first"
"$APP/Contents/MacOS/Kyvia" & pid=$!
disown
tmp=$(mktemp -d)
trap 'kill $pid 2>/dev/null; rm -rf "$tmp"' EXIT
for _ in {1..100}; do curl -s -o /dev/null "$URL" && break; sleep 0.1; done

[[ $(code -d '{"title":"x"}') == 403 ]] || fail "a request without X-Kyvia must get 403"
[[ $(code -H 'X-Kyvia: 1' -d '{"title":"smoke"}') == 204 ]] || fail "a valid toast must get 204"
[[ $(code -H 'X-Kyvia: 1' -d 'not json') == 400 ]] || fail "a bad body must get 400"
bin/kyvia -t success 'quotes " and \ backslash' $'two\nlines' || fail "the CLI must escape any text"
rc=0; bin/kyvia 2>/dev/null || rc=$?
[[ $rc == 2 ]] || fail "the CLI without a title must exit 2, got $rc"
ln -s "$PWD/bin/kyvia" "$tmp/kv"
[[ $("$tmp/kv" 2>&1) == "usage: kv "* ]] || fail "the kv link must name itself in usage"
echo "smoke OK"
