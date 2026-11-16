# Reactive Stop-Loss Vault

**Track: Every Second Counts — time-sensitive DeFi on Base Sepolia**
**Reactive Omni Buildathon (DoraHacks)**

A vault position on Base Sepolia that protects itself. The moment the price
of the position's asset falls through a stop-loss — or rises through a
take-profit — a reactive contract watching the price feed from Reactive
Network's Lasna testnet decides and fires a cross-chain callback that makes
the vault exit the position into a stable token. No keeper network, no
off-chain bot, no user transaction: the loop is closed entirely by contracts,
and with Omni's ~1-second blocks and instant finality it closes in seconds —
exactly the regime where a few seconds decide whether a stop-loss is worth
anything.

## How it works

```
 Base Sepolia (84532)                 Reactive Lasna (5318007)            Base Sepolia (84532)
┌───────────────────┐               ┌────────────────────────┐          ┌────────────────────┐
│  MockPriceFeed    │  PriceUpdated │  StopLossReactive      │ callback │  GuardedVault      │
│  setPrice($85)    │ ─────────────►│  react(): $85 <= $90   │ ────────►│  executeExit():    │
│                   │   event       │  stop-loss → request   │  via     │  swap 100 AST at   │
└───────────────────┘               │  callback, disarm      │  proxy   │  $85 → 8,500 USDQ  │
                                    └────────────────────────┘          └────────────────────┘
```

1. **Origin.** Anyone (in the demo: the owner) pushes a price to
   `MockPriceFeed` on Base Sepolia, emitting `PriceUpdated(uint256)`.
2. **Decision.** `StopLossReactive` on Lasna is subscribed to that event via
   the Reactive system contract (`0x8888…8888`). Every price lands in
   `react()`: the contract records it, compares it against the armed
   stop-loss / take-profit for the watched position, and — only on a cross —
   disarms itself (one-shot, so a burst of updates can't drain fees) and calls
   `SYSTEM.requestCallbackV_1_0(...)` with an `executeExit` payload.
3. **Execution.** Reactive Network delivers the callback on Base Sepolia
   through the chain's callback proxy (`0x476F…3585`). `GuardedVault`
   authenticates it twice — the caller must be the proxy
   (`onlyServiceProvider`) and the first payload argument, which the proxy
   overwrites with the requesting reactive contract's address, must be the
   authorized reactive contract (`onlyCallbackSender`) — then swaps the
   user's whole position into USDQ at the trigger price and pays the user.

The decision logic lives on the reactive side on purpose: the vault is a dumb
executor that only authenticates and swaps. Thresholds, arming and one-shot
semantics are reactive-contract state, set by the owner with `setTriggers()`
(which also re-arms after a trigger).

### Contracts

| Contract | Chain | Role |
| --- | --- | --- |
| `MockToken` ×2 (AST / USDQ) | Base Sepolia | Demo asset and stable payout token (minimal ERC-20) |
| `MockPriceFeed` | Base Sepolia | Oracle stand-in; `setPrice` emits the origin event |
| `StopLossReactive` | Reactive Lasna | Subscribes, decides, requests the callback |
| `GuardedVault` | Base Sepolia | Holds positions + USDQ reserve; executes exits |

Deployed addresses and the transaction hashes of a full live loop are in
[`deployments.md`](deployments.md). A shot-by-shot script for the demo video
is in [`demo-script.md`](demo-script.md).

### Fees (Reactive Omni economy)

Both sides are pre-funded so execution never stalls on debt:

- Reactive side: the contract is deployed with 2 lREACT of balance (spent via
  `pay()`) plus 3 lREACT of system-contract reserves via `depositTo()`.
  A `react()` costs roughly `gasPrice × (gasUsed + 100,000)` ≈ 0.03 lREACT.
- Destination side: the vault gets 0.005 ETH of balance plus 0.01 ETH of
  proxy reserves via the proxy's `depositTo()`. At Base Sepolia gas prices a
  callback costs a fraction of a cent.

## Run it

### Unit tests (no network needed)

```bash
forge test
```

12 tests cover the full loop end-to-end: the test etches a mock system
contract at the real SYSTEM address, feeds fabricated `LogRecord`s into
`react()`, captures the requested callback, and delivers it to the vault
through a mock proxy — plus the auth guards (wrong caller, wrong reactive
sender), one-shot semantics, and the graceful no-position exit.

### Live demo (testnets)

Prerequisite: a deployer wallet with ≥ 0.16 ETH on **Base Sepolia**
(deployments, vault funding, and 0.1 ETH for the lREACT exchange below).

```bash
export DEPLOYER_PK=<testnet-only deployer key>
./run-demo.sh
```

`run-demo.sh` performs the whole flow and prints the evidence:

1. Exchanges 0.1 Base Sepolia ETH for 10 lREACT through the official Reactive
   faucet contract on Base Sepolia (`0x2afa…5967`, `request(address)`), if
   the Lasna balance is low.
2. Deploys tokens + feed (Base Sepolia), the reactive contract (Lasna), the
   vault (Base Sepolia), and arms the triggers ($90 / $120 around $100).
3. Opens the demo position (deployer deposits 100 AST at $100), included in
   the vault deployment step.
4. Pushes the price to **$95** — the reactive contract observes it and does
   nothing (in range).
5. Pushes the price to **$85** — stop-loss. The script then polls Lasna for
   the `CallbackRequest` log (the reactive transaction) and Base Sepolia for
   the vault's `PositionExited` log (the callback transaction), cross-checks
   with the system contract's `getCallbacks()`, and verifies the position is
   closed and the user holds 8,500 USDQ.
6. Writes all addresses and hashes to `deployments.md`.

The four deployment steps also exist as standalone Foundry scripts in
`script/` (`DeployBase`, `DeployReactive`, `DeployVault`,
`ConfigureReactive`) if you prefer to run them individually.

## Networks

| Network | Chain ID | RPC | Explorer |
| --- | --- | --- | --- |
| Base Sepolia | 84532 | https://base-sepolia-rpc.publicnode.com | https://sepolia.basescan.org |
| Reactive Lasna | 5318007 | https://lasna-rpc.rnk.dev/ | https://lasna.reactscan.net |

Key protocol addresses: system contract (Lasna)
`0x8888888888888888888888888888888888888888`; callback proxy (Base Sepolia)
`0x476F44b11F5C942c58f4c8E3d0300E5710743585`; lREACT faucet (Base Sepolia)
`0x2afaFD298b23b62760711756088F75B7409f5967`.

## Notes and limitations

- Demo collateral only: `MockToken` has open minting and `MockPriceFeed` is
  owner-pushed. Swapping in a real Chainlink feed and a Uniswap pool for the
  exit is the obvious production path and changes nothing about the reactive
  loop itself.
- One watched position per reactive contract instance in this build; the
  vault itself supports any number of users, and `setTriggers` can be called
  again to watch a new position.
- The vault caps a payout at its USDQ reserve; a production version would
  swap against a DEX instead of an internal reserve.
- Built with Foundry 1.9, Solidity 0.8.30, and
  [`reactive-lib-omni`](https://github.com/Reactive-Network/reactive-lib-omni)
  (vendored under `lib/`).

## License

MIT — see [`LICENSE`](LICENSE).

> **Note on `lib/`:** this GitHub mirror omits the vendored libraries for size.
> `lib/forge-std` and `lib/reactive-lib-omni` are unmodified copies of the
> official releases (foundry-rs/forge-std and the Reactive Network omni
> library); restore them with `forge install` or by copying the official
> sources into `lib/` before running `forge build`.
