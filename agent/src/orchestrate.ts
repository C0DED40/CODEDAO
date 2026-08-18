/**
 * The round state machine: package, judge, bind, sign, relay, reveal.
 *
 * The ordering here is not stylistic. Each step is placed where it is because doing it later would cost
 * the slot money or the round its quorum:
 *
 *   - The **guard runs before any signature exists**, not after. A signature that exists is evidence,
 *     and §5.5 needs only two of them with different verdicts to burn the whole bond.
 *   - The **reason is pinned before the commitment is relayed**, so a reveal can never point at a document
 *     nobody can fetch. A failed pin degrades the record; a relayed commitment with no document is a
 *     §5.7 obligation the operator cannot meet.
 *   - The **reveal reconciles against the chain first**. A slot whose commitment never landed must not
 *     reveal: the registry reverts with `NoCommitment`, and in the worst case a retry storm burns gas
 *     against a round the slot was never in.
 *   - A **slot that failed to judge does not attest at all.** Committing a rejection because a provider
 *     returned a 503 would let infrastructure trouble kill deals, and §5.4's lapse path exists precisely
 *     so that outcome harms nobody.
 */

import { randomBytes } from 'node:crypto'
import { toHex, type Hex } from 'viem'
import {
  buildCommitment,
  deriveSalt,
  hashReason,
  hashSystemPrompt,
  modelHash,
  signCommit,
  signReveal,
  type Domain,
} from './attest.js'
import { bindVerdict, EquivocationRefused, type AttestationStore } from './guard.js'
import type { Pinner } from './ipfs.js'
import type { Relayer } from './relay.js'
import { runBoard, type SlotBinding, type SlotOutcome } from './runner.js'
import { renderPackage, type RenderOptions } from './package/render.js'
import { SYSTEM_PROMPT, TRANCHE_SYSTEM_PROMPT } from './prompt.js'
import type {
  AdjudicationPackage,
  CommitAttestation,
  ModelIdentity,
  ReasonDocument,
  RevealAttestation,
  RoundKind,
} from './types.js'

export interface RoundContext {
  readonly roundId: bigint
  readonly kind: RoundKind
  readonly subject: bigint
  /** Unix seconds, from the registry's `Round`. */
  readonly commitEnd: number
  readonly revealEnd: number
}

export interface BuiltPackage {
  readonly pkg: AdjudicationPackage
  readonly render: Omit<RenderOptions, 'packageSalt'>
}

export interface SlotKeys {
  readonly signingKey: Hex
  /** Separate from the signing key: it derives salts and nothing else. */
  readonly saltSecret: Hex
}

export interface OrchestratorDeps {
  readonly board: readonly SlotBinding[]
  readonly store: AttestationStore
  readonly keys: (slot: number) => SlotKeys
  readonly domain: Domain
  readonly pinner: Pinner
  readonly relayer: Relayer
  readonly buildPackage: (ctx: RoundContext) => Promise<BuiltPackage>
  /** Per-round, unpredictable, and identical for all ten slots. Seeds the prose fence tag. */
  readonly packageSalt: (ctx: RoundContext) => Hex
  readonly now?: () => number
  readonly randomNonce?: () => Hex
  /**
   * Slot deadline. Defaults to a fifth of the remaining commit window, floored at 30 seconds and
   * capped at ten minutes.
   *
   * The cap matters more than the fraction. A fifth of a fresh 24-hour window is nearly five hours,
   * which means a hung provider would consume most of the window before the harness noticed and left no
   * time to retry. A model that has not answered in ten minutes is not going to; failing that slot early
   * keeps eight others' chances of reaching the reveal window intact.
   */
  readonly modelTimeoutMs?: number
  readonly log?: (event: LogEvent) => void
}

export type LogEvent =
  | { readonly kind: 'package_built'; readonly roundId: bigint; readonly chars: number }
  | { readonly kind: 'board_run'; readonly roundId: bigint; readonly judged: number; readonly failed: number; readonly projected: string }
  | { readonly kind: 'slot_failed'; readonly roundId: bigint; readonly slot: number; readonly error: string }
  | { readonly kind: 'pin_failed'; readonly roundId: bigint; readonly slot: number; readonly error: string }
  | { readonly kind: 'equivocation_refused'; readonly roundId: bigint; readonly slot: number; readonly error: string }
  | { readonly kind: 'commits_relayed'; readonly roundId: bigint; readonly accepted: readonly number[]; readonly rejected: number }
  | { readonly kind: 'reveals_relayed'; readonly roundId: bigint; readonly accepted: readonly number[]; readonly rejected: number }
  | { readonly kind: 'reveal_skipped'; readonly roundId: bigint; readonly slot: number; readonly reason: string }

export interface CommitPhaseResult {
  readonly outcomes: readonly SlotOutcome[]
  readonly attestations: readonly CommitAttestation[]
  readonly reasons: ReadonlyMap<number, { readonly doc: ReasonDocument; readonly cid?: string }>
  readonly relayed?: { readonly accepted: readonly number[]; readonly rejected: number }
}

export async function commitPhase(
  deps: OrchestratorDeps,
  ctx: RoundContext,
): Promise<CommitPhaseResult> {
  const now = deps.now ?? (() => Date.now())
  const log = deps.log ?? (() => {})
  const nonce = deps.randomNonce ?? (() => toHex(randomBytes(32)))

  const built = await deps.buildPackage(ctx)
  const salt = deps.packageSalt(ctx)
  const userPrompt = renderPackage(built.pkg, { ...built.render, packageSalt: salt })
  log({ kind: 'package_built', roundId: ctx.roundId, chars: userPrompt.length })

  const systemPrompt = ctx.kind === 'Tranche' ? TRANCHE_SYSTEM_PROMPT : SYSTEM_PROMPT
  const systemPromptHash = hashSystemPrompt(systemPrompt)

  const remainingMs = Math.max(0, ctx.commitEnd * 1000 - now())
  const timeoutMs =
    deps.modelTimeoutMs ?? Math.max(30_000, Math.min(600_000, Math.floor(remainingMs / 5)))

  const board = await runBoard(deps.board, { systemPrompt, userPrompt, timeoutMs })
  log({
    kind: 'board_run',
    roundId: ctx.roundId,
    judged: board.judged,
    failed: board.failed,
    projected: board.projected,
  })

  const attestations: CommitAttestation[] = []
  const reasons = new Map<number, { doc: ReasonDocument; cid?: string }>()

  for (const outcome of board.outcomes) {
    if (outcome.status !== 'judged' || outcome.verdict === undefined) {
      log({ kind: 'slot_failed', roundId: ctx.roundId, slot: outcome.slot, error: outcome.error ?? 'no verdict' })
      continue
    }

    const identity: ModelIdentity = {
      provider: outcome.provider,
      // What the API served, not what was asked for (§5.4).
      model: outcome.servedModel ?? outcome.model,
      version: outcome.servedModel ?? 'unreported',
      systemPromptHash,
    }

    const doc: ReasonDocument = {
      code: outcome.verdict.code,
      text: outcome.verdict.text,
      nonce: nonce(),
      model: identity,
      roundId: ctx.roundId.toString(),
      slot: outcome.slot,
    }

    const reasonHash = hashReason(doc)
    const keys = deps.keys(outcome.slot)
    const saltHex = deriveSalt(keys.saltSecret, ctx.roundId, outcome.slot)
    const commitment = buildCommitment(outcome.verdict.approve, reasonHash, saltHex)
    const mHash = modelHash(identity)

    // The guard, before any signature exists.
    let bound
    try {
      bound = await bindVerdict(deps.store, {
        slot: outcome.slot,
        roundId: ctx.roundId.toString(),
        verdict: outcome.verdict.approve,
        reasonHash,
        modelHash: mHash,
        committedAt: new Date(now()).toISOString(),
      })
    } catch (err) {
      // Refusing to sign costs a quarter of this slot's bond at worst. Signing anyway could cost all of
      // it and the seat.
      log({
        kind: 'equivocation_refused',
        roundId: ctx.roundId,
        slot: outcome.slot,
        error: err instanceof EquivocationRefused ? err.message : String(err),
      })
      continue
    }

    // If a prior attempt already bound a verdict for this round, its reason document is the one the
    // chain will be asked to match. Reuse the stored hash rather than this run's.
    const effectiveReasonHash = bound.record.reasonHash
    const effectiveCommitment = buildCommitment(bound.record.verdict, effectiveReasonHash, saltHex)

    let cid: string | undefined
    try {
      const pinned = await deps.pinner.pin(doc)
      cid = pinned.cid
    } catch (err) {
      // Degraded record, not an invalid vote. §5.7's legibility suffers; the verdict stands.
      log({ kind: 'pin_failed', roundId: ctx.roundId, slot: outcome.slot, error: String(err) })
    }
    reasons.set(outcome.slot, cid === undefined ? { doc } : { doc, cid })

    attestations.push(
      await signCommit({
        signingKey: keys.signingKey,
        domain: deps.domain,
        roundId: ctx.roundId,
        slot: outcome.slot,
        commitment: effectiveCommitment,
        modelHash: bound.record.modelHash,
      }),
    )
  }

  if (attestations.length === 0) {
    return { outcomes: board.outcomes, attestations, reasons }
  }

  const receipt = await deps.relayer.submitCommits(attestations)
  log({
    kind: 'commits_relayed',
    roundId: ctx.roundId,
    accepted: receipt.accepted,
    rejected: receipt.rejected.length,
  })

  return {
    outcomes: board.outcomes,
    attestations,
    reasons,
    relayed: { accepted: receipt.accepted, rejected: receipt.rejected.length },
  }
}

export interface RevealPhaseResult {
  readonly attestations: readonly RevealAttestation[]
  readonly skipped: readonly { readonly slot: number; readonly reason: string }[]
  readonly relayed?: { readonly accepted: readonly number[]; readonly rejected: number }
}

export async function revealPhase(
  deps: OrchestratorDeps,
  ctx: RoundContext,
): Promise<RevealPhaseResult> {
  const log = deps.log ?? (() => {})

  // Reconcile against the chain. A slot that never landed a commitment cannot reveal: the registry
  // reverts with `NoCommitment`, and retrying that is gas spent proving something we could have read.
  const onChain = new Set(await deps.relayer.committedSlots(ctx.roundId))

  const attestations: RevealAttestation[] = []
  const skipped: { slot: number; reason: string }[] = []

  for (const binding of deps.board) {
    const slot = binding.config.slot
    const record = await deps.store.read(slot, ctx.roundId)

    if (record === null) {
      skipped.push({ slot, reason: 'no verdict was bound for this round' })
      log({ kind: 'reveal_skipped', roundId: ctx.roundId, slot, reason: 'no bound verdict' })
      continue
    }
    if (!onChain.has(slot)) {
      skipped.push({ slot, reason: 'commitment is not on chain' })
      log({ kind: 'reveal_skipped', roundId: ctx.roundId, slot, reason: 'commitment absent on chain' })
      continue
    }

    const keys = deps.keys(slot)
    attestations.push(
      await signReveal({
        signingKey: keys.signingKey,
        domain: deps.domain,
        roundId: ctx.roundId,
        slot,
        verdict: record.verdict,
        reasonHash: record.reasonHash,
        // Recomputed, never stored. This is why the salt is derived (see `deriveSalt`).
        salt: deriveSalt(keys.saltSecret, ctx.roundId, slot),
      }),
    )
  }

  if (attestations.length === 0) return { attestations, skipped }

  const receipt = await deps.relayer.submitReveals(attestations)
  log({
    kind: 'reveals_relayed',
    roundId: ctx.roundId,
    accepted: receipt.accepted,
    rejected: receipt.rejected.length,
  })

  return {
    attestations,
    skipped,
    relayed: { accepted: receipt.accepted, rejected: receipt.rejected.length },
  }
}
