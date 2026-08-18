import { describe, expect, it } from 'vitest'
import { keccak256, toHex, type Hex } from 'viem'
import { watchPass, type WatchDeps } from '../src/watch.js'
import type { OnChainRound } from '../src/chain/index.js'
import { MemoryAttestationStore } from '../src/guard.js'
import { NullPinner } from '../src/ipfs.js'
import { BOARD } from '../src/board.js'
import { validateManifest } from '../src/package/manifest.js'
import type { JudgeInput, JudgeResult, ModelAdapter } from '../src/models/index.js'
import type { OrchestratorDeps } from '../src/orchestrate.js'
import type { RelayReceipt, Relayer } from '../src/relay.js'
import type { AdjudicationPackage, CommitAttestation, RevealAttestation } from '../src/types.js'

const TEXT = 'A published justification long enough to be legible to the founder who received it.'
const COMMIT_END = 2_000_000_000
const REVEAL_END = COMMIT_END + 86_400

class Yes implements ModelAdapter {
  constructor(readonly provider: string, readonly model: string) {}
  async judge(_i: JudgeInput): Promise<JudgeResult> {
    return { verdict: { approve: true, code: 'tokenomics', text: TEXT }, servedModel: 'served' }
  }
}

class Spy implements Relayer {
  onChain = new Set<number>()
  revealedSlots = new Set<number>()
  commitCalls = 0
  revealCalls = 0
  async submitCommits(a: readonly CommitAttestation[]): Promise<RelayReceipt> {
    this.commitCalls += 1
    for (const x of a) this.onChain.add(x.slot)
    return { txHash: '0x', accepted: a.map((x) => x.slot), rejected: [] }
  }
  async submitReveals(a: readonly RevealAttestation[]): Promise<RelayReceipt> {
    this.revealCalls += 1
    for (const x of a) this.revealedSlots.add(x.slot)
    return { txHash: '0x', accepted: a.map((x) => x.slot), rejected: [] }
  }
  async committedSlots(): Promise<readonly number[]> {
    return [...this.onChain]
  }
}

function pkg(): AdjudicationPackage {
  return {
    roundId: 1n,
    kind: 'Origination',
    subject: 1n,
    actions: [],
    simulation: { ok: true, gasUsed: 1n, transfers: [] },
    investeeSource: [],
    manifest: {},
    description: 'ok',
    history: [],
  }
}

function slotsToMask(slots: Iterable<number>): number {
  let m = 0
  for (const s of slots) m |= 1 << s
  return m
}

function make(over: {
  now?: number
  state?: number
  committed?: number[]
  revealed?: number[]
  commitSafetyMs?: number
}) {
  const relayer = new Spy()
  for (const s of over.committed ?? []) relayer.onChain.add(s)
  for (const s of over.revealed ?? []) relayer.revealedSlots.add(s)

  const orchestrator: OrchestratorDeps = {
    board: BOARD.map((config) => ({ config, adapter: new Yes(config.provider, config.model) })),
    store: new MemoryAttestationStore(),
    pinner: new NullPinner(),
    relayer,
    domain: { chainId: 1, verifyingContract: '0x1111111111111111111111111111111111111111' },
    keys: (slot) => ({
      signingKey: keccak256(toHex(`k${slot}`)) as Hex,
      saltSecret: keccak256(toHex(`s${slot}`)) as Hex,
    }),
    buildPackage: async () => ({ pkg: pkg(), render: { validation: validateManifest({}), targetsFlagged: false } }),
    packageSalt: () => keccak256(toHex('salt')),
    now: () => over.now ?? COMMIT_END * 1000 - 3_600_000,
    randomNonce: () => keccak256(toHex('n')),
  }

  const round: OnChainRound = {
    roundId: 1n,
    subject: 1n,
    kind: 'Origination',
    state: over.state ?? 1,
    commitEnd: COMMIT_END,
    revealEnd: REVEAL_END,
    commits: (over.committed ?? []).length,
    reveals: (over.revealed ?? []).length,
    approvals: 0,
    committedMask: slotsToMask(over.committed ?? []),
    revealedMask: slotsToMask(over.revealed ?? []),
    trancheIndex: 0,
  }

  const deps: WatchDeps = {
    reader: {
      roundCount: async () => 1n,
      round: async () => round,
      committedSlots: async () => over.committed ?? [],
    } as unknown as WatchDeps['reader'],
    orchestrator,
    now: () => over.now ?? COMMIT_END * 1000 - 3_600_000,
    ...(over.commitSafetyMs !== undefined ? { commitSafetyMs: over.commitSafetyMs } : {}),
  }
  return { deps, relayer }
}

describe('commit window', () => {
  it('commits when the window is open with time to spare', async () => {
    const { deps, relayer } = make({})
    const actions = await watchPass(deps)
    expect(actions[0]).toEqual({ kind: 'committed', roundId: 1n, slots: 10 })
    expect(relayer.commitCalls).toBe(1)
  })

  it('declines to start with too little of the window left', async () => {
    // An uncommitted slot forfeits nothing. A slot that commits too late to reveal forfeits 25% of its
    // bond, so starting a board that cannot finish is strictly worse than not starting.
    const { deps, relayer } = make({ now: COMMIT_END * 1000 - 60_000 })
    const actions = await watchPass(deps)
    expect(actions[0]?.kind).toBe('skipped')
    expect((actions[0] as { reason: string }).reason).toContain('too little of the commit window')
    expect(relayer.commitCalls).toBe(0)
  })

  it('does nothing when all our slots already committed', async () => {
    const { deps, relayer } = make({ committed: [0, 1, 2, 3, 4, 5, 6, 7, 8, 9] })
    const actions = await watchPass(deps)
    expect(actions[0]?.kind).toBe('skipped')
    expect(relayer.commitCalls).toBe(0)
  })
})

describe('reveal window', () => {
  it('reveals what committed', async () => {
    const { deps, relayer } = make({
      now: COMMIT_END * 1000 + 3_600_000,
      committed: [0, 1, 2, 3, 4, 5, 6, 7, 8, 9],
    })
    // Bind verdicts as a prior commit phase would have.
    for (let s = 0; s < 10; s += 1) {
      await deps.orchestrator.store.claim({
        slot: s,
        roundId: '1',
        verdict: true,
        reasonHash: keccak256(toHex('r')) as Hex,
        modelHash: keccak256(toHex('m')) as Hex,
        committedAt: '2026-01-01T00:00:00.000Z',
      })
    }
    const actions = await watchPass(deps)
    expect(actions[0]).toEqual({ kind: 'revealed', roundId: 1n, slots: 10 })
    expect(relayer.revealCalls).toBe(1)
  })

  it('does nothing when everything of ours has already revealed', async () => {
    const all = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]
    const { deps, relayer } = make({ now: COMMIT_END * 1000 + 3_600_000, committed: all, revealed: all })
    const actions = await watchPass(deps)
    expect(actions[0]?.kind).toBe('skipped')
    expect(relayer.revealCalls).toBe(0)
  })

  it('still attempts a reveal near the window edge, because the forfeit is already owed', async () => {
    const { deps, relayer } = make({ now: REVEAL_END * 1000 - 60_000, committed: [0] })
    await deps.orchestrator.store.claim({
      slot: 0,
      roundId: '1',
      verdict: true,
      reasonHash: keccak256(toHex('r')) as Hex,
      modelHash: keccak256(toHex('m')) as Hex,
      committedAt: '2026-01-01T00:00:00.000Z',
    })
    const actions = await watchPass(deps)
    expect(actions[0]?.kind).toBe('revealed')
    expect(relayer.revealCalls).toBe(1)
  })
})

describe('rounds that need nothing', () => {
  it('ignores a round that is not open', async () => {
    const { deps, relayer } = make({ state: 2 })
    expect(await watchPass(deps)).toEqual([])
    expect(relayer.commitCalls).toBe(0)
  })

  it('reports a round whose windows have both closed', async () => {
    const { deps } = make({ now: REVEAL_END * 1000 + 1000 })
    const actions = await watchPass(deps)
    expect((actions[0] as { reason: string }).reason).toContain('awaiting settlement')
  })
})

describe('restart safety', () => {
  it('does not re-judge while its own commit transaction is still in flight', async () => {
    // The chain read is stale between submitting a batch and that batch being mined. Without the local
    // check, every poll in that gap would run ten model calls and submit a batch the registry rejects.
    const { deps, relayer } = make({})
    await watchPass(deps)
    const first = relayer.commitCalls

    const actions = await watchPass(deps)
    expect(relayer.commitCalls).toBe(first)
    expect((actions[0] as { reason: string }).reason).toContain('already bound locally')
  })

  it('a crash and restart mid-window rebinds nothing and re-signs the same commitment', async () => {
    const { deps } = make({})
    await watchPass(deps)
    const before = await deps.orchestrator.store.read(0, 1n)
    await watchPass(deps)
    const after = await deps.orchestrator.store.read(0, 1n)
    expect(after).toEqual(before)
  })
})
