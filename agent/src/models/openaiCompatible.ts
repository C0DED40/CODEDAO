/**
 * Adapter for the OpenAI chat-completions shape, which most providers expose.
 *
 * One implementation covers OpenAI, xAI, DeepSeek, Mistral, Moonshot, Z.ai and Alibaba. That is a
 * convenience of protocol, not of behaviour: the seven models behind it are still seven independent
 * evaluators, which is what §5.2 requires. Sharing a request format does not correlate their failures;
 * sharing a base model would.
 */

import { ModelFailure, withTimeout, type FetchLike, type JudgeInput, type JudgeResult, type ModelAdapter } from './index.js'
import { parseVerdict } from './index.js'

export interface OpenAiCompatibleConfig {
  readonly provider: string
  readonly model: string
  readonly baseUrl: string
  readonly apiKey: string
  readonly fetchImpl?: FetchLike
  /** Some providers reject `response_format`; set false for those. */
  readonly supportsJsonMode?: boolean
  readonly extraHeaders?: Readonly<Record<string, string>>
}

export class OpenAiCompatibleAdapter implements ModelAdapter {
  readonly provider: string
  readonly model: string
  private readonly cfg: OpenAiCompatibleConfig
  private readonly doFetch: FetchLike

  constructor(cfg: OpenAiCompatibleConfig) {
    this.cfg = cfg
    this.provider = cfg.provider
    this.model = cfg.model
    this.doFetch = cfg.fetchImpl ?? globalThis.fetch
  }

  async judge(input: JudgeInput): Promise<JudgeResult> {
    const body: Record<string, unknown> = {
      model: this.cfg.model,
      messages: [
        { role: 'system', content: input.systemPrompt },
        { role: 'user', content: input.userPrompt },
      ],
      // Deterministic as the provider allows. Not for reproducibility, which is impossible across a
      // fleet, but because a reviewer whose verdict swings on sampling noise is not reviewing.
      temperature: 0,
      max_tokens: 2048,
    }
    if (this.cfg.supportsJsonMode !== false) body.response_format = { type: 'json_object' }

    const res = await withTimeout(
      (signal) =>
        this.doFetch(`${this.cfg.baseUrl.replace(/\/$/, '')}/chat/completions`, {
          method: 'POST',
          headers: {
            'content-type': 'application/json',
            authorization: `Bearer ${this.cfg.apiKey}`,
            ...(this.cfg.extraHeaders ?? {}),
          },
          body: JSON.stringify(body),
          signal,
        }),
      input.timeoutMs,
    )

    if (!res.ok) {
      throw new ModelFailure(this.provider, this.model, `HTTP ${res.status} ${await safeText(res)}`)
    }

    const json = (await res.json()) as {
      model?: string
      choices?: { message?: { content?: string } }[]
    }
    const content = json.choices?.[0]?.message?.content
    if (typeof content !== 'string' || content.length === 0) {
      throw new ModelFailure(this.provider, this.model, 'response contained no message content')
    }
    // Fall back to the requested identifier only if the provider omits it, and say so, because an
    // unverified identifier is weaker evidence than a verified one.
    const servedModel = json.model ?? `${this.cfg.model}?unreported`

    return { verdict: parseVerdict(content, this.provider, this.model), servedModel }
  }
}

async function safeText(res: Response): Promise<string> {
  try {
    return (await res.text()).slice(0, 300)
  } catch {
    return '<no body>'
  }
}
