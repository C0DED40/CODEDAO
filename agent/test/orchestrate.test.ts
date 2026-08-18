import { describe, expect, it } from 'vitest'
import { keccak256, toHex, type Hex } from 'viem'
import { commitPhase, revealPhase, type BuiltPackage, type OrchestratorDeps, type RoundContext } from '../src/orchestrate.js'
import { MemoryAttestationStore } from '../src/guard.js'
import { NullPinner } from '../src/ipfs.js'
import { BOARD } from '../src/board.js'
import { validateManifest } from '../src/package/manifest.js'
import { ModelFailure, type JudgeInput, type JudgeResult, type ModelAdapter } from '../src/models/index.js'
import { buildCommitment, deriveSalt, type Domain } from '../src/attest.js'
import type { AdjudicationPackage, CommitAttestation, RevealAttestation } from '../src/types.js'
import type { RelayReceipt, Relayer } from '../src/relay.js'
import type { SlotBinding } from '../src/runner.js'

const DOMAIN: Domain = { chainId: 4663, verifyingContract: '0x1111111111111111111111111111111111111111' }
const TEXT = 'A published justification long enough to be legible to the founder who received it.'
const CTX: RoundContext = { roundId: 7n, kind: 'Origination', subject: 3n, commitEnd: 2_000_000_000, revealEnd: 2_000_086_400 }

class Stub implements ModelAdapter {
  readonly seen: JudgeInput[] = []
  constructor(readonly provider: string, readonly model: string, private readonly b: (i: JudgeInput) => Promise<JudgeResult>) {}
  async judge(i: JudgeInput): Promise<JudgeResult> {
    this.seen.push(i)
    return this.b(i)
  }
}

const yes = async (): Promise<JudgeResult> => ({
  verdict: { approve: true, code: 'tokenomics', text: TEXT },
  servedModel: 'served-v9',
})
const no = async (): Promise<JudgeResult> => ({
  verdict: { approve: false, code: 'valuation', text: TEXT },
  servedModel: 'served-v9',
})
const dead = async (): Promise<JudgeResult> => {
  throw new ModelFailure('p', 'm', '503 upstream')
}

class SpyRelayer implements Relayer {
  commits: CommitAttestation[][] = []
  reveals: RevealAttestation[][] = []
  onChain = new Set<number>()
  rejectSlots = new Set<number>()

  async submitCommits(atts: readonly CommitAttestation[]): Promise<RelayReceipt> {
    this.commits.push([...atts])
    const accepted: number[] = []
    const rejected: { slot: number; reason: string }[] = []
    for (const a of atts) {
      if (this.rejectSlots.has(a.slot)) rejected.push({ slot: a.slot, reason: 'rejected by test' })
      else {
        accepted.push(a.slot)
        this.onChain.add(a.slot)
      }
    }
    return { txHash: '0xtx', accepted, rejected }
  }

  async submitReveals(atts: readonly RevealAttestation[]): Promise<RelayReceipt> {
    this.reveals.push([...atts])
    return { txHash: '0xtx2', accepted: atts.map((a) => a.slot), rejected: [] }
  }

  async committedSlots(): Promise<readonly number[]> {
    return [...this.onChain]
  }
}

function pkg(): AdjudicationPackage {
  return {
    roundId: 7n,
    kind: 'Origination',
    subject: 3n,
    actions: [],
    simulation: { ok: true, gasUsed: 1n, transfers: [] },
    investeeSource: [],
    manifest: {},
    description: 'A zk coprocessor.',
    history: [],
  }
}

function deps(behaviours: ((i: JudgeInput) => Promise<JudgeResult>)[], over: Partial<OrchestratorDeps> = {}) {
  const board: SlotBinding[] = behaviours.map((b, i) => ({
    config: BOARD[i]!,
    adapter: new Stub(BOARD[i]!.provider, BOARD[i]!.model, b),
  }))
  const store = new MemoryAttestationStore()
  const pinner = new NullPinner()
  const relayer = new SpyRelayer()
  const events: unknown[] = []
  const built: BuiltPackage = { pkg: pkg(), render: { validation: validateManifest({}), targetsFlagged: false } }
  const d: OrchestratorDeps = {
    board,
    store,
    pinner,
    relayer,
    domain: DOMAIN,
    keys: (slot) => ({
      signingKey: keccak256(toHex(`key-${slot}`)) as Hex,
      saltSecret: keccak256(toHex(`salt-${slot}`)) as Hex,
    }),
    buildPackage: async () => built,
    packageSalt: () => keccak256(toHex('pkg-salt')),
    now: () => 1_999_000_000_000,
    randomNonce: () => keccak256(toHex('nonce')),
    log: (e) => events.push(e),
    ...over,
  }
  return { d, store, pinner, relayer, events, board }
}

const ten = (b: (i: JudgeInput) => Promise<JudgeResult>) => Array.from({ length: 10 }, () => b)

describe('commit phase', () => {
  it('signs and relays one commitment per judged slot', async () => {
    const { d, relayer } = deps(ten(yes))
    const r = await commitPhase(d, CTX)
    expect(r.attestations).toHaveLength(10)
    expect(relayer.commits[0]).toHaveLength(10)
    expect(r.relayed?.accepted).toHaveLength(10)
  })

  it('does not attest for a slot whose model failed', async () => {
    // §5.4's lapse path exists so infrastructure trouble harms nobody. Committing a rejection because a
    // provider returned a 503 would let flakiness kill deals instead.
    const { d } = deps([dead, dead, ...Array.from({ length: 8 }, () => yes)])
    const r = await commitPhase(d, CTX)
    expect(r.attestations).toHaveLength(8)
    expect(r.attestations.map((a) => a.slot)).not.toContain(0)
  })

  it('relays nothing when every slot failed', async () => {
    const { d, relayer } = deps(ten(dead))
    const r = await commitPhase(d, CTX)
    expect(r.attestations).toHaveLength(0)
    expect(relayer.commits).toHaveLength(0)
  })

  it('commits to a hash the reveal can reproduce', async () => {
    const { d, store } = deps(ten(yes))
    const r = await commitPhase(d, CTX)
    const record = await store.read(0, 7n)
    const salt = deriveSalt(keccak256(toHex('salt-0')) as Hex, 7n, 0)
    expect(r.attestations[0]!.commitment).toBe(buildCommitment(record!.verdict, record!.reasonHash, salt))
  })

  it('records the model the API served, not the one requested (§5.4)', async () => {
    const { d, pinner } = deps(ten(yes))
    await commitPhase(d, CTX)
    expect(pinner.pinned[0]!.model.model).toBe('served-v9')
  })

  it('pins every reason document before relaying', async () => {
    const { d, pinner } = deps(ten(yes))
    await commitPhase(d, CTX)
    expect(pinner.pinned).toHaveLength(10)
  })

  it('still attests when pinning fails, because the verdict is already bound', async () => {
    const { d, events } = deps(ten(yes), {
      pinner: {
        async pin() {
          throw new Error('ipfs unreachable')
        },
      },
    })
    const r = await commitPhase(d, CTX)
    expect(r.attestations).toHaveLength(10)
    expect(events.some((e) => (e as { kind: string }).kind === 'pin_failed')).toBe(true)
  })

  it('hands every slot the same prompt', async () => {
    const { d, board } = deps(ten(yes))
    await commitPhase(d, CTX)
    const prompts = board.map((b) => (b.adapter as Stub).seen[0]!.userPrompt)
    expect(new Set(prompts).size).toBe(1)
  })

  it('caps the model timeout at ten minutes however much window remains', async () => {
    // A fifth of a fresh 24-hour window is nearly five hours. A hung provider would then eat most of the
    // window before anyone noticed, leaving no time to retry the other nine.
    const { d, board } = deps(ten(yes))
    await commitPhase(d, CTX)
    expect((board[0]!.adapter as Stub).seen[0]!.timeoutMs).toBe(600_000)
  })

  it('shortens the timeout as the window closes', async () => {
    const { d, board } = deps(ten(yes), { now: () => CTX.commitEnd * 1000 - 600_000 })
    await commitPhase(d, CTX)
    // Two minutes left of a ten-minute remainder.
    expect((board[0]!.adapter as Stub).seen[0]!.timeoutMs).toBe(120_000)
  })

  it('floors the timeout when the window is nearly closed', async () => {
    const { d, board } = deps(ten(yes), { now: () => CTX.commitEnd * 1000 - 1_000 })
    await commitPhase(d, CTX)
    expect((board[0]!.adapter as Stub).seen[0]!.timeoutMs).toBe(30_000)
  })
})

describe('the guard is consulted before any signature exists', () => {
  it('refuses to sign a second, opposite verdict for the same round', async () => {
    // The whole point: §5.5 needs only two signed attestations with different verdicts to burn the bond
    // and vacate the seat. If the guard ran after signing, the evidence would already exist.
    const shared = new MemoryAttestationStore()
    const first = deps(ten(yes), { store: shared })
    await commitPhase(first.d, CTX)

    const second = deps(ten(no), { store: shared })
    const r = await commitPhase(second.d, CTX)

    expect(r.attestations).toHaveLength(0)
    expect(second.events.filter((e) => (e as { kind: string }).kind === 'equivocation_refused')).toHaveLength(10)
  })

  it('is idempotent for a rerun that reaches the same verdict', async () => {
    const shared = new MemoryAttestationStore()
    await commitPhase(deps(ten(yes), { store: shared }).d, CTX)
    const r = await commitPhase(deps(ten(yes), { store: shared }).d, CTX)
    expect(r.attestations).toHaveLength(10)
  })

  it('reuses the stored reason hash on a rerun, so the commitment stays reproducible', async () => {
    const shared = new MemoryAttestationStore()
    const a = await commitPhase(deps(ten(yes), { store: shared }).d, CTX)
    // A rerun generates a fresh nonce, so a naive implementation would commit to a different hash and
    // then be unable to reveal against the first commitment.
    const b = await commitPhase(
      deps(ten(yes), { store: shared, randomNonce: () => keccak256(toHex('different')) }).d,
      CTX,
    )
    expect(b.attestations[0]!.commitment).toBe(a.attestations[0]!.commitment)
  })
})

describe('reveal phase', () => {
  it('reveals every slot whose commitment is on chain', async () => {
    const { d, relayer } = deps(ten(yes))
    await commitPhase(d, CTX)
    const r = await revealPhase(d, CTX)
    expect(r.attestations).toHaveLength(10)
    expect(relayer.reveals[0]).toHaveLength(10)
  })

  it('skips a slot whose commitment never landed', async () => {
    // The registry reverts with NoCommitment. Retrying that is gas spent proving something readable.
    const { d, relayer } = deps(ten(yes))
    relayer.rejectSlots.add(4)
    await commitPhase(d, CTX)
    const r = await revealPhase(d, CTX)
    expect(r.attestations.map((a) => a.slot)).not.toContain(4)
    expect(r.skipped.find((s) => s.slot === 4)?.reason).toContain('not on chain')
  })

  it('skips a slot that never bound a verdict', async () => {
    const { d } = deps([dead, ...Array.from({ length: 9 }, () => yes)])
    await commitPhase(d, CTX)
    const r = await revealPhase(d, CTX)
    expect(r.skipped.find((s) => s.slot === 0)?.reason).toContain('no verdict')
  })

  it('recomputes the salt rather than relying on stored state', async () => {
    // Losing a salt between commit and reveal forfeits 25% of the bond (§15). A fresh process with only
    // the slot secret must be able to reveal.
    const shared = new MemoryAttestationStore()
    const first = deps(ten(yes), { store: shared })
    await commitPhase(first.d, CTX)

    const fresh = deps(ten(yes), { store: shared, relayer: first.relayer })
    const r = await revealPhase(fresh.d, CTX)
    expect(r.attestations).toHaveLength(10)
    expect(r.attestations[0]!.salt).toBe(deriveSalt(keccak256(toHex('salt-0')) as Hex, 7n, 0))
  })

  it('reveals the bound verdict even if a later run would have judged differently', async () => {
    const shared = new MemoryAttestationStore()
    const first = deps(ten(no), { store: shared })
    await commitPhase(first.d, CTX)
    const r = await revealPhase(deps(ten(yes), { store: shared, relayer: first.relayer }).d, CTX)
    expect(r.attestations.every((a) => a.verdict === false)).toBe(true)
  })

  it('relays nothing when no slot can reveal', async () => {
    const { d, relayer } = deps(ten(dead))
    await commitPhase(d, CTX)
    const r = await revealPhase(d, CTX)
    expect(r.attestations).toHaveLength(0)
    expect(relayer.reveals).toHaveLength(0)
  })
})

describe('tranche track', () => {
  it('uses the narrower prompt that denies investment discretion (§8.4)', async () => {
    const { d, board } = deps(ten(yes))
    await commitPhase(d, { ...CTX, kind: 'Tranche' })
    const sys = (board[0]!.adapter as Stub).seen[0]!.systemPrompt
    expect(sys).toContain('Your authority here is narrow')
    expect(sys).not.toContain('Pass two, the investment')
  })
})
