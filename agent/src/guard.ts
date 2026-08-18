/**
 * The equivocation guard.
 *
 * This is the most dangerous module in the harness, and it is worth being explicit about why. §5.5:
 * "If any party submits two validly signed attestations from the same slot key for the same proposal
 * with different verdicts, the contract slashes the bond and vacates the slot in the same transaction.
 * No vote, no judgment, no appeal."
 *
 * There is no recovery path. A harness that signs `approve` at 09:00 and `reject` at 09:05 for the
 * same round has destroyed the slot's entire bond and lost the seat, and nobody had to attack it. The
 * realistic ways that happens are all mundane:
 *
 *   - the process restarts mid-round, re-runs the model, and the model answers differently;
 *   - two instances overlap during a deploy, and both sign;
 *   - a request times out, the caller retries, and the first attempt had actually succeeded.
 *
 * So signing is gated on a durable compare-and-set. The guard is deliberately **fail-closed**: if the
 * store cannot be read or the claim cannot be established, it refuses to sign. A slot that stays silent
 * forfeits a quarter of its bond (§15); a slot that equivocates forfeits all of it and the seat. When
 * the choice is between those two, silence is correct every time.
 */

import { mkdir, readFile, writeFile } from 'node:fs/promises'
import { dirname, join } from 'node:path'
import type { Hex } from 'viem'

export class EquivocationRefused extends Error {
  constructor(
    readonly slot: number,
    readonly roundId: bigint,
    readonly existing: boolean,
    readonly attempted: boolean,
  ) {
    super(
      `slot ${slot} already committed verdict ${existing} for round ${roundId}; refusing to sign ${attempted}. ` +
        'Signing both would burn the slot bond under whitepaper §5.5.',
    )
    this.name = 'EquivocationRefused'
  }
}

export class GuardUnavailable extends Error {
  constructor(cause: unknown) {
    super(`attestation store unavailable; refusing to sign. ${String(cause)}`)
    this.name = 'GuardUnavailable'
  }
}

export interface VerdictRecord {
  readonly slot: number
  readonly roundId: string
  readonly verdict: boolean
  readonly reasonHash: Hex
  readonly modelHash: Hex
  readonly committedAt: string
}

/**
 * A store with create-once semantics. `claim` must be atomic: given concurrent callers for the same
 * key, exactly one may succeed and the rest must observe the winner's record.
 */
export interface AttestationStore {
  /** Returns the stored record, or null. Must throw rather than return null on an I/O failure. */
  read(slot: number, roundId: bigint): Promise<VerdictRecord | null>
  /** Writes only if absent. Returns the record that ended up stored, whoever wrote it. */
  claim(record: VerdictRecord): Promise<VerdictRecord>
}

/**
 * File-backed store using exclusive create, which gives create-once semantics on a single filesystem.
 *
 * **This is not sufficient for a multi-machine deployment.** `O_EXCL` on a local filesystem does not
 * coordinate across hosts, and on most network filesystems it does not either. Running two harness
 * instances against this store on separate machines can produce two conflicting signatures, which is
 * exactly the outcome the guard exists to prevent. For anything beyond a single operator on a single
 * host, back the store with something that offers a real unique constraint, a Postgres primary key on
 * `(slot, round_id)` being the obvious choice.
 */
export class FileAttestationStore implements AttestationStore {
  constructor(private readonly root: string) {}

  private path(slot: number, roundId: bigint): string {
    return join(this.root, `slot-${slot}`, `round-${roundId}.json`)
  }

  async read(slot: number, roundId: bigint): Promise<VerdictRecord | null> {
    try {
      const raw = await readFile(this.path(slot, roundId), 'utf8')
      return JSON.parse(raw) as VerdictRecord
    } catch (err) {
      if ((err as NodeJS.ErrnoException).code === 'ENOENT') return null
      // Any other failure is an unknown state, and unknown state must not be signed through.
      throw new GuardUnavailable(err)
    }
  }

  async claim(record: VerdictRecord): Promise<VerdictRecord> {
    const path = this.path(record.slot, BigInt(record.roundId))
    try {
      await mkdir(dirname(path), { recursive: true })
      await writeFile(path, JSON.stringify(record, null, 2), { flag: 'wx' })
      return record
    } catch (err) {
      if ((err as NodeJS.ErrnoException).code === 'EEXIST') {
        const existing = await this.read(record.slot, BigInt(record.roundId))
        if (existing === null) throw new GuardUnavailable('claim raced with a delete')
        return existing
      }
      throw new GuardUnavailable(err)
    }
  }
}

/** In-memory store, for tests only. */
export class MemoryAttestationStore implements AttestationStore {
  private readonly records = new Map<string, VerdictRecord>()

  private key(slot: number, roundId: bigint): string {
    return `${slot}:${roundId}`
  }

  async read(slot: number, roundId: bigint): Promise<VerdictRecord | null> {
    return this.records.get(this.key(slot, roundId)) ?? null
  }

  async claim(record: VerdictRecord): Promise<VerdictRecord> {
    const k = this.key(record.slot, BigInt(record.roundId))
    const existing = this.records.get(k)
    if (existing !== undefined) return existing
    this.records.set(k, record)
    return record
  }
}

export interface GuardResult {
  /** The verdict that is bound for this round. Always the first one claimed. */
  readonly record: VerdictRecord
  /** True when this call established the claim, false when it observed an earlier one. */
  readonly fresh: boolean
}

/**
 * Bind a verdict to (slot, round) or refuse.
 *
 * Idempotent by design: a retry with the same verdict returns the stored record rather than erroring,
 * because a retry is the common case and failing it would push the slot toward a reveal failure. A
 * retry with a *different* verdict throws, because that is equivocation and there is no safe way to
 * proceed.
 */
export async function bindVerdict(
  store: AttestationStore,
  candidate: VerdictRecord,
): Promise<GuardResult> {
  const roundId = BigInt(candidate.roundId)
  const prior = await store.read(candidate.slot, roundId)
  if (prior !== null) {
    if (prior.verdict !== candidate.verdict) {
      throw new EquivocationRefused(candidate.slot, roundId, prior.verdict, candidate.verdict)
    }
    return { record: prior, fresh: false }
  }

  const stored = await store.claim(candidate)
  if (stored.verdict !== candidate.verdict) {
    // Lost a race to a concurrent caller that bound the opposite verdict. The winner's record stands,
    // and this caller must not sign against it.
    throw new EquivocationRefused(candidate.slot, roundId, stored.verdict, candidate.verdict)
  }
  return { record: stored, fresh: stored === candidate }
}
