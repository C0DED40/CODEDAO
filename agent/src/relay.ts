/**
 * The relayer boundary.
 *
 * Decision 1.4 in the build log: operators sign, anyone submits. Three reasons, and the first is the one
 * that matters: §5.5's equivocation slashing needs *two validly signed attestations* to exist as objects.
 * With direct transactions the second is simply rejected by the contract and there is nothing to produce
 * as evidence, so the clause would be unenforceable by construction.
 *
 * The relayer is therefore untrusted with respect to content. It cannot forge an attestation, because
 * every one carries a slot-key signature the registry verifies. What it can do is withhold one, which is
 * why `submitCommits` and `submitReveals` report what was accepted rather than assuming success: a slot
 * whose commitment never landed must not go on to reveal, and a slot whose reveal never landed needs to
 * be visible before the window closes.
 */

import type { CommitAttestation, RevealAttestation } from './types.js'

export interface RelayReceipt {
  readonly txHash: string
  /** Slots the chain accepted. May be a subset of what was submitted. */
  readonly accepted: readonly number[]
  readonly rejected: readonly { readonly slot: number; readonly reason: string }[]
}

export interface Relayer {
  submitCommits(atts: readonly CommitAttestation[]): Promise<RelayReceipt>
  submitReveals(atts: readonly RevealAttestation[]): Promise<RelayReceipt>
  /** Which slots the chain records as having committed, for reconciliation before revealing. */
  committedSlots(roundId: bigint): Promise<readonly number[]>
}
