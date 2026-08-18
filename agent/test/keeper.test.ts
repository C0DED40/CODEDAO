/**
 * The keeper's decision logic.
 *
 * Every step here sends a transaction, so what needs testing is not the sending but the deciding: which
 * calls it makes, which it declines, and that one failing step does not take the pass down with it. A
 * keeper that skips a due settlement stalls the origination queue; a keeper that claims fees into the
 * wrong account is worse. Both are read-path bugs, and both are testable without a chain.
 */
import { describe, expect, it } from 'vitest'
import type { Address, PublicClient, WalletClient } from 'viem'
import {
  claimAttestationFees,
  executeBuyback,
  revalueBonds,
  rolloverIfDue,
  runKeeperPass,
  settleDueRounds,
  syncFeePool,
  type KeeperDeps,
  type KeeperTargets,
} from '../src/keeper.js'

const SAINE = '0x0000000000000000000000000000000000000001' as Address
const DCODE = '0x0000000000000000000000000000000000000002' as Address
const GOVERNOR = '0x0000000000000000000000000000000000000003' as Address
const ORACLE = '0x0000000000000000000000000000000000000004' as Address
const RECEIVER = '0x0000000000000000000000000000000000000005' as Address
const CODE = '0x0000000000000000000000000000000000000006' as Address
const OPERATOR = '0x00000000000000000000000000000000000000aa' as Address

type Reads = Record<string, unknown | ((args: readonly unknown[]) => unknown)>

interface Written {
  readonly functionName: string
  readonly address: Address
  readonly args?: readonly unknown[]
}

function deps(reads: Reads, opts: { readonly now?: number; readonly operator?: Address } = {}) {
  const written: Written[] = []
  const reader = {
    async readContract(req: { functionName: string; address: Address; args?: readonly unknown[] }) {
      const entry = reads[req.functionName]
      if (entry === undefined) throw new Error(`unexpected read: ${req.functionName}`)
      return typeof entry === 'function' ? (entry as (a: readonly unknown[]) => unknown)(req.args ?? []) : entry
    },
  } as unknown as PublicClient
  const wallet = {
    account: { address: '0x00000000000000000000000000000000000000bb' as Address },
    async writeContract(req: { functionName: string; address: Address; args?: readonly unknown[] }) {
      written.push({ functionName: req.functionName, address: req.address, ...(req.args ? { args: req.args } : {}) })
      return '0xdeadbeef'
    },
  } as unknown as WalletClient
  const targets: KeeperTargets = {
    saine: SAINE,
    dcode: DCODE,
    governor: GOVERNOR,
    oracle: ORACLE,
    receiver: RECEIVER,
    code: CODE,
    ...(opts.operator !== undefined ? { operator: opts.operator } : {}),
  }
  const d: KeeperDeps = { reader, wallet, targets, now: () => (opts.now ?? 1_700_000_000) * 1000 }
  return { d, written }
}

describe('settleDueRounds', () => {
  const OPEN = 1

  it('settles a round whose reveal window has closed', async () => {
    const { d, written } = deps({
      roundCount: 3n,
      getRound: ([id]: readonly unknown[]) => ({
        state: (id as bigint) === 2n ? OPEN : 2,
        revealEnd: 1_000n,
        commits: 10,
        reveals: 8,
      }),
    })
    const actions = await settleDueRounds(d)
    expect(actions).toHaveLength(1)
    expect(written).toEqual([{ functionName: 'settleRound', address: SAINE, args: [2n] }])
  })

  it('settles early once every committed slot has revealed', async () => {
    const { d, written } = deps({
      roundCount: 1n,
      getRound: () => ({ state: OPEN, revealEnd: 9_999_999_999n, commits: 9, reveals: 9 }),
    })
    await settleDueRounds(d)
    expect(written.map((w) => w.functionName)).toEqual(['settleRound'])
  })

  it('leaves an open round alone while reveals are outstanding', async () => {
    const { d, written } = deps({
      roundCount: 1n,
      getRound: () => ({ state: OPEN, revealEnd: 9_999_999_999n, commits: 10, reveals: 4 }),
    })
    expect(await settleDueRounds(d)).toEqual([])
    expect(written).toEqual([])
  })

  it('scans only the tail, because anything older is long settled', async () => {
    const seen: bigint[] = []
    const { d } = deps({
      roundCount: 100n,
      getRound: ([id]: readonly unknown[]) => {
        seen.push(id as bigint)
        return { state: 2, revealEnd: 0n, commits: 0, reveals: 0 }
      },
    })
    await settleDueRounds(d)
    expect(seen[0]).toBe(80n)
    expect(seen).toHaveLength(21)
  })
})

describe('rolloverIfDue', () => {
  it('waits until the boundary timestamp has passed', async () => {
    const { d, written } = deps({ currentSeason: 3, seasonEnd: 2_000n }, { now: 1_999 })
    expect((await rolloverIfDue(d))[0]?.skipped).toBe('not due')
    expect(written).toEqual([])
  })

  it('rolls over once it has', async () => {
    const { d, written } = deps({ currentSeason: 3, seasonEnd: 2_000n }, { now: 2_001 })
    await rolloverIfDue(d)
    expect(written.map((w) => w.functionName)).toEqual(['rollover'])
  })

  it('does nothing before governance opens', async () => {
    const { d, written } = deps({ currentSeason: 0 })
    expect((await rolloverIfDue(d))[0]?.skipped).toBe('no season')
    expect(written).toEqual([])
  })
})

describe('syncFeePool', () => {
  it('credits CODE that arrived without a sync behind it', async () => {
    const { d, written } = deps({ balanceOf: 600_000n, totalBondedCode: 500_000n, feePool: 10_000n })
    const actions = await syncFeePool(d)
    expect(actions[0]?.txHash).toBe('0xdeadbeef')
    expect(written.map((w) => w.functionName)).toEqual(['syncFeePool'])
  })

  it('does not mistake bonds for an unsynced balance', async () => {
    // The registry holds ten bonds and nothing else. None of it is the DAO's to spend.
    const { d, written } = deps({ balanceOf: 500_000n, totalBondedCode: 500_000n, feePool: 0n })
    expect((await syncFeePool(d))[0]?.skipped).toBe('nothing to sync')
    expect(written).toEqual([])
  })

  it('does nothing when everything present is already accounted for', async () => {
    const { d, written } = deps({ balanceOf: 510_000n, totalBondedCode: 500_000n, feePool: 10_000n })
    expect((await syncFeePool(d))[0]?.skipped).toBe('nothing to sync')
    expect(written).toEqual([])
  })
})

describe('claimAttestationFees', () => {
  it('collects for the configured operator', async () => {
    const { d, written } = deps({ owedUsd: 50n * 10n ** 18n, feePool: 100_000n }, { operator: OPERATOR })
    await claimAttestationFees(d)
    expect(written).toEqual([
      { functionName: 'claimAttestationFees', address: SAINE, args: [OPERATOR] },
    ])
  })

  it('does not collect when no operator is configured', async () => {
    // Phase one: the fee is zero and the team runs every seat.
    const { d, written } = deps({})
    expect((await claimAttestationFees(d))[0]?.skipped).toBe('not collecting')
    expect(written).toEqual([])
  })

  it('does not send a transaction for nothing accrued', async () => {
    const { d, written } = deps({ owedUsd: 0n, feePool: 100_000n }, { operator: OPERATOR })
    expect((await claimAttestationFees(d))[0]?.skipped).toBe('nothing owed')
    expect(written).toEqual([])
  })

  it('leaves the debt standing when the pool is empty', async () => {
    // Waiting costs the operator nothing: the debt is denominated in USD, not CODE.
    const { d, written } = deps({ owedUsd: 50n * 10n ** 18n, feePool: 0n }, { operator: OPERATOR })
    expect((await claimAttestationFees(d))[0]?.skipped).toBe('pool empty')
    expect(written).toEqual([])
  })
})

describe('executeBuyback', () => {
  it('waits for the contract to say the interval elapsed', async () => {
    const { d, written } = deps({ buybackReady: false })
    expect((await executeBuyback(d))[0]?.skipped).toBe('not ready')
    expect(written).toEqual([])
  })

  it('converts once it has', async () => {
    const { d, written } = deps({ buybackReady: true })
    await executeBuyback(d)
    expect(written.map((w) => w.functionName)).toEqual(['executeBuyback'])
  })
})

describe('revalueBonds', () => {
  it('is unconditional, because a bond below target keeps its slot live until someone says so', async () => {
    const { d, written } = deps({})
    await revalueBonds(d)
    expect(written.map((w) => w.functionName)).toEqual(['revalueBonds'])
  })
})

describe('runKeeperPass', () => {
  it('carries on after a step throws', async () => {
    // A reverting rollover must not prevent a buyback that is separately due.
    const { d, written } = deps({
      roundCount: 0n,
      currentSeason: () => {
        throw new Error('rpc exploded')
      },
      buybackReady: true,
      balanceOf: 0n,
      totalBondedCode: 0n,
      feePool: 0n,
    })
    const actions = await runKeeperPass(d)
    expect(actions.some((a) => a.error !== undefined)).toBe(true)
    expect(written.map((w) => w.functionName)).toEqual(['revalueBonds', 'poke', 'executeBuyback'])
  })

  it('reports every step it considered, skipped or not', async () => {
    const { d } = deps({
      roundCount: 0n,
      currentSeason: 1,
      seasonEnd: 9_999_999_999n,
      buybackReady: false,
      balanceOf: 0n,
      totalBondedCode: 0n,
      feePool: 0n,
    })
    const names = new Set((await runKeeperPass(d)).map((a) => a.name))
    expect(names).toContain('rollover')
    expect(names).toContain('revalueBonds')
    expect(names).toContain('pokeOracle')
    expect(names).toContain('executeBuyback')
    expect(names).toContain('syncFeePool')
    expect(names).toContain('claimAttestationFees')
  })
})
