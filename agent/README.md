# SAINE harness

The off-chain half of §5. Builds adjudication packages, runs the ten-model board, signs attestations,
and relays them to `contracts/src/Saine.sol`.

Without this, the protocol funds nothing. A proposal passes its vote, a commit-reveal round opens,
nobody commits, and 48 hours later it lapses at the eight-reveal liveness floor. The contracts behave
correctly in that scenario, which is what the lapse path is for, but no deal ever completes.

```
npm install
npm test
```

Copy `.env.example` to `.env` and fill it. `npm start` and `npm run check` load that file from this directory.

## Home chain

The harness talks to whatever `SAINE_RPC_URL` and `SAINE_CHAIN_ID` name. The two home-chain values:

```
# Robinhood mainnet
SAINE_CHAIN_ID=4663
SAINE_RPC_URL=https://rpc.mainnet.chain.robinhood.com

# Robinhood testnet
SAINE_CHAIN_ID=46630
SAINE_RPC_URL=https://rpc.testnet.chain.robinhood.com
```

They must agree. Attestations include the chain id in the EIP-712 domain, so a harness pointed at
testnet with the mainnet id produces signatures the registry will reject. `saine check` reads the
node and refuses a mismatch. Public RPCs are rate-limited; a provider URL is fine in the same slot.

## Status

Feature-complete against §5. 120 tests.

| Module | What it does |
| --- | --- |
| `src/attest.ts` | Commitment construction, deterministic salt derivation, EIP-712 signing, model hashing |
| `src/guard.ts` | The equivocation guard, fail-closed |
| `src/fence.ts` | Fencing proposer prose as untrusted input |
| `src/board.ts` | The ten seats, with the constraint checks |
| `src/prompt.ts` | Versioned system prompts, hashed into every attestation |
| `src/runner.ts` | Fans a package to ten evaluators, isolated, one outage cannot abort the round |
| `src/orchestrate.ts` | The round state machine: package, judge, bind, sign, pin, relay, reveal |
| `src/watch.ts` | Polls for open rounds and acts early in each window |
| `src/keeper.ts` | Settlement, rollover, bond revaluation, oracle poke, buybacks, bridge batching |
| `src/relay.ts`, `src/chain/` | Batched submission over viem, ABIs generated from the compiled contracts |
| `src/ipfs.ts` | Pinning reason documents, with a pin failure degrading the record not the vote |
| `src/package/` | Manifest schema and validation, the §5.3 renderer, package assembly |
| `src/models/` | Three API shapes covering all ten providers |
| `src/config.ts` | Environment loading, with key-hygiene checks |
| `src/main.ts` | `saine watch`, `saine keep`, `saine check` |

## Phase one and phase two (§5.8)

The same binary serves both phases; what changes is `SAINE_OPERATED_SLOTS`.

**Phase one.** "At launch, the team operates all ten agent slots." Leave the variable unset and the
harness runs every seat, expects credentials for all ten providers, and enforces §5.2's board-wide
constraints locally, because in that phase they are entirely the team's to satisfy.

```
# phase one: all ten seats, ten providers' credentials
SAINE_ANTHROPIC_API_KEY=...  SAINE_OPENAI_API_KEY=...   # ...and eight more
SAINE_SLOT_0_SIGNING_KEY=...  SAINE_SLOT_0_SALT_SECRET=...  # ...and nine more pairs
```

**Phase two.** From the trigger, governance reassigns seats to independent operators, capped at two each.
Each runs this same harness holding one or two slots and holding no credentials for anybody else's:

```
SAINE_OPERATED_SLOTS=3
SAINE_DEEPSEEK_API_KEY=...
SAINE_SLOT_3_SIGNING_KEY=...  SAINE_SLOT_3_SALT_SECRET=...
```

Requiring all twenty secrets would have made the harness unusable by exactly the operators §5.8 hands it
to, so the config is scoped to what a process actually runs. Three or more seats is refused, since §5.2's
cap makes it unseatable; only the phase-one team holds all ten.

### Getting paid (§5.8)

Phase two pays operators per attestation, from the treasury, at a USD rate governance sets. Two variables
turn collection on:

```
SAINE_OPERATOR_ADDRESS=0x...   # the address governance assigned to your seat
SAINE_CODE_ADDRESS=0x...       # with the other three keeper addresses
```

The fee accrues in USD when a round settles, credited to whoever held the seat at commit time, and is
claimable in CODE at the oracle price whenever the pool can cover it. `saine keep` claims it on each pass.
The relayer key signs that transaction and never receives the money: the contract pays the named operator
whoever calls, so the operator address can be a multisig or a cold key that never sends anything.

Nothing accrues in phase one, where the rate is zero and the team runs every seat, and nothing is lost if
the pool is unfunded: the debt stands in USD until governance tops it up. `feeShortfallCode()` is what
governance reads to see the liability it has accumulated.

The keeper's four extra addresses (`SAINE_DCODE_ADDRESS`, `SAINE_ORACLE_ADDRESS`, `SAINE_RECEIVER_ADDRESS`,
`SAINE_CODE_ADDRESS`) are all-or-nothing. A keeper configured with three of them would run four of its
steps and throw on the fifth, which reads as a broken keeper rather than an unconfigured one.

A single-seat operator cannot verify the board's provider diversity from their own configuration, because
the other nine seats are somebody else's. `checkOperatedSlots` checks what they can check locally, and the
registry's `distinctProviders()` is where the board-wide property is read.

Run `saine check` before anything else. It validates the configuration and the board composition,
confirms `SAINE_CHAIN_ID` matches the connected node, and exits; discovering a missing credential at
the first commit window costs a lapsed round.

ABIs in `src/chain/abi.ts` are generated from `contracts/out` by `npm run gen:abi`. Regenerate after any
change to a contract interface: hand-transcribed ABIs drift silently, and the failure looks like a chain
problem rather than a typo.

Not built: a live end-to-end run. Everything here is tested against mocks and a fixture chain, and no
part of it has spoken to a real provider or a real node.

`contracts/test/unit/Eip712Parity.t.sol` pins the attestation encoding across both languages with
literals generated by `test/fixtures/generate.ts`. If TypeScript and Solidity ever disagree, that test
fails. Without it, a divergence surfaces on mainnet as an unexplained lapse.

## The board

§5.2 gives the selection criterion, and it is not capability:

> The reason is correlated failure. Ten instances of one model receiving one adversarial input fail as
> one reviewer, and a six-of-ten threshold over identical evaluators carries no information.

So this board is chosen for **decorrelated failure**. The ten strongest models available would be a
worse board than this one, because the ten strongest are heavily correlated: shared training corpora,
shared RLHF methodology, and in several cases shared lineage.

| Slot | Provider | Model | Weights | Why this seat |
| --- | --- | --- | --- | --- |
| 0 | Anthropic | `claude-opus-5` | closed | Strong on long-context code review; distinct safety tuning |
| 1 | OpenAI | `gpt-5.6-sol` | closed | Different corpus and RLHF lineage from every other seat |
| 2 | Google | `gemini-3.7-flash` | closed | Third independent US frontier lineage |
| 3 | xAI | `grok-4.6` | closed | Fourth US lineage, materially different tuning posture |
| 4 | Mistral | `mistral-medium-3-5` | closed | European lab; different regulatory and jailbreak-corpus regime |
| 5 | Meta | `muse-spark-1.2` | closed | Fifth US lineage, different training philosophy |
| 6 | DeepSeek | `deepseek-v4-pro` | open | Chinese lineage; strong at code; verifiable checkpoint |
| 7 | Alibaba | `qwen3.8-max` | open | Independent Chinese lineage |
| 8 | Z.ai | `glm-5.3` | open | Third Chinese lineage, distinct from both above |
| 9 | Moonshot | `kimi-k3` | closed | Fourth Chinese lineage, closed weights |

Ten providers against §5.2's floor of four. No two seats share a base model or a distillation lineage,
which rules out the tempting move of filling three seats with one provider's flagship, balanced and
cheap tiers: a distilled sibling inherits its teacher's blind spots, so those three seats would vote as
one while looking like three.

Three regulatory regimes, roughly six US seats, one European, and four Chinese. Labs in different
jurisdictions are tuned against different jailbreak corpora and different safety expectations, so an
input that defeats one lineage's training tends not to defeat another's. That is the property the
six-of-ten threshold is buying.

### On open weights

Capped at three, and the cap is a judgement rather than a derivation, because the argument runs both
ways.

Against: an attacker crafting a proposal can iterate offline against open weights at zero cost until
the model approves. They need to neutralise four rejections, and three freely attackable seats is a
head start.

For: an open checkpoint can be pinned and independently verified, so §5.4's model hash means something.
A closed provider can substitute a model behind the same API name, and all that changes is the hash of
what the operator *claims* was used. The open seats are the ones where substitution is actually
detectable rather than merely asserted.

Three of ten keeps both properties in the room. `checkBoard()` enforces the cap.

### Verify the identifiers before deploying

These were compiled in August 2026 from public release trackers, which lag and disagree with each other
on specifics. Confirm each against the provider's own API documentation, and record in the `version`
field **what the API actually served**, not what was requested. §5.4's substitution detection depends
on that distinction.

### Operational cost of this choice

Ten providers means ten API accounts, ten credential sets, ten rate-limit regimes and ten independent
failure modes, all of which the team carries alone during phase one (§5.8). A provider that goes down
during a reveal window costs 25% of that slot's bond if it had already committed, and pushes the board
toward the eight-reveal floor. Expect to need retry logic per provider and a monitored alert when any
slot misses a commit window.

Also expect a **lower approval rate than a homogeneous board would give**. Ten genuinely different
reviewers disagree more, which is the entire point, but six of ten is a real bar when the ten are not
correlated. Worth modelling against live proposals before the first deal.

## Two hazards worth reading the code for

**Equivocation is unrecoverable.** §5.5 slashes the whole bond and vacates the seat, atomically, on two
signed attestations with different verdicts for one round. No vote, no appeal. The realistic causes are
mundane: a restart mid-round where the model answers differently, two instances overlapping during a
deploy, a retry after a timeout that had actually succeeded. `src/guard.ts` gates every signature on a
durable compare-and-set and refuses to sign when it cannot check. The file-backed store is single-host
only; a multi-machine deployment needs a real unique constraint.

**Salts are derived, not random.** A random salt has to survive from the commit window into the reveal
window, and losing it forfeits a quarter of the bond. Deriving it from a per-slot secret removes that
dependency entirely. The confidentiality cost is bounded: `reasonHash` carries a random nonce from the
reason document, so knowing the salt still leaves the verdict sealed behind an unguessable 32 bytes.
