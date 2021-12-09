# beacon_chain
# Copyright (c) 2021, 2022 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import chronicles
import ../beacon_node,
       ./rest_utils

logScope: topics = "rest_light_client"

proc installLightClientApiHandlers*(router: var RestRouter, node: BeaconNode) =
  let altairStartSlot =
    compute_start_slot_at_epoch(node.dag.cfg.ALTAIR_FORK_EPOCH)

  # https://github.com/ChainSafe/lodestar/blob/22c2667d5/packages/api/src/routes/lightclient.ts#L62
  router.api(MethodGet,
             "/eth/v1/lightclient/committee_updates") do (
    `from`, to: Option[SyncCommitteePeriod]) -> RestApiResponse:
    let vfrom = block:
      if `from`.isNone():
        return RestApiResponse.jsonError(Http400, MissingFromValueError)
      let rfrom = `from`.get()
      if rfrom.isErr():
        return RestApiResponse.jsonError(Http400, InvalidSyncPeriodError,
                                         $rfrom.error())
      rfrom.get()
    let vto = block:
      if to.isNone():
        return RestApiResponse.jsonError(Http400, MissingToValueError)
      let rto = to.get()
      if rto.isErr():
        return RestApiResponse.jsonError(Http400, InvalidSyncPeriodError,
                                         $rto.error())
      rto.get()
    let
      minPeriod = vfrom
      maxPeriod = min(vto, node.dag.head.slot.sync_committee_period)
    if maxPeriod < minPeriod:
      return RestApiResponse.jsonResponse(newSeq[LightClientUpdate](0))

    let startTick = Moment.now()
    const maxPeriodsPerRequest = 128
    let numPeriods = maxPeriod - minPeriod + 1
    var updates = newSeqOfCap[LightClientUpdate](numPeriods)
    for period in minPeriod .. maxPeriod:
      let update = node.dag.getBestLightClientUpdateForPeriod(period)
      if update.isSome:
        updates.add update.get
        if updates.len >= maxPeriodsPerRequest:
          break
      if Moment.now() - startTick > 10.seconds:
        break
    return RestApiResponse.jsonResponse(updates)

  # https://github.com/ChainSafe/lodestar/blob/22c2667d5/packages/api/src/routes/lightclient.ts#L63
  router.api(MethodGet,
             "/eth/v1/lightclient/head_update/") do () -> RestApiResponse:
    let update = node.dag.getLatestLightClientUpdate
    if update.isNone:
      return RestApiResponse.jsonError(Http404,
                                       LightClientHeaderUpdateUnavailable)
    return RestApiResponse.jsonResponse(update.get)

  # https://github.com/ChainSafe/lodestar/blob/22c2667d5/packages/api/src/routes/lightclient.ts#L64
  router.api(MethodGet,
             "/eth/v1/lightclient/snapshot/{block_root}") do (
    block_root: Eth2Digest) -> RestApiResponse:
    let vroot = block:
      if block_root.isErr():
        return RestApiResponse.jsonError(Http400, InvalidBlockRootValueError,
                                         $block_root.error())
      block_root.get()
    let blockRef = node.dag.getRef(vroot)
    if blockRef == nil or
        blockRef.slot > node.dag.finalizedHead.slot or
        blockRef.slot < node.dag.tail.slot or
        blockRef.slot < altairStartSlot:
      return RestApiResponse.jsonError(Http404, LightClientSnapshotUnavailable)
    node.withStateForBlockSlot(blockRef.atSlot(blockRef.slot)):
      withStateAndBlck(stateData.data, node.dag.get(blck).data):
        when stateFork >= BeaconStateFork.Altair:
          return RestApiResponse.jsonResponse(RestLightClientSnapshot(
            header: BeaconBlockHeader(
              slot: blck.message.slot,
              proposer_index: blck.message.proposer_index,
              parent_root: blck.message.parent_root,
              state_root: blck.message.state_root,
              body_root: blck.message.body.hash_tree_root()),
            current_sync_committee:
              state.data.current_sync_committee,
            current_sync_committee_branch:
              build_proof(state.data, CURRENT_SYNC_COMMITTEE_INDEX).get))
        else: raiseAssert "Unreachable"
    return RestApiResponse.jsonError(Http500, InternalServerError,
                                     "Block retrieval failed")
