# beacon_chain
# Copyright (c) 2022-2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [], gcsafe.}

import
  chronicles, web3/engine_api_types,
  ./beacon_node

logScope: topics = "beacnde"

func shouldSyncViaLightClient*(node: BeaconNode, wallSlot: Slot): bool =
  let optimisticHeader = node.lightClient.optimisticHeader
  withForkyHeader(optimisticHeader):
    when lcDataFork > LightClientDataFork.None:
      shouldSyncViaLightClient(
        lightClientSlot = forkyHeader.beacon.slot,
        dagSlot = node.dag.headState.slot,
        wallSlot = wallSlot)
    else:
      false

proc initLightClient*(
    node: BeaconNode,
    rng: ref HmacDrbgContext,
    cfg: RuntimeConfig,
    forkDigests: ref ForkDigests,
    getBeaconTime: GetBeaconTimeFn,
    genesis_validators_root: Eth2Digest) =
  template config(): auto = node.config

  # Creating a light client is not dependent on `syncLightClient`
  # because the light client module also handles gossip subscriptions
  # for broadcasting light client data as a server.

  let
    lightEnvelopeHandler = proc(
        signedEnvelope: gloas.SignedExecutionPayloadEnvelope
    ): Future[void] {.async: (raises: [CancelledError]).} =
      if node.elManager == nil:
        return
      if signedEnvelope.message.payload.block_hash.isZero:
        return
      discard await node.elManager.newPayload(
        signedEnvelope.message,
        deadline = sleepAsync(NEWPAYLOAD_TIMEOUT), retry = true)

    lightBlockHandler = proc(
        signedBlock: ForkedSignedBeaconBlock
    ): Future[void] {.async: (raises: [CancelledError]).} =
      withBlck(signedBlock):
        when consensusFork >= ConsensusFork.Gloas:
          discard
        elif consensusFork >= ConsensusFork.Bellatrix:
          if forkyBlck.message.is_execution_block:
            template payload(): auto = forkyBlck.message.body.execution_payload
            if not payload.block_hash.isZero:
              discard await node.elManager.newExecutionPayload(
                forkyBlck.message)
          else: discard
    lightBlockProcessor = initLightBlockProcessor(
      cfg.timeParams, getBeaconTime, lightBlockHandler)
    lightEnvelopeProcessor = initLightEnvelopeProcessor(
      cfg.timeParams, getBeaconTime, lightEnvelopeHandler)

    shouldInhibitSync = func(): bool =
      if isNil(node.syncOverseer):
        false
      else:
        not node.syncOverseer.syncInProgress  # No LC sync needed if DAG in sync
    lightClient = createLightClient(
      node.network, rng, config, cfg, forkDigests, getBeaconTime,
      genesis_validators_root, LightClientFinalizationMode.Strict,
      shouldInhibitSync = shouldInhibitSync)

  if config.syncLightClient:
    proc onOptimisticHeader(
        lightClient: LightClient,
        optimisticHeader: ForkedLightClientHeader) =
      if node.lightClientFcuFut != nil:
        return
      withForkyHeader(optimisticHeader):
        when lcDataFork > LightClientDataFork.None:
          let bid = forkyHeader.beacon.toBlockId()
          logScope:
            opt = bid
            dag = node.dag.head.bid
            wallSlot = node.currentSlot
          when lcDataFork >= LightClientDataFork.Capella:
            let
              consensusFork = node.dag.cfg.consensusForkAtEpoch(bid.slot.epoch)
              blockHash = forkyHeader.execution_block_hash

            # Retain light client head for other `forkchoiceUpdated` callers.
            # May temporarily block `forkchoiceUpdated` calls, e.g., Geth:
            # - Refuses `newPayload`: "Ignoring payload while snap syncing"
            # - Refuses `fcU`: "Forkchoice requested unknown head"
            # Once DAG sync catches up or as new light client heads are fetched
            # the situation recovers
            debug "New LC optimistic header"
            node.consensusManager[].setLightClientHead(bid, blockHash)
            if not node.consensusManager[]
                .shouldSyncViaLightClient(node.currentSlot):
              return

            # engine_forkchoiceUpdated
            let beaconHead = node.attestationPool[].getBeaconHead(nil)
            withConsensusFork(consensusFork):
              when lcDataForkAtConsensusFork(consensusFork) == lcDataFork:
                let state = ForkchoiceStateV1.init(
                  blockHash, beaconHead.safeExecutionBlockHash,
                  beaconHead.finalizedExecutionBlockHash,
                )
                node.lightClientFcuFut = node.elManager.forkchoiceUpdated(
                  state, payloadAttributes = Opt.none consensusFork.PayloadAttributes
                )
                node.lightClientFcuFut.addCallback do(future: pointer):
                  node.lightClientFcuFut = nil
          else:
            # The execution block hash is only available from Capella onward
            info "Ignoring new LC optimistic header until Capella"

    proc onFinalizedHeader(
        lightClient: LightClient,
        finalizedHeader: ForkedLightClientHeader) =
      if not node.consensusManager[].shouldSyncViaLightClient(node.currentSlot):
        return

      node.eventBus.optFinHeaderUpdateQueue.emit(finalizedHeader)

    lightClient.onOptimisticHeader = onOptimisticHeader
    lightClient.onFinalizedHeader = onFinalizedHeader
    lightClient.trustedBlockRoot = config.trustedBlockRoot

  elif config.trustedBlockRoot.isSome:
    warn "Ignoring `trustedBlockRoot`, light client not enabled",
      syncLightClient = config.syncLightClient,
      trustedBlockRoot = config.trustedBlockRoot

  node.lightBlockProcessor = lightBlockProcessor
  node.lightEnvelopeProcessor = lightEnvelopeProcessor
  node.lightClient = lightClient

proc startLightClient*(node: BeaconNode) =
  if not node.config.syncLightClient:
    return

  node.lightClient.start()

proc installLightClientMessageValidators*(node: BeaconNode) =
  let eth2Processor =
    if node.config.lightClientDataServe:
      # Process gossip using both full node and light client
      node.processor
    elif node.config.syncLightClient:
      # Only process gossip using light client
      nil
    else:
      # Light client topics will never be subscribed to, no validators needed
      return

  node.lightClient.installMessageValidators(eth2Processor)

proc updateLightClientGossipStatus*(
    node: BeaconNode, slot: Slot, dagIsBehind: bool) =
  let isBehind =
    if node.config.lightClientDataServe:
      # Forward DAG's readiness to handle light client gossip
      dagIsBehind
    else:
      # Full node is not interested in gossip
      true

  node.lightClient.updateGossipStatus(slot, some isBehind)

proc updateLightClientFromDag*(node: BeaconNode) =
  if node.config.trustedBlockRoot.isSome:
    return
  if not node.config.syncLightClient:
    return
  if node.dag.finalizedHead.slot < node.dag.cfg.ALTAIR_FORK_EPOCH.start_slot:
    return

  let
    dagPeriod = node.dag.finalizedHead.slot.sync_committee_period
    lcHeader = node.lightClient.finalizedHeader
    lcInitialized = lcHeader.kind > LightClientDataFork.None
    lcPeriod = withForkyHeader(lcHeader):
      when lcDataFork > LightClientDataFork.None:
        forkyHeader.beacon.slot.sync_committee_period
      else:
        GENESIS_SLOT.sync_committee_period
  if lcInitialized and dagPeriod <= lcPeriod:
    return

  let dagUpdate = node.dag.lcDataStore.cache.latest
  withForkyFinalityUpdate(dagUpdate):
    when lcDataFork > LightClientDataFork.None:
      if forkyFinalityUpdate.finalized_header.beacon.slot
          .sync_committee_period == dagPeriod:
        let headPeriod = node.dag.head.slot.sync_committee_period
        if headPeriod == dagPeriod:
          let header = ForkedLightClientHeader.init(
            forkyFinalityUpdate.finalized_header)
          template current_sync_committee: lent SyncCommittee =
            withState(node.dag.headState):
              when consensusFork >= ConsensusFork.Altair:
                forkyState.data.current_sync_committee
              else:
                raiseAssert "Unreachable"
          node.lightClient.resetToFinalizedHeader(
            header, current_sync_committee)
          return

  let shouldBootstrap =
    if lcInitialized:
      dagPeriod > lcPeriod + 1
    else:
      node.lightClient.trustedBlockRoot.isNone
  if shouldBootstrap:
    node.lightClient.trustedBlockRoot =
      some(node.dag.finalizedHead.blck.root)
    node.lightClient.resetToFinalizedHeader(
      default(ForkedLightClientHeader), default(altair.SyncCommittee))
