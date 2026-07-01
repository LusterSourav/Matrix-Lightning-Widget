#!/usr/bin/env bash
set -uo pipefail

# Matrix Lightning Widget — Comprehensive test suite
# ponytail: single self-contained bash script, 33 tests, one file
# Run: bash tests/test_all.sh

PASS=0
FAIL=0
BASE=${BASE:-http://citadel.test}
FAILED_TESTS=""

header()  { printf "\n%s\n" "────────────────────────────────────────"; }
ok()      { PASS=$((PASS+1)); printf "  ✓ %s\n" "$1"; }
fail()    { FAIL=$((FAIL+1)); FAILED_TESTS="$FAILED_TESTS  - $1\n"; printf "  ✗ %s\n" "$1"; }
check()   { if eval "$1"; then ok "$2"; else fail "$2"; fi; }

# Login once, reuse token (wait out rate limiter)
TOKEN=""
for i in 1 2 3 4 5; do
  RESULT=$(curl -s -X POST "$BASE/_matrix/client/v3/login" \
    -d '{"type":"m.login.password","user":"admin","password":"citadel"}')
  TOKEN=$(echo "$RESULT" | jq -r '.access_token')
  if [ -n "$TOKEN" ] && [ "$TOKEN" != "null" ]; then
    break
  fi
  WAIT=$(echo "$RESULT" | jq -r '.retry_after_ms // 10000')
  WAIT=$(( (WAIT + 999) / 1000 ))
  [ "$WAIT" -gt 0 ] && sleep "$WAIT"
done
NODEA_ID=$(docker compose exec -T lightningd-a lightning-cli --network=regtest getinfo 2>/dev/null | jq -r '.id')
NODEB_ID=$(docker compose exec -T lightningd-b lightning-cli --network=regtest getinfo 2>/dev/null | jq -r '.id')

echo "
╔════════════════════════════════════════╗
║   Lightning Widget — 33 Test Suite    ║
╚════════════════════════════════════════╝"

# === SECTION 1: Infrastructure (8 tests) ===
header
echo " Infrastructure"

check 'docker compose ps 2>/dev/null | grep "bitcoind" | grep -q "Up.*healthy"' \
  "bitcoind is up and healthy"
check 'docker compose ps 2>/dev/null | grep "lightningd-a" | grep -q "Up.*healthy"' \
  "lightningd-a is up and healthy"
check 'docker compose ps 2>/dev/null | grep "lightningd-b" | grep -q "Up.*healthy"' \
  "lightningd-b is up and healthy"
check 'docker compose ps 2>/dev/null | grep "synapse" | grep -q "Up.*healthy"' \
  "synapse is up and healthy"
check 'docker compose ps 2>/dev/null | grep "gateway" | grep -q "Up"' \
  "gateway is up"
check 'docker compose ps 2>/dev/null | grep "element" | grep -q "Up"' \
  "element is up"
check 'curl -sf "$BASE/_matrix/client/v3/login" -o /dev/null -w "%{http_code}" 2>/dev/null | grep -q 200' \
  "synapse responds on port 80 through gateway"
check 'docker compose exec -T bitcoind bitcoin-cli -regtest -rpcuser=citadel -rpcpassword=citadel getblockchaininfo 2>/dev/null | jq -e ".chain == \"regtest\"" > /dev/null' \
  "bitcoind is on regtest chain"

# === SECTION 2: Lightning Network (5 tests) ===
header
echo " Lightning Network"

check 'docker compose exec -T lightningd-a lightning-cli --network=regtest getinfo 2>/dev/null | jq -e ".blockheight > 0" > /dev/null' \
  "node-a is synced (blockheight > 0)"
check 'docker compose exec -T lightningd-b lightning-cli --network=regtest getinfo 2>/dev/null | jq -e ".blockheight > 0" > /dev/null' \
  "node-b is synced (blockheight > 0)"
check 'docker compose exec -T lightningd-a lightning-cli --network=regtest getinfo 2>/dev/null | jq -e ".num_peers >= 1" > /dev/null' \
  "node-a has at least 1 peer"
check 'docker compose exec -T lightningd-a lightning-cli --network=regtest listpeerchannels 2>/dev/null | jq -e ".channels[0].state == \"CHANNELD_NORMAL\"" > /dev/null' \
  "channel is CHANNELD_NORMAL"
check 'docker compose exec -T lightningd-a lightning-cli --network=regtest listfunds 2>/dev/null | jq -e ".channels | length > 0" > /dev/null' \
  "node-a has funded channels"

# === SECTION 3: Matrix API (5 tests) ===
header
echo " Matrix API"

check 'test -n "$TOKEN" && test "$TOKEN" != "null"' \
  "admin can log in to matrix"
check 'curl -sf "$BASE/_matrix/client/v3/account/whoami" -H "Authorization: Bearer $TOKEN" | jq -e ".user_id == \"@admin:citadel.local\"" > /dev/null' \
  "whoami returns admin user_id"
check 'curl -sf -X POST "$BASE/_matrix/client/v3/createRoom" -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" -d "{\"name\":\"test-ci\"}" | jq -e ".room_id" > /dev/null' \
  "can create a room"
check 'curl -sf "$BASE/_matrix/client/v3/joined_rooms" -H "Authorization: Bearer $TOKEN" | jq -e ".joined_rooms | length >= 1" > /dev/null' \
  "admin is in at least 1 room (after creating one)"

# === SECTION 4: Gateway proxying (5 tests) ===
header
echo " Gateway & Proxy"

check 'curl -s -o /dev/null -w "%{http_code}" "$BASE/" 2>/dev/null | grep -q 200' \
  "gateway serves element at /"
check 'curl -s -o /dev/null -w "%{http_code}" "$BASE/_matrix/client/v3/login" 2>/dev/null | grep -q 200' \
  "gateway proxies /_matrix/* to synapse (login endpoint returns 200)"
check 'curl -s -X POST -o /dev/null -w "%{http_code}" "$BASE/clnrest/v1/getinfo" 2>/dev/null | grep -q 201' \
  "gateway proxies /clnrest/* to CLN (POST returns 201)"
check 'curl -s -o /dev/null -w "%{http_code}" "$BASE/widget.html" 2>/dev/null | grep -q 200' \
  "gateway serves /widget.html"
check 'curl -sf "$BASE/widget.html" 2>/dev/null | grep -qi "Lightning"' \
  "widget HTML has expected content"

# === SECTION 5: CLN REST API (4 tests) ===
header
echo " CLN REST API"

check 'curl -s -X POST "$BASE/clnrest/v1/getinfo" | jq -e ".id == \"$NODEA_ID\"" > /dev/null' \
  "getinfo returns node-a identity"
check 'curl -s -X POST "$BASE/clnrest/v1/listpeerchannels" | jq -e ".channels | length > 0" > /dev/null' \
  "listpeerchannels returns channels"
check 'curl -s -X POST "$BASE/clnrest/v1/listpays" | jq -e ".pays | length >= 0" > /dev/null' \
  "listpays returns (possibly empty) payment list"
check 'curl -s -X POST "$BASE/clnrest/v1/getinfo" | jq -e ".blockheight > 0" > /dev/null' \
  "getinfo shows synced blockheight"

# === SECTION 6: Security (3 tests) ===
header
echo " Security"

check 'curl -s -I "$BASE/widget.html" 2>/dev/null | grep -qi "X-Frame-Options: SAMEORIGIN"' \
  "widget has X-Frame-Options: SAMEORIGIN (allows Element iframe on same domain)"
check 'curl -s -I "$BASE/widget.html" 2>/dev/null | grep -qi "Content-Security-Policy"' \
  "widget has CSP header (with frame-ancestors for iframe safety)"
check 'curl -s -X POST "$BASE/_matrix/client/v3/login" -d "{\"type\":\"m.login.password\",\"user\":\"admin\",\"password\":\"WRONG\"}" 2>/dev/null | grep -q "M_FORBIDDEN"' \
  "synapse rejects wrong password (returns M_FORBIDDEN)"

# === SECTION 7: Widget content (3 tests) ===
header
echo " Widget Content"

WIDGET_HTML=$(curl -sf "$BASE/widget.html" 2>/dev/null)
check 'echo "$WIDGET_HTML" | grep -qi "clnrest/v1"' \
  "widget uses /clnrest/v1 API path"
check 'echo "$WIDGET_HTML" | grep -qi "keysend"' \
  "widget has keysend functionality"
check 'echo "$WIDGET_HTML" | grep -qi "textContent.*return.*innerHTML"' \
  "widget has XSS escaping via textContent + innerHTML"

# === SECTION 8: Edge cases (4 tests) ===
header
echo " Edge Cases"

check 'curl -s -X POST "$BASE/clnrest/v1/keysend" -H "Content-Type: application/json" -d "{\"destination\":\"not-a-pubkey\",\"amount_msat\":1000}" 2>/dev/null | jq -e ".code" > /dev/null' \
  "keysend fails with invalid pubkey (returns cln error code)"
check 'curl -s -X POST "$BASE/clnrest/v1/listpays" -d "{\"limit\":0}" 2>/dev/null | jq -e ".pays" > /dev/null' \
  "listpays handles zero limit gracefully"
check 'curl -s -X POST "$BASE/clnrest/v1/getinfo" 2>/dev/null | jq -e ".id | test(\"^0[2-3][0-9a-f]{64}$\")" > /dev/null' \
  "CLN node id is valid 66-char hex pubkey"
check 'curl -s -X POST "$BASE/clnrest/v1/listpeerchannels" 2>/dev/null | jq -e ".channels[0].amount_msat == null or .channels[0].amount_msat > 0" > /dev/null' \
  "channel amount is null (self) or positive"

# === SECTION 9: Integration — Full keysend flow (3 tests) ===
header
echo " Integration"

# Keysend 5000 msats from node-a to node-b
KEYSEND_RESULT=$(curl -s -X POST "$BASE/clnrest/v1/keysend" \
  -H "Content-Type: application/json" \
  -d "{\"destination\":\"$NODEB_ID\",\"amount_msat\":5000}" 2>/dev/null)

check 'echo "$KEYSEND_RESULT" | jq -e ".payment_hash" > /dev/null' \
  "keysend to node-b returns payment_hash"
check 'echo "$KEYSEND_RESULT" | jq -e ".status == \"complete\"" > /dev/null' \
  "keysend is complete (not pending/failed)"

# Check payment shows up in listpays
PAYMENT_HASH=$(echo "$KEYSEND_RESULT" | jq -r '.payment_hash')
check "curl -s -X POST \"$BASE/clnrest/v1/listpays\" 2>/dev/null | jq -e \".pays[] | select(.payment_hash == \\\"$PAYMENT_HASH\\\") | .status == \\\"complete\\\"\" > /dev/null" \
  "payment appears in listpays as complete"

# === SUMMARY ===
header
printf "\n"
if [ "$FAIL" -eq 0 ]; then
  echo "  All $PASS tests passed."
else
  printf "  %d passed, %d failed.\n" "$PASS" "$FAIL"
  printf "\n  Failed tests:\n"
  printf "$FAILED_TESTS"
fi
header
printf "\n"

[ "$FAIL" -eq 0 ] || exit 1
