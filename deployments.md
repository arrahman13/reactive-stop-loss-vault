# Deployments — live testnet run

Run 2026-11-16 (run-demo.sh; the script's own evidence polling timed out, so the
hashes below were collected and verified directly from chain logs afterwards).

| Contract | Chain | Address |
| --- | --- | --- |
| MockToken (AST) | Base Sepolia (84532) | `0xd30f28f4ce588bc2fd26d68635c45d9dc36cdd6d` |
| MockToken (USDQ) | Base Sepolia (84532) | `0x807b57cdc281ff8de536437ff17e953d7c20998b` |
| MockPriceFeed | Base Sepolia (84532) | `0x834c586bf5c5e986539de3080bd1aefe49970c0c` |
| StopLossReactive | Reactive Lasna (5318007) | `0x454abea18d926dd609052fff9b70a47ebf663751` |
| GuardedVault | Base Sepolia (84532) | `0xc4743e669cb75a9407fed12d39e1998f6a663732` |

Deployer / demo user: `0xfb086CaC09A4fCe1F399F3F107261e27F1AB895E`

## The loop (stop-loss)

| Step | Hash |
| --- | --- |
| Origin tx #1 — price $100 → $95 (seen, no trigger) | `0x5162accc974bf19131e0b8cee4ec653a2606e11425ff8d99a53048e46c75d18e` |
| Reactive tx on Lasna — PriceSeen $95, no trigger | `0x765903e5fc8862880e5b265ca0ec455db9a4e244574ead49d3294ca7720a4d20` |
| Origin tx #2 — price $95 → $85 (stop-loss) | `0x49010040fdb93f3aa2c3ab64032a75b00f8fc1711f3ae5b1d980c80d10c98cc8` |
| Reactive tx on Lasna — decision + Triggered + callback request | `0x67851570baf32f814fa574437a15befa70c368b3497ee77841187194954ea6bd` |
| Callback tx on Base Sepolia — vault exit, 8,500 USDQ paid | `0x86e1f0aec490b8432adddae54f2bac4af7fee7be0a771fcd20a3fd055971c9a4` |

Verified end state on-chain: reactive `lastPrice` = $85, `triggerCount` = 1,
vault position = 0, demo user USDQ balance = 8,500 (100 AST × $85).
