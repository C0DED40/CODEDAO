/**
 * Shared types for the SAINE harness.
 *
 * Whitepaper section references point at `CODE DAO Whitepaper v0.1`; the on-chain counterparts live
 * in `contracts/src/Saine.sol`.
 */

import type { Address, Hex } from 'viem'

/** §5.4 tally: the board's three outcomes. Mirrors `Saine.RoundState`. */
export type RoundState = 'None' | 'Open' | 'Approved' | 'Rejected' | 'Lapsed'

/** Mirrors `Saine.RoundKind`. */
export type RoundKind = 'Origination' | 'Tranche' | 'Advisory'

export const ROUND_KIND_INDEX: Record<RoundKind, number> = {
  Origination: 0,
  Tranche: 1,
  Advisory: 2,
}

/**
 * §5.7's fixed taxonomy. Closed on purpose: "The taxonomy makes verdicts machine-comparable across
 * seasons, which is the raw material for detecting both drift and capture." A free-text-only reason
 * would make that comparison impossible.
 */
export const REASON_CODES = [
  'tokenomics',
  'team',
  'contract_risk',
  'valuation',
  'mandate_fit',
  'insufficient_information',
] as const

export type ReasonCode = (typeof REASON_CODES)[number]

/**
 * A reason document, pinned to IPFS with its hash bound inside the commitment (§5.4).
 *
 * `nonce` is not decoration. The commitment is `keccak256(verdict, reasonHash, salt)`, and the salt is
 * derived deterministically (see `deriveSalt`). Without unpredictable entropy in the reason document,
 * anyone who learned a slot's salt secret could enumerate the two possible verdicts against the six
 * taxonomy codes and read a sealed verdict before the reveal. The nonce makes `reasonHash`
 * unguessable, which is what keeps the commitment blind.
 */
export interface ReasonDocument {
  readonly code: ReasonCode
  readonly text: string
  readonly nonce: Hex
  /** Identity of the evaluator, so a published reason can be attributed after the fact (§5.4). */
  readonly model: ModelIdentity
  readonly roundId: string
  readonly slot: number
}

/**
 * §5.4: "Every attestation is published with a hash of the model identifier, version, and system
 * prompt in use, so silent model substitution is detectable after the fact."
 */
export interface ModelIdentity {
  readonly provider: string
  readonly model: string
  readonly version: string
  /** Hash of the exact system prompt used, not a description of it. */
  readonly systemPromptHash: Hex
}

/** One of the ten seats. */
export interface SlotConfig {
  readonly slot: number
  readonly provider: string
  /** Provider tag as registered on chain, used for the four-provider constraint (§5.2). */
  readonly providerTag: string
  readonly model: string
  readonly openWeights: boolean
}

/** A verdict, before it is committed. */
export interface Judgement {
  readonly approve: boolean
  readonly reason: ReasonDocument
}

/** What the model is asked to return. */
export interface ModelVerdict {
  readonly approve: boolean
  readonly code: ReasonCode
  readonly text: string
}

/** §5.3's adjudication package, in the order the whitepaper specifies. */
export interface AdjudicationPackage {
  readonly roundId: bigint
  readonly kind: RoundKind
  readonly subject: bigint
  /** 1. Decoded calldata of every action, annotated against the known-target registry. */
  readonly actions: readonly DecodedAction[]
  /** 2. Simulation trace of the full execution path, including the payout. */
  readonly simulation: SimulationTrace
  /** 3. Verified source at every investee address named in the manifest. */
  readonly investeeSource: readonly VerifiedSource[]
  /** 4. The structured manifest. */
  readonly manifest: unknown
  /** 5. The prose description. Untrusted; fenced before it reaches a model. */
  readonly description: string
  /** 6. The deal's history: prior submissions with their verdicts and published reasons. */
  readonly history: readonly PriorRound[]
}

export interface DecodedAction {
  readonly target: Address
  readonly selector: Hex
  readonly signature: string
  readonly args: readonly unknown[]
  /** False when the (target, selector) pair is outside the registry, so §6.2 required a flag. */
  readonly registered: boolean
}

export interface SimulationTrace {
  readonly ok: boolean
  readonly gasUsed: bigint
  readonly revertReason?: string
  readonly transfers: readonly {
    readonly token: Address
    readonly from: Address
    readonly to: Address
    readonly amount: bigint
  }[]
}

export interface VerifiedSource {
  readonly address: Address
  readonly verified: boolean
  readonly name?: string
  readonly source?: string
}

export interface PriorRound {
  readonly roundId: bigint
  readonly outcome: RoundState
  readonly reasons: readonly { readonly slot: number; readonly code: ReasonCode; readonly text: string }[]
}

/** A signed commitment, ready to relay. */
export interface CommitAttestation {
  readonly roundId: bigint
  readonly slot: number
  readonly commitment: Hex
  readonly modelHash: Hex
  readonly signature: Hex
}

/** A signed reveal, ready to relay. */
export interface RevealAttestation {
  readonly roundId: bigint
  readonly slot: number
  readonly verdict: boolean
  readonly reasonHash: Hex
  readonly salt: Hex
  readonly signature: Hex
}
