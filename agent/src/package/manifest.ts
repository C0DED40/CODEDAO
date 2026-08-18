/**
 * The manifest: schema, validation, and the checks §6.1 and §8.4 make load-bearing.
 *
 * The contract already refuses a proposal whose manifest investee differs from its calldata investee
 * (invariant 4), so by the time a package reaches the board that equality holds. What the contract
 * cannot check is everything about the manifest that is not an address: whether the milestones are
 * mechanically verifiable, whether the repayment terms match what the investee's deployed contracts
 * actually implement, whether the numbers are internally consistent. §5.3 makes those the board's job,
 * and this module gives the board a structured answer rather than making ten models each parse JSON.
 *
 * Validation findings are passed to the board as evidence, not used to skip the round. A malformed
 * manifest is a reason to reject, and the rejection should come from the board with a published reason
 * under §5.7, not from a harness that quietly declined to ask.
 */

import { isAddress, type Address } from 'viem'

export interface Manifest {
  readonly investee: string
  readonly investeeName?: string
  readonly allocationWeth: string
  readonly repayment: {
    readonly supplyBps: number
    readonly vestingMonths: number
    readonly longStopMonths: number
    readonly floorMultipleBps: number
  }
  readonly milestones: readonly {
    readonly index: number
    readonly kind: MilestoneKind
    readonly description: string
    readonly windowEnd: string
    readonly evidence: Readonly<Record<string, string>>
  }[]
  readonly links?: readonly string[]
  readonly description: string
}

/**
 * §8.4's closed list. "Milestones are defined in the manifest at proposal time, hashed on-chain, and
 * must be mechanically verifiable from public artefacts... Interpretive milestones, traction,
 * partnerships, successful launches, are invalid at submission."
 */
export const MILESTONE_KINDS = [
  'verified_contract',
  'published_audit',
  'mainnet_migration',
  'onchain_metric',
] as const

export type MilestoneKind = (typeof MILESTONE_KINDS)[number]

/** Evidence fields each kind must carry for the claim to be checkable at all. */
const REQUIRED_EVIDENCE: Readonly<Record<MilestoneKind, readonly string[]>> = {
  verified_contract: ['address', 'chainId'],
  published_audit: ['auditor', 'reportUri', 'scope'],
  mainnet_migration: ['address', 'chainId'],
  onchain_metric: ['metric', 'source', 'threshold'],
}

export type Severity = 'fatal' | 'finding'

export interface ManifestIssue {
  readonly severity: Severity
  readonly path: string
  readonly message: string
}

export interface ManifestValidation {
  readonly manifest?: Manifest
  readonly issues: readonly ManifestIssue[]
  /** True when the document could not be read as a manifest at all. */
  readonly malformed: boolean
}

const MAX_SUPPLY_BPS = 10_000
const MAX_VESTING_MONTHS = 24 // §15
const LONG_STOP_MONTHS = 36 // §15
const MAX_MILESTONE_WINDOW_MONTHS = 12 // §15

export function validateManifest(doc: unknown): ManifestValidation {
  const issues: ManifestIssue[] = []
  const fatal = (path: string, message: string) => issues.push({ severity: 'fatal', path, message })
  const finding = (path: string, message: string) => issues.push({ severity: 'finding', path, message })

  if (typeof doc !== 'object' || doc === null || Array.isArray(doc)) {
    return { issues: [{ severity: 'fatal', path: '$', message: 'not a JSON object' }], malformed: true }
  }
  const m = doc as Record<string, unknown>

  if (typeof m.investee !== 'string' || !isAddress(m.investee)) {
    fatal('investee', 'missing or not a valid address')
  }
  if (typeof m.allocationWeth !== 'string' || !/^\d+$/.test(m.allocationWeth)) {
    // A string, so a large wei value cannot lose precision through a JSON number.
    fatal('allocationWeth', 'must be a decimal wei string')
  }
  if (typeof m.description !== 'string' || m.description.length === 0) {
    fatal('description', 'missing')
  }

  const r = m.repayment
  if (typeof r !== 'object' || r === null) {
    fatal('repayment', 'missing')
  } else {
    const rep = r as Record<string, unknown>
    if (typeof rep.supplyBps !== 'number' || rep.supplyBps <= 0 || rep.supplyBps > MAX_SUPPLY_BPS) {
      fatal('repayment.supplyBps', `must be between 1 and ${MAX_SUPPLY_BPS}`)
    }
    if (
      typeof rep.vestingMonths !== 'number' ||
      rep.vestingMonths < 1 ||
      rep.vestingMonths > MAX_VESTING_MONTHS
    ) {
      fatal('repayment.vestingMonths', `§15 caps vesting at ${MAX_VESTING_MONTHS} monthly installments`)
    }
    if (rep.longStopMonths !== LONG_STOP_MONTHS) {
      finding('repayment.longStopMonths', `§15 fixes the long-stop at ${LONG_STOP_MONTHS} months`)
    }
    if (rep.floorMultipleBps !== 12_500) {
      finding('repayment.floorMultipleBps', '§15 fixes the long-stop floor at 1.25x (12500 bps)')
    }
  }

  if (!Array.isArray(m.milestones) || m.milestones.length !== 2) {
    // §8.3's split is 40/30/30: tranche one unlocks on execution, so exactly two milestones gate the
    // remaining two tranches.
    fatal('milestones', 'must be exactly two, gating tranches two and three (§8.3)')
  } else {
    m.milestones.forEach((raw, i) => {
      const path = `milestones[${i}]`
      if (typeof raw !== 'object' || raw === null) {
        fatal(path, 'not an object')
        return
      }
      const ms = raw as Record<string, unknown>
      if (typeof ms.kind !== 'string' || !(MILESTONE_KINDS as readonly string[]).includes(ms.kind)) {
        // The heart of §8.4. An interpretive milestone hands the board a judgement call it is explicitly
        // denied on the tranche track, where it "holds no discretion the manifest did not give it".
        fatal(path + '.kind', `interpretive or unknown milestone kind "${String(ms.kind)}"; §8.4 requires one of ${MILESTONE_KINDS.join(', ')}`)
      } else {
        const required = REQUIRED_EVIDENCE[ms.kind as MilestoneKind]
        const ev = (typeof ms.evidence === 'object' && ms.evidence !== null ? ms.evidence : {}) as Record<string, unknown>
        for (const key of required) {
          if (typeof ev[key] !== 'string' || (ev[key] as string).length === 0) {
            fatal(`${path}.evidence.${key}`, `required for kind "${ms.kind}"`)
          }
        }
      }
      if (typeof ms.windowEnd !== 'string' || Number.isNaN(Date.parse(ms.windowEnd))) {
        fatal(path + '.windowEnd', 'must be an ISO timestamp')
      }
      if (typeof ms.description !== 'string' || ms.description.length < 10) {
        finding(path + '.description', 'too short to be legible to the board or the founder')
      }
    })

    // Windows must ascend, and each must be inside §15's twelve-month cap.
    const ends = m.milestones
      .map((raw) => (typeof raw === 'object' && raw !== null ? (raw as Record<string, unknown>).windowEnd : undefined))
      .map((v) => (typeof v === 'string' ? Date.parse(v) : Number.NaN))
    if (!Number.isNaN(ends[0]!) && !Number.isNaN(ends[1]!)) {
      if (ends[1]! <= ends[0]!) {
        fatal('milestones[1].windowEnd', 'must be later than the first milestone window')
      }
      const gapMonths = (ends[1]! - ends[0]!) / (1000 * 60 * 60 * 24 * 30)
      if (gapMonths > MAX_MILESTONE_WINDOW_MONTHS) {
        fatal('milestones[1].windowEnd', `§15 caps each milestone window at ${MAX_MILESTONE_WINDOW_MONTHS} months`)
      }
    }
  }

  const malformed = issues.some((i) => i.severity === 'fatal')
  return malformed
    ? { issues, malformed: true }
    : { manifest: doc as unknown as Manifest, issues, malformed: false }
}

/** The address the calldata must agree with, per invariant 4. */
export function manifestInvestee(m: Manifest): Address {
  return m.investee as Address
}
