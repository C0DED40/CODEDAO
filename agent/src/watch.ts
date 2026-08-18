/**
 * The watcher: finds rounds and drives them through their two windows.
 *
 * §15 gives 24 hours to commit and 24 to reveal, which sounds generous and is not. The whole board has to
 * be judged, signed and relayed inside the first window, and every slot that committed has to reveal
 * inside the second or forfeit a quarter of its bond. So the loop is built around one rule: **act early in
 * each window, never near its edge**.
 *
 * A crash-and-restart mid-window has to be safe, because it will happen. It is safe here because the
 * work is idempotent by construction: `commitPhase` consults the guard, which returns the already-bound
 * verdict rather than re-judging, and `revealPhase` reads its inputs from the guard record and the chain
 * rather than from anything held in memory.
 */

import type { OrchestratorDeps, RoundContext } from './orchestrate.js'
import { commitPhase, revealPhase } from './orchestrate.js'
import type { ChainReader } from './chain/index.js'
import { maskToSlots } from './chain/index.js'

/** Registry `RoundState` indices. */
const STATE_OPEN = 1

export interface WatchDeps {
  readonly reader: ChainReader
  readonly orchestrator: OrchestratorDeps
  readonly now?: () => number
  readonly log?: (msg: string, detail?: unknown) => void
  /**
   * How close to a window's end the watcher refuses to start work.
   *
   * Starting a board with four minutes left produces ten model calls that cannot finish, a relay that
   * misses, and in the worst case a slot that commits after the window and wastes the gas. Declining is
   * better: an uncommitted slot loses nothing, while a committed slot that cannot reveal loses 25%.
   */
  readonly commitSafetyMs?: number
  readonly revealSafetyMs?: number
}

export type WatchAction =
  | { readonly kind: 'committed'; readonly roundId: bigint; readonly slots: number }
  | { readonly kind: 'revealed'; readonly roundId: bigint; readonly slots: number }
  | { readonly kind: 'skipped'; readonly roundId: bigint; readonly reason: string }

/**
 * One pass over the recent rounds.
 *
 * Scans a bounded tail rather than every round ever opened. Anything older than the window pair has
 * either settled or lapsed, and re-reading it every minute would grow the pass without bound.
 */
export async function watchPass(deps: WatchDeps, tail = 20n): Promise<WatchAction[]> {
  const now = (deps.now ?? Date.now)()
  const log = deps.log ?? (() => {})
  const commitSafety = deps.commitSafetyMs ?? 15 * 60_000
  const revealSafety = deps.revealSafetyMs ?? 10 * 60_000

  const count = await deps.reader.roundCount()
  const from = count > tail ? count - tail + 1n : 1n
  const actions: WatchAction[] = []

  for (let id = from; id <= count; id += 1n) {
    const r = await deps.reader.round(id)
    if (r.state !== STATE_OPEN) continue

    const ctx: RoundContext = {
      roundId: id,
      kind: r.kind,
      subject: r.subject,
      commitEnd: r.commitEnd,
      revealEnd: r.revealEnd,
    }

    const commitEndMs = r.commitEnd * 1000
    const revealEndMs = r.revealEnd * 1000
    const ourSlots = deps.orchestrator.board.map((b) => b.config.slot)
    const committed = new Set(maskToSlots(r.committedMask))
    const revealed = new Set(maskToSlots(r.revealedMask))

    if (now < commitEndMs) {
      const outstanding = ourSlots.filter((s) => !committed.has(s))
      if (outstanding.length === 0) {
        actions.push({ kind: 'skipped', roundId: id, reason: 'all our slots already committed' })
        continue
      }

      // Check what we have bound locally as well as what the chain shows. Between submitting a batch and
      // that batch being mined, the chain read is stale, so a pass in that gap would re-judge all ten
      // models and submit a batch the registry rejects with `AlreadyCommitted`. The guard would keep the
      // verdict correct either way, but ten model calls per poll interval is a bill for nothing.
      const bound = await Promise.all(outstanding.map((s) => deps.orchestrator.store.read(s, id)))
      if (bound.every((b) => b !== null)) {
        actions.push({
          kind: 'skipped',
          roundId: id,
          reason: 'verdicts already bound locally; awaiting the commit transaction to appear on chain',
        })
        continue
      }
      if (commitEndMs - now < commitSafety) {
        // An uncommitted slot forfeits nothing. A slot that commits too late to reveal forfeits 25%.
        actions.push({ kind: 'skipped', roundId: id, reason: 'too little of the commit window left to finish safely' })
        continue
      }
      const result = await commitPhase(deps.orchestrator, ctx)
      log(`round ${id}: committed ${result.attestations.length} slots`)
      actions.push({ kind: 'committed', roundId: id, slots: result.attestations.length })
      continue
    }

    if (now < revealEndMs) {
      const outstanding = ourSlots.filter((s) => committed.has(s) && !revealed.has(s))
      if (outstanding.length === 0) {
        actions.push({ kind: 'skipped', roundId: id, reason: 'nothing of ours left to reveal' })
        continue
      }
      if (revealEndMs - now < revealSafety) {
        // Still attempt it: a late reveal that lands is worth more than a clean skip, because the
        // alternative is the forfeit that is already owed.
        log(`round ${id}: revealing close to the window edge, ${outstanding.length} slots outstanding`)
      }
      const result = await revealPhase(deps.orchestrator, ctx)
      log(`round ${id}: revealed ${result.attestations.length} slots`, result.skipped)
      actions.push({ kind: 'revealed', roundId: id, slots: result.attestations.length })
      continue
    }

    actions.push({ kind: 'skipped', roundId: id, reason: 'both windows closed; awaiting settlement' })
  }

  return actions
}

export interface RunLoopOptions {
  readonly intervalMs: number
  readonly signal?: AbortSignal
}

/** Poll until aborted. A thrown pass is logged and retried rather than ending the process. */
export async function runWatchLoop(deps: WatchDeps, opts: RunLoopOptions): Promise<void> {
  const log = deps.log ?? (() => {})
  while (opts.signal?.aborted !== true) {
    try {
      const actions = await watchPass(deps)
      const acted = actions.filter((a) => a.kind !== 'skipped')
      if (acted.length > 0) log('watch pass acted', acted)
    } catch (err) {
      // A node hiccup must not end the process: the next pass is a minute away and the windows are hours.
      log('watch pass failed; retrying next interval', err)
    }
    await sleep(opts.intervalMs, opts.signal)
  }
}

function sleep(ms: number, signal?: AbortSignal): Promise<void> {
  return new Promise((resolve) => {
    const timer = setTimeout(resolve, ms)
    signal?.addEventListener('abort', () => {
      clearTimeout(timer)
      resolve()
    }, { once: true })
  })
}
