/**
 * The model adapter boundary.
 *
 * Ten seats, ten providers, three API shapes. Everything provider-specific lives behind this
 * interface so the board runner cannot accidentally treat one provider differently from another,
 * which would undermine the independence §5.2 is buying.
 */

import type { ModelVerdict, ReasonCode } from '../types.js'
import { REASON_CODES } from '../types.js'

export interface JudgeInput {
  readonly systemPrompt: string
  readonly userPrompt: string
  readonly timeoutMs: number
}

export interface JudgeResult {
  readonly verdict: ModelVerdict
  /**
   * The model identifier the API actually served, read from the response rather than echoed from the
   * request. §5.4's substitution detection depends on this distinction: recording what was asked for
   * would make the published hash a statement about our intent, not about what judged the proposal.
   */
  readonly servedModel: string
}

export interface ModelAdapter {
  readonly provider: string
  readonly model: string
  judge(input: JudgeInput): Promise<JudgeResult>
}

export class ModelFailure extends Error {
  constructor(
    readonly provider: string,
    readonly model: string,
    message: string,
    override readonly cause?: unknown,
  ) {
    super(`${provider}/${model}: ${message}`)
    this.name = 'ModelFailure'
  }
}

const MIN_TEXT = 40
const MAX_TEXT = 4000

/**
 * Strict parsing. A response that is not exactly what was asked for is a failure, never a coerced
 * verdict.
 *
 * The temptation is to be lenient: pull the first "true" out of the text, default a missing code to
 * `insufficient_information`, accept a bare "APPROVE". Every one of those turns a malformed response
 * into a vote, and a malformed response means the model did not answer the question. Six of those
 * leniently-parsed votes releases treasury capital.
 */
export function parseVerdict(raw: string, provider: string, model: string): ModelVerdict {
  const text = stripFences(raw).trim()

  let parsed: unknown
  try {
    parsed = JSON.parse(text)
  } catch (err) {
    throw new ModelFailure(provider, model, 'response was not valid JSON', err)
  }

  if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
    throw new ModelFailure(provider, model, 'response was not a JSON object')
  }

  const obj = parsed as Record<string, unknown>

  if (typeof obj.approve !== 'boolean') {
    throw new ModelFailure(provider, model, `"approve" must be a boolean, got ${typeof obj.approve}`)
  }
  if (typeof obj.code !== 'string' || !(REASON_CODES as readonly string[]).includes(obj.code)) {
    throw new ModelFailure(provider, model, `"code" must be one of the §5.7 taxonomy, got ${String(obj.code)}`)
  }
  if (typeof obj.text !== 'string') {
    throw new ModelFailure(provider, model, '"text" must be a string')
  }
  if (obj.text.trim().length < MIN_TEXT) {
    // §5.7 wants reasons "legible to the founder who received them". A reason too short to contain a
    // finding is not a reason, and the published record is meant to be auditable across seasons.
    throw new ModelFailure(provider, model, `"text" too short (${obj.text.trim().length} < ${MIN_TEXT})`)
  }
  if (obj.text.length > MAX_TEXT) {
    throw new ModelFailure(provider, model, `"text" too long (${obj.text.length} > ${MAX_TEXT})`)
  }

  return { approve: obj.approve, code: obj.code as ReasonCode, text: obj.text.trim() }
}

/** Providers sometimes wrap JSON in markdown despite being asked not to. */
function stripFences(s: string): string {
  const m = /^\s*```(?:json)?\s*\n([\s\S]*?)\n\s*```\s*$/.exec(s)
  return m?.[1] ?? s
}

/** Shared timeout wrapper, so a hung provider cannot hold a whole round past its commit window. */
export async function withTimeout<T>(p: (signal: AbortSignal) => Promise<T>, ms: number): Promise<T> {
  const controller = new AbortController()
  const timer = setTimeout(() => controller.abort(), ms)
  try {
    return await p(controller.signal)
  } finally {
    clearTimeout(timer)
  }
}

export type FetchLike = typeof globalThis.fetch
