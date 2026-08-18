/**
 * Configuration and key material.
 *
 * Twenty secrets, two per slot, and the split is deliberate. A slot's signing key authorises attestations;
 * its salt secret derives commitment salts and nothing else. Keeping them separate means a compromise of
 * the salt store does not let an attacker sign, and a compromise of a signing key does not immediately
 * reveal earlier sealed verdicts.
 *
 * Nothing here defaults. A missing key throws at startup rather than at the first commit window, because
 * discovering it then costs a lapsed round, and discovering it halfway through a board costs a slot that
 * committed and could not reveal.
 */

import { isAddress, isHex, type Address, type Hex } from 'viem'
import type { SlotKeys } from './orchestrate.js'
import type { Domain } from './attest.js'
import type { Addresses } from './chain/index.js'
import { SLOTS } from './board.js'

export class ConfigError extends Error {
  constructor(message: string) {
    super(message)
    this.name = 'ConfigError'
  }
}

export interface HarnessConfig {
  readonly rpcUrl: string
  readonly chainId: number
  readonly addresses: Addresses
  readonly domain: Domain
  readonly relayerKey: Hex
  /**
   * The slots this process operates.
   *
   * §5.8 makes this a moving target rather than a constant. In phase one "the team operates all ten
   * agent slots", so one process holds every seat. From the phase two trigger governance reassigns
   * seats to independent operators, capped at two each, and each of those runs this same harness holding
   * one or two slots and no credentials for anybody else's.
   *
   * Defaults to all ten, which is phase one. Set `SAINE_OPERATED_SLOTS=3` or `=3,7` for a phase-two
   * operator.
   */
  readonly operatedSlots: readonly number[]
  /** Keyed by slot index. Only the operated slots are present. */
  readonly slotKeys: ReadonlyMap<number, SlotKeys>
  readonly ipfsApiUrl?: string
  readonly pollIntervalMs: number
  /**
   * Addresses the keeper needs and the adjudication path does not.
   *
   * Optional as a set, because a process that only judges rounds should not be made to know where the
   * receiver is. Present only when all four are configured: a keeper missing one of them would run four
   * of its steps and throw on the fifth, which reads as a broken keeper rather than an unconfigured one.
   */
  readonly keeper?: KeeperAddresses
  /**
   * The operator address this harness collects attestation fees for (§5.8). Unset in phase one, where
   * the fee is zero. Never a key this process holds: the contract pays the named operator whoever calls,
   * so the relayer signs the transaction and the money goes elsewhere.
   */
  readonly operatorAddress?: Address
}

export interface KeeperAddresses {
  readonly dcode: Address
  readonly oracle: Address
  readonly receiver: Address
  readonly code: Address
}

type Env = Readonly<Record<string, string | undefined>>

function need(env: Env, key: string): string {
  const v = env[key]
  if (v === undefined || v.length === 0) throw new ConfigError(`missing required environment variable ${key}`)
  return v
}

function needAddress(env: Env, key: string): Address {
  const v = need(env, key)
  if (!isAddress(v)) throw new ConfigError(`${key} is not a valid address: ${v}`)
  return v
}

function optionalAddress(env: Env, key: string): Address | undefined {
  const v = env[key]
  if (v === undefined || v.length === 0) return undefined
  if (!isAddress(v)) throw new ConfigError(`${key} is not a valid address: ${v}`)
  return v
}

function needKey(env: Env, key: string): Hex {
  const v = need(env, key)
  // Checked rather than trusted: a truncated key silently derives a different address, so the slot's
  // signatures would be rejected and look like an agent that went quiet.
  if (!isHex(v) || v.length !== 66) {
    throw new ConfigError(`${key} must be a 0x-prefixed 32-byte hex private key`)
  }
  return v
}

export function loadConfig(env: Env = process.env): HarnessConfig {
  const chainId = Number(need(env, 'SAINE_CHAIN_ID'))
  if (!Number.isInteger(chainId) || chainId <= 0) throw new ConfigError('SAINE_CHAIN_ID must be a positive integer')

  const addresses: Addresses = {
    saine: needAddress(env, 'SAINE_REGISTRY_ADDRESS'),
    governor: needAddress(env, 'SAINE_GOVERNOR_ADDRESS'),
    escrow: needAddress(env, 'SAINE_ESCROW_ADDRESS'),
    targets: needAddress(env, 'SAINE_TARGETS_ADDRESS'),
  }

  const operatedSlots = parseSlots(env.SAINE_OPERATED_SLOTS)

  const slotKeys = new Map<number, SlotKeys>()
  for (const i of operatedSlots) {
    slotKeys.set(i, {
      signingKey: needKey(env, `SAINE_SLOT_${i}_SIGNING_KEY`),
      saltSecret: needKey(env, `SAINE_SLOT_${i}_SALT_SECRET`),
    })
  }

  assertDistinct([...slotKeys.values()])

  const keeperKeys = ['SAINE_DCODE_ADDRESS', 'SAINE_ORACLE_ADDRESS', 'SAINE_RECEIVER_ADDRESS', 'SAINE_CODE_ADDRESS']
  const keeperSet = keeperKeys.filter((k) => (env[k] ?? '').length > 0)
  if (keeperSet.length !== 0 && keeperSet.length !== keeperKeys.length) {
    const missing = keeperKeys.filter((k) => !keeperSet.includes(k))
    throw new ConfigError(`keeper addresses are all or nothing; missing ${missing.join(', ')}`)
  }
  const keeper: KeeperAddresses | undefined =
    keeperSet.length === keeperKeys.length
      ? {
          dcode: needAddress(env, 'SAINE_DCODE_ADDRESS'),
          oracle: needAddress(env, 'SAINE_ORACLE_ADDRESS'),
          receiver: needAddress(env, 'SAINE_RECEIVER_ADDRESS'),
          code: needAddress(env, 'SAINE_CODE_ADDRESS'),
        }
      : undefined

  const operatorAddress = optionalAddress(env, 'SAINE_OPERATOR_ADDRESS')

  const ipfs = env.SAINE_IPFS_API_URL
  return {
    rpcUrl: need(env, 'SAINE_RPC_URL'),
    chainId,
    addresses,
    domain: { chainId, verifyingContract: addresses.saine },
    relayerKey: needKey(env, 'SAINE_RELAYER_KEY'),
    operatedSlots,
    slotKeys,
    ...(ipfs !== undefined && ipfs.length > 0 ? { ipfsApiUrl: ipfs } : {}),
    pollIntervalMs: Number(env.SAINE_POLL_INTERVAL_MS ?? 60_000),
    ...(keeper !== undefined ? { keeper } : {}),
    ...(operatorAddress !== undefined ? { operatorAddress } : {}),
  }
}

/**
 * Which seats this process holds.
 *
 * Unset means all ten, because that is phase one and it is the configuration that must not require extra
 * ceremony to get right. A phase-two operator names their seats explicitly, and naming more than two is
 * refused here as well as on chain: §5.2's cap activates at the trigger, and a harness that happily ran
 * three seats would produce signatures the registry has already made impossible to seat.
 */
export function parseSlots(raw: string | undefined): number[] {
  if (raw === undefined || raw.trim().length === 0) {
    return Array.from({ length: SLOTS }, (_v, i) => i)
  }
  const parts = raw
    .split(',')
    .map((p) => p.trim())
    .filter((p) => p.length > 0)
  if (parts.length === 0) throw new ConfigError('SAINE_OPERATED_SLOTS was set but listed no slots')

  const slots: number[] = []
  for (const p of parts) {
    const n = Number(p)
    if (!Number.isInteger(n) || n < 0 || n >= SLOTS) {
      throw new ConfigError(`SAINE_OPERATED_SLOTS contains "${p}"; slots are 0 to ${SLOTS - 1}`)
    }
    if (slots.includes(n)) throw new ConfigError(`SAINE_OPERATED_SLOTS lists slot ${n} twice`)
    slots.push(n)
  }
  if (slots.length > 2 && slots.length !== SLOTS) {
    // Either you are the phase-one team holding everything, or you are an independent operator capped at
    // two (§5.2). Anything between is a configuration that cannot be seated.
    throw new ConfigError(
      `SAINE_OPERATED_SLOTS lists ${slots.length} slots. §5.2 caps an operator at 2 from the phase two ` +
        `trigger; only the phase-one team holds all ${SLOTS}.`,
    )
  }
  return slots.sort((a, b) => a - b)
}

/**
 * Ten seats must mean ten keys.
 *
 * Two slots sharing a signing key is the quietest way to destroy the board's meaning: the registry sees
 * two entries and the six-of-ten threshold counts two votes, but there is one key, so a leak takes both
 * and either can be made to equivocate on the other's behalf. Two slots sharing a salt secret is milder
 * and still wrong, since it makes one slot's sealed verdict derivable from the other's.
 */
function assertDistinct(keys: readonly SlotKeys[]): void {
  const signing = new Set(keys.map((k) => k.signingKey.toLowerCase()))
  if (signing.size !== keys.length) {
    throw new ConfigError('two slots share a signing key; each seat must have its own')
  }
  const salts = new Set(keys.map((k) => k.saltSecret.toLowerCase()))
  if (salts.size !== keys.length) {
    throw new ConfigError('two slots share a salt secret; each seat must have its own')
  }
  for (const k of keys) {
    if (k.signingKey.toLowerCase() === k.saltSecret.toLowerCase()) {
      throw new ConfigError('a slot signing key is being reused as its salt secret; keep them separate')
    }
  }
}
