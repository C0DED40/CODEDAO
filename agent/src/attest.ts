/**
 * Attestation: commitment construction, salt derivation, and EIP-712 signing.
 *
 * Every encoding here must match `contracts/src/Saine.sol` byte for byte. A mismatch does not fail
 * loudly; it produces a signature the contract rejects, which looks exactly like an agent that went
 * quiet and costs 25% of the slot's bond. The tests pin the type hashes against the contract's.
 */

import {
  encodeAbiParameters,
  keccak256,
  toHex,
  concatHex,
  type Address,
  type Hex,
} from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import type { CommitAttestation, ModelIdentity, ReasonDocument, RevealAttestation } from './types.js'

/** Matches `EIP712("SAINE", "1")` in the registry's constructor. */
export const EIP712_DOMAIN_NAME = 'SAINE'
export const EIP712_DOMAIN_VERSION = '1'

export const COMMIT_TYPES = {
  Commit: [
    { name: 'roundId', type: 'uint256' },
    { name: 'slot', type: 'uint8' },
    { name: 'commitment', type: 'bytes32' },
    { name: 'modelHash', type: 'bytes32' },
  ],
} as const

export const REVEAL_TYPES = {
  Reveal: [
    { name: 'roundId', type: 'uint256' },
    { name: 'slot', type: 'uint8' },
    { name: 'verdict', type: 'bool' },
    { name: 'reasonHash', type: 'bytes32' },
    { name: 'salt', type: 'bytes32' },
  ],
} as const

export interface Domain {
  readonly chainId: number
  readonly verifyingContract: Address
}

function domainOf(d: Domain) {
  return {
    name: EIP712_DOMAIN_NAME,
    version: EIP712_DOMAIN_VERSION,
    chainId: d.chainId,
    verifyingContract: d.verifyingContract,
  } as const
}

/**
 * `keccak256(abi.encode(verdict, reasonHash, salt))`, exactly as the contract recomputes it on reveal.
 *
 * The reason hash is inside the commitment because §5.4 requires it: "an agent's justification is
 * fixed at the same instant as its verdict and cannot be composed after observing the tally." An
 * implementation that committed only to the verdict would let an agent write its reasoning to suit
 * whichever side won, which is the thing that makes the published record evidence rather than theatre.
 */
export function buildCommitment(verdict: boolean, reasonHash: Hex, salt: Hex): Hex {
  return keccak256(
    encodeAbiParameters(
      [{ type: 'bool' }, { type: 'bytes32' }, { type: 'bytes32' }],
      [verdict, reasonHash, salt],
    ),
  )
}

/** Canonical hash of a reason document. Whatever is pinned to IPFS must hash to this. */
export function hashReason(reason: ReasonDocument): Hex {
  return keccak256(toHex(canonicalReasonJson(reason)))
}

/**
 * Deterministic JSON, because `JSON.stringify` key order is insertion order and a re-serialisation
 * with different ordering would hash differently. The on-chain hash is the only binding between the
 * published document and the attestation, so the serialisation has to be reproducible by anyone
 * auditing it later.
 */
export function canonicalReasonJson(reason: ReasonDocument): string {
  return JSON.stringify({
    code: reason.code,
    model: {
      model: reason.model.model,
      provider: reason.model.provider,
      systemPromptHash: reason.model.systemPromptHash,
      version: reason.model.version,
    },
    nonce: reason.nonce,
    roundId: reason.roundId,
    slot: reason.slot,
    text: reason.text,
  })
}

/**
 * `keccak256(saltSecret, roundId, slot)`.
 *
 * Derived rather than random, and that is a deliberate trade. A random salt has to survive from the
 * commit window into the reveal window; if it is lost, the slot cannot reveal, forfeits a quarter of
 * its bond (§15), and drags the board toward the eight-reveal floor. Deriving it from a per-slot
 * secret removes the storage dependency entirely: the salt can always be recomputed.
 *
 * What that costs is a confidentiality margin against an attacker who already holds the slot's salt
 * secret. It does not cost the blindness of the commitment, because `reasonHash` still carries the
 * nonce from the reason document, so knowing the salt reveals nothing without also guessing an
 * unpredictable 32-byte value. See `ReasonDocument.nonce`.
 */
export function deriveSalt(saltSecret: Hex, roundId: bigint, slot: number): Hex {
  return keccak256(
    encodeAbiParameters(
      [{ type: 'bytes32' }, { type: 'uint256' }, { type: 'uint8' }],
      [saltSecret, roundId, slot],
    ),
  )
}

/**
 * §5.4's model hash: identifier, version, and the system prompt actually in use.
 *
 * Hashing the prompt rather than naming it is the point. A provider or operator who swapped the model
 * or quietly rewrote its instructions would produce a different hash against the same registry entry,
 * which is what makes substitution "detectable after the fact".
 */
export function modelHash(identity: ModelIdentity): Hex {
  return keccak256(
    encodeAbiParameters(
      [{ type: 'string' }, { type: 'string' }, { type: 'string' }, { type: 'bytes32' }],
      [identity.provider, identity.model, identity.version, identity.systemPromptHash],
    ),
  )
}

export function hashSystemPrompt(prompt: string): Hex {
  return keccak256(toHex(prompt))
}

export interface SignInput {
  readonly signingKey: Hex
  readonly domain: Domain
  readonly roundId: bigint
  readonly slot: number
}

export async function signCommit(
  input: SignInput & { readonly commitment: Hex; readonly modelHash: Hex },
): Promise<CommitAttestation> {
  const account = privateKeyToAccount(input.signingKey)
  const signature = await account.signTypedData({
    domain: domainOf(input.domain),
    types: COMMIT_TYPES,
    primaryType: 'Commit',
    message: {
      roundId: input.roundId,
      slot: input.slot,
      commitment: input.commitment,
      modelHash: input.modelHash,
    },
  })
  return {
    roundId: input.roundId,
    slot: input.slot,
    commitment: input.commitment,
    modelHash: input.modelHash,
    signature,
  }
}

export async function signReveal(
  input: SignInput & { readonly verdict: boolean; readonly reasonHash: Hex; readonly salt: Hex },
): Promise<RevealAttestation> {
  const account = privateKeyToAccount(input.signingKey)
  const signature = await account.signTypedData({
    domain: domainOf(input.domain),
    types: REVEAL_TYPES,
    primaryType: 'Reveal',
    message: {
      roundId: input.roundId,
      slot: input.slot,
      verdict: input.verdict,
      reasonHash: input.reasonHash,
      salt: input.salt,
    },
  })
  return {
    roundId: input.roundId,
    slot: input.slot,
    verdict: input.verdict,
    reasonHash: input.reasonHash,
    salt: input.salt,
    signature,
  }
}

/** The type hashes the contract uses, recomputed here so a test can pin them. */
export const COMMIT_TYPEHASH: Hex = keccak256(
  toHex('Commit(uint256 roundId,uint8 slot,bytes32 commitment,bytes32 modelHash)'),
)
export const REVEAL_TYPEHASH: Hex = keccak256(
  toHex('Reveal(uint256 roundId,uint8 slot,bool verdict,bytes32 reasonHash,bytes32 salt)'),
)

/** Exposed for the domain-separator test. */
export function domainSeparator(d: Domain): Hex {
  const typeHash = keccak256(
    toHex('EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)'),
  )
  return keccak256(
    concatHex([
      typeHash,
      keccak256(toHex(EIP712_DOMAIN_NAME)),
      keccak256(toHex(EIP712_DOMAIN_VERSION)),
      encodeAbiParameters([{ type: 'uint256' }], [BigInt(d.chainId)]),
      encodeAbiParameters([{ type: 'address' }], [d.verifyingContract]),
    ]),
  )
}
