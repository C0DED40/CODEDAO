# CODE DAO

A decentralised venture organisation. Capital sits in an autonomous on-chain treasury, deal flow
comes from the fifty largest stakers, allocation decisions come from everyone else, and between the
vote and the money sits a board of ten independent AI agents that reads the code before a single
token moves.

Built from `CODE DAO Whitepaper v0.1`. Section references throughout the code point back to it.

## Layout

```
contracts/   Foundry project: the protocol and its test suite
agent/       SAINE harness: builds adjudication packages, runs the ten-model board
frontend/    Interface: proposals, voting, verdicts, vintages, staking
docs/        Build decisions, parameter table, operator runbook
```

## Contracts

| Contract | Role | Whitepaper |
| --- | --- | --- |
| `Code.sol` | ERC20, fixed supply, 0.49% tax, two burn sinks, self-sealing | §2 |
| `DCode.sol` | Staking, seasons, Guardian/Many split, delegation, penalties | §3, §4, §7 |
| `Treasury.sol` | Genesis 500M plus accrued tax, draws at TWAP | §11 |
| `Governor.sol` | Three tracks: origination, halt, advisory | §6 |
| `CodeTimelock.sol` | Admin of the governed layer | §14 |
| `Saine.sol` | Ten slots, commit-reveal, bonds, equivocation slashing | §5 |
| `Escrow.sol` | Obligations, tranches, warrants, defaults | §8 |
| `VintageVault.sol` | Per-vintage accumulators, claims, exit forfeiture | §10 |
| `Satellite.sol` | Per-investee-chain repayment intake | §9 |
| `Receiver.sol` | Home-chain buyback, 50% burn / 50% vintage | §9 |
| `Targets.sol` | Known-good target registry | §6.2 |
| `Oracle.sol` | V2 TWAP against Chainlink ETH/USD, staleness guards | §11 |
| `StargateSatelliteAdapter.sol` | Sends a batch and its manifest in one crossing | §9 |
| `StargateHomeAdapter.sol` | Receives it, covers the bridge fee from maintenance | §9 |

## Build

```
cd contracts
./setup.sh
forge test
```

Deep fuzzing and invariants: `forge test --profile deep`.

## Interface

```
cd frontend
npm install
npm run dev
```

## Deployment

Robinhood Chain (Arbitrum-stack L2, ETH gas). Uniswap v2 is the canonical pool for oracle and swap
purposes; see `docs/DECISIONS.md` §1.1 for why v2 rather than v3.

| Network | Chain ID | Foundry RPC alias | Explorer |
| --- | --- | --- | --- |
| Mainnet | 4663 | `robinhood` | robinhoodchain.blockscout.com |
| Testnet | 46630 | `robinhood_testnet` | explorer.testnet.chain.robinhood.com |

`forge script` takes `--rpc-url robinhood` or `--rpc-url robinhood_testnet` (set `ROBINHOOD_RPC_URL` /
`ROBINHOOD_TESTNET_RPC_URL`). The SAINE harness uses the same split: `SAINE_CHAIN_ID=4663` or `46630`
with `SAINE_RPC_URL` at the matching node. Attestations are EIP-712-bound to that id, so the two
must agree; `saine check` reads the node and refuses a mismatch.

## Status

All twelve contracts are built and tested, with the bridge adapters and the deploy script; 297 tests
pass. A funding proposal runs end to end
in `test/integration/Lifecycle.t.sol`: Guardian submits, the Many vote, the ten-agent board commits
and reveals, six approve, the timelock executes, and WETH reaches the investee.

Outstanding:

- A `LayerZeroAdapter` implementing `IBridgeAdapter`. Nothing in `Satellite.sol` or `Receiver.sol`
  depends on a particular messaging layer, so this is one small contract and no changes elsewhere.
- Deploy script. Note that deployment requires address prediction, because the token needs the
  treasury and the timelock needs the governor, and both pairs are circular and immutable by design.
  See `docs/DECISIONS.md` §2.16.
- Team vesting for the 6% allocation is out of scope by decision, and so is enforced by nothing here.

`docs/DECISIONS.md` tracks every judgement call with its reasoning, including the defects the test
suite found and what changed in response. `docs/PARAMETERS.md` is the deployment configuration table.

## Licence

AGPL-3.0-only for the protocol sources.

Nothing in this repository is an offer of securities or a solicitation of investment.
