#!/usr/bin/env bash
# Full live demo of the Reactive stop-loss loop on testnets:
#   Base Sepolia (origin + destination)  <->  Reactive Lasna (reactive contract)
#
# Prerequisite: the deployer wallet (KEY_FILE, default ../deployer.key) holds
# at least ~0.2 ETH on Base Sepolia. The script exchanges 0.1 ETH of it for
# 10 lREACT through the official Reactive faucet contract when needed.
#
# It deploys everything, opens a 100 AST position at $100 with a $90 stop-loss
# and $120 take-profit, then:
#   1. moves the price to $95  -> reactive contract sees it, does nothing
#   2. moves the price to $85  -> stop-loss fires, vault pays out 8,500 USDQ
# and prints the three transaction hashes that prove the loop.
set -euo pipefail
cd "$(dirname "$0")"
export PATH="$HOME/.foundry/bin:$PATH"

KEY_FILE="${KEY_FILE:-../deployer.key}"
export DEPLOYER_PK="$(cat "$KEY_FILE")"
DEPLOYER="$(cast wallet address --private-key "$DEPLOYER_PK")"

BASE_RPC="https://base-sepolia-rpc.publicnode.com"
LASNA_RPC="https://lasna-rpc.rnk.dev/"
FAUCET="0x2afaFD298b23b62760711756088F75B7409f5967" # Reactive faucet on Base Sepolia
SYS="0x8888888888888888888888888888888888888888"

# Big-int-safe >= comparison for wei amounts (bash arithmetic is int64 and
# overflows above ~9.22e18 wei, e.g. a 10 lREACT balance reads as negative).
ge_wei() { python3 -c "import sys; sys.exit(0 if int(sys.argv[1]) >= int(sys.argv[2]) else 1)" "$1" "$2"; }

echo "== Deployer: $DEPLOYER"
BASE_BAL="$(cast balance "$DEPLOYER" --rpc-url "$BASE_RPC")"
LASNA_BAL="$(cast balance "$DEPLOYER" --rpc-url "$LASNA_RPC")"
echo "== Base Sepolia balance: $BASE_BAL wei"
echo "== Lasna balance:        $LASNA_BAL wei"

# Minimum Base balance depends on whether the lREACT exchange is still needed:
# 0.16 ETH if the 0.1 ETH faucet exchange is yet to happen, else 0.05 ETH.
MIN_BASE=160000000000000000
if ge_wei "$LASNA_BAL" 6000000000000000000; then MIN_BASE=50000000000000000; fi
if ! ge_wei "$BASE_BAL" "$MIN_BASE"; then
    echo "ERROR: deployer needs >= $MIN_BASE wei Base Sepolia ETH for this run." >&2
    echo "Fund $DEPLOYER on Base Sepolia and re-run." >&2
    exit 1
fi

if ! ge_wei "$LASNA_BAL" 6000000000000000000; then
    echo "== Exchanging 0.1 Base Sepolia ETH for 10 lREACT via the Reactive faucet..."
    cast send "$FAUCET" "request(address)" "$DEPLOYER" --value 0.1ether \
        --rpc-url "$BASE_RPC" --private-key "$DEPLOYER_PK" --json > /dev/null
    for _ in $(seq 1 36); do
        sleep 5
        LASNA_BAL="$(cast balance "$DEPLOYER" --rpc-url "$LASNA_RPC")"
        ge_wei "$LASNA_BAL" 6000000000000000000 && break
    done
    echo "== Lasna balance now: $LASNA_BAL wei"
    if ! ge_wei "$LASNA_BAL" 6000000000000000000; then
        echo "ERROR: lREACT did not arrive in time; re-run later." >&2
        exit 1
    fi
fi

parse_created() { # $1 = broadcast run-latest.json, prints CREATE addresses in order
    python3 - "$1" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
for tx in d["transactions"]:
    if tx.get("transactionType") == "CREATE":
        print(tx["contractAddress"])
PYEOF
}

echo "== Step 1: deploy tokens + feed on Base Sepolia"
forge script script/DeployBase.s.sol --rpc-url "$BASE_RPC" --broadcast --silent
mapfile -t CREATED < <(parse_created broadcast/DeployBase.s.sol/84532/run-latest.json)
export AST="${CREATED[0]}" USDQ="${CREATED[1]}" FEED="${CREATED[2]}"
echo "   AST=$AST USDQ=$USDQ FEED=$FEED"

echo "== Step 2: deploy reactive contract on Lasna"
forge script script/DeployReactive.s.sol --rpc-url "$LASNA_RPC" --broadcast --silent
mapfile -t CREATED < <(parse_created broadcast/DeployReactive.s.sol/5318007/run-latest.json)
export REACTIVE="${CREATED[0]}"
echo "   REACTIVE=$REACTIVE"

echo "== Step 3: deploy vault on Base Sepolia + open position"
forge script script/DeployVault.s.sol --rpc-url "$BASE_RPC" --broadcast --silent
mapfile -t CREATED < <(parse_created broadcast/DeployVault.s.sol/84532/run-latest.json)
export VAULT="${CREATED[0]}"
echo "   VAULT=$VAULT"

echo "== Step 4: arm triggers on Lasna (stop \$90 / take-profit \$120)"
export USER="$DEPLOYER"
forge script script/ConfigureReactive.s.sol --rpc-url "$LASNA_RPC" --broadcast --silent

send_price() { # $1 = price in wei; prints tx hash
    cast send "$FEED" "setPrice(uint256)" "$1" --rpc-url "$BASE_RPC" \
        --private-key "$DEPLOYER_PK" --json | python3 -c "import json,sys; print(json.load(sys.stdin)['transactionHash'])"
}

wait_last_price() { # $1 = expected lastPrice on the reactive contract
    for _ in $(seq 1 60); do
        sleep 5
        LP="$(cast call "$REACTIVE" "lastPrice()(uint256)" --rpc-url "$LASNA_RPC" | awk '{print $1}')"
        [ "$LP" = "$1" ] && return 0
    done
    echo "ERROR: reactive contract did not observe price $1 in time" >&2
    return 1
}

echo "== Step 5: price \$100 -> \$95 (in range: reactive sees it, no trigger)"
ORIGIN_TX_1="$(send_price 95000000000000000000)"
wait_last_price 95000000000000000000
TRIGGERS="$(cast call "$REACTIVE" "triggerCount()(uint256)" --rpc-url "$LASNA_RPC")"
echo "   origin tx: $ORIGIN_TX_1 ; triggerCount=$TRIGGERS (expected 0)"

echo "== Step 6: price \$95 -> \$85 (stop-loss!)"
ORIGIN_TX_2="$(send_price 85000000000000000000)"
wait_last_price 85000000000000000000

echo "== Step 7: collect the loop evidence"
REACTIVE_TX="$(python3 script/poll_callback.py callback-request "$LASNA_RPC" "$SYS" "$REACTIVE" 300 | cut -d= -f2)"
echo "   reactive tx (Lasna): $REACTIVE_TX"
DEST_TX="$(python3 script/poll_callback.py position-exited "$BASE_RPC" "$VAULT" 300 | cut -d= -f2)"
echo "   callback tx (Base Sepolia): $DEST_TX"
echo "   getCallbacks cross-check:"
cast call "$SYS" "getCallbacks(uint256)((uint256,address,uint256,uint256,uint256,bytes)[])" \
    "$(python3 -c "print(int('$REACTIVE_TX', 16))")" --rpc-url "$LASNA_RPC" || true

POSITION="$(cast call "$VAULT" "positions(address)(uint256,uint256)" "$DEPLOYER" --rpc-url "$BASE_RPC" | head -1)"
USER_USDQ="$(cast call "$USDQ" "balanceOf(address)(uint256)" "$DEPLOYER" --rpc-url "$BASE_RPC" | awk '{print $1}')"
echo
echo "================ LOOP EVIDENCE ================"
echo "Deployer:        $DEPLOYER"
echo "AST:             $AST"
echo "USDQ:            $USDQ"
echo "Price feed:      $FEED"
echo "Reactive (Lasna): $REACTIVE"
echo "Vault (Base):    $VAULT"
echo "Origin tx #1 (price -> \$95, no trigger): $ORIGIN_TX_1"
echo "Origin tx #2 (price -> \$85, stop-loss):  $ORIGIN_TX_2"
echo "Reactive tx (Lasna, decision + callback request): $REACTIVE_TX"
echo "Callback tx (Base Sepolia, vault exit):  $DEST_TX"
echo "Position after:  $POSITION (expected 0)"
echo "User USDQ after: $USER_USDQ (expected 8500000000000000000000)"
echo "==============================================="

cat > deployments.md <<EOF
# Deployments — live testnet run

Generated by \`run-demo.sh\`.

| Contract | Chain | Address |
| --- | --- | --- |
| MockToken (AST) | Base Sepolia (84532) | \`$AST\` |
| MockToken (USDQ) | Base Sepolia (84532) | \`$USDQ\` |
| MockPriceFeed | Base Sepolia (84532) | \`$FEED\` |
| StopLossReactive | Reactive Lasna (5318007) | \`$REACTIVE\` |
| GuardedVault | Base Sepolia (84532) | \`$VAULT\` |

Deployer / demo user: \`$DEPLOYER\`

## The loop (stop-loss)

| Step | Hash |
| --- | --- |
| Origin tx #1 — price \$100 → \$95 (seen, no trigger) | \`$ORIGIN_TX_1\` |
| Origin tx #2 — price \$95 → \$85 (stop-loss) | \`$ORIGIN_TX_2\` |
| Reactive tx on Lasna — decision + CallbackRequest | \`$REACTIVE_TX\` |
| Callback tx on Base Sepolia — vault exit, 8,500 USDQ paid | \`$DEST_TX\` |
EOF
echo "Wrote deployments.md"
