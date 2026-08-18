/**
 * Pinning reason documents.
 *
 * §5.4: "Reason documents (a code from a fixed taxonomy plus free text) are stored on IPFS; the on-chain
 * hash binds them." The binding runs one way: the chain holds the hash, so a document that fails to pin
 * leaves an attestation nobody can read, and §5.7's whole argument about legibility and capture detection
 * rests on those documents being retrievable.
 *
 * A pin failure therefore does not block the round. The verdict is already bound by the commitment and the
 * board's job is done; an unretrievable reason is a degraded record, not an invalid vote. But it is
 * reported, because a slot whose reasons are never readable is indistinguishable from a slot gaming §5.7,
 * and the operator should find that out from their own logs rather than from an accusation.
 */

import type { ReasonDocument } from './types.js'
import { canonicalReasonJson, hashReason } from './attest.js'
import type { Hex } from 'viem'

export interface PinResult {
  readonly cid: string
  readonly hash: Hex
}

export interface Pinner {
  pin(doc: ReasonDocument): Promise<PinResult>
}

export class PinFailed extends Error {
  constructor(cause: unknown) {
    super(`failed to pin reason document: ${String(cause)}`)
    this.name = 'PinFailed'
  }
}

export interface KuboConfig {
  /** e.g. http://127.0.0.1:5001 */
  readonly apiUrl: string
  readonly fetchImpl?: typeof globalThis.fetch
  readonly timeoutMs?: number
}

/** Pins through a Kubo-compatible HTTP API. */
export class KuboPinner implements Pinner {
  constructor(private readonly cfg: KuboConfig) {}

  async pin(doc: ReasonDocument): Promise<PinResult> {
    // The exact bytes that were hashed, so what is retrievable hashes to what is on chain. Re-serialising
    // with different key order would break that link silently.
    const body = canonicalReasonJson(doc)
    const hash = hashReason(doc)
    const doFetch = this.cfg.fetchImpl ?? globalThis.fetch

    const form = new FormData()
    form.append('file', new Blob([body], { type: 'application/json' }), 'reason.json')

    const controller = new AbortController()
    const timer = setTimeout(() => controller.abort(), this.cfg.timeoutMs ?? 15_000)
    try {
      const res = await doFetch(`${this.cfg.apiUrl.replace(/\/$/, '')}/api/v0/add?pin=true&cid-version=1`, {
        method: 'POST',
        body: form,
        signal: controller.signal,
      })
      if (!res.ok) throw new PinFailed(`HTTP ${res.status}`)
      const json = (await res.json()) as { Hash?: string }
      if (typeof json.Hash !== 'string') throw new PinFailed('response contained no CID')
      return { cid: json.Hash, hash }
    } catch (err) {
      throw err instanceof PinFailed ? err : new PinFailed(err)
    } finally {
      clearTimeout(timer)
    }
  }
}

/** For tests and dry runs: computes the hash, stores nothing. */
export class NullPinner implements Pinner {
  readonly pinned: ReasonDocument[] = []
  async pin(doc: ReasonDocument): Promise<PinResult> {
    this.pinned.push(doc)
    return { cid: `null://${hashReason(doc)}`, hash: hashReason(doc) }
  }
}
