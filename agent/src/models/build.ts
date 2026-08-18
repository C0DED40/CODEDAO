/**
 * Wiring the ten seats to concrete adapters.
 *
 * Credentials arrive per provider from the environment. Nothing is defaulted: a missing key throws at
 * construction rather than at the first commit window, because discovering it then costs a lapsed round.
 */

import { AnthropicAdapter } from './anthropic.js'
import { GoogleAdapter } from './google.js'
import { OpenAiCompatibleAdapter } from './openaiCompatible.js'
import type { FetchLike, ModelAdapter } from './index.js'
import { BOARD } from '../board.js'
import type { SlotConfig } from '../types.js'
import type { SlotBinding } from '../runner.js'

/** Base URLs for the providers that speak the chat-completions shape. */
export const OPENAI_COMPATIBLE_ENDPOINTS: Readonly<Record<string, string>> = {
  openai: 'https://api.openai.com/v1',
  xai: 'https://api.x.ai/v1',
  deepseek: 'https://api.deepseek.com/v1',
  mistral: 'https://api.mistral.ai/v1',
  moonshot: 'https://api.moonshot.ai/v1',
  zai: 'https://api.z.ai/api/paas/v4',
  alibaba: 'https://dashscope-intl.aliyuncs.com/compatible-mode/v1',
  meta: 'https://api.llama.com/v1',
}

/** Environment variable holding each provider's key. */
export function envVarFor(provider: string): string {
  return `SAINE_${provider.toUpperCase()}_API_KEY`
}

export class MissingCredential extends Error {
  constructor(provider: string) {
    super(`no API key for provider "${provider}"; set ${envVarFor(provider)}`)
    this.name = 'MissingCredential'
  }
}

export interface BuildOptions {
  readonly env?: Readonly<Record<string, string | undefined>>
  readonly fetchImpl?: FetchLike
  readonly board?: readonly SlotConfig[]
  /**
   * The slots this process operates. Defaults to all of them, which is phase one (§5.8).
   *
   * A phase-two operator holds one or two seats and has credentials for one provider. Building all ten
   * would demand nine keys they will never have and refuse to start, so the build is scoped to what they
   * actually run.
   */
  readonly slots?: readonly number[]
  /** Override a provider's endpoint, for a self-hosted open-weights seat. */
  readonly endpoints?: Readonly<Record<string, string>>
}

export function buildAdapter(slot: SlotConfig, opts: BuildOptions = {}): ModelAdapter {
  const env = opts.env ?? process.env
  const apiKey = env[envVarFor(slot.provider)]
  if (apiKey === undefined || apiKey.length === 0) throw new MissingCredential(slot.provider)

  const fetchImpl = opts.fetchImpl

  if (slot.provider === 'anthropic') {
    return new AnthropicAdapter({ model: slot.model, apiKey, ...(fetchImpl ? { fetchImpl } : {}) })
  }
  if (slot.provider === 'google') {
    return new GoogleAdapter({ model: slot.model, apiKey, ...(fetchImpl ? { fetchImpl } : {}) })
  }

  const baseUrl = opts.endpoints?.[slot.provider] ?? OPENAI_COMPATIBLE_ENDPOINTS[slot.provider]
  if (baseUrl === undefined) {
    throw new Error(`no endpoint known for provider "${slot.provider}"; pass one via options.endpoints`)
  }
  return new OpenAiCompatibleAdapter({
    provider: slot.provider,
    model: slot.model,
    baseUrl,
    apiKey,
    ...(fetchImpl ? { fetchImpl } : {}),
  })
}

/**
 * Build all ten bindings, or fail.
 *
 * Deliberately all-or-nothing. A board short two providers still satisfies the eight-reveal floor on a
 * good day, so a partial build would start, appear to work, and then lapse the first time any other slot
 * had trouble. Refusing to start is louder and cheaper.
 */
export function buildBoard(opts: BuildOptions = {}): SlotBinding[] {
  const board = opts.board ?? BOARD
  const wanted = opts.slots
  const seats = wanted === undefined ? board : board.filter((s) => wanted.includes(s.slot))

  if (wanted !== undefined) {
    const missing = wanted.filter((s) => !board.some((b) => b.slot === s))
    if (missing.length > 0) {
      throw new Error(`operated slots ${missing.join(', ')} are not in the board definition`)
    }
  }

  return seats.map((config) => ({ config, adapter: buildAdapter(config, opts) }))
}
