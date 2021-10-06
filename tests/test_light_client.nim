# beacon_chain
# Copyright (c) 2021, 2022 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.used.}

import
  # Standard library
  algorithm,
  # Status libraries
  chronicles, eth/keys, taskpools,
  # Beacon chain internals
  ../beacon_chain/consensus_object_pools/
    [block_clearance, block_quarantine, blockchain_dag],
  ../beacon_chain/spec/[forks, helpers, light_client_sync, state_transition],
  # Test utilities
  ./testutil, ./testdbutil

suite "Light Client" & preset():
  let
    cfg = block:
      var res = defaultRuntimeConfig
      res.ALTAIR_FORK_EPOCH = GENESIS_EPOCH + 1
      res
    altairStartSlot = compute_start_slot_at_epoch(cfg.ALTAIR_FORK_EPOCH)

  proc advanceToSlot(
      dag: ChainDAGRef,
      targetSlot: Slot,
      verifier: var BatchVerifier,
      quarantine: var Quarantine,
      attested = true,
      syncCommitteeRatio = 0.75) =
    var cache: StateCache
    const maxAttestedSlotsPerPeriod = 3 * SLOTS_PER_EPOCH
    while true:
      var slot = getStateField(dag.headState.data, slot)
      doAssert targetSlot >= slot
      if targetSlot == slot: break

      # When there is a large jump, skip to the end of the current period,
      # create blocks for a few epochs to finalize it, then proceed.
      let
        nextPeriod = slot.sync_committee_period + 1
        periodEpoch = compute_start_epoch_at_sync_committee_period(nextPeriod)
        periodSlot = compute_start_slot_at_epoch(periodEpoch)
        checkpointSlot = periodSlot - maxAttestedSlotsPerPeriod
      if targetSlot > checkpointSlot:
        var info: ForkedEpochInfo
        doAssert process_slots(cfg, dag.headState.data, checkpointSlot,
                               cache, info, flags = {})
        slot = checkpointSlot

      # Create blocks for final few epochs.
      let blocks = min(targetSlot - slot, maxAttestedSlotsPerPeriod)
      for blck in makeTestBlocks(dag.headState.data, cache, blocks.int,
                                 attested, syncCommitteeRatio, cfg):
        let added =
          case blck.kind
          of BeaconBlockFork.Phase0:
            const nilCallback = OnPhase0BlockAdded(nil)
            dag.addHeadBlock(verifier, blck.phase0Data, nilCallback)
          of BeaconBlockFork.Altair:
            const nilCallback = OnAltairBlockAdded(nil)
            dag.addHeadBlock(verifier, blck.altairData, nilCallback)
          of BeaconBlockFork.Merge:
            const nilCallback = OnMergeBlockAdded(nil)
            dag.addHeadBlock(verifier, blck.mergeData, nilCallback)
        check: added.isOk()
        dag.updateHead(added[], quarantine)

  setup:
    const num_validators = SLOTS_PER_EPOCH
    let
      validatorMonitor = newClone(ValidatorMonitor.init())
      dag = ChainDAGRef.init(
        cfg, makeTestDB(num_validators), validatorMonitor, {},
        createLightClientData = true)
      quarantine = newClone(Quarantine.init())
      taskpool = TaskPool.new()
    var verifier = BatchVerifier(rng: keys.newRng(), taskpool: taskpool)

  test "Pre-Altair":
    # Genesis.
    check:
      dag.headState.data.kind == BeaconStateFork.Phase0
      dag.getBestLightClientUpdateForPeriod(0.SyncCommitteePeriod).isNone
      dag.getLatestFinalizedLightClientUpdate.isNone
      dag.getLatestNonFinalizedLightClientUpdate.isNone

    # Advance to last slot before Altair.
    dag.advanceToSlot(altairStartSlot - 1, verifier, quarantine[])
    check:
      dag.headState.data.kind == BeaconStateFork.Phase0
      dag.getBestLightClientUpdateForPeriod(0.SyncCommitteePeriod).isNone
      dag.getLatestFinalizedLightClientUpdate.isNone
      dag.getLatestNonFinalizedLightClientUpdate.isNone

    # Advance to Altair.
    dag.advanceToSlot(altairStartSlot, verifier, quarantine[])
    check:
      dag.headState.data.kind == BeaconStateFork.Altair
      dag.getBestLightClientUpdateForPeriod(0.SyncCommitteePeriod).isNone
      dag.getLatestFinalizedLightClientUpdate.isNone
      dag.getLatestNonFinalizedLightClientUpdate.isNone

  test "Light client sync":
    # Advance to Altair.
    dag.advanceToSlot(altairStartSlot, verifier, quarantine[])

    # Initialize light client.
    let genesis_validators_root = dag.genesisValidatorsRoot
    var store = block:
      let snapshot =
        withStateAndBlck(dag.headState.data, dag.get(dag.headState.blck).data):
          when stateFork >= BeaconStateFork.Altair:
            LightClientSnapshot(
              current_sync_committee: state.data.current_sync_committee,
              next_sync_committee: state.data.next_sync_committee)
          else: raiseAssert "Unreachable"
      LightClientStore(snapshot: snapshot)

    # Advance to target slot.
    const
      headPeriod = 2.SyncCommitteePeriod
      periodEpoch = compute_start_epoch_at_sync_committee_period(headPeriod)
      headSlot = compute_start_slot_at_epoch(periodEpoch + 2) + 5
    dag.advanceToSlot(headSlot, verifier, quarantine[])
    let currentSlot = getStateField(dag.headState.data, slot)

    # Sync to latest sync committee period.
    while store.snapshot.header.slot.sync_committee_period + 1 < headPeriod:
      let
        nextPeriod = store.snapshot.header.slot.sync_committee_period + 1
        bestUpdate = dag.getBestLightClientUpdateForPeriod(nextPeriod)
      check:
        bestUpdate.isSome
        bestUpdate.get.header.slot.sync_committee_period == nextPeriod
        process_light_client_update(
          store, bestUpdate.get, currentSlot, genesis_validators_root)
        store.snapshot.header == bestUpdate.get.header

    # Sync to latest finalized update.
    var latestFinalized = dag.getLatestFinalizedLightClientUpdate
    check:
      latestFinalized.isSome
      latestFinalized.get.header.slot == dag.finalizedHead.blck.slot
      process_light_client_update(
        store, latestFinalized.get, currentSlot, genesis_validators_root)
      store.snapshot.header == latestFinalized.get.header

    # Sync to latest non-finalized update.
    var latestNonFinalized = dag.getLatestNonFinalizedLightClientUpdate
    check: latestNonFinalized.isSome
    latestNonFinalized.get.next_sync_committee = SyncCommittee()
    latestNonFinalized.get.next_sync_committee_branch.fill(Eth2Digest())
    check:
      latestNonFinalized.get.header.slot == dag.headState.blck.parent.slot
      process_light_client_update(
        store, latestNonFinalized.get, currentSlot, genesis_validators_root)
      store.snapshot.header == latestFinalized.get.header
      store.valid_updates.len == 1
      latestNonFinalized.get in store.valid_updates
