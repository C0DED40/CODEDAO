/**
 * The ten seats.
 *
 * §5.2 states the selection criterion, and it is not capability: "The reason is correlated failure. Ten
 * instances of one model receiving one adversarial input fail as one reviewer, and a six-of-ten
 * threshold over identical evaluators carries no information."
 *
 * So the board is chosen for **decorrelated failure**, and the ten strongest models would be a worse
 * board than this one. Four axes of correlation are avoided deliberately:
 *
 *   1. **Provider.** Ten distinct providers, against §5.2's floor of four. Shared training corpora,
 *      shared RLHF methodology and shared safety tuning all make same-provider models fail together.
 *   2. **Family.** No two seats share a base model or a distillation lineage. This rules out the
 *      tempting move of filling three seats with one provider's flagship, balanced and cheap tiers:
 *      a distilled sibling inherits its teacher's blind spots, so those three seats would vote as one.
 *   3. **Regulatory and linguistic regime.** US, Chinese and European labs are tuned against different
 *      jailbreak corpora and different safety expectations, so an input that defeats one lineage's
 *      training tends not to defeat another's.
 *   4. **Weight availability.** Capped at three open-weights seats, for the reason in the note below.
 *
 * The open-weights question cuts both ways and the cap is a judgement, not a derivation. Against them:
 * an attacker crafting a proposal can iterate offline against open weights at zero cost until the model
 * approves, which is a head start on the four rejections they need to neutralise. For them: an open
 * checkpoint can be pinned and verified, so §5.4's model hash actually means something, where a closed
 * provider could substitute a model behind the same API name and only the hash of what the operator
 * *claims* would change. Three of ten keeps both properties in the room.
 *
 * **Verify every identifier before deployment.** These were compiled in August 2026 from release
 * trackers, which lag and disagree with each other on specifics. The `version` field must record what
 * the API actually served, not what was requested, because §5.4's substitution detection depends on it.
 */

import type { SlotConfig } from './types.js'

export const BOARD: readonly SlotConfig[] = [
  { slot: 0, provider: 'anthropic', providerTag: 'anthropic', model: 'claude-opus-5', openWeights: false },
  { slot: 1, provider: 'openai', providerTag: 'openai', model: 'gpt-5.6-sol', openWeights: false },
  { slot: 2, provider: 'google', providerTag: 'google', model: 'gemini-3.7-flash', openWeights: false },
  { slot: 3, provider: 'xai', providerTag: 'xai', model: 'grok-4.6', openWeights: false },
  { slot: 4, provider: 'mistral', providerTag: 'mistral', model: 'mistral-medium-3-5', openWeights: false },
  { slot: 5, provider: 'meta', providerTag: 'meta', model: 'muse-spark-1.2', openWeights: false },
  { slot: 6, provider: 'deepseek', providerTag: 'deepseek', model: 'deepseek-v4-pro', openWeights: true },
  { slot: 7, provider: 'alibaba', providerTag: 'alibaba', model: 'qwen3.8-max', openWeights: true },
  { slot: 8, provider: 'zai', providerTag: 'zai', model: 'glm-5.3', openWeights: true },
  { slot: 9, provider: 'moonshot', providerTag: 'moonshot', model: 'kimi-k3', openWeights: false },
] as const

export const APPROVAL_THRESHOLD = 6
export const LIVENESS_FLOOR = 8
export const SLOTS = 10
export const MIN_PROVIDERS = 4
export const MAX_OPEN_WEIGHTS = 3
export const MAX_SLOTS_PER_OPERATOR_PHASE_TWO = 2


export interface BoardCheck {
  readonly ok: boolean
  readonly providers: number
  readonly openWeights: number
  readonly problems: readonly string[]
}

/**
 * Check a board against the constraints the registry enforces, plus the two this harness adds.
 *
 * The provider floor is checked on chain too (`Saine.assignSlot` reverts below four). It is checked
 * here as well because a harness misconfiguration that quietly ran two seats on one provider would
 * satisfy the registry, which only sees the provider *tag*, while making the six-of-ten threshold
 * weaker than it looks. The registry can only enforce what it is told.
 */
/**
 * What a phase-two operator can and cannot verify about the board.
 *
 * §5.2's constraints are properties of all ten seats, and an operator holding one or two cannot check
 * them from their own configuration: they do not know who holds the rest. They can read it from the
 * registry, which is why `verifyRegistryDiversity` exists. What they *can* check locally is that their own
 * seats are within the operator cap and that they hold credentials for what they claim to run.
 */
export function checkOperatedSlots(slots: readonly number[], board: readonly SlotConfig[] = BOARD): BoardCheck {
  const problems: string[] = []
  const seats = board.filter((s) => slots.includes(s.slot))

  if (seats.length !== slots.length) {
    problems.push('operated slots include indices absent from the board definition')
  }
  if (slots.length === 0) problems.push('no slots configured')
  if (slots.length > MAX_SLOTS_PER_OPERATOR_PHASE_TWO && slots.length !== SLOTS) {
    problems.push(
      `${slots.length} slots exceeds §5.2's two-slot operator cap; only the phase-one team holds all ${SLOTS}`,
    )
  }

  const providers = new Set(seats.map((s) => s.provider))
  if (slots.length === SLOTS) {
    // Holding everything means the full-board constraints are yours to satisfy.
    return checkBoard(board)
  }
  if (providers.size !== seats.length) {
    // Two seats on one provider is legal for an operator, and it wastes one of the two: the pair fails
    // together, so the board gains one independent reviewer where it thinks it gained two.
    problems.push('two operated seats share a provider, so they do not fail independently')
  }

  return { ok: problems.length === 0, providers: providers.size, openWeights: seats.filter((s) => s.openWeights).length, problems }
}

export function checkBoard(board: readonly SlotConfig[] = BOARD): BoardCheck {
  const problems: string[] = []

  if (board.length !== SLOTS) problems.push(`expected ${SLOTS} slots, got ${board.length}`)

  const seenSlots = new Set<number>()
  for (const s of board) {
    if (seenSlots.has(s.slot)) problems.push(`duplicate slot index ${s.slot}`)
    seenSlots.add(s.slot)
  }

  const providers = new Set(board.map((s) => s.provider))
  if (providers.size < MIN_PROVIDERS) {
    problems.push(`only ${providers.size} distinct providers; §5.2 requires at least ${MIN_PROVIDERS}`)
  }

  const models = new Set(board.map((s) => s.model))
  if (models.size !== board.length) {
    problems.push('two slots share a model; §5.2 requires ten distinct models')
  }

  const openWeights = board.filter((s) => s.openWeights).length
  if (openWeights > MAX_OPEN_WEIGHTS) {
    problems.push(`${openWeights} open-weights slots exceeds the cap of ${MAX_OPEN_WEIGHTS}`)
  }

  // A provider holding four or more seats can single-handedly deny the six-of-ten threshold, which
  // makes it a veto. Not a whitepaper rule, but it follows from the arithmetic.
  for (const p of providers) {
    const held = board.filter((s) => s.provider === p).length
    if (held > SLOTS - APPROVAL_THRESHOLD) {
      problems.push(`provider ${p} holds ${held} slots, enough to veto any approval`)
    }
  }

  return { ok: problems.length === 0, providers: providers.size, openWeights, problems }
}
