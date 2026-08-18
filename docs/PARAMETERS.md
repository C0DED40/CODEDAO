# CODE DAO — parameters

## Fixed by whitepaper §15

Compiled as constants. Changing any of these is a redeploy, not a proposal.

| Parameter | Value | Where |
| --- | --- | --- |
| Total supply | 1,000,000,000 CODE | `Code.TOTAL_SUPPLY` |
| Distribution | 50% treasury / 40% sale and LP / 6% team / 4% ops | deploy script |
| Transaction tax | 0.49% (0.40 treasury, 0.09 maintenance) | `Code.TREASURY_BPS`, `Code.MAINTENANCE_BPS` |
| Team vesting | 12-month linear | vesting contract (scope open) |
| Guardian seats | 50 | `DCode.GUARDIAN_SEATS` |
| Season length | 13 weeks | `DCode.SEASON_LENGTH` |
| Voting period | 5 days | governor |
| Commit / reveal window | 24h / 24h | `Saine` |
| Timelock delay | 24h | `CodeTimelock` |
| Quorum | 10% of seasonal effective voting power | governor |
| Many penalty, wrong vote | 10%, multiplicative, season-bounded | `PenaltyMath.WRONG_VOTE_MULT` |
| Many penalty, non-vote | 15%, multiplicative, season-bounded | `PenaltyMath.NON_VOTE_MULT` |
| Guardian penalty | 50% plus proposal exclusion | `PenaltyMath.GUARDIAN_MULT` |
| SAINE board | 10 agents, 10 distinct models | `Saine` |
| SAINE approval threshold | 6 of 10 | `Saine` |
| SAINE liveness floor | 8 of 10 reveals | `Saine` |
| Provider diversity | min 4 providers all phases; 2-slot operator cap from phase two | `Saine` |
| Operator bond | $1,000 of CODE per slot, revalued each boundary | `Saine` |
| Reveal-failure forfeit | 25% of slot bond, burned | `Saine` |
| Attestation fee | 0 at genesis, set by governance, ceiling $100 per attestation | `Saine.attestationFeeUsd` |
| Attestation fee scope | phase two only, per revealed attestation, USD-denominated | `Saine` |
| Proposal bond | $1,000 of liquid CODE | governor |
| Per-deal cap | 0.5% of treasury balance at TWAP | `Treasury` |
| Per-deal floor | 5 WETH; ceiling is the greater of cap and floor | `Treasury` |
| Originations per season | 10 (§15 says 12; see DECISIONS §3.1) | governor |
| Guardian proposals per season | 2 | governor |
| Tranche split | 40 / 30 / 30 | `Escrow` |
| Vesting cap | 24 months, monthly installments | `Escrow` |
| Long-stop | 36 months from first draw | `Escrow` |
| Long-stop floor | 1.25x drawn value, WETH-denominated | `Escrow` |
| Default grace period | one missed installment | `Escrow` |
| Reproposal cooldown | 30 days, material change required | governor |
| Milestone window | per manifest, max 12 months each | `Escrow` |
| Tranche claim expiry | 6 months per unlocked tranche | `Escrow` |
| Repayment batch trigger | 20x bridge cost or 30 days | `Satellite` |
| Bridge cost basis | adapter `quoteFee()` at batch time | `Satellite` |
| Return split | 50% burn / 50% vintage | `Receiver` |
| Phase two trigger | end of season 8, or 2,000 WETH cumulative deployed | `Saine` |

## Not in §15 — timelock-tunable, with proposed initial values

Per the ruling in DECISIONS §1.8, each is a governance parameter behind the timelock. Initial
values below are proposals awaiting review.

| Parameter | Proposed | Reasoning |
| --- | --- | --- |
| Oracle TWAP window | 30 minutes | A v2 cumulative-price oracle is coarser than a v3 tick oracle, so the window has to do more work. 30 minutes makes a sustained multi-block push expensive relative to a 0.5%-of-treasury cheque, while still tracking a genuinely moving market closely enough that draws are not priced off stale data. |
| Treasury draw max slippage | 100 bps | Draws convert treasury CODE to WETH and are the largest recurring swap. Tight enough that a sandwich is unprofitable at typical depth; loose enough that a legitimate draw does not revert on ordinary volatility. Reverting is the safe failure here — the draw simply retries. |
| Repayment swap max slippage | 200 bps | Satellite swaps happen in the investee's token against native liquidity that may be thin, and a revert leaves a founder who has already paid unable to discharge. Wider bound, with the escrow's floor path as the backstop when it still cannot clear. |
| Buyback max slippage | 150 bps | Large purchases split across intervals per §9, so each tranche should clear comfortably. |
| Buyback split threshold | 1% of pool reserves | Above this a purchase is split across intervals rather than executed whole. |
| Minimum launch stake | governance opens only once 50 seats are filled | Prevents a launch where everyone is a Guardian and quorum is unreachable. See DECISIONS §2.7. |
| Illiquidity strikes / gap | 3 strikes, 12h apart | A single quote showing thin liquidity is cheap to manufacture; a day of it is not. See DECISIONS §2.19. |
| Bridge bounty | 0.002 WETH from a maintenance-funded pool | Never drawn from a batch (§9). |
| Buyback interval / cap | 10 minutes, 5 WETH per execution | Implements §9's "large purchases split across intervals". |
| Rollover bounty | to be set | Funded from a maintenance-topped pool holding no other rights. See DECISIONS §3.6. |

## Notes

All timing is timestamp-denominated. `block.number` appears nowhere: on Arbitrum-stack chains it
tracks an approximation of the L1 block number, so block-denominated logic is wrong by construction
(§12).
