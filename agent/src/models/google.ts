/**
 * Adapter for Google's generateContent API.
 *
 * Notable difference from the other two shapes: the response does not echo a model identifier, so
 * `servedModel` is marked unreported. §5.4's substitution detection is correspondingly weaker for this
 * seat, which is worth knowing rather than papering over: the published hash records what was
 * requested, and only the provider knows whether that is what ran.
 */

import { ModelFailure, parseVerdict, withTimeout, type FetchLike, type JudgeInput, type JudgeResult, type ModelAdapter } from './index.js'

export interface GoogleConfig {
  readonly provider?: string
  readonly model: string
  readonly baseUrl?: string
  readonly apiKey: string
  readonly fetchImpl?: FetchLike
}

export class GoogleAdapter implements ModelAdapter {
  readonly provider: string
  readonly model: string
  private readonly cfg: GoogleConfig
  private readonly doFetch: FetchLike

  constructor(cfg: GoogleConfig) {
    this.cfg = cfg
    this.provider = cfg.provider ?? 'google'
    this.model = cfg.model
    this.doFetch = cfg.fetchImpl ?? globalThis.fetch
  }

  async judge(input: JudgeInput): Promise<JudgeResult> {
    const base = (this.cfg.baseUrl ?? 'https://generativelanguage.googleapis.com/v1beta').replace(/\/$/, '')
    const res = await withTimeout(
      (signal) =>
        this.doFetch(`${base}/models/${this.cfg.model}:generateContent`, {
          method: 'POST',
          headers: { 'content-type': 'application/json', 'x-goog-api-key': this.cfg.apiKey },
          body: JSON.stringify({
            systemInstruction: { parts: [{ text: input.systemPrompt }] },
            contents: [{ role: 'user', parts: [{ text: input.userPrompt }] }],
            generationConfig: {
              temperature: 0,
              maxOutputTokens: 2048,
              responseMimeType: 'application/json',
            },
          }),
          signal,
        }),
      input.timeoutMs,
    )

    if (!res.ok) {
      throw new ModelFailure(this.provider, this.model, `HTTP ${res.status}`)
    }

    const json = (await res.json()) as {
      modelVersion?: string
      candidates?: { content?: { parts?: { text?: string }[] } }[]
    }
    const text = json.candidates?.[0]?.content?.parts?.[0]?.text
    if (typeof text !== 'string' || text.length === 0) {
      throw new ModelFailure(this.provider, this.model, 'response contained no candidate text')
    }

    return {
      verdict: parseVerdict(text, this.provider, this.model),
      servedModel: json.modelVersion ?? `${this.cfg.model}?unreported`,
    }
  }
}
