/**
 * Adapter for Anthropic's Messages API, which does not use the chat-completions shape.
 */

import { ModelFailure, parseVerdict, withTimeout, type FetchLike, type JudgeInput, type JudgeResult, type ModelAdapter } from './index.js'

export interface AnthropicConfig {
  readonly provider?: string
  readonly model: string
  readonly baseUrl?: string
  readonly apiKey: string
  readonly apiVersion?: string
  readonly fetchImpl?: FetchLike
}

export class AnthropicAdapter implements ModelAdapter {
  readonly provider: string
  readonly model: string
  private readonly cfg: AnthropicConfig
  private readonly doFetch: FetchLike

  constructor(cfg: AnthropicConfig) {
    this.cfg = cfg
    this.provider = cfg.provider ?? 'anthropic'
    this.model = cfg.model
    this.doFetch = cfg.fetchImpl ?? globalThis.fetch
  }

  async judge(input: JudgeInput): Promise<JudgeResult> {
    const res = await withTimeout(
      (signal) =>
        this.doFetch(`${(this.cfg.baseUrl ?? 'https://api.anthropic.com').replace(/\/$/, '')}/v1/messages`, {
          method: 'POST',
          headers: {
            'content-type': 'application/json',
            'x-api-key': this.cfg.apiKey,
            'anthropic-version': this.cfg.apiVersion ?? '2023-06-01',
          },
          body: JSON.stringify({
            model: this.cfg.model,
            system: input.systemPrompt,
            messages: [{ role: 'user', content: input.userPrompt }],
            temperature: 0,
            max_tokens: 2048,
          }),
          signal,
        }),
      input.timeoutMs,
    )

    if (!res.ok) {
      throw new ModelFailure(this.provider, this.model, `HTTP ${res.status}`)
    }

    const json = (await res.json()) as {
      model?: string
      content?: { type?: string; text?: string }[]
    }
    const block = json.content?.find((c) => c.type === 'text')
    if (typeof block?.text !== 'string' || block.text.length === 0) {
      throw new ModelFailure(this.provider, this.model, 'response contained no text block')
    }

    return {
      verdict: parseVerdict(block.text, this.provider, this.model),
      servedModel: json.model ?? `${this.cfg.model}?unreported`,
    }
  }
}
