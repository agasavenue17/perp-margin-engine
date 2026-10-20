# perp-margin-engine

A working model of a perpetual futures exchange core in Solidity: collateral vaulting, leveraged long/short positions with mark-to-market PnL settlement, keeper-pushed funding rates, and maintenance-margin liquidation with liquidator incentives. Built with Foundry, with a full test suite (11 tests).

It implements the core accounting used by on-chain perps exchanges (in the style of GMX / dYdX / Hyperliquid margin mechanics). Educational reference implementation — **not audited, not for production use**.

## Components

| Contract | Role |
| --- | --- |
| `src/PerpMarket.sol` | Position lifecycle: open / close / liquidate, equity + PnL accounting, funding accrual |
| `src/CollateralVault.sol` | Custody of the quote asset; only the market can move balances |
| `src/mocks/MockOracle.sol` | Settable price feed (stands in for Chainlink/Pyth in local tests) |
| `src/mocks/MockUSD.sol` | Minimal ERC20 used as the collateral asset |

## Mechanics

- **Collateral**: single ERC20 quote asset. Deposits sit in the vault; margin is drawn from the same balance.
- **Positions**: one position per trader. Notional is USD-denominated; leverage 1–20x. Initial margin = `sizeUsd / leverage`.
- **PnL**: mark-to-market against the oracle price — `(exitPrice - entryPrice) / entryPrice * sizeUsd` (sign flips for shorts).
- **Funding**: a keeper pushes a rate (bps per period). Positive rate => longs pay shorts, negative => shorts pay longs. Applied linearly over the period.
- **Liquidation**: a position is liquidatable when `equity < 6.25% * notional` (maintenance margin). Anyone can liquidate; the liquidator receives **2% of the remaining equity**, the trader keeps the rest.

## Quick start

```bash
forge build
forge test -vv
```

Deployment order (no script, plain constructors):

1. `MockUSD` (or any ERC20) — the collateral token
2. `CollateralVault(token)`
3. `MockOracle(initialPrice)` — or a real oracle adapter
4. `PerpMarket(vault, oracle)`
5. `vault.setMarket(perpMarket)`
6. `perpMarket.setKeeper(keeperAddress)`

## Tests

`test/PerpMarket.t.sol` covers: deposit/withdraw (incl. withdraw blocked with an open position), long and short PnL settlement, under-collateralized and invalid-leverage reverts, liquidation at the maintenance-margin boundary with liquidator bonus payout, funding accrual (long pays short), funding deducted on close, and keeper-only funding access.

## Design notes / known simplifications

- PnL is settled against the vault's pooled collateral; there is no insurance fund or ADL. A deeply underwater position can burn the full balance to zero.
- `accrueFunding` iterates the trader registry — fine for a reference implementation, not gas-scalable. Production systems use a cumulative funding index instead.
- The oracle is mockable by design; a production deployment needs a manipulation-resistant feed.

## License

MIT
