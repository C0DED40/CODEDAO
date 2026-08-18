# CODE DAO — build decisions

Every judgement call made while turning the whitepaper into code, with the reasoning. Whitepaper
section references are to `CODE DAO Whitepaper v0.1`.

Status key: **settled** (ruled on by Dom), **proposed** (my choice, awaiting review), **open**
(needs a ruling before the affected contract can be finished).

---

## 1. Settled by Dom

### 1.1 Canonical pool is Uniswap v2 — settled

The 0.49% transfer tax is incompatible with Uniswap v3 and v4 on the sell side. Both compute the
input amount by measuring the pool's own balance delta, and a token that skims a fee in transit
makes that check fail, so `CODE → WETH` through a normal v3 router reverts. v2 is the version that
tolerates fee-on-transfer, via `swapExactTokensForTokensSupportingFeeOnTransferTokens`.

Consequences accepted:

- Oracles read v2 cumulative prices rather than v3 tick accumulators. A v2 TWAP is coarser and
  needs a longer window for equivalent manipulation resistance, which is reflected in the window
  chosen in `PARAMETERS.md`.
- v2 liquidity is less capital-efficient, so realised slippage on treasury draws will be worse than
  a v3 pool of the same depth. The per-swap minimum-out bounds matter more, not less.
- Uniswap v2, v3, v4 and UniswapX are all live on Robinhood Chain, so this is a designation
  choice rather than an availability constraint.

### 1.2 Guardian set computed on-chain — settled

A 50-slot leaderboard maintained on deposit, frozen at each rollover. No trusted party, no merkle
root, and rollover stays permissionless as §3.2 requires.

One property worth stating plainly, because it is a real deviation from "the fifty largest
stakers": the board is **eventually** correct, not **continuously** correct. It self-heals upward
(a deposit that beats the smallest seat takes it immediately) but cannot self-heal downward,
because it does not track the field below the cut and so does not know who the 51st largest staker
is. A withdrawal can therefore leave a seated account smaller than an unseated one until someone
calls `pokeBoard`.

This is acceptable because the incentive to correct it is bilateral, which is unusual and is what
makes it converge. A seat is not purely a prize: it confers proposal rights but *removes* voting
rights. So a large staker wrongly outside the set wants in, and a staker wrongly inside it wants
out. Either party, or anyone at all, can fix the board at any time before the boundary, and only
the state at the boundary is consequential.

Tie-break at rank 50: **the incumbent keeps the seat**. `_boardConsider` compares strictly, so an
exactly-equal challenger does not unseat anyone. This avoids making the outcome depend on address
ordering, which would be gameable by grinding a vanity address.

### 1.3 Penalties are lazy, derived from bitmaps — settled

Each account stores two 128-bit masks per season: which scored proposals it voted on, and how. The
multiplier is computed on read as `0.90^wrongs × 0.85^absences`, with the exponents from a
population count.

This is not an optimisation, it is the only way the non-vote penalty can exist. Absence produces no
transaction, so there is nothing to hook and no way to enumerate the silent without iterating every
staker. Making absence the default state of a bit prices silence at zero gas.

Two consequences:

- **Penalty reset is free.** §3.2 says every multiplier is cleared at rollover. Because multipliers
  are derived from per-season bitmaps, incrementing the season index *is* the clearing. No loop.
- **The aggregate stays exact.** Quorum is a percentage of live effective Many power (§4.2), so the
  aggregate cannot be an estimate. At each verdict the losing tally and the absent remainder are
  both known, and because a penalty scales every affected account by the same factor, scaling
  distributes over the sum: reducing the aggregate by 10% of the losing tally plus 15% of the
  absent weight yields precisely the sum of the individually reduced weights. Verified by
  `testFuzz_manyEffective_tracksSumUnderArbitraryVotePatterns`.

Residual: the aggregate truncates once per verdict where individual reads truncate per account, so
the two differ by at most one wei per participant, always in the aggregate's favour. Quorum is
therefore very marginally harder to reach than the sum of individual weights would imply. Asserted
rather than hidden, in `test_manyEffective_tracksSumOfIndividualWeights`.

### 1.4 SAINE attestations are EIP-712 signed and relayed — settled

Operators sign; anyone submits. Three reasons this is the only shape that works:

- §5.5's equivocation slashing requires *two validly signed attestations from the same slot key*.
  With direct transactions there is no second signature to produce, because the contract simply
  rejects a second commit. The clause would be dead code.
- Ten funded hot wallets on the home chain is an operational burden and a key-management liability
  for every operator.
- §12 notes adjudication is transaction-heavy — 20 commit and reveal transactions per round across
  three tracks. A relayer can batch ten commitments into one transaction.

### 1.5 Penalty magnitudes — settled

The whitepaper governs, and the project brief's 50% belongs to the Guardian:

| Party | Event | Penalty |
| --- | --- | --- |
| Guardian | sponsored a proposal SAINE rejected | 50% |
| Many | voted against the SAINE verdict | 10% |
| Many | did not vote on an adjudicated proposal | 15% |

The ordering is load-bearing and is now a test (`test_penalty_votingDominatesAbstention`). A wrong
call must cost strictly less than silence, or abstention dominates and the electorate stops
engaging with exactly the difficult proposals the mechanism exists to judge.

### 1.6 No abstain option — settled

Ballots are For or Against. An abstain that avoided the 15% would be strictly better than voting on
every proposal for every participant, so everyone would abstain and the scoring system would stop
functioning. Absent weight is therefore exactly aggregate-minus-participated, which is also what
keeps the quorum arithmetic in 1.3 exact.

### 1.7 Delegation locked at the snapshot — settled

Delegation changes take effect at the next boundary, like stake and weights. One delegate per
season, one voting record, one multiplier for everyone behind them, and no fleeing a delegate after
a bad vote to shed exposure that §4.1 deliberately attaches.

Chains are forbidden in both directions: an account holding inbound delegation cannot delegate
onward, and an account that has delegated away cannot receive. Resolving a ballot therefore never
walks a list.

### 1.8 Missing parameters are timelock-tunable with documented defaults — settled

See `PARAMETERS.md`. Every value not fixed in §15 is a governance parameter behind the timelock
with a stated initial value and reasoning.

---

## 2. Decisions I made without asking, because there was no real alternative

### 2.1 Guardian delegation is voided in a bounded pass, not by prohibition

§4.1 says Guardians neither give nor receive delegation, but ranking is on own principal alone
(§4.1 again), so a large staker cannot escape a seat by delegating and the two rules can collide.
Handled in two directions, both without iteration:

- **Outbound.** At rollover, the loop over the fifty frozen seats also records each Guardian's
  outbound delegation in `voidedGuardianInbound`, which is subtracted from the delegate's ballot
  weight. Fifty iterations, once per quarter. A Guardian's stake votes nothing, through anyone.
- **Inbound.** A delegation pointing at an address that wins a seat resolves back to the delegator
  at read time (`resolvedDelegateeOf`). Without this, a member of the Many whose chosen delegate
  happened to grow into the top fifty would be unable to vote through them *and* would be charged
  15% for the resulting silence — punished for someone else's deposit. They now simply vote for
  themselves. Tested in `test_delegation_revertsToSelfWhenTheDelegateWinsASeat`.

I considered prohibiting delegation to any top-50 address and rejected it: seats are only known at
the boundary, so the prohibition cannot be enforced at delegation time, and the version that
excludes delegates from the leaderboard lets a whale dodge a seat for one wei of inbound
delegation.

### 2.2 Weight leaves on withdrawal *request*, tokens leave at the boundary

§3.1 says withdrawals settle at the boundary. Implemented as: principal and dCODE reduce
immediately, CODE is collectable after the boundary.

The alternative — reducing weight only on collection — would let a participant request an exit late
in a season and still carry full claim weight into the vintage freeze, which is the forfeiture §10.3
exists to impose. Current-season *voting* weight is untouched either way, because ballots read the
previous season's checkpoint, so this cannot be used to dodge a season's penalties
(`test_penalty_cannotBeEvadedByRequestingExit`).

### 2.3 The monotone vintage cap needs a second trace

§10.3's rule is "the lowest total stake the participant has held at any point since the vintage
froze". The principal trace cannot answer this. Checkpoint pushes at the same season key overwrite,
so an account that exits to zero and re-stakes inside one quarter leaves a trace showing only the
later, higher figure: the dip disappears, and with it the permanent forfeiture.

`_lowWater` records the *floor* of each season rather than its last value, written only when
principal falls. The minimum over the period is then the principal at the season's close, minimised
against every floor recorded since. A season with no entry never fell.

This was caught by `test_withdraw_monotoneCapIsPermanent` failing against the first implementation,
which is the test earning its keep.

### 2.4 Exit settles every open vintage, and the exiting account pays for it

`requestWithdraw` takes the full ordered list of the account's open vintages and reverts if it is
short or misordered. The vault must settle what accrued at the old weight before its base contracts
(§10.3), and that cannot be done lazily because the accumulator's denominator is global.

Cost scales with seasons participated: roughly one vault call per season since first staking. After
five years that is twenty calls in one transaction. Cheap on this chain, and it is the departing
participant paying for their own departure rather than socialising it onto the next reader. If it
ever becomes a problem the list can be paginated across several calls before the final reduction.

### 2.5 A true burn, not a dead address

§2.3 describes the sinks as sending to "the dead address". `Code.burn` reduces `totalSupply`
instead. Identical economics, and deflation becomes directly readable from the token rather than
requiring anyone to subtract a particular address's balance. Nothing is left in a balance that
could later be argued to be recoverable.

### 2.6 The token seals itself on a deadline

§14 promises no whitelist change "by anyone, ever". A `renounceOwnership` that the deployer must
remember to call does not deliver that. `setExempt` reverts unconditionally after
`SEAL_WINDOW` (7 days) from deployment, whether or not `seal()` was ever called, so a deployment
that forgets still becomes immutable on schedule (`test_seal_happensOnScheduleEvenIfForgotten`).

### 2.7 Governance does not open with an empty Many

With 50 or fewer stakers everyone is a Guardian, the Many is empty, and quorum is unreachable
forever. `openFirstSeason` reverts until the board can seat fifty, so season 1 cannot begin in a
state where §4.1's split is meaningless.

### 2.8 Only settled slots score anyone

A proposal that has opened its adjudication slot but not yet reached a verdict must not read as an
absence — nobody has been given anything to be right or wrong about yet. The multiplier masks
against `settledMask`, not `scoredCount`.

### 2.9 Protocol addresses are barred from staking at the door

Invariant 3 and §2.4 exclude the treasury, escrow, vault and every other protocol contract from
staking, ranking and quorum. My first pass left this to convention: nothing in `DCode` stopped the
treasury calling `stake()`, it simply never would.

That is not an invariant. Any future proposal that routed treasury CODE through the staking vault,
for any reason, would hand the treasury 500,000,000 of governance weight, which is a permanent lock
on all fifty Guardian seats and a majority of every quorum. `barredFromStaking` is now checked in
`stake()` and set at wiring time, so the exclusion holds regardless of what governance later
decides to do with treasury funds.

### 2.10 Scored slots are strictly serial, which advisory rounds must respect at settlement

This one changed the design. §6.3 serialises origination, and I had leaned on that to derive absent
weight: with one proposal at a time, no penalty lands mid-vote, so the aggregate is constant across
a voting window and absence is the aggregate less the two tallies.

But §5.6 puts advisory rounds on a background track. An advisory verdict settling in the middle of a
binding proposal's voting window applies penalties mid-window, so ballots cast before it and after
it are weighted on different multipliers. The two tallies then no longer sum against any single
denominator, and the derived absent weight is simply wrong. Quorum is a percentage of that number,
so this is not a rounding concern.

Fixed in two parts:

- Each slot records the settled-verdict mask and the aggregate power as they stood when it opened
  (`slotOpenMask`, `slotOpenPower`). Every ballot on a proposal is weighted on the terms that
  existed when that proposal opened, and absent weight is derived against the same base. This is
  also the natural reading of §7.2's "voting power for the remainder of the season": the remainder
  is measured in proposals, not seconds.
- Settlement is serialised. A slot cannot open while another is open, and cannot settle unless it is
  the open one. Advisory rounds lose nothing they were promised: they still never block the binding
  queue, their verdicts are still produced whenever the agents produce them, and only the instant
  their penalties land is ordered. Every participant's weight then moves at discrete, publicly
  known moments rather than at whatever moment an advisory reveal happened to be relayed.

The alternative was to let the aggregate drift and accept an approximate quorum denominator. For a
number that decides whether the treasury spends, approximate is not good enough.

### 2.11 The vintage vault distinguishes an exit from a cap it is only now learning about

Two different contractions reduce a participant's claim weight, and my first pass ran both through
one code path. The tests caught it.

An **exit** gives up weight that was genuinely held until that instant, so §10.3 settles everything
that arrived while it was held before the base contracts. A **monotone cap the vault has not yet
seen** is different: the participant's stake had already fallen below their frozen weight before the
vault ever registered them, so the difference was never claim weight they held at any point after
the freeze. Settling it pays them for weight that did not exist, and in the failing test it paid
Carol 100 where she was owed 40.

The gap arises because the staking vault pushes a sync on withdrawal, but a withdrawal during season
N cannot sync vintage N, which has not frozen yet. So the cap on the *current* season's vintage is
always learned late, at first registration.

The share of past arrivals that had been allocated to that phantom weight is now burned. That is the
same treatment §2.3 gives the penalty differential, for the same reason: it is value credited
against weight counted in the base that nobody can ever claim. Crucially it is *not* redistributed
to the other participants, because §2.3's objection to profiting from a neighbour's shortfall
applies here too.

### 2.12 Liability is rounded up, not down

Each participant's claim truncates independently, so the sum of the individual floors can exceed the
floor of the sum by up to a wei per participant. Tracking the distributable pot with a floor meant
the last claimant of a vintage hit an underflow and could not be paid. Found by fuzzing.

The pot is now rounded up, at a cost of at most one wei of under-burn per credit. The error direction
matters more than its size: it errs toward the participants and toward a slightly smaller burn,
rather than toward a vault that cannot settle what it says it owes.

### 2.13 Advisory rounds occupy the scored slot rather than running fully in the background

§5.6 and §6.3 describe advisory rounds as running "on a background track" that "never blocks the
binding queue". In this implementation a defeated proposal keeps its scored slot until its advisory
verdict lands, which means the next origination proposal's vote cannot open until then. That is a
deviation from the description and it is forced, so it is worth setting out why.

Three requirements collide. §4.2 wants quorum computed against live effective power, exactly. §7.1
wants advisory rounds to score the electorate. §7.1 also makes penalties multiplicative within a
season.

Multiplicative penalties do not commute with parallel settlement. If an advisory round and a binding
round overlap, an account penalised in both has a true final weight of `base x 0.9 x 0.9`, but two
independently computed reductions each take 10% of the same starting weight and remove 0.19 where
0.20 is removed. The aggregate then drifts from the sum of the individual weights, and quorum is a
percentage of that aggregate. I tried deferring the reductions to the next slot boundary; it fails
for exactly the accounts penalised twice.

The cost of serialising turns out to be nothing. A defeated proposal's advisory round takes one
commit-and-reveal cycle, which is precisely what a successful proposal's binding round takes, so the
queue consumes 7 days per proposal either way and the capacity arithmetic in §3.1 above is unchanged.
The deviation is descriptive, not economic.

A lapsed round is handled separately, through `voidScoredSlot`: the slot is retired without setting
its settled bit, so nobody reads as absent on a round that never produced a judgement, and the queue
still moves on.

### 2.14 The oracle maintains itself at the point of use

Found by the integration test, and it would have been a launch-day outage. Every price-dependent
entry point in the protocol reverts on a stale average: treasury draws, the proposal bond, the
operator bond, the per-deal ceiling. `update()` deliberately reverts when called too soon, which is
right for a keeper but useless as a self-heal, because a caller cannot know whether enough time has
passed.

So an oracle nobody maintained would not merely go quiet. It would stop originations and drawdowns,
and the failure would read as a rejected proposal rather than as missing infrastructure.

`poke()` folds in the elapsed interval if it is long enough and returns silently if it is not.
`propose()` and `fundDraw()` call it on the way past, so the paths that need a price maintain the
oracle themselves and the protocol carries no dependency on anyone running a bot. A poke after a long
silence yields an average over that whole silence, which is a longer window than configured and
therefore more manipulation-resistant, not less.

### 2.15 Parameter proposals are scored exactly like originations

§7.1's table is headed "Every adjudicated origination proposal", and names only halts and tranche
checks as scoring nobody. Parameter proposals fall in the gap: they are adjudicated (§5.1 says SAINE
reviews "every proposal the Many approve") but they are not originations.

They are scored here, and the sponsor of a rejected one takes the 50%. Exempting them would make the
proposals that change the rules the cheapest thing in the system to get wrong, which inverts the risk
ordering the penalty schedule exists to create. They do consume the serialised queue, but they are
counted against the Guardian's two-per-season cap rather than the origination cap, since §15 sizes
that cap by adjudication capacity for deals.

### 2.16 Deployment requires address prediction

Two constructor dependencies are circular. The token needs the treasury address it pays tax to, and
the treasury needs the token. The timelock needs the governor that proposes to it, and the governor
needs the timelock. Neither can be fixed by wiring afterwards, because both are immutable by design
(§14: the token "holds no ongoing power", and the timelock is self-administered from the first block
with no deployer admin left behind).

The deploy therefore computes addresses ahead of time from the deployer's nonce sequence and passes
them into constructors. The integration test does the same thing and asserts each prediction held, so
a mistake in the deployment procedure fails a test rather than producing a live system wired to empty
addresses.

### 2.17 No pending delay before voting opens

§6.3 lists a `Pending` state between `Draft` and `Active`. Voting opens immediately on submission
here. The manifest is pinned to IPFS and hash-committed before `propose()` can succeed (§6.1), so
there is nothing about the proposal that a delay would reveal, and a delay would extend the serialised
queue's occupancy per proposal without adding information. Reinstating it is a one-line change if you
want the review window for its own sake.

### 2.18 The messaging layer sits behind an adapter interface

§12 names LayerZero, but nothing in `Satellite.sol` or `Receiver.sol` depends on it. All cross-chain
traffic goes through two functions on `IBridgeAdapter`: `quoteFee` and `send`. Replacing LayerZero
with anything else is a new adapter contract and no change to either.

Quoting is part of the interface rather than an off-chain estimate someone passes in, because §15's
batch trigger is "20x bridge cost" and a caller-supplied cost would let whoever triggers the batch
decide when the batch triggers.

### 2.19 The floor path opens on sustained illiquidity, not on one quote

§8.5 says an installment settles against the floor when it "cannot clear the repayment swap within
its slippage bound", and invariant 14 says the escrow decides, never the investee. The whitepaper
does not say how illiquidity is established, and the obvious implementation is exploitable.

If a single quote were enough, the attack is: push the pool thin, certify, settle against the floor
at the recorded value, unwind the push. The investee gets to pick whichever path is cheaper that
month, which is precisely the free option §8.5 refuses them.

So certification takes repeated failures spaced hours apart, three strikes twelve hours apart by
default, both governance-tunable within bounds. A day of genuine absence is expensive to manufacture
in a way that one block is not. Recovery before the third strike authorises nothing.

Two supporting rules keep the decision out of the investee's hands entirely. The token path closes
by itself when the pool is thin, because `payInstallment` reverts on its minimum-out. And the floor
path is closed unless certification has already happened, so in any given month exactly one path is
open and it is not the investee who chose which.

### 2.20 The minimum WETH per installment comes from the home chain

The figure that decides which settlement path is open is set at registration from the escrow, not
computed on the satellite chain. §8.5 gives that decision to the escrow, and letting a satellite
derive it from local liquidity would move the decision to the chain with the manipulable pool.

### 2.21 Infrastructure costs never touch a batch

§9: "Bridge and swap costs are paid from the maintenance slice, so stakers' distributions are never
haircut by infrastructure." So the bridge fee comes from native gas the satellite holds, and the
caller's bounty comes from a separately funded WETH pool. A batch that crosses is the whole of what
the swap produced. Asserted directly in `test_bridge_bountyComesFromMaintenanceNotTheBatch`.

The home-chain buyback is deliberately *unbountied*, which is the opposite choice and worth saying
why. Bridging needs a bounty because it is one transaction on a foreign chain that benefits people
who are not there. A buyback benefits every holder of the vintage it credits, all of whom are on this
chain and already motivated, and a bounty would be paid out of the very distribution it exists to
deliver.

### 2.22 Each queued repayment keeps its own vintage and its own WETH

The receiver queues per-entry amounts rather than a pooled total. Pooling and apportioning afterwards
is arithmetically equivalent only if every entry clears at the same price, and §9's requirement that
"large purchases split across intervals" guarantees they will not. Keeping the entries separate means
the CODE bought with a given repayment is credited to the season that funded that deal, at the price
that repayment actually got.

A repayment larger than the per-execution cap is partially converted, with the remainder left at the
head of the queue. The obligation is reported to the escrow only when the last of it converts, so a
split repayment is never credited twice.

### 2.23 The satellite's governor must be a cross-chain executor, not a key

The home-chain timelock owns the protocol (§14) but cannot call a function on another chain directly.
`Satellite.governor` therefore has to be an executor that acts only on messages from that timelock.
Pointing it at an ordinary key would put a satellite's slippage bounds and strike thresholds outside
governance, which §14 does not permit. **This is a deployment requirement, not something the contract
can enforce**, and it is the sharpest remaining edge in the cross-chain design.

### 2.24 LayerZero moves messages; Stargate moves the value

§9 needs WETH to arrive on the home chain alongside its manifest, and §12 names LayerZero. But raw
LayerZero V2 messaging cannot move a token: `ILayerZeroEndpointV2.send` carries bytes, nothing more.
Building against it alone would have produced a receiver holding manifests for value that never came.

The implementation therefore uses Stargate, LayerZero's asset layer, whose `sendToken` carries the
transfer and a composed message in a single crossing. That matters beyond convenience: bridging value
and manifest over two channels would open a window where the home chain holds WETH it cannot attribute
to any vintage, and a replay or reordering on either channel would misroute a return.

Both surfaces are declared locally in `ILayerZero.sol` rather than imported, for the reason given in
`IExternal.sol`: the real packages drag in the whole OApp stack and its own pinned OpenZeppelin copy.
Every struct and signature was transcribed field by field from `@layerzerolabs/lz-evm-protocol-v2`
2.0.11, `@layerzerolabs/lz-evm-oapp-v2` 2.3.44 and `@stargatefinance/stg-evm-v2` 9.0.0, and the
versions are recorded in the file so a reviewer can diff them. **These are ABI-level dependencies on
contracts the DAO does not control, so re-check before mainnet**: a struct field added upstream would
silently change the encoding.

### 2.25 The bridge takes a fee, so the home adapter holds a maintenance buffer

Stargate delivers less than was sent. §9 says infrastructure costs come from the maintenance slice and
that "stakers' distributions are never haircut by infrastructure", so the shortfall cannot simply be
passed through to the vintage.

`StargateHomeAdapter` therefore holds a maintenance-funded WETH buffer and covers the difference, so
the full manifest value reaches the receiver. Only when that buffer is empty does the shortfall fall on
the repayment, and then it is scaled across the entries pro-rata and announced in a
`ShortfallSocialised` event. A silent haircut would make §9's promise false in exactly the case where
nobody was watching, which is the case that matters.

The reverse also has to be handled: a satellite that over-sends produces a surplus, and that surplus
goes to the buffer that paid for the crossing rather than to whichever vintage happened to be in the
batch.

### 2.26 Three checks authenticate a delivery, and the third is the one that matters

`lzCompose` is otherwise callable by anyone with a well-formed message. So: only the LayerZero endpoint
may call it, only the Stargate pool may be the composing sender, and the (source endpoint id,
composing address) pair must match the registry.

The third is the load-bearing one. Without it, any Stargate user on any connected chain could send a
dust transfer with a fabricated manifest and have it credited to a vintage of their choosing. The first
two checks do not catch that, because such a transfer arrives through the genuine endpoint and the
genuine pool.

The landed amount is also read from the composed message's header, written by the destination-side OFT,
rather than from the manifest. The manifest is the source chain's claim; the header is the only figure
the home chain computed itself.

### 2.27 The deploy script is the thing under test

`script/Deploy.s.sol` exposes `DeployLib.deploy` / `wire` / `distribute`, and both integration tests
call it rather than reimplementing the wiring. A deploy script that nothing exercises is a liability:
the address predictions in §2.16 depend on an exact deployment order, and a reordering would otherwise
surface as a live system wired to empty addresses rather than as a failing test.

`CrossChainTest` additionally asserts that every `configurer` is zero after wiring, so nothing in the
protocol can be rewired outside governance once the deployment finishes.

### 2.28 Attestation fees accrue in USD, are frozen at round open, and belong to the operator who committed

§5.8 promises that "in phase two, independent operators are paid per attestation from the treasury,
giving the DAO a performance lever and operators a reason to stay live". Nothing in the contracts paid
anybody, and the omission is not cosmetic. A phase-two operator posts a $1,000 bond, pays for inference
on every round including the advisory ones nobody voted on, risks a quarter of the bond on a missed
reveal and all of it on equivocation, and without a fee receives nothing at all. The rational response
is to decline the seat, or to take it and go quiet, which walks the board toward the eight-reveal floor
that freezes every outcome. Four judgement calls inside the mechanism:

**Accrued in USD, not converted at settlement.** Converting would mean reading the oracle inside
`settleRound`, and a stale average would then revert settlement. On the origination track that also
freezes the queue, because invariant 6 allows one proposal at a time, so a missed keeper poke would
become a governance halt. An operator carrying price risk between accrual and claim is a much smaller
problem. `test_fees_settlementCannotBeBlockedByAStaleOracle` pins it.

**The rate is frozen when the round opens.** Reading `attestationFeeUsd` at settlement would let
governance reprice work already done, and reading it at each reveal would pay early revealers more than
late ones in the same round. Freezing it at open means an operator knows what a round pays before
spending inference on it. It also folds the phase test in: a round opened in phase one pays nothing
however long it stays open.

**Credited on reveal, for every outcome including a lapse.** Not on commit, because §15 already forfeits
a quarter of the bond for committing and going silent, and paying for the commitment as well would
reward exactly the behaviour the forfeit punishes. For every outcome, because a lapse is not the
revealing slots' fault: paying only on approvals and rejections would leave the eight who did their job
unpaid because two others went dark, which is the opposite of "a reason to stay live".

**Credited to the operator who held the seat at commit, not the incumbent at settlement.** Reassignment
is a governance act available at any time (§5.2), the reveal is signed by the key frozen at commit and so
can only have come from the committing operator, and paying whoever holds the seat when the round settles
would let a reassignment take earnings that were already worked for. `roundOperatorOf` is written only on
rounds that actually pay, so phase one costs no extra gas. An equivocation report clears that record for
the reported round: a slot that signed two contradictory attestations did not perform an attestation.

Claiming is permissionless with a fixed recipient. The operator address is whatever governance assigned,
which may be a multisig or a cold key with no business sending routine transactions, so anyone may
trigger the payment and it can only ever go to the operator. Because the debt is USD-denominated, timing
the claim gains nothing, so there is no griefing angle in claiming on somebody's behalf.

### 2.29 The fee pool is funded by push and sync, because `Treasury.spend` cannot approve a spender

The obvious shape is `fundFeePool(amount)` pulling with `transferFrom`, and it is unusable by the only
party that matters. `Treasury.spend` pushes tokens to a recipient; it has no approve path. A proposal
funding the pool through a pull would have to route the DAO's CODE through some intermediary account
first, which is precisely the kind of call §6.2's manifest rules exist to make suspicious. So a proposal
pairs `treasury.spend(code, saine, amount)` with `saine.syncFeePool()`, and the CODE never leaves
protocol contracts. `test_fees_governanceFundsThePoolThroughTheTreasury` runs it end to end
through the real governor, timelock and treasury.

The sync is permissionless and the keeper runs it, so a proposal carries only the spend: since the
registry track (§2.30) forbids parameter proposals from targeting the registry, the two calls can no
longer travel together, and they do not need to. CODE delivered to the registry sits uncredited until
someone syncs it, and anyone can.

`syncFeePool` credits only the surplus over `totalBondedCode + feePool`, which is why that running total
exists. The registry holds two pools of CODE in one balance: bonds, which belong to operators and are
burnable only by §15's penalties, and the fee pool, which belongs to the DAO. Tracking the bonded total
makes the separation provable rather than asserted, and every test that touches a bond asserts
`balanceOf(saine) == totalBondedCode + feePool` afterwards.

Neither `fundFeePool` nor `setAttestationFee` is seeded into the known-target registry, deliberately.
§6.2's registry sorts calls into routine ones the agents can skim and novel ones the package flags for
close reading, and a proposal that pays the board is the second kind.

### 2.30 A fourth track, for proposals the board cannot veto

Every binding proposal passed through SAINE, including a parameter proposal that reassigned a slot. That
is circular: a board with a reason to stay seated could reject its own replacement, and rejecting it
would also slash the Guardian who proposed it and every voter who agreed, under §7.2 and §7.3. Before
attestation fees the reason was reputational; with them it is a salary. A board that can block its own
removal cannot be removed, and §5.5's entire answer to capture is that the electorate can act on what
the published reasons show them. So there has to be a path by which they act.

`Kind.Registry` is that path. Its calls target the agent registry and nothing else, and a passed vote is
the whole authorisation: no round opens, no verdict is sought, nobody is scored or slashed in either
direction. Six choices inside it:

**Restricted by target, not by selector.** `Saine`'s only governance-gated entry points are `assignSlot`
and `setAttestationFee`, and the contract is immutable, so testing the target is exactly equivalent to
listing those two selectors and cannot drift from the contract as a selector list could. Everything else
on that address is already permissionless, so routing it through the timelock grants a caller nothing.

**The registry track is the only route to the registry.** Parameter proposals may no longer target
`Saine` at all. Two routes for the same call, differing only in whether the board can veto it, would
make the veto decorative: a proposer would always take the route without it. This mirrors the
funding/parameter split in §6.2 and is enforced the same way, by shape.

**Unscored, like halt.** Scoring means scoring against a verdict (§7.1), and this track produces none.
It reads ballot weight against a mask snapshotted at its own opening, so it takes no scored slot, queues
behind nothing, and cannot jam the season's serial scoring by never settling. A voter who sits one out
takes no non-vote penalty, because there is nothing to have been wrong about.

**Queued from `Succeeded`, not `Approved`.** `Approved` means the board approved. On this track the board
is not asked, so claiming that state would be a lie told in a public enum that a frontend will render.

**The same quorum and the same simple majority as everywhere else.** The temptation is to demand a
supermajority for the one track with no second check. It is the wrong instinct: this is the route by
which a captured board gets replaced, and making it harder than an ordinary proposal hands the board
exactly the protection the track exists to remove. It does keep every other guard, so it is
Guardian-proposed, bonded, quorum-bound and timelocked.

**It controls the board, not the treasury.** The rate can be set here, but no CODE reaches the fee pool
without `treasury.spend`, which is a parameter proposal and still adjudicated. The electorate gains the
power to hire, fire and price the board; the board keeps its say over money. That split is the reason
this exemption is narrow enough to be safe.

`test_registry_survivesABoardThatHasGoneCompletelyDark` is the test that matters: an origination lapses
because not one commitment arrives, and a registry proposal then replaces the seat regardless.

**This is an addition to §6 as written, which describes three tracks.** The whitepaper needs a fourth.

---

## 3. Ruled on after review

1. **Origination cap reduced to 10.** §15 says 12, but serialised origination occupies the queue
   for 7 days (5 days voting, 24h commit, 24h reveal), so twelve is 84 days of a 91-day season with
   no gaps and instant submission, and §6.2 forbids opening a proposal that cannot finish in-season.
   Ten leaves roughly three weeks of slack for gaps between proposals and the occasional lapsed
   round. **This is a deviation from the §15 table and the whitepaper should be updated to match.**

2. **TGE registration: investee registers, SAINE holds a challenge window.** Cheapest path for
   honest teams. Worth noting the risk that was accepted: the default outcome of agent inaction is
   that whatever the investee claimed stands. The challenge window length should therefore be
   generous, and a registration that converts a warrant into a vesting schedule is exactly the kind
   of event the agents should be reliably awake for.

3. **Sale, liquidity and team vesting are out of scope.** The deploy script sends the 40% and the 6%
   to addresses you nominate. The team's 6% therefore vests on trust rather than in code; §2.1's
   "vesting linearly over 12 months" is not enforced by anything in this repository.

4. **Lapsed rounds carry the full 30-day cooldown.** Uniform treatment with any other failure to
   pass. Recorded for the avoidance of doubt: this cuts against §5.4's "a stalled or unreachable
   agent set freezes outcomes; it never punishes users", since the sponsor waits 30 days for the
   board's downtime. Chosen deliberately after that trade-off was put.

5. **Bridge-cost basis:** LayerZero `quote()` at batch time. **Rollover bounty:** a maintenance-
   funded pool holding no other rights.

6. **The board no longer adjudicates proposals about the board.** Ruled by Dom on 18 August: a
   proposal whose only calls target the agent registry passes on the Many's vote alone. Built as a
   fourth track rather than as a conditional inside the parameter track, so the different lifecycle
   is visible in the proposal's own kind rather than inferred from its calldata. Reasoning and the
   six choices inside it are in §2.30. The narrow scope is what makes it safe: the electorate gains
   the power to seat, unseat and price the board, and the board keeps its say over every proposal
   that moves money.

---

## 4. Divergences from the whitepaper that need a document update

1. Originations per season: §15 says 12, the build sets 10. See §3.1 above.
2. §16.3 lists 19 invariants; an earlier note of mine said 20. No code impact.
3. §2.3 and §9 describe burns as sends to "the dead address"; the implementation performs a true
   burn that reduces `totalSupply`. See §2.5.
4. §6 describes three proposal tracks; there are now four. The registry track carries proposals whose
   only calls target the agent registry, and it is not adjudicated. See §2.30.
5. §5.8 promises operators are paid per attestation but sets no rate. §15 now needs a row: zero at
   genesis, governance-set, ceiling $100 per attestation. See §2.28.

---

## 5. Superseded

The original open-questions list, retained for reference.

1. **§15's origination cap of 12 is very close to infeasible.** Serialised origination costs 5 days
   voting plus 24h commit plus 24h reveal, so 7 days of queue occupancy per proposal. Twelve
   proposals is 84 days of a 91-day season, assuming zero gap between them and instant submission.
   Any slack at all and the twelfth cannot finish before the boundary, and §6.2 forbids opening a
   proposal that cannot complete in-season. Effective capacity is 10 to 11. Options: accept 12 as a
   ceiling that is never reached, reduce it to 10 and state it honestly, or shorten the voting
   period.
2. **Who registers an investee's TGE?** §16.1 has the escrow "register TGE (token address and
   supply) to convert warrants into vesting schedules". That is an oracle problem: someone must
   attest that token X belongs to this investee and its supply is Y. Candidates: a passed parameter
   proposal, a SAINE tranche-style commit-reveal round, or the investee themselves with a SAINE
   challenge window.
3. **Are the sale, liquidity and team vesting contracts in scope?** §2.1 allocates 40% to public
   sale and liquidity and 6% to team vesting over 12 months, but §16.1's inventory contains
   neither. Currently out of scope; the deploy script would send those allocations to addresses
   you nominate.
4. **Lapsed proposals.** §6.4 sets a 30-day cooldown for *rejected or defeated* deals. A round that
   lapses for want of reveals (§5.4) is neither. Proposed: no cooldown, because nobody was judged
   and no rejection registry entry is written. Needs confirmation.
5. **Bridge-cost basis for the batch trigger.** §15 batches at "20x bridge cost", but bridge cost
   is a live quote from the messaging layer. Proposed: read LayerZero's `quote()` at batch time.
6. **Rollover bounty funding.** §3.2 gives rollover "a small CODE bounty from maintenance", but §14
   says the maintenance address holds no protocol permissions. Proposed: a pre-funded bounty pool
   contract that maintenance tops up and that holds no other rights.
