/**
 * The board runner: fans one adjudication package out to ten independent evaluators.
 *
 * This module is where §5.2's independence claim is either true or a comfortable fiction. Three
 * properties make it true, and all three are enforced here rather than assumed:
 *
 *   1. **Every slot receives byte-identical artefacts.** A six-of-ten threshold only carries
 *      information if the ten were answering the same question. The prompt is built once, above this
 *      function, and handed to each adapter unchanged.
 *   2. **No slot observes another.** Ten separate calls, no shared mutable state, and nothing from one
 *      outcome is threaded into another's input. A runner that fed early verdicts to later slots would
 *      produce a board that looked like ten reviewers and voted like one.
 *   3. **One provider's outage does not abort the round.** `Promise.allSettled`, per-slot timeouts, and
 *      failures recorded rather than thrown. A runner that propagated the first rejection would let any
 *      single provider deny every approval, which is a veto handed to whoever is having a bad day.
 */

import type { ModelAdapter } from './models/index.js'
import { ModelFailure } from './models/index.js'
import type { ModelVerdict, SlotConfig } from './types.js'

export interface SlotBinding {
  readonly config: SlotConfig
  readonly adapter: ModelAdapter
}

export type SlotStatus = 'judged' | 'failed'

export interface SlotOutcome {
  readonly slot: number
  readonly status: SlotStatus
  readonly provider: string
  readonly model: string
  readonly verdict?: ModelVerdict
  /** What the API said it served, for §5.4's model hash. */
  readonly servedModel?: string
  readonly error?: string
  readonly elapsedMs: number
}

export interface RunOptions {
  readonly systemPrompt: string
  readonly userPrompt: string
  /**
   * Per-slot deadline. Must leave room inside the commit window (§15: 24 hours) for signing and
   * relaying, so it is set well below it rather than near it.
   */
  readonly timeoutMs: number
  /** Injected for tests; defaults to wall clock. */
  readonly now?: () => number
}

export interface BoardResult {
  readonly outcomes: readonly SlotOutcome[]
  readonly judged: number
  readonly failed: number
  readonly approvals: number
  /**
   * What the tally would be if every judged slot revealed. Advisory only: the contract tallies reveals,
   * not intentions, and a slot that judged may still fail to reveal.
   */
  readonly projected: 'approve' | 'reject' | 'lapse'
}

export async function runBoard(
  slots: readonly SlotBinding[],
  opts: RunOptions,
): Promise<BoardResult> {
  const now = opts.now ?? (() => Date.now())

  const settled = await Promise.allSettled(
    slots.map(async (binding): Promise<SlotOutcome> => {
      const started = now()
      try {
        const result = await binding.adapter.judge({
          systemPrompt: opts.systemPrompt,
          userPrompt: opts.userPrompt,
          timeoutMs: opts.timeoutMs,
        })
        return {
          slot: binding.config.slot,
          status: 'judged',
          provider: binding.config.provider,
          model: binding.config.model,
          verdict: result.verdict,
          servedModel: result.servedModel,
          elapsedMs: now() - started,
        }
      } catch (err) {
        return {
          slot: binding.config.slot,
          status: 'failed',
          provider: binding.config.provider,
          model: binding.config.model,
          error: err instanceof ModelFailure ? err.message : String(err),
          elapsedMs: now() - started,
        }
      }
    }),
  )

  // Every branch above returns rather than throws, so a rejected promise here would mean a bug in this
  // function rather than a provider failure. Recorded as a failed slot instead of crashing the round.
  const outcomes: SlotOutcome[] = settled.map((s, i) =>
    s.status === 'fulfilled'
      ? s.value
      : {
          slot: slots[i]!.config.slot,
          status: 'failed' as const,
          provider: slots[i]!.config.provider,
          model: slots[i]!.config.model,
          error: `runner fault: ${String(s.reason)}`,
          elapsedMs: 0,
        },
  )

  const judged = outcomes.filter((o) => o.status === 'judged').length
  const approvals = outcomes.filter((o) => o.status === 'judged' && o.verdict?.approve === true).length

  return {
    outcomes,
    judged,
    failed: outcomes.length - judged,
    approvals,
    projected: judged < 8 ? 'lapse' : approvals >= 6 ? 'approve' : 'reject',
  }
}
