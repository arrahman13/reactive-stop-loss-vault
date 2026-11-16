# Demo video script — Reactive Stop-Loss Vault (target: 2:30, hard limit 3:00)

Fill in the addresses/hashes from `deployments.md` before recording.
Tabs to have open: (1) terminal in this repo, (2) Lasna Reactscan on the
reactive contract, (3) Base Sepolia Basescan on the vault, (4) this README.

## 0:00–0:20 — The problem

**Say:** "A stop-loss is only worth something if it fires in time. Keeper bots
sleep, get congested, or go down. This vault watches its own price feed from
Reactive Network and exits itself — no bot, no user transaction."

**Show:** README architecture diagram.

## 0:20–0:50 — The setup

**Say:** "On Base Sepolia: a price feed, a vault holding my position of
100 AST bought at $100, and a stable-token reserve. On Reactive Lasna: one
contract subscribed to the feed's PriceUpdated event, armed with a $90
stop-loss and a $120 take-profit."

**Show:** Basescan vault page (position + reserve), Reactscan reactive
contract page (armed, thresholds). Point at the deployed addresses.

## 0:50–1:20 — In-range price move (nothing happens — on purpose)

**Do:** in the terminal:

```bash
cast send $FEED "setPrice(uint256)" 95000000000000000000 \
  --rpc-url https://base-sepolia-rpc.publicnode.com --private-key $DEPLOYER_PK
```

**Say:** "Price drops to $95 — inside the band. Watch the reactive contract:
it sees the event, records the price… and does nothing. No callback, no fees
wasted."

**Show:** Reactscan: the reactive transaction for the $95 event;
`lastPrice = 95`, `triggerCount = 0`.

## 1:20–2:10 — The stop-loss fires

**Do:**

```bash
cast send $FEED "setPrice(uint256)" 85000000000000000000 \
  --rpc-url https://base-sepolia-rpc.publicnode.com --private-key $DEPLOYER_PK
```

**Say:** "Now $85 — through the $90 stop. The reactive contract compares,
decides, disarms itself so it can't double-fire, and requests a callback.
Reactive Network delivers it back on Base Sepolia through the callback proxy,
the vault authenticates the caller and the originating reactive contract,
swaps the position at $85, and pays out."

**Show, in order:**
1. Basescan: the `setPrice($85)` origin transaction.
2. Reactscan: the reactive transaction + `CallbackRequest` log.
3. Basescan: the callback transaction into the vault — `PositionExited`
   event, position at zero, **8,500 USDQ in the user's wallet**.

## 2:10–2:30 — Close

**Say:** "Three transactions, two chains, zero bots: event, decision,
execution — the full loop in seconds thanks to Omni's one-second finality.
The same contract also takes profit at $120, and `forge test` replays the
whole loop locally against a mock system contract. Code and evidence are in
the repo."

**Show:** `deployments.md` evidence table; end on the repo README.
