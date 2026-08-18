import { describe, expect, it, vi } from 'vitest'
import { runBoard, type SlotBinding } from '../src/runner.js'
import { ModelFailure, type JudgeInput, type JudgeResult, type ModelAdapter } from '../src/models/index.js'
import { BOARD } from '../src/board.js'
import type { ModelVerdict } from '../src/types.js'

const TEXT = 'A reason long enough to satisfy the minimum length required of a published justification.'

function verdict(approve: boolean): ModelVerdict {
  return { approve, code: 'tokenomics', text: TEXT }
}

class Stub implements ModelAdapter {
  readonly seen: JudgeInput[] = []
  constructor(
    readonly provider: string,
    readonly model: string,
    private readonly behaviour: (i: JudgeInput) => Promise<JudgeResult>,
  ) {}
  async judge(i: JudgeInput): Promise<JudgeResult> {
    this.seen.push(i)
    return this.behaviour(i)
  }
}

function bind(behaviours: ((i: JudgeInput) => Promise<JudgeResult>)[]): {
  slots: SlotBinding[]
  stubs: Stub[]
} {
  const stubs = behaviours.map((b, i) => new Stub(BOARD[i]!.provider, BOARD[i]!.model, b))
  const slots = stubs.map((s, i) => ({ config: BOARD[i]!, adapter: s }))
  return { slots, stubs }
}

const ok = (approve: boolean) => async (): Promise<JudgeResult> => ({
  verdict: verdict(approve),
  servedModel: 'served-x',
})

const boom = (msg: string) => async (): Promise<JudgeResult> => {
  throw new ModelFailure('p', 'm', msg)
}

const OPTS = { systemPrompt: 'sys', userPrompt: 'pkg', timeoutMs: 1_000 }

describe('every slot sees identical artefacts', () => {
  it('hands the same prompt to all ten', async () => {
    const { slots, stubs } = bind(Array.from({ length: 10 }, () => ok(true)))
    await runBoard(slots, OPTS)
    for (const s of stubs) {
      expect(s.seen).toHaveLength(1)
      expect(s.seen[0]!.userPrompt).toBe('pkg')
      expect(s.seen[0]!.systemPrompt).toBe('sys')
    }
  })

  it('never leaks one slot verdict into another slot prompt', async () => {
    // A runner that threaded early verdicts into later prompts would produce ten reviewers that vote
    // as one, which is the exact failure §5.2 exists to prevent.
    const { slots, stubs } = bind(Array.from({ length: 10 }, () => ok(true)))
    await runBoard(slots, OPTS)
    for (const s of stubs) {
      expect(s.seen[0]!.userPrompt).not.toContain('approve')
      expect(s.seen[0]!.userPrompt).not.toContain(TEXT)
    }
  })
})

describe('isolation of failures', () => {
  it('one provider outage does not abort the other nine', async () => {
    const behaviours = [boom('503 from provider'), ...Array.from({ length: 9 }, () => ok(true))]
    const { slots } = bind(behaviours)
    const r = await runBoard(slots, OPTS)
    expect(r.judged).toBe(9)
    expect(r.failed).toBe(1)
    expect(r.approvals).toBe(9)
  })

  it('records the failure rather than voting on the slot behalf', async () => {
    // Committing a rejection on a technical failure would let provider flakiness kill deals. §5.4's
    // lapse path exists precisely so infrastructure trouble harms nobody.
    const { slots } = bind([boom('timeout'), ...Array.from({ length: 9 }, () => ok(true))])
    const r = await runBoard(slots, OPTS)
    const failed = r.outcomes.find((o) => o.status === 'failed')
    expect(failed?.verdict).toBeUndefined()
    expect(failed?.error).toContain('timeout')
  })

  it('survives all ten failing', async () => {
    const { slots } = bind(Array.from({ length: 10 }, () => boom('down')))
    const r = await runBoard(slots, OPTS)
    expect(r.judged).toBe(0)
    expect(r.projected).toBe('lapse')
  })
})

describe('projected tally mirrors §5.4', () => {
  it('approves at six of ten', async () => {
    const { slots } = bind([
      ...Array.from({ length: 6 }, () => ok(true)),
      ...Array.from({ length: 4 }, () => ok(false)),
    ])
    expect((await runBoard(slots, OPTS)).projected).toBe('approve')
  })

  it('rejects at five approvals with quorum', async () => {
    const { slots } = bind([
      ...Array.from({ length: 5 }, () => ok(true)),
      ...Array.from({ length: 5 }, () => ok(false)),
    ])
    expect((await runBoard(slots, OPTS)).projected).toBe('reject')
  })

  it('lapses below eight judged, even if every judgement approved', async () => {
    const { slots } = bind([
      ...Array.from({ length: 7 }, () => ok(true)),
      ...Array.from({ length: 3 }, () => boom('down')),
    ])
    const r = await runBoard(slots, OPTS)
    expect(r.approvals).toBe(7)
    expect(r.projected).toBe('lapse')
  })
})

describe('concurrency', () => {
  it('runs the board in parallel, not in sequence', async () => {
    // Ten sequential calls at even 60s each would overrun the 24-hour commit window on a bad day, and
    // would make the slowest provider set the pace for the whole board.
    let live = 0
    let peak = 0
    const slow = async (): Promise<JudgeResult> => {
      live += 1
      peak = Math.max(peak, live)
      await new Promise((r) => setTimeout(r, 5))
      live -= 1
      return { verdict: verdict(true), servedModel: 'served-x' }
    }
    const { slots } = bind(Array.from({ length: 10 }, () => slow))
    await runBoard(slots, OPTS)
    expect(peak).toBe(10)
  })

  it('passes the timeout through to each adapter', async () => {
    const { slots, stubs } = bind(Array.from({ length: 10 }, () => ok(true)))
    await runBoard(slots, { ...OPTS, timeoutMs: 42_000 })
    expect(stubs[0]!.seen[0]!.timeoutMs).toBe(42_000)
  })
})

describe('runner faults', () => {
  it('a thrown non-ModelFailure is still recorded as a failed slot', async () => {
    const weird = async (): Promise<JudgeResult> => {
      throw new Error('kaboom')
    }
    const { slots } = bind([weird, ...Array.from({ length: 9 }, () => ok(true))])
    const r = await runBoard(slots, OPTS)
    expect(r.failed).toBe(1)
    expect(r.outcomes.find((o) => o.status === 'failed')?.error).toContain('kaboom')
  })

  it('records elapsed time per slot', async () => {
    const clock = vi.fn(() => 0)
    let t = 0
    clock.mockImplementation(() => (t += 10))
    const { slots } = bind(Array.from({ length: 10 }, () => ok(true)))
    const r = await runBoard(slots, { ...OPTS, now: clock })
    for (const o of r.outcomes) expect(o.elapsedMs).toBeGreaterThan(0)
  })
})
