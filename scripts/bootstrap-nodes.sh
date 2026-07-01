#!/bin/sh

NET=${LIGHTNINGD_NETWORK:-regtest}
RPC="curl -sf --user citadel:${BITCOIN_RPC_PASSWORD:-citadel} --data-binary"
BTC="http://bitcoind:18443"

btc_rpc() {
  $RPC "{\"jsonrpc\":\"1.0\",\"id\":\"$2\",\"method\":\"$1\",\"params\":$3}" "$BTC" | jq -r '.result'
}

btc_rpc_raw() {
  $RPC "{\"jsonrpc\":\"1.0\",\"id\":\"$2\",\"method\":\"$1\",\"params\":$3}" "$BTC"
}

echo "waiting for bitcoind..."
until btc_rpc ping 1 2>/dev/null; do sleep 2; done

echo "creating wallet..."
btc_rpc_raw createwallet 1 '["citadel"]' 2>/dev/null || \
btc_rpc_raw loadwallet 2 '["citadel"]' 2>/dev/null || true

echo "[3/5] generating 101 blocks..."
ADDR=$(btc_rpc getnewaddress 3 '[]')
btc_rpc generatetoaddress 4 "[101,\"$ADDR\"]" > /dev/null

# ponytail: entrypoint's inotifywait can miss if dir doesn't exist yet
echo "[3b/5] waiting for lightningd sync (blockheight > 0)..."
for i in $(seq 1 30); do
  INFO=$(lightning-cli --network="$NET" getinfo 2>/dev/null)
  HEIGHT=$(echo "$INFO" | jq -r '.blockheight // 0')
  [ "$HEIGHT" -gt 0 ] && break
  sleep 2
done

echo "[4/5] getting B node ID from RPC socket..."
B_ID=""
for i in $(seq 1 15); do
  if [ -S "/cln-b/$NET/lightning-rpc" ]; then
    B_ID=$(lightning-cli --rpc-file="/cln-b/$NET/lightning-rpc" getinfo 2>/dev/null | jq -r '.id // empty')
    [ -n "$B_ID" ] && break
  fi
  sleep 2
done

[ -z "$B_ID" ] && echo "WARN: could not get B node ID" && exit 0

echo "  B node ID: ${B_ID%?}..."

echo "[5/7] waiting for B to sync (blockheight > 0)..."
for i in $(seq 1 30); do
  BHEIGHT=$(lightning-cli --rpc-file="/cln-b/$NET/lightning-rpc" getinfo 2>/dev/null | jq -r '.blockheight // 0')
  [ "$BHEIGHT" -gt 0 ] && break
  sleep 2
done

echo "[6/7] funding CLN wallet..."
CLN_ADDR=$(lightning-cli --network="$NET" newaddr 2>/dev/null | jq -r '.bech32 // empty')
if [ -n "$CLN_ADDR" ]; then
  TXID=$(btc_rpc sendtoaddress 6 "[\"$CLN_ADDR\", 10]" 2>/dev/null)
  ADDR_CONF=$(btc_rpc getnewaddress 7 '[]')
  btc_rpc generatetoaddress 8 "[1,\"$ADDR_CONF\"]" > /dev/null
fi
# ponytail: wait for CLN to see the new UTXO before fundchannel
for i in $(seq 1 30); do
  FUNDS=$(lightning-cli --network="$NET" listfunds 2>/dev/null)
  N=$(echo "$FUNDS" | jq '.outputs | length')
  [ "$N" -gt 0 ] 2>/dev/null && break
  sleep 2
done

echo "[7/7] connecting to node B..."
lightning-cli --network="$NET" connect "$B_ID" lightningd-b 9735 2>/dev/null || true
sleep 1

echo "[8/7] opening channel..."
lightning-cli --network="$NET" fundchannel "$B_ID" 500000 2>/dev/null || \
  lightning-cli --network="$NET" multifundchannel "[{\"id\":\"$B_ID\",\"amount\":500000}]" 2>/dev/null || true

ADDR2=$(btc_rpc getnewaddress 5 '[]')
btc_rpc generatetoaddress 6 "[6,\"$ADDR2\"]" > /dev/null

CLNREST_RUNE=$(lightning-cli --network="$NET" createrune \
  -k 'restrictions=[["method=getinfo","method=listpeerchannels","method=keysend","method=listpays","method=listchannels"]]' 2>/dev/null | jq -r '.rune // empty')
if [ -n "$CLNREST_RUNE" ]; then
  echo "$CLNREST_RUNE" > /data/.clnrest-rune
  cat > /data/default.conf <<'NGINX'
upstream element { server element:80; }
upstream synapse { server synapse:8008; }
upstream clnrest { server lightningd-a:3010; }

server {
    listen 80;
    server_name citadel.test citadel.local localhost;

    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;

    location /_matrix {
        proxy_pass http://synapse;
    }

    location /clnrest/ {
        proxy_pass http://clnrest/;
        proxy_set_header Host $host;
        proxy_set_header Rune CLNREST_RUNE_PLACEHOLDER;
    }

    location /widget.html {
        root /data;
        try_files /widget.html =404;
        add_header X-Frame-Options SAMEORIGIN always;
        add_header Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; connect-src 'self'; frame-ancestors 'self'" always;
    }

    location / {
        proxy_pass http://element;
    }
}
NGINX
  sed -i "s|CLNREST_RUNE_PLACEHOLDER|$CLNREST_RUNE|g" /data/default.conf
  echo "  clnrest rune: ${CLNREST_RUNE%?}..."
  echo "  nginx config written"

  cat > /data/widget.html <<'WIDGET'
<!DOCTYPE html>
<html>
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Lightning</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{background:#1a1d23;color:#c8c8c8;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;font-size:13px;padding:12px;line-height:1.4}
h2{font-size:14px;font-weight:600;color:#fff;margin-bottom:8px}
h3{font-size:12px;font-weight:600;color:#a0a0a0;margin:12px 0 6px;text-transform:uppercase;letter-spacing:.5px}
.info-grid{display:grid;grid-template-columns:1fr 1fr;gap:4px;margin-bottom:8px}
.info-label{color:#7a7a7a;font-size:11px}
.info-value{color:#e0e0e0;font-size:12px;text-align:right;font-family:monospace;word-break:break-all}
.balance{background:#23272e;border-radius:6px;padding:10px;margin-bottom:10px;text-align:center}
.balance-amount{font-size:24px;font-weight:700;color:#0d9e6d}
.balance-label{font-size:11px;color:#7a7a7a;margin-top:2px}
.form-group{margin-bottom:8px}
.form-group label{display:block;font-size:11px;color:#a0a0a0;margin-bottom:2px}
.form-group input{width:100%;padding:7px 10px;background:#23272e;border:1px solid #333842;border-radius:4px;color:#e0e0e0;font-size:13px;font-family:monospace}
.form-group input:focus{outline:none;border-color:#0d9e6d}
.btn{width:100%;padding:8px;background:#0d9e6d;color:#fff;border:none;border-radius:4px;font-size:13px;font-weight:600;cursor:pointer}
.btn:hover{background:#0bb878}
.btn:disabled{opacity:.5;cursor:not-allowed}
.result{padding:8px 10px;border-radius:4px;margin-top:8px;font-size:12px;display:none}
.result.success{display:block;background:#0d2b1e;border:1px solid #0d9e6d;color:#6fcf97}
.result.error{display:block;background:#2b1a1a;border:1px solid #e74c3c;color:#e74c3c}
.tx-list{margin-top:4px}
.tx{display:flex;justify-content:space-between;padding:4px 0;border-bottom:1px solid #23272e;font-size:11px}
.tx-status{font-weight:600;font-size:10px;text-transform:uppercase;padding:1px 4px;border-radius:2px}
.tx-status.complete{background:#0d2b1e;color:#6fcf97}
.tx-status.pending{background:#2b2200;color:#f0c040}
.tx-status.failed{background:#2b1a1a;color:#e74c3c}
.tx-amount{color:#e0e0e0;font-family:monospace}
.tx-dest{color:#7a7a7a;font-family:monospace;font-size:10px;max-width:120px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.loading{text-align:center;padding:30px;color:#7a7a7a;font-size:12px}
.spinner{display:inline-block;width:12px;height:12px;border:2px solid #333842;border-top-color:#0d9e6d;border-radius:50%;animation:spin .6s linear infinite;margin-right:6px;vertical-align:middle}
@keyframes spin{to{transform:rotate(360deg)}}
.error-banner{padding:12px;background:#2b1a1a;border:1px solid #e74c3c;border-radius:4px;color:#e74c3c;font-size:12px;text-align:center}
.error-banner small{display:block;color:#7a7a7a;margin-top:4px}
</style>
</head>
<body>
<div id="loading" class="loading"><span class="spinner"></span>Connecting to node...</div>
<div id="error" style="display:none"></div>
<div id="app" style="display:none">
  <h2>Lightning Node</h2>
  <div class="info-grid" id="nodeInfo"></div>
  <div class="balance" id="balanceSection">
    <div class="balance-amount" id="balanceAmount">-</div>
    <div class="balance-label">local balance</div>
  </div>
  <h3>Send Keysend</h3>
  <div class="form-group">
    <label>Destination pubkey</label>
    <input type="text" id="destInput" placeholder="02abc...">
  </div>
  <div class="form-group">
    <label>Amount (sat)</label>
    <input type="number" id="amtInput" placeholder="1000" min="1">
  </div>
  <button class="btn" id="sendBtn">Send</button>
  <div id="sendResult" class="result"></div>
  <h3>Recent Payments</h3>
  <div id="txList" class="tx-list"></div>
</div>
<script>
const A = '/clnrest/v1';
async function api(m,b){const r=await fetch(A+"/"+m,{method:"POST",headers:{"Content-Type":"application/json"},body:b?JSON.stringify(b):"{}"});if(!r.ok){const e=await r.json().catch(()=>({error:r.statusText}));throw new Error(e.error||e.message||"HTTP "+r.status)}return r.json()}
async function init(){try{const i=await api("getinfo"),c=await api("listpeerchannels"),a=i.alias||"node-a",p=i.id,n=i.num_active_channels||0,b=i.blockheight||"?",l=((c.channels||[]).reduce((s,x)=>{const m=parseInt(x.our_amount_msat||"0");return s+(isNaN(m)?0:m)},0)/1e3).toLocaleString();document.getElementById("nodeInfo").innerHTML='<div class="info-label">Alias</div><div class="info-value">'+e(a)+'</div><div class="info-label">Pubkey</div><div class="info-value" style="font-size:10px">'+e(p.slice(0,40))+'...</div><div class="info-label">Channels</div><div class="info-value">'+n+'</div><div class="info-label">Block</div><div class="info-value">'+b+'</div>';document.getElementById("balanceAmount").textContent=l;document.getElementById("balanceSection").querySelector(".balance-label").textContent=n>0?"local balance (sat)":"no channels";txs();document.getElementById("loading").style.display="none";document.getElementById("app").style.display="block"}catch(x){document.getElementById("loading").style.display="none";document.getElementById("error").style.display="block";document.getElementById("error").innerHTML='<div class="error-banner">Failed to connect<div class="error-detail">'+e(x.message)+"</div></div>"}}
async function txs(){try{const p=await api("listpays"),l=document.getElementById("txList"),t=(p.pays||p.sends||[]).slice(-10).reverse();if(!t.length){l.innerHTML='<div style="color:#7a7a7a;font-size:11px;text-align:center;padding:10px">No payments yet</div>';return}l.innerHTML=t.map(x=>{const s=(x.status||"pending").toLowerCase(),a=parseInt(x.amount_msat||"0")/1e3;return'<div class="tx"><span class="tx-dest" title="'+e(x.destination||"")+'">'+e((x.destination||x.payment_hash||"?").slice(0,16))+'</span><span class="tx-amount">'+a.toLocaleString()+" sat</span><span class='tx-status "+s+"'>"+s+"</span></div>"}).join("")}catch(x){}}
function doKeysend(){const d=document.getElementById("destInput").value.trim(),a=parseInt(document.getElementById("amtInput").value),r=document.getElementById("sendResult");r.className="result";r.style.display="none";if(!d||d.length<66){r.className="result error";r.textContent="Enter a valid 66-char hex pubkey";r.style.display="block";return}if(!a||a<1){r.className="result error";r.textContent="Enter a valid amount (>= 1 sat)";r.style.display="block";return}document.getElementById("sendBtn").disabled=true;document.getElementById("sendBtn").textContent="Sending...";api("keysend",{destination:d,amount_msat:a*1e3,label:"w-"+Date.now()}).then(res=>{r.className="result success";r.innerHTML="Sent! Preimage: "+e((res.payment_preimage||"").slice(0,16))+"...";r.style.display="block";document.getElementById("destInput").value="";document.getElementById("amtInput").value="";txs()}).catch(x=>{r.className="result error";r.textContent="Failed: "+x.message;r.style.display="block"}).finally(()=>{document.getElementById("sendBtn").disabled=false;document.getElementById("sendBtn").textContent="Send"})}
function e(s){if(!s)return "";const d=document.createElement("div");d.textContent=s;return d.innerHTML}
document.getElementById("sendBtn").addEventListener("click",doKeysend);init();
</script>
</body>
</html>
WIDGET
  echo "  widget HTML written"
fi

echo "=== bootstrap done ==="
