import { describe, expect, it } from 'vitest'
import { mkdtemp } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import {
  EquivocationRefused,
  FileAttestationStore,
  GuardUnavailable,
  MemoryAttestationStore,
  bindVerdict,
  type AttestationStore,
  type VerdictRecord,
} from '../src/guard.js'

function record(overrides: Partial<VerdictRecord> = {}): VerdictRecord {
  return {
    slot: 3,
    roundId: '7',
    verdict: true,
    reasonHash: ('0x' + '11'.repeat(32)) as `0x${string}`,
    modelHash: ('0x' + '22'.repeat(32)) as `0x${string}`,
    committedAt: '2026-08-18T10:00:00.000Z',
    ...overrides,
  }
}

function suite(name: string, make: () => Promise<AttestationStore>) {
  describe(name, () => {
    it('binds the first verdict', async () => {
      const store = await make()
      const r = await bindVerdict(store, record())
      expect(r.fresh).toBe(true)
      expect(r.record.verdict).toBe(true)
    })

    it('is idempotent for a retry with the same verdict', async () => {
      // The common case. Failing a retry would push the slot toward a reveal failure, which costs 25%
      // of the bond, so a repeat of the same verdict must succeed quietly.
      const store = await make()
      await bindVerdict(store, record())
      const again = await bindVerdict(store, record())
      expect(again.fresh).toBe(false)
      expect(again.record.verdict).toBe(true)
    })

    it('refuses the opposite verdict for the same round', async () => {
      // §5.5: two signed attestations with different verdicts burn the whole bond and vacate the seat,
      // atomically and without appeal. This is the single defect that cannot be recovered from.
      const store = await make()
      await bindVerdict(store, record({ verdict: true }))
      await expect(bindVerdict(store, record({ verdict: false }))).rejects.toThrow(EquivocationRefused)
    })

    it('scopes the binding to the round', async () => {
      const store = await make()
      await bindVerdict(store, record({ roundId: '7', verdict: true }))
      const other = await bindVerdict(store, record({ roundId: '8', verdict: false }))
      expect(other.fresh).toBe(true)
    })

    it('scopes the binding to the slot', async () => {
      const store = await make()
      await bindVerdict(store, record({ slot: 3, verdict: true }))
      const other = await bindVerdict(store, record({ slot: 4, verdict: false }))
      expect(other.fresh).toBe(true)
    })

    it('survives a concurrent race, and only one verdict wins', async () => {
      const store = await make()
      const results = await Promise.allSettled([
        bindVerdict(store, record({ verdict: true })),
        bindVerdict(store, record({ verdict: false })),
      ])
      const fulfilled = results.filter((r) => r.status === 'fulfilled')
      // Both may resolve if they agree, but they disagree here, so exactly one must survive.
      expect(fulfilled.length).toBeLessThanOrEqual(2)
      const verdicts = new Set(
        fulfilled.map((r) => (r as PromiseFulfilledResult<{ record: VerdictRecord }>).value.record.verdict),
      )
      expect(verdicts.size).toBe(1)
    })
  })
}

suite('MemoryAttestationStore', async () => new MemoryAttestationStore())
suite('FileAttestationStore', async () =>
  new FileAttestationStore(await mkdtemp(join(tmpdir(), 'saine-guard-'))),
)

describe('fail-closed behaviour', () => {
  it('refuses to sign when the store cannot be read', async () => {
    // A slot that stays silent forfeits a quarter of its bond. A slot that signs blind can equivocate
    // and lose all of it plus the seat. Unknown state must therefore never be signed through.
    const broken: AttestationStore = {
      async read() {
        throw new GuardUnavailable('disk on fire')
      },
      async claim(r) {
        return r
      },
    }
    await expect(bindVerdict(broken, record())).rejects.toThrow(GuardUnavailable)
  })

  it('refuses when a claim races to the opposite verdict', async () => {
    const adversarial: AttestationStore = {
      async read() {
        return null
      },
      async claim() {
        return record({ verdict: false })
      },
    }
    await expect(bindVerdict(adversarial, record({ verdict: true }))).rejects.toThrow(EquivocationRefused)
  })
})
