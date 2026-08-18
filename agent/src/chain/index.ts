/**
 * Chain reads and writes, over viem.
 *
 * Everything the harness needs from the chain is behind these two interfaces so the orchestrator can be
 * tested without a node, which matters: the tests that protect the bond are the ones that must run on
 * every commit, and a suite that needs an RPC endpoint does not.
 */

import {
  createPublicClient,
  createWalletClient,
  http,
  type Abi,
  type Address,
  type Hex,
  type PublicClient,
  type WalletClient,
} from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import { SAINE_ABI, TARGETS_ABI, GOVERNOR_ABI } from './abi.js'
import type { RelayReceipt, Relayer } from '../relay.js'
import type { CommitAttestation, RevealAttestation, RoundKind } from '../types.js'
import { ROUND_KIND_INDEX } from '../types.js'

export interface Addresses {
  readonly saine: Address
  readonly governor: Address
  readonly escrow: Address
  readonly targets: Address
}

export interface OnChainRound {
  readonly roundId: bigint
  readonly subject: bigint
  readonly kind: RoundKind
  readonly state: number
  readonly commitEnd: number
  readonly revealEnd: number
  readonly commits: number
  readonly reveals: number
  readonly approvals: number
  readonly committedMask: number
  readonly revealedMask: number
  readonly trancheIndex: number
}

const KIND_BY_INDEX: readonly RoundKind[] = ['Origination', 'Tranche', 'Advisory']

export class ChainReader {
  constructor(
    private readonly client: PublicClient,
    private readonly addr: Addresses,
  ) {}

  static fromRpc(rpcUrl: string, addr: Addresses): ChainReader {
    return new ChainReader(createPublicClient({ transport: http(rpcUrl) }), addr)
  }

  async roundCount(): Promise<bigint> {
    return (await this.client.readContract({
      address: this.addr.saine,
      abi: SAINE_ABI as Abi,
      functionName: 'roundCount',
    })) as bigint
  }

  async round(roundId: bigint): Promise<OnChainRound> {
    const r = (await this.client.readContract({
      address: this.addr.saine,
      abi: SAINE_ABI as Abi,
      functionName: 'getRound',
      args: [roundId],
    })) as {
      subject: bigint
      kind: number
      state: number
      commitEnd: bigint
      revealEnd: bigint
      commits: number
      reveals: number
      approvals: number
      committedMask: number
      revealedMask: number
      trancheIndex: number
    }
    return {
      roundId,
      subject: r.subject,
      kind: KIND_BY_INDEX[r.kind] ?? 'Origination',
      state: r.state,
      commitEnd: Number(r.commitEnd),
      revealEnd: Number(r.revealEnd),
      commits: r.commits,
      reveals: r.reveals,
      approvals: r.approvals,
      committedMask: r.committedMask,
      revealedMask: r.revealedMask,
      trancheIndex: r.trancheIndex,
    }
  }

  /** Slots the chain records as having committed, decoded from the bitmask. */
  async committedSlots(roundId: bigint): Promise<number[]> {
    const r = await this.round(roundId)
    return maskToSlots(r.committedMask)
  }

  async isKnownTarget(target: Address, selector: Hex): Promise<boolean> {
    return (await this.client.readContract({
      address: this.addr.targets,
      abi: TARGETS_ABI as Abi,
      functionName: 'isKnown',
      args: [target, selector],
    })) as boolean
  }

  /** The proposal a round adjudicates, for the manifest hash and the flag §6.2 requires. */
  async proposal(id: bigint): Promise<{
    readonly manifestHash: Hex
    readonly investee: Address
    readonly targetsFlagged: boolean
    readonly proposer: Address
    readonly season: number
  }> {
    const p = (await this.client.readContract({
      address: this.addr.governor,
      abi: GOVERNOR_ABI as Abi,
      functionName: 'getProposal',
      args: [id],
    })) as {
      manifestHash: Hex
      investee: Address
      targetsFlagged: boolean
      proposer: Address
      season: number
    }
    return {
      manifestHash: p.manifestHash,
      investee: p.investee,
      targetsFlagged: p.targetsFlagged,
      proposer: p.proposer,
      season: p.season,
    }
  }

  async actions(id: bigint): Promise<{ readonly targets: readonly Address[]; readonly calldatas: readonly Hex[] }> {
    const a = (await this.client.readContract({
      address: this.addr.governor,
      abi: GOVERNOR_ABI as Abi,
      functionName: 'getActions',
      args: [id],
    })) as { targets: readonly Address[]; calldatas: readonly Hex[] }
    return { targets: a.targets, calldatas: a.calldatas }
  }

  /**
   * Simulate the proposal's actions as the timelock would execute them.
   *
   * §5.3 wants "a simulation trace of the full execution path, including the payout". Simulated from the
   * timelock's address because that is who executes: simulating from anywhere else would revert on the
   * access control and tell the board nothing about the deal.
   */
  async simulateAs(
    executor: Address,
    calls: readonly { readonly to: Address; readonly data: Hex }[],
  ): Promise<{ ok: boolean; gasUsed: bigint; revertReason?: string }> {
    let gasUsed = 0n
    for (const c of calls) {
      try {
        const gas = await this.client.estimateGas({ account: executor, to: c.to, data: c.data })
        gasUsed += gas
      } catch (err) {
        return { ok: false, gasUsed, revertReason: extractRevert(err) }
      }
    }
    return { ok: true, gasUsed }
  }
}

export function maskToSlots(mask: number): number[] {
  const out: number[] = []
  for (let i = 0; i < 10; i += 1) {
    if ((mask & (1 << i)) !== 0) out.push(i)
  }
  return out
}

function extractRevert(err: unknown): string {
  const s = String((err as { shortMessage?: string })?.shortMessage ?? err)
  return s.slice(0, 300)
}

/**
 * Relays signed attestations. Holds no slot key: it holds gas.
 *
 * The distinction is the point of decision 1.4. This account can withhold an attestation, and cannot
 * forge one. §12 notes adjudication is transaction-heavy, twenty commit and reveal transactions per
 * round across three tracks, so batching ten signatures into one call is the difference between a
 * board that is economical to run and one that is not.
 */
export class ViemRelayer implements Relayer {
  constructor(
    private readonly wallet: WalletClient,
    private readonly reader: ChainReader,
    private readonly saine: Address,
  ) {}

  static fromKey(rpcUrl: string, relayerKey: Hex, addr: Addresses): ViemRelayer {
    const account = privateKeyToAccount(relayerKey)
    const wallet = createWalletClient({ account, transport: http(rpcUrl) })
    return new ViemRelayer(wallet, ChainReader.fromRpc(rpcUrl, addr), addr.saine)
  }

  async submitCommits(atts: readonly CommitAttestation[]): Promise<RelayReceipt> {
    const before = new Set(await this.reader.committedSlots(atts[0]!.roundId))
    const txHash = await this.wallet.writeContract({
      address: this.saine,
      abi: SAINE_ABI as Abi,
      functionName: 'submitCommits',
      args: [
        atts.map((a) => ({
          roundId: a.roundId,
          slot: a.slot,
          commitment: a.commitment,
          modelHash: a.modelHash,
        })),
        atts.map((a) => a.signature),
      ],
      chain: null,
      account: this.wallet.account!,
    })

    // Read back rather than assume. A batch is atomic, so a single bad signature reverts all ten, and
    // reporting them as accepted would send the whole board on to reveal against commitments that do
    // not exist.
    const after = new Set(await this.reader.committedSlots(atts[0]!.roundId))
    const accepted = atts.map((a) => a.slot).filter((s) => after.has(s) && !before.has(s))
    const rejected = atts
      .map((a) => a.slot)
      .filter((s) => !after.has(s))
      .map((slot) => ({ slot, reason: 'not present in committedMask after submission' }))
    return { txHash, accepted, rejected }
  }

  async submitReveals(atts: readonly RevealAttestation[]): Promise<RelayReceipt> {
    const txHash = await this.wallet.writeContract({
      address: this.saine,
      abi: SAINE_ABI as Abi,
      functionName: 'submitReveals',
      args: [
        atts.map((a) => ({
          roundId: a.roundId,
          slot: a.slot,
          verdict: a.verdict,
          reasonHash: a.reasonHash,
          salt: a.salt,
        })),
        atts.map((a) => a.signature),
      ],
      chain: null,
      account: this.wallet.account!,
    })
    const r = await this.reader.round(atts[0]!.roundId)
    const revealed = new Set(maskToSlots(r.revealedMask))
    const accepted = atts.map((a) => a.slot).filter((s) => revealed.has(s))
    const rejected = atts
      .map((a) => a.slot)
      .filter((s) => !revealed.has(s))
      .map((slot) => ({ slot, reason: 'not present in revealedMask after submission' }))
    return { txHash, accepted, rejected }
  }

  async committedSlots(roundId: bigint): Promise<readonly number[]> {
    return this.reader.committedSlots(roundId)
  }
}

export { ROUND_KIND_INDEX }
