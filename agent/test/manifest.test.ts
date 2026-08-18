import { describe, expect, it } from 'vitest'
import { validateManifest } from '../src/package/manifest.js'

const INVESTEE = '0x1111111111111111111111111111111111111111'

function good(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    investee: INVESTEE,
    allocationWeth: '20000000000000000000',
    description: 'A zk coprocessor for verifiable off-chain compute.',
    repayment: { supplyBps: 500, vestingMonths: 24, longStopMonths: 36, floorMultipleBps: 12500 },
    milestones: [
      {
        index: 1,
        kind: 'published_audit',
        description: 'Audit of the settlement contracts',
        windowEnd: '2027-02-01T00:00:00.000Z',
        evidence: { auditor: 'Trail of Bits', reportUri: 'ipfs://bafy', scope: 'settlement/*' },
      },
      {
        index: 2,
        kind: 'verified_contract',
        description: 'Mainnet settlement contract deployed and verified',
        windowEnd: '2027-06-01T00:00:00.000Z',
        evidence: { address: INVESTEE, chainId: '1' },
      },
    ],
    ...overrides,
  }
}

describe('a well-formed manifest', () => {
  it('validates cleanly', () => {
    const v = validateManifest(good())
    expect(v.malformed).toBe(false)
    expect(v.issues.filter((i) => i.severity === 'fatal')).toEqual([])
  })
})

describe('§8.4: milestones must be mechanically verifiable', () => {
  it('rejects an interpretive milestone', () => {
    // "Interpretive milestones, traction, partnerships, successful launches, are invalid at submission."
    // The tranche track gives the board no investment discretion, so a milestone that requires judgement
    // hands it a decision it is explicitly denied.
    const v = validateManifest(
      good({
        milestones: [
          { index: 1, kind: 'traction', description: 'Meaningful user growth', windowEnd: '2027-02-01T00:00:00.000Z', evidence: {} },
          good().milestones as never,
        ],
      }),
    )
    expect(v.malformed).toBe(true)
    expect(v.issues.some((i) => i.message.includes('interpretive'))).toBe(true)
  })

  it('rejects a valid kind that lacks the evidence needed to check it', () => {
    const ms = good().milestones as Record<string, unknown>[]
    const v = validateManifest(
      good({ milestones: [{ ...ms[0]!, evidence: { auditor: 'Trail of Bits' } }, ms[1]!] }),
    )
    expect(v.malformed).toBe(true)
    expect(v.issues.some((i) => i.path.includes('evidence.reportUri'))).toBe(true)
  })

  it('requires exactly two, matching the 40/30/30 split', () => {
    const ms = good().milestones as Record<string, unknown>[]
    expect(validateManifest(good({ milestones: [ms[0]!] })).malformed).toBe(true)
    expect(validateManifest(good({ milestones: [...ms, ms[0]!] })).malformed).toBe(true)
  })

  it('requires ascending windows', () => {
    const ms = good().milestones as Record<string, unknown>[]
    const v = validateManifest(
      good({ milestones: [{ ...ms[0]!, windowEnd: '2027-09-01T00:00:00.000Z' }, ms[1]!] }),
    )
    expect(v.malformed).toBe(true)
  })

  it('enforces §15 twelve-month cap per window', () => {
    const ms = good().milestones as Record<string, unknown>[]
    const v = validateManifest(
      good({ milestones: [ms[0]!, { ...ms[1]!, windowEnd: '2029-01-01T00:00:00.000Z' }] }),
    )
    expect(v.malformed).toBe(true)
    expect(v.issues.some((i) => i.message.includes('12 months'))).toBe(true)
  })
})

describe('§15 repayment parameters', () => {
  it('rejects vesting beyond twenty-four months', () => {
    const v = validateManifest(good({ repayment: { supplyBps: 500, vestingMonths: 36, longStopMonths: 36, floorMultipleBps: 12500 } }))
    expect(v.malformed).toBe(true)
  })

  it('flags a non-standard long-stop as a finding rather than fatal', () => {
    // The board should see it and weigh it; it is not the harness's job to decide.
    const v = validateManifest(good({ repayment: { supplyBps: 500, vestingMonths: 24, longStopMonths: 48, floorMultipleBps: 12500 } }))
    expect(v.malformed).toBe(false)
    expect(v.issues.some((i) => i.severity === 'finding' && i.path.includes('longStop'))).toBe(true)
  })

  it('rejects a supply percentage outside the representable range', () => {
    expect(validateManifest(good({ repayment: { supplyBps: 0, vestingMonths: 24, longStopMonths: 36, floorMultipleBps: 12500 } })).malformed).toBe(true)
    expect(validateManifest(good({ repayment: { supplyBps: 10001, vestingMonths: 24, longStopMonths: 36, floorMultipleBps: 12500 } })).malformed).toBe(true)
  })
})

describe('basic shape', () => {
  it('rejects a non-object', () => {
    expect(validateManifest('nope').malformed).toBe(true)
    expect(validateManifest([]).malformed).toBe(true)
    expect(validateManifest(null).malformed).toBe(true)
  })

  it('rejects a bad investee address', () => {
    expect(validateManifest(good({ investee: 'not-an-address' })).malformed).toBe(true)
  })

  it('requires the allocation as a decimal wei string, so precision cannot be lost', () => {
    // A JSON number would silently round a wei value above 2^53.
    expect(validateManifest(good({ allocationWeth: 2e19 })).malformed).toBe(true)
    expect(validateManifest(good({ allocationWeth: '20000000000000000000' })).malformed).toBe(false)
  })
})
