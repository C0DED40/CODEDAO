/**
 * Assembling §5.3's adjudication package.
 *
 * The package is the board's entire view of a proposal, so anything omitted here is something ten
 * reviewers cannot weigh. Two consequences shape the code:
 *
 *   - **A missing artefact is reported, never silently dropped.** If verified source cannot be fetched, the
 *     board is told that it could not be fetched, which is different from being told there is none. §5.3
 *     asks the agents to check deployed contracts against claimed terms, and an unexplained absence would
 *     let them approve on the assumption that someone else had looked.
 *   - **Decoding failure is itself evidence.** Calldata this harness cannot decode is calldata a voter
 *     could not read either, which is exactly the condition §6.1 built the manifest binding to prevent.
 */

import { decodeFunctionData, slice, type Abi, type Address, type Hex } from 'viem'
import { ESCROW_ABI, GOVERNOR_ABI, TREASURY_ABI, DCODE_ABI, SAINE_ABI, TARGETS_ABI, ORACLE_ABI, RECEIVER_ABI } from '../chain/abi.js'
import type { ChainReader } from '../chain/index.js'
import type { AdjudicationPackage, DecodedAction, PriorRound, RoundKind, SimulationTrace, VerifiedSource } from '../types.js'
import { validateManifest, type Manifest, type ManifestValidation } from './manifest.js'

/** Fetches a document by CID. */
export interface ManifestFetcher {
  fetch(cid: string): Promise<unknown>
}

/** Fetches verified source for an address. */
export interface SourceFetcher {
  fetch(address: Address): Promise<VerifiedSource>
}

/** Prior adjudications of the same deal, for §6.4's material-change judgement. */
export interface HistorySource {
  priorRounds(investee: Address): Promise<readonly PriorRound[]>
}

export interface BuildDeps {
  readonly reader: ChainReader
  readonly manifests: ManifestFetcher
  readonly sources: SourceFetcher
  readonly history: HistorySource
  readonly timelock: Address
  readonly log?: (msg: string, detail?: unknown) => void
}

/** ABIs the harness can decode against, so a call to a protocol contract renders as a signature. */
const KNOWN_ABIS: readonly Abi[] = [
  ESCROW_ABI as Abi,
  GOVERNOR_ABI as Abi,
  TREASURY_ABI as Abi,
  DCODE_ABI as Abi,
  SAINE_ABI as Abi,
  TARGETS_ABI as Abi,
  ORACLE_ABI as Abi,
  RECEIVER_ABI as Abi,
]

export interface BuildInput {
  readonly roundId: bigint
  readonly kind: RoundKind
  readonly subject: bigint
  /** IPFS CID of the manifest, from the proposal's `descriptionUri` or an equivalent index. */
  readonly manifestCid?: string
}

export interface BuiltPackageFull {
  readonly pkg: AdjudicationPackage
  readonly validation: ManifestValidation
  readonly targetsFlagged: boolean
}

export async function buildAdjudicationPackage(
  deps: BuildDeps,
  input: BuildInput,
): Promise<BuiltPackageFull> {
  const log = deps.log ?? (() => {})

  const proposal = await deps.reader.proposal(input.subject)
  const { targets, calldatas } = await deps.reader.actions(input.subject)

  const actions: DecodedAction[] = []
  for (let i = 0; i < targets.length; i += 1) {
    const target = targets[i]!
    const data = calldatas[i]!
    const selector = data.length >= 10 ? (slice(data, 0, 4) as Hex) : ('0x' as Hex)
    const registered = selector === '0x' ? false : await deps.reader.isKnownTarget(target, selector)
    actions.push({ target, selector, registered, ...decode(data) })
  }

  let manifestDoc: unknown = null
  if (input.manifestCid !== undefined) {
    try {
      manifestDoc = await deps.manifests.fetch(input.manifestCid)
    } catch (err) {
      log('manifest fetch failed', err)
      manifestDoc = { _error: `manifest could not be fetched from ${input.manifestCid}: ${String(err)}` }
    }
  } else {
    manifestDoc = { _error: 'no manifest CID was recorded for this proposal' }
  }

  const validation = validateManifest(manifestDoc)

  // Addresses to inspect: whatever the manifest names, plus the investee the contract bound at
  // submission. Invariant 4 makes those equal for a well-formed proposal, and a disagreement is exactly
  // what the board should see.
  const addresses = new Set<Address>()
  if (proposal.investee !== '0x0000000000000000000000000000000000000000') addresses.add(proposal.investee)
  const manifest = validation.manifest as Manifest | undefined
  if (manifest !== undefined) addresses.add(manifest.investee as Address)

  const investeeSource: VerifiedSource[] = []
  for (const address of addresses) {
    try {
      investeeSource.push(await deps.sources.fetch(address))
    } catch (err) {
      // Reported as unverified with the reason, not omitted. Silence would read as "nothing to inspect".
      log('source fetch failed', err)
      investeeSource.push({ address, verified: false, name: `fetch failed: ${String(err).slice(0, 120)}` })
    }
  }

  const simulation = await simulate(deps, targets, calldatas)

  let history: readonly PriorRound[] = []
  try {
    history = await deps.history.priorRounds(proposal.investee)
  } catch (err) {
    log('history fetch failed', err)
  }

  const description = typeof manifest?.description === 'string' ? manifest.description : ''

  return {
    pkg: {
      roundId: input.roundId,
      kind: input.kind,
      subject: input.subject,
      actions,
      simulation,
      investeeSource,
      manifest: manifestDoc,
      description,
      history,
    },
    validation,
    targetsFlagged: proposal.targetsFlagged,
  }
}

function decode(data: Hex): { signature: string; args: readonly unknown[] } {
  for (const abi of KNOWN_ABIS) {
    try {
      const { functionName, args } = decodeFunctionData({ abi, data })
      return { signature: functionName, args: (args ?? []) as readonly unknown[] }
    } catch {
      // Not this ABI; try the next.
    }
  }
  // Undecodable calldata is a finding in its own right: a voter could not read it either.
  return {
    signature: '<undecodable: no known ABI matches this selector>',
    args: [{ rawCalldata: data }],
  }
}

async function simulate(
  deps: BuildDeps,
  targets: readonly Address[],
  calldatas: readonly Hex[],
): Promise<SimulationTrace> {
  const calls = targets.map((to, i) => ({ to, data: calldatas[i]! }))
  try {
    const r = await deps.reader.simulateAs(deps.timelock, calls)
    return r.ok
      ? { ok: true, gasUsed: r.gasUsed, transfers: [] }
      : { ok: false, gasUsed: r.gasUsed, transfers: [], ...(r.revertReason ? { revertReason: r.revertReason } : {}) }
  } catch (err) {
    return { ok: false, gasUsed: 0n, transfers: [], revertReason: `simulation unavailable: ${String(err)}` }
  }
}

/** Reads a manifest from a Kubo-compatible gateway. */
export class GatewayManifestFetcher implements ManifestFetcher {
  constructor(
    private readonly gatewayUrl: string,
    private readonly fetchImpl: typeof globalThis.fetch = globalThis.fetch,
    private readonly timeoutMs = 15_000,
  ) {}

  async fetch(cid: string): Promise<unknown> {
    const clean = cid.replace(/^ipfs:\/\//, '')
    const controller = new AbortController()
    const timer = setTimeout(() => controller.abort(), this.timeoutMs)
    try {
      const res = await this.fetchImpl(`${this.gatewayUrl.replace(/\/$/, '')}/ipfs/${clean}`, {
        signal: controller.signal,
      })
      if (!res.ok) throw new Error(`gateway HTTP ${res.status}`)
      return await res.json()
    } finally {
      clearTimeout(timer)
    }
  }
}

/** Reads verified source from a Sourcify-compatible repository. */
export class SourcifySourceFetcher implements SourceFetcher {
  constructor(
    private readonly baseUrl: string,
    private readonly chainId: number,
    private readonly fetchImpl: typeof globalThis.fetch = globalThis.fetch,
  ) {}

  async fetch(address: Address): Promise<VerifiedSource> {
    const url = `${this.baseUrl.replace(/\/$/, '')}/files/any/${this.chainId}/${address}`
    const res = await this.fetchImpl(url)
    if (!res.ok) return { address, verified: false }
    const json = (await res.json()) as { files?: { name?: string; content?: string }[] }
    const sol = json.files?.filter((f) => f.name?.endsWith('.sol')) ?? []
    if (sol.length === 0) return { address, verified: false }
    return {
      address,
      verified: true,
      name: sol[0]?.name ?? 'unnamed',
      source: sol.map((f) => `// ${f.name}\n${f.content ?? ''}`).join('\n\n'),
    }
  }
}
