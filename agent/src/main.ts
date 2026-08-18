#!/usr/bin/env node
/**
 * Entrypoints.
 *
 *   saine watch    poll for open rounds and drive commit and reveal
 *   saine keep     run the permissionless calls nobody is obliged to make
 *   saine check    validate configuration and board composition, then exit
 *
 * `check` exists because everything else is expensive to get wrong at the wrong moment. Discovering a
 * missing credential at the first commit window costs a lapsed round; discovering it here costs nothing.
 */

import { createPublicClient, createWalletClient, http } from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import { loadConfig } from './config.js'
import { buildBoard } from './models/build.js'
import { checkOperatedSlots } from './board.js'
import { ChainReader, ViemRelayer } from './chain/index.js'
import { FileAttestationStore } from './guard.js'
import { KuboPinner, NullPinner } from './ipfs.js'
import { GatewayManifestFetcher, SourcifySourceFetcher, buildAdjudicationPackage } from './package/build.js'
import { runWatchLoop, type WatchDeps } from './watch.js'
import { runKeeperPass } from './keeper.js'
import { keccak256, toHex } from 'viem'
import type { OrchestratorDeps } from './orchestrate.js'

function log(msg: string, detail?: unknown): void {
  const line = { at: new Date().toISOString(), msg, ...(detail !== undefined ? { detail: serialise(detail) } : {}) }
  process.stdout.write(`${JSON.stringify(line)}\n`)
}

function serialise(v: unknown): unknown {
  return JSON.parse(JSON.stringify(v, (_k, x) => (typeof x === 'bigint' ? x.toString() : x)))
}

async function main(): Promise<void> {
  const command = process.argv[2] ?? 'check'
  const cfg = loadConfig()

  // Phase one holds all ten and must satisfy §5.2 locally. A phase-two operator holds one or two and
  // cannot: the rest of the board is somebody else's, and the registry is the place to read it.
  const composition = checkOperatedSlots(cfg.operatedSlots)
  if (!composition.ok) {
    // §5.2's constraints are enforced on chain for what the registry can see, which is the provider tag.
    // A harness running two seats on one provider behind different tags would satisfy the registry and
    // quietly weaken the six-of-ten threshold, so it is refused here.
    for (const p of composition.problems) log('board composition problem', p)
    process.exitCode = 1
    return
  }

  if (command === 'check') {
    buildBoard({ slots: cfg.operatedSlots }) // throws on a missing credential
    log('configuration valid', {
      operatedSlots: cfg.operatedSlots,
      phase: cfg.operatedSlots.length === 10 ? 'one (team operates all ten)' : 'two (independent operator)',
      providers: composition.providers,
      openWeights: composition.openWeights,
      registry: cfg.addresses.saine,
      chainId: cfg.chainId,
    })
    return
  }

  const reader = ChainReader.fromRpc(cfg.rpcUrl, cfg.addresses)
  const relayer = ViemRelayer.fromKey(cfg.rpcUrl, cfg.relayerKey, cfg.addresses)

  if (command === 'keep') {
    const publicClient = createPublicClient({ transport: http(cfg.rpcUrl) })
    const wallet = createWalletClient({
      account: privateKeyToAccount(cfg.relayerKey),
      transport: http(cfg.rpcUrl),
    })
    const actions = await runKeeperPass({
      reader: publicClient,
      wallet,
      targets: {
        saine: cfg.addresses.saine,
        dcode: process.env.SAINE_DCODE_ADDRESS as `0x${string}`,
        governor: cfg.addresses.governor,
        oracle: process.env.SAINE_ORACLE_ADDRESS as `0x${string}`,
        receiver: process.env.SAINE_RECEIVER_ADDRESS as `0x${string}`,
      },
      log,
    })
    log('keeper pass complete', actions)
    return
  }

  if (command !== 'watch') {
    log('unknown command', { command, expected: ['watch', 'keep', 'check'] })
    process.exitCode = 2
    return
  }

  const orchestrator: OrchestratorDeps = {
    board: buildBoard({ slots: cfg.operatedSlots }),
    store: new FileAttestationStore(process.env.SAINE_STATE_DIR ?? './.saine-state'),
    pinner: cfg.ipfsApiUrl !== undefined ? new KuboPinner({ apiUrl: cfg.ipfsApiUrl }) : new NullPinner(),
    relayer,
    domain: cfg.domain,
    keys: (slot) => {
      const k = cfg.slotKeys.get(slot)
      if (k === undefined) throw new Error(`no keys configured for slot ${slot}`)
      return k
    },
    buildPackage: async (ctx) => {
      const built = await buildAdjudicationPackage(
        {
          reader,
          manifests: new GatewayManifestFetcher(process.env.SAINE_IPFS_GATEWAY ?? 'https://ipfs.io'),
          sources: new SourcifySourceFetcher(
            process.env.SAINE_SOURCIFY_URL ?? 'https://sourcify.dev/server',
            cfg.chainId,
          ),
          history: { priorRounds: async () => [] },
          timelock: process.env.SAINE_TIMELOCK_ADDRESS as `0x${string}`,
          log,
        },
        { roundId: ctx.roundId, kind: ctx.kind, subject: ctx.subject },
      )
      return {
        pkg: built.pkg,
        render: { validation: built.validation, targetsFlagged: built.targetsFlagged },
      }
    },
    // Unpredictable before the round opens, identical across all ten slots within it, so the prose fence
    // cannot be closed by its author and every seat still evaluates the same artefacts.
    packageSalt: (ctx) => keccak256(toHex(`${cfg.addresses.saine}:${ctx.roundId}:${ctx.subject}`)),
    log: (e) => log('orchestrator', e),
  }

  const deps: WatchDeps = { reader, orchestrator, log }
  const controller = new AbortController()
  for (const sig of ['SIGINT', 'SIGTERM'] as const) {
    process.on(sig, () => {
      log('shutting down after the current pass', { signal: sig })
      controller.abort()
    })
  }

  log('watching', { registry: cfg.addresses.saine, intervalMs: cfg.pollIntervalMs })
  await runWatchLoop(deps, { intervalMs: cfg.pollIntervalMs, signal: controller.signal })
}

main().catch((err: unknown) => {
  log('fatal', String(err))
  process.exitCode = 1
})
