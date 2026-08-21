import { describe, expect, it } from 'vitest'
import {
  assertChainIdMatch,
  ConfigError,
  homeNetworkName,
  loadConfig,
  ROBINHOOD_MAINNET_CHAIN_ID,
  ROBINHOOD_TESTNET_CHAIN_ID,
} from '../src/config.js'

const A = '0x1111111111111111111111111111111111111111'

function env(overrides: Record<string, string | undefined> = {}): Record<string, string | undefined> {
  const base: Record<string, string | undefined> = {
    SAINE_RPC_URL: 'http://localhost:8545',
    SAINE_CHAIN_ID: String(ROBINHOOD_MAINNET_CHAIN_ID),
    SAINE_REGISTRY_ADDRESS: A,
    SAINE_GOVERNOR_ADDRESS: A,
    SAINE_ESCROW_ADDRESS: A,
    SAINE_TARGETS_ADDRESS: A,
    SAINE_RELAYER_KEY: '0x' + 'ff'.repeat(32),
  }
  for (let i = 0; i < 10; i += 1) {
    base[`SAINE_SLOT_${i}_SIGNING_KEY`] = '0x' + (i + 1).toString(16).padStart(2, '0').repeat(32)
    base[`SAINE_SLOT_${i}_SALT_SECRET`] = '0x' + (i + 100).toString(16).padStart(2, '0').repeat(32)
  }
  return { ...base, ...overrides }
}

describe('phase one and phase two (§5.8)', () => {
  it('defaults to all ten slots, which is phase one', () => {
    // "At launch, the team operates all ten agent slots." That is the configuration that must not need
    // extra ceremony to get right.
    const c = loadConfig(env())
    expect(c.operatedSlots).toEqual([0, 1, 2, 3, 4, 5, 6, 7, 8, 9])
    expect(c.slotKeys.size).toBe(10)
  })

  it('lets a phase-two operator run one seat with only their own credentials', () => {
    // From the trigger, governance reassigns seats to independent operators. One of them holds slot 3 and
    // has no key for anybody else's seat, so requiring all twenty secrets would make the harness unusable
    // by exactly the people §5.8 hands it to.
    const e = env({ SAINE_OPERATED_SLOTS: '3' })
    for (let i = 0; i < 10; i += 1) {
      if (i === 3) continue
      e[`SAINE_SLOT_${i}_SIGNING_KEY`] = undefined
      e[`SAINE_SLOT_${i}_SALT_SECRET`] = undefined
    }
    const c = loadConfig(e)
    expect(c.operatedSlots).toEqual([3])
    expect(c.slotKeys.size).toBe(1)
    expect(c.slotKeys.get(3)).toBeDefined()
  })

  it('allows the two seats §5.2 permits an operator', () => {
    const c = loadConfig(env({ SAINE_OPERATED_SLOTS: '7,2' }))
    expect(c.operatedSlots).toEqual([2, 7])
  })

  it('refuses three seats, which the registry could not seat anyway', () => {
    // §5.2: "no assignment may leave an operator holding more than two slots" from the trigger onward.
    expect(() => loadConfig(env({ SAINE_OPERATED_SLOTS: '1,2,3' }))).toThrow(/caps an operator at 2/)
  })

  it('rejects a slot index outside the board', () => {
    expect(() => loadConfig(env({ SAINE_OPERATED_SLOTS: '10' }))).toThrow(/slots are 0 to 9/)
  })

  it('rejects a duplicated slot', () => {
    expect(() => loadConfig(env({ SAINE_OPERATED_SLOTS: '4,4' }))).toThrow(/twice/)
  })
})

describe('loadConfig', () => {
  it('loads a complete environment', () => {
    const c = loadConfig(env())
    expect(c.slotKeys.size).toBe(10)
    expect(c.domain.verifyingContract).toBe(A)
    expect(c.domain.chainId).toBe(ROBINHOOD_MAINNET_CHAIN_ID)
  })

  it('accepts the Robinhood testnet chain id', () => {
    const c = loadConfig(env({ SAINE_CHAIN_ID: String(ROBINHOOD_TESTNET_CHAIN_ID) }))
    expect(c.chainId).toBe(ROBINHOOD_TESTNET_CHAIN_ID)
    expect(c.domain.chainId).toBe(ROBINHOOD_TESTNET_CHAIN_ID)
    expect(homeNetworkName(c.chainId)).toBe('robinhood-testnet')
  })

  it('refuses an RPC that is not the configured chain', () => {
    // A harness pointed at testnet with the mainnet id signs a domain the registry will reject.
    expect(() => assertChainIdMatch(ROBINHOOD_MAINNET_CHAIN_ID, ROBINHOOD_TESTNET_CHAIN_ID)).toThrow(
      /SAINE_CHAIN_ID is 4663.*RPC reports 46630/,
    )
    expect(() => assertChainIdMatch(ROBINHOOD_TESTNET_CHAIN_ID, ROBINHOOD_TESTNET_CHAIN_ID)).not.toThrow()
  })

  it('throws on a missing variable rather than defaulting', () => {
    // Discovering a missing key at the first commit window costs a lapsed round; discovering it midway
    // through a board costs a slot that committed and cannot reveal.
    expect(() => loadConfig(env({ SAINE_SLOT_7_SALT_SECRET: undefined }))).toThrow(ConfigError)
    expect(() => loadConfig(env({ SAINE_RPC_URL: undefined }))).toThrow(ConfigError)
  })

  it('rejects a truncated private key', () => {
    // A short key derives a different address silently, so the slot's signatures would be rejected and
    // the failure would look like an agent that went quiet.
    expect(() => loadConfig(env({ SAINE_SLOT_0_SIGNING_KEY: '0xdeadbeef' }))).toThrow(/32-byte/)
  })

  it('rejects a malformed address', () => {
    expect(() => loadConfig(env({ SAINE_ESCROW_ADDRESS: 'not-an-address' }))).toThrow(/valid address/)
  })

  it('refuses two slots sharing a signing key', () => {
    // The registry would show two seats and the threshold would count two votes, but one leak takes both.
    const e = env()
    e.SAINE_SLOT_1_SIGNING_KEY = e.SAINE_SLOT_0_SIGNING_KEY
    expect(() => loadConfig(e)).toThrow(/share a signing key/)
  })

  it('refuses two slots sharing a salt secret', () => {
    const e = env()
    e.SAINE_SLOT_3_SALT_SECRET = e.SAINE_SLOT_2_SALT_SECRET
    expect(() => loadConfig(e)).toThrow(/share a salt secret/)
  })

  it('refuses a signing key reused as a salt secret', () => {
    const e = env()
    e.SAINE_SLOT_5_SALT_SECRET = e.SAINE_SLOT_5_SIGNING_KEY
    expect(() => loadConfig(e)).toThrow(/keep them separate/)
  })
})

describe('keeper and fee collection (§5.8)', () => {
  const B = '0x2222222222222222222222222222222222222222'
  const KEEPER = {
    SAINE_DCODE_ADDRESS: B,
    SAINE_ORACLE_ADDRESS: B,
    SAINE_RECEIVER_ADDRESS: B,
    SAINE_CODE_ADDRESS: B,
  }

  it('omits the keeper block entirely when none of it is configured', () => {
    // A process that only judges rounds should not be made to know where the receiver is.
    const c = loadConfig(env())
    expect(c.keeper).toBeUndefined()
    expect(c.operatorAddress).toBeUndefined()
  })

  it('loads the keeper addresses when all four are present', () => {
    const c = loadConfig(env(KEEPER))
    expect(c.keeper?.code).toBe(B)
    expect(c.keeper?.receiver).toBe(B)
  })

  it('refuses a partial keeper configuration rather than throwing on the fifth step', () => {
    expect(() => loadConfig(env({ ...KEEPER, SAINE_CODE_ADDRESS: undefined }))).toThrow(/all or nothing/)
  })

  it('takes an operator address for fee collection and validates it', () => {
    const c = loadConfig(env({ ...KEEPER, SAINE_OPERATOR_ADDRESS: B }))
    expect(c.operatorAddress).toBe(B)
    expect(() => loadConfig(env({ SAINE_OPERATOR_ADDRESS: 'not-an-address' }))).toThrow(ConfigError)
  })
})
