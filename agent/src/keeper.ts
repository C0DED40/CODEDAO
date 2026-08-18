/**
 * The keeper: the permissionless calls nobody is obliged to make.
 *
 * Several protocol mechanisms are deliberately open to anyone and bountied or self-interested, so the
 * design carries no privileged infrastructure. That is a good property and it has a failure mode: a
 * function anyone may call is a function everyone may ignore. Each of these has a concrete cost when it
 * goes uncalled:
 *
 *   - **Season rollover** (§3.2). Until it runs, penalties from the closed season are still in force, the
 *     new electorate has no weight, and no proposal can open because §6.2 refuses anything that cannot
 *     finish in-season. Governance stops.
 *   - **Round settlement** (§5.4). An unsettled round is a proposal in limbo and, on the origination
 *     track, a queue that never frees: invariant 6 allows one at a time, so the next proposal cannot open.
 *   - **Bridge batching** (§9). Repayments sit on the satellite chain. The 30-day trigger bounds the
 *     delay only if someone calls.
 *   - **Buybacks** (§9). WETH sits in the receiver, unconverted, so no CODE is burned and no vintage is
 *     credited.
 *   - **Bond revaluation** (§5.5). A bond that has fallen below target keeps its slot live, which means a
 *     seat is attesting against collateral that no longer covers it.
 *   - **Oracle maintenance**. Now self-healing at the point of use, but a poke keeps the average fresh for
 *     readers that cannot poke, such as the per-deal ceiling a proposer reads before submitting.
 *
 * The keeper does not decide anything. Every call here is one the contracts already permit from any
 * address, and the harness runs them because it is the process most likely to be awake.
 */

import type { Abi, Address, Hex, PublicClient, WalletClient } from 'viem'
import { SAINE_ABI, DCODE_ABI, GOVERNOR_ABI, SATELLITE_ABI, RECEIVER_ABI, ORACLE_ABI } from './chain/abi.js'

export interface KeeperTargets {
  readonly saine: Address
  readonly dcode: Address
  readonly governor: Address
  readonly oracle: Address
  readonly receiver: Address
  /** Satellites are per investee chain, so each needs its own client. */
  readonly satellites?: readonly { readonly chainId: number; readonly address: Address }[]
}

export interface KeeperDeps {
  readonly reader: PublicClient
  readonly wallet: WalletClient
  readonly targets: KeeperTargets
  readonly now?: () => number
  readonly log?: (msg: string, detail?: unknown) => void
}

export interface KeeperAction {
  readonly name: string
  readonly reason: string
  readonly txHash?: Hex
  readonly skipped?: string
  readonly error?: string
}

/**
 * Run one pass. Every step is independent and a failure in one must not stop the rest: a reverting
 * rollover should not prevent a buyback that is separately due.
 */
export async function runKeeperPass(deps: KeeperDeps): Promise<KeeperAction[]> {
  const actions: KeeperAction[] = []
  const log = deps.log ?? (() => {})

  for (const step of [settleDueRounds, rolloverIfDue, revalueBonds, pokeOracle, executeBuyback]) {
    try {
      actions.push(...(await step(deps)))
    } catch (err) {
      actions.push({ name: step.name, reason: 'step threw', error: String(err) })
      log(`keeper step ${step.name} failed`, err)
    }
  }
  return actions
}

/**
 * Settle any round whose reveal window has closed.
 *
 * On the origination track this is the call that frees the queue, so leaving it undone stalls every
 * subsequent proposal, not just this one.
 */
export async function settleDueRounds(deps: KeeperDeps): Promise<KeeperAction[]> {
  const now = Math.floor((deps.now ?? Date.now)() / 1000)
  const count = (await deps.reader.readContract({
    address: deps.targets.saine,
    abi: SAINE_ABI as Abi,
    functionName: 'roundCount',
  })) as bigint

  const out: KeeperAction[] = []
  // Only the tail is worth scanning: anything older is long settled.
  const from = count > 20n ? count - 20n : 1n
  for (let id = from; id <= count; id += 1n) {
    const r = (await deps.reader.readContract({
      address: deps.targets.saine,
      abi: SAINE_ABI as Abi,
      functionName: 'getRound',
      args: [id],
    })) as { state: number; revealEnd: bigint; commits: number; reveals: number }

    if (r.state !== 1) continue // not Open
    const ready = now > Number(r.revealEnd) || (r.commits > 0 && r.reveals === r.commits)
    if (!ready) continue

    const txHash = await deps.wallet.writeContract({
      address: deps.targets.saine,
      abi: SAINE_ABI as Abi,
      functionName: 'settleRound',
      args: [id],
      chain: null,
      account: deps.wallet.account!,
    })
    out.push({ name: 'settleRound', reason: `round ${id} reveal window closed`, txHash })
  }
  return out
}

/** §3.2: permissionless once the boundary timestamp passes, carrying a small bounty. */
export async function rolloverIfDue(deps: KeeperDeps): Promise<KeeperAction[]> {
  const now = Math.floor((deps.now ?? Date.now)() / 1000)
  const season = (await deps.reader.readContract({
    address: deps.targets.dcode,
    abi: DCODE_ABI as Abi,
    functionName: 'currentSeason',
  })) as number

  if (season === 0) return [{ name: 'rollover', reason: 'governance not open yet', skipped: 'no season' }]

  const end = (await deps.reader.readContract({
    address: deps.targets.dcode,
    abi: DCODE_ABI as Abi,
    functionName: 'seasonEnd',
    args: [season],
  })) as bigint

  if (now <= Number(end)) {
    return [{ name: 'rollover', reason: `season ${season} ends at ${end}`, skipped: 'not due' }]
  }

  const txHash = await deps.wallet.writeContract({
    address: deps.targets.dcode,
    abi: DCODE_ABI as Abi,
    functionName: 'rollover',
    chain: null,
    account: deps.wallet.account!,
  })
  return [{ name: 'rollover', reason: `season ${season} boundary passed`, txHash }]
}

/**
 * §5.5: bonds are revalued at each season boundary, and a slot below target suspends.
 *
 * Called every pass rather than only at boundaries. The contract decides whether anything changes, and
 * calling more often than required costs one transaction while calling less often leaves a seat attesting
 * against collateral that no longer covers it.
 */
export async function revalueBonds(deps: KeeperDeps): Promise<KeeperAction[]> {
  const txHash = await deps.wallet.writeContract({
    address: deps.targets.saine,
    abi: SAINE_ABI as Abi,
    functionName: 'revalueBonds',
    chain: null,
    account: deps.wallet.account!,
  })
  return [{ name: 'revalueBonds', reason: 'keep slot collateral honest', txHash }]
}

/** Keeps the average fresh for readers that cannot poke, such as a proposer reading the per-deal ceiling. */
export async function pokeOracle(deps: KeeperDeps): Promise<KeeperAction[]> {
  const txHash = await deps.wallet.writeContract({
    address: deps.targets.oracle,
    abi: ORACLE_ABI as Abi,
    functionName: 'poke',
    chain: null,
    account: deps.wallet.account!,
  })
  return [{ name: 'pokeOracle', reason: 'maintain the time-weighted average', txHash }]
}

/** §9 step 5. Unbountied by design, so the keeper is the process most likely to do it. */
export async function executeBuyback(deps: KeeperDeps): Promise<KeeperAction[]> {
  const ready = (await deps.reader.readContract({
    address: deps.targets.receiver,
    abi: RECEIVER_ABI as Abi,
    functionName: 'buybackReady',
  })) as boolean

  if (!ready) return [{ name: 'executeBuyback', reason: 'nothing queued or interval not elapsed', skipped: 'not ready' }]

  const txHash = await deps.wallet.writeContract({
    address: deps.targets.receiver,
    abi: RECEIVER_ABI as Abi,
    functionName: 'executeBuyback',
    chain: null,
    account: deps.wallet.account!,
  })
  return [{ name: 'executeBuyback', reason: 'queued repayment ready to convert', txHash }]
}

/**
 * §9 step 3, on a satellite chain. Separate because it needs a client for that chain, and the batch is
 * only worth bridging when the contract says the trigger is met.
 */
export async function bridgeIfReady(
  reader: PublicClient,
  wallet: WalletClient,
  satellite: Address,
): Promise<KeeperAction[]> {
  const [ready] = (await reader.readContract({
    address: satellite,
    abi: SATELLITE_ABI as Abi,
    functionName: 'batchReady',
  })) as readonly [boolean, bigint]

  if (!ready) return [{ name: 'bridgeBatch', reason: 'below 20x fee and under 30 days', skipped: 'not ready' }]

  const txHash = await wallet.writeContract({
    address: satellite,
    abi: SATELLITE_ABI as Abi,
    functionName: 'bridgeBatch',
    chain: null,
    account: wallet.account!,
  })
  return [{ name: 'bridgeBatch', reason: 'batch trigger met', txHash }]
}

export { GOVERNOR_ABI }
