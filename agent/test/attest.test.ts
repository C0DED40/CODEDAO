import { describe, expect, it } from 'vitest'
import { keccak256, toHex, encodeAbiParameters, recoverTypedDataAddress } from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import {
  COMMIT_TYPEHASH,
  COMMIT_TYPES,
  REVEAL_TYPEHASH,
  REVEAL_TYPES,
  buildCommitment,
  canonicalReasonJson,
  deriveSalt,
  hashReason,
  hashSystemPrompt,
  modelHash,
  signCommit,
  signReveal,
  type Domain,
} from '../src/attest.js'
import type { ReasonDocument } from '../src/types.js'

const KEY = '0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d' as const
const DOMAIN: Domain = { chainId: 4663, verifyingContract: '0x1111111111111111111111111111111111111111' }

function reason(overrides: Partial<ReasonDocument> = {}): ReasonDocument {
  return {
    code: 'tokenomics',
    text: 'The implied valuation is 40x the comparable set and the manifest does not justify it.',
    nonce: '0xdead000000000000000000000000000000000000000000000000000000000beef',
    model: {
      provider: 'anthropic',
      model: 'claude-opus-5',
      version: '2026-07-24',
      systemPromptHash: hashSystemPrompt('a prompt'),
    },
    roundId: '7',
    slot: 3,
    ...overrides,
  }
}

describe('type hashes match the contract', () => {
  // These strings are copied from Saine.sol. If either diverges, every signature the harness produces
  // is rejected on chain, and the failure looks like an agent that went quiet: 25% of the slot bond,
  // burned, for a typo.
  it('commit typehash', () => {
    expect(COMMIT_TYPEHASH).toBe(
      keccak256(toHex('Commit(uint256 roundId,uint8 slot,bytes32 commitment,bytes32 modelHash)')),
    )
  })

  it('reveal typehash', () => {
    expect(REVEAL_TYPEHASH).toBe(
      keccak256(toHex('Reveal(uint256 roundId,uint8 slot,bool verdict,bytes32 reasonHash,bytes32 salt)')),
    )
  })
})

describe('commitment', () => {
  it('is keccak256(abi.encode(verdict, reasonHash, salt))', () => {
    const rh = hashReason(reason())
    const salt = deriveSalt('0x' + '11'.repeat(32) as `0x${string}`, 7n, 3)
    expect(buildCommitment(true, rh, salt)).toBe(
      keccak256(
        encodeAbiParameters([{ type: 'bool' }, { type: 'bytes32' }, { type: 'bytes32' }], [true, rh, salt]),
      ),
    )
  })

  it('binds the verdict, so flipping it breaks the commitment', () => {
    const rh = hashReason(reason())
    const salt = deriveSalt('0x' + '11'.repeat(32) as `0x${string}`, 7n, 3)
    expect(buildCommitment(true, rh, salt)).not.toBe(buildCommitment(false, rh, salt))
  })

  it('binds the reason, so the justification cannot be composed after the tally (§5.4)', () => {
    const salt = deriveSalt('0x' + '11'.repeat(32) as `0x${string}`, 7n, 3)
    const a = hashReason(reason({ text: 'rejected on valuation' }))
    const b = hashReason(reason({ text: 'approved on strength of the team' }))
    expect(buildCommitment(true, a, salt)).not.toBe(buildCommitment(true, b, salt))
  })
})

describe('salt derivation', () => {
  const secret = ('0x' + 'ab'.repeat(32)) as `0x${string}`

  it('is reproducible, so a lost salt cannot cost a reveal', () => {
    expect(deriveSalt(secret, 7n, 3)).toBe(deriveSalt(secret, 7n, 3))
  })

  it('differs per round and per slot', () => {
    expect(deriveSalt(secret, 7n, 3)).not.toBe(deriveSalt(secret, 8n, 3))
    expect(deriveSalt(secret, 7n, 3)).not.toBe(deriveSalt(secret, 7n, 4))
  })

  it('leaves the commitment blind even if the salt leaks, because the reason carries entropy', () => {
    // An attacker holding the salt would otherwise enumerate two verdicts against six taxonomy codes.
    // The nonce in the reason document is what defeats that.
    const salt = deriveSalt(secret, 7n, 3)
    const withNonceA = hashReason(reason({ nonce: ('0x' + '01'.repeat(32)) as `0x${string}` }))
    const withNonceB = hashReason(reason({ nonce: ('0x' + '02'.repeat(32)) as `0x${string}` }))
    expect(buildCommitment(true, withNonceA, salt)).not.toBe(buildCommitment(true, withNonceB, salt))
  })
})

describe('reason hashing', () => {
  it('is stable under key reordering', () => {
    const a = reason()
    const b: ReasonDocument = {
      slot: a.slot,
      roundId: a.roundId,
      nonce: a.nonce,
      model: a.model,
      text: a.text,
      code: a.code,
    }
    expect(canonicalReasonJson(a)).toBe(canonicalReasonJson(b))
    expect(hashReason(a)).toBe(hashReason(b))
  })
})

describe('model hash (§5.4)', () => {
  it('changes when the system prompt changes', () => {
    const base = reason().model
    const a = modelHash(base)
    const b = modelHash({ ...base, systemPromptHash: hashSystemPrompt('a different prompt') })
    expect(a).not.toBe(b)
  })

  it('changes when the model version changes, so substitution is detectable', () => {
    const base = reason().model
    expect(modelHash(base)).not.toBe(modelHash({ ...base, version: '2026-08-01' }))
  })
})

describe('signatures recover to the slot key', () => {
  it('commit', async () => {
    const att = await signCommit({
      signingKey: KEY,
      domain: DOMAIN,
      roundId: 7n,
      slot: 3,
      commitment: keccak256(toHex('c')),
      modelHash: keccak256(toHex('m')),
    })
    const recovered = await recoverTypedDataAddress({
      domain: { name: 'SAINE', version: '1', chainId: DOMAIN.chainId, verifyingContract: DOMAIN.verifyingContract },
      types: COMMIT_TYPES,
      primaryType: 'Commit',
      message: { roundId: 7n, slot: 3, commitment: att.commitment, modelHash: att.modelHash },
      signature: att.signature,
    })
    expect(recovered).toBe(privateKeyToAccount(KEY).address)
  })

  it('reveal', async () => {
    const rh = hashReason(reason())
    const salt = deriveSalt(('0x' + 'cd'.repeat(32)) as `0x${string}`, 7n, 3)
    const att = await signReveal({
      signingKey: KEY,
      domain: DOMAIN,
      roundId: 7n,
      slot: 3,
      verdict: true,
      reasonHash: rh,
      salt,
    })
    const recovered = await recoverTypedDataAddress({
      domain: { name: 'SAINE', version: '1', chainId: DOMAIN.chainId, verifyingContract: DOMAIN.verifyingContract },
      types: REVEAL_TYPES,
      primaryType: 'Reveal',
      message: { roundId: 7n, slot: 3, verdict: true, reasonHash: rh, salt },
      signature: att.signature,
    })
    expect(recovered).toBe(privateKeyToAccount(KEY).address)
  })

  it('a signature for one round does not verify for another', async () => {
    const att = await signCommit({
      signingKey: KEY,
      domain: DOMAIN,
      roundId: 7n,
      slot: 3,
      commitment: keccak256(toHex('c')),
      modelHash: keccak256(toHex('m')),
    })
    const recovered = await recoverTypedDataAddress({
      domain: { name: 'SAINE', version: '1', chainId: DOMAIN.chainId, verifyingContract: DOMAIN.verifyingContract },
      types: COMMIT_TYPES,
      primaryType: 'Commit',
      message: { roundId: 8n, slot: 3, commitment: att.commitment, modelHash: att.modelHash },
      signature: att.signature,
    })
    expect(recovered).not.toBe(privateKeyToAccount(KEY).address)
  })
})
