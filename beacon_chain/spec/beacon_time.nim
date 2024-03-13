# beacon_chain
# Copyright (c) 2018-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  std/[hashes, typetraits],
  results,
  chronicles,
  chronos/timer,
  json_serialization,
  ./presets

export hashes, timer, json_serialization, presets

# A collection of time units that permeate the spec - common to all of them is
# that they expressed relative to the genesis of the chain at varying
# granularities:
#
# * BeaconTime - nanoseconds since genesis
# * Slot - SLOTS_PER_SECOND seconds since genesis
# * Epoch - EPOCHS_PER_SLOT slots since genesis
# * SyncCommitteePeriod - EPOCHS_PER_SYNC_COMMITTEE_PERIOD epochs since genesis

type
  TimeDiff* = object
    nanoseconds*: int64
    ## Difference between two points in time with nanosecond granularity
    ## Can be negative (unlike timer.Duration)

  SlotTimes* = object
    SECONDS_PER_SLOT*: uint64

  BeaconTime* = object
    ## A point in time, relative to the genesis of the chain
    ##
    ## Implemented as nanoseconds since genesis - negative means before
    ## the chain started.
    slotTimes*: SlotTimes
    ns_since_genesis*: int64

const
  # Earlier spec versions had these at a different slot
  GENESIS_SLOT* = Slot(0)
  GENESIS_EPOCH* = Epoch(0) # compute_epoch_at_slot(GENESIS_SLOT)

  # https://github.com/ethereum/consensus-specs/blob/v1.4.0-beta.7/specs/phase0/fork-choice.md#constant
  INTERVALS_PER_SLOT* = 3

  FAR_FUTURE_NS_SINCE_GENESIS = int64.high

template ethTimeUnit*(typ: type) {.dirty.} =
  func `+`*(x: typ, y: uint64): typ {.borrow.}
  func `-`*(x: typ, y: uint64): typ {.borrow.}
  func `-`*(x: uint64, y: typ): typ {.borrow.}

  # Not closed over type in question (Slot or Epoch)
  func `mod`*(x: typ, y: uint64): uint64 {.borrow.}
  func `div`*(x: typ, y: uint64): uint64 {.borrow.}
  func `div`*(x: uint64, y: typ): uint64 {.borrow.}
  func `-`*(x: typ, y: typ): uint64 {.borrow.}

  iterator countdown*(a, b: typ, step: Positive = 1): typ =
    # otherwise we use the signed version that breaks at the boundary
    for i in countdown(distinctBase(a), distinctBase(b), step):
      yield typ(i)

  func `*`*(x: typ, y: uint64): uint64 {.borrow.}

  func `+=`*(x: var typ, y: typ) {.borrow.}
  func `+=`*(x: var typ, y: uint64) {.borrow.}
  func `-=`*(x: var typ, y: typ) {.borrow.}
  func `-=`*(x: var typ, y: uint64) {.borrow.}

  # Comparison operators
  func `<`*(x: typ, y: typ): bool {.borrow.}
  func `<`*(x: typ, y: uint64): bool {.borrow.}
  func `<`*(x: uint64, y: typ): bool {.borrow.}
  func `<=`*(x: typ, y: typ): bool {.borrow.}
  func `<=`*(x: typ, y: uint64): bool {.borrow.}
  func `<=`*(x: uint64, y: typ): bool {.borrow.}

  func `==`*(x: typ, y: typ): bool {.borrow.}
  func `==`*(x: typ, y: uint64): bool {.borrow.}
  func `==`*(x: uint64, y: typ): bool {.borrow.}

  # Nim integration
  func `$`*(x: typ): string {.borrow.}
  func hash*(x: typ): Hash {.borrow.}

  template asUInt64*(v: typ): uint64 = distinctBase(v)
  template shortLog*(v: typ): auto = distinctBase(v)

  # Serialization
  proc writeValue*(writer: var JsonWriter, value: typ) {.raises: [IOError].} =
    writeValue(writer, uint64 value)

  proc readValue*(reader: var JsonReader, value: var typ)
                 {.raises: [IOError, SerializationError].} =
    value = typ reader.readValue(uint64)

ethTimeUnit Slot
ethTimeUnit Epoch
ethTimeUnit SyncCommitteePeriod

template `<`*(a, b: BeaconTime): bool =
  a.ns_since_genesis < b.ns_since_genesis
template `<=`*(a, b: BeaconTime): bool =
  a.ns_since_genesis <= b.ns_since_genesis
template `<`*(a, b: TimeDiff): bool =
  a.nanoseconds < b.nanoseconds
template `<=`*(a, b: TimeDiff): bool =
  a.nanoseconds <= b.nanoseconds
template `<`*(a: TimeDiff, b: Duration): bool =
  a.nanoseconds < b.nanoseconds

func init*(
    t: typedesc[SlotTimes], SECONDS_PER_SLOT: uint64): Opt[SlotTimes] =
  if SECONDS_PER_SLOT == 0 or
      SECONDS_PER_SLOT > int64.high.uint64 div 1_000_000_000'u64:
    return Opt.none SlotTimes
  Opt.some SlotTimes(
    SECONDS_PER_SLOT: SECONDS_PER_SLOT)

func NANOSECONDS_PER_SLOT*(slotTimes: SlotTimes): uint64 =
  slotTimes.SECONDS_PER_SLOT * 1_000_000_000'u64

# Offsets from the slot start to when the corresponding message should be sent

# https://github.com/ethereum/consensus-specs/blob/v1.4.0-beta.7/specs/phase0/validator.md#attesting
func attestationSlotOffset*(slotTimes: SlotTimes): TimeDiff =
  TimeDiff(nanoseconds:
    slotTimes.NANOSECONDS_PER_SLOT.int64 div INTERVALS_PER_SLOT)

# https://github.com/ethereum/consensus-specs/blob/v1.4.0-beta.7/specs/phase0/validator.md#broadcast-aggregate
func aggregateSlotOffset*(slotTimes: SlotTimes): TimeDiff =
  TimeDiff(nanoseconds:
    slotTimes.NANOSECONDS_PER_SLOT.int64 * 2 div INTERVALS_PER_SLOT)

# https://github.com/ethereum/consensus-specs/blob/v1.4.0-beta.7/specs/altair/validator.md#prepare-sync-committee-message
func syncCommitteeMessageSlotOffset*(slotTimes: SlotTimes): TimeDiff =
  TimeDiff(nanoseconds:
    slotTimes.NANOSECONDS_PER_SLOT.int64 div INTERVALS_PER_SLOT)

# https://github.com/ethereum/consensus-specs/blob/v1.4.0-beta.7/specs/altair/validator.md#broadcast-sync-committee-contribution
func syncContributionSlotOffset*(slotTimes: SlotTimes): TimeDiff =
  TimeDiff(nanoseconds:
    slotTimes.NANOSECONDS_PER_SLOT.int64 * 2 div INTERVALS_PER_SLOT)

# https://github.com/ethereum/consensus-specs/blob/v1.4.0-beta.7/specs/altair/light-client/p2p-interface.md#sync-committee
func lightClientFinalityUpdateSlotOffset*(slotTimes: SlotTimes): TimeDiff =
  TimeDiff(nanoseconds:
    slotTimes.NANOSECONDS_PER_SLOT.int64 div INTERVALS_PER_SLOT)

# https://github.com/ethereum/consensus-specs/blob/v1.4.0-beta.7/specs/altair/light-client/p2p-interface.md#sync-committee
func lightClientOptimisticUpdateSlotOffset*(slotTimes: SlotTimes): TimeDiff =
  TimeDiff(nanoseconds:
    slotTimes.NANOSECONDS_PER_SLOT.int64 div INTERVALS_PER_SLOT)

func toSlot*(t: BeaconTime): tuple[afterGenesis: bool, slot: Slot] =
  if t.ns_since_genesis == FAR_FUTURE_NS_SINCE_GENESIS:
    (
      true,
      FAR_FUTURE_SLOT
    )
  elif t.ns_since_genesis >= 0:
    (
      true,
      Slot(uint64(t.ns_since_genesis) div t.slotTimes.NANOSECONDS_PER_SLOT)
    )
  else:
    (
      false,
      Slot(uint64(-t.ns_since_genesis) div t.slotTimes.NANOSECONDS_PER_SLOT)
    )

template `+`*(t: BeaconTime, offset: Duration | TimeDiff): BeaconTime =
  BeaconTime(
    slotTimes: t.slotTimes,
    ns_since_genesis: t.ns_since_genesis + offset.nanoseconds)

template `-`*(t: BeaconTime, offset: Duration | TimeDiff): BeaconTime =
  BeaconTime(
    slotTimes: t.slotTimes,
    ns_since_genesis: t.ns_since_genesis - offset.nanoseconds)

template `-`*(a, b: BeaconTime): TimeDiff =
  TimeDiff(nanoseconds: a.ns_since_genesis - b.ns_since_genesis)

template `+`*(a: TimeDiff, b: Duration): TimeDiff =
  TimeDiff(nanoseconds: a.nanoseconds + b.nanoseconds)

func toFloatSeconds*(t: TimeDiff): float =
  float(t.nanoseconds) / 1_000_000_000.0

func start_beacon_time*(
    s: Slot, slotTimes: SlotTimes): BeaconTime =
  # The point in time that a slot begins
  let maxSlot = Slot(
    uint64(FAR_FUTURE_NS_SINCE_GENESIS) div slotTimes.NANOSECONDS_PER_SLOT)
  BeaconTime(
    slotTimes: slotTimes,
    ns_since_genesis:
      if s > maxSlot:
        FAR_FUTURE_NS_SINCE_GENESIS
      else:
        int64(uint64(s) * slotTimes.NANOSECONDS_PER_SLOT))

func block_deadline*(
    s: Slot, slotTimes: SlotTimes): BeaconTime =
  s.start_beacon_time(slotTimes)

func attestation_deadline*(
    s: Slot, slotTimes: SlotTimes): BeaconTime =
  s.start_beacon_time(slotTimes) +
  slotTimes.attestationSlotOffset

func aggregate_deadline*(
    s: Slot, slotTimes: SlotTimes): BeaconTime =
  s.start_beacon_time(slotTimes) +
  slotTimes.aggregateSlotOffset

func sync_committee_message_deadline*(
    s: Slot, slotTimes: SlotTimes): BeaconTime =
  s.start_beacon_time(slotTimes) +
  slotTimes.syncCommitteeMessageSlotOffset

func sync_contribution_deadline*(
    s: Slot, slotTimes: SlotTimes): BeaconTime =
  s.start_beacon_time(slotTimes) +
  slotTimes.syncContributionSlotOffset

func light_client_finality_update_time*(
    s: Slot, slotTimes: SlotTimes): BeaconTime =
  s.start_beacon_time(slotTimes) +
  slotTimes.lightClientFinalityUpdateSlotOffset

func light_client_optimistic_update_time*(
    s: Slot, slotTimes: SlotTimes): BeaconTime =
  s.start_beacon_time(slotTimes) +
  slotTimes.lightClientOptimisticUpdateSlotOffset

func slotOrZero*(time: BeaconTime): Slot =
  let exSlot = time.toSlot()
  if exSlot.afterGenesis: exSlot.slot
  else: Slot(0)

# https://github.com/ethereum/consensus-specs/blob/v1.4.0-beta.6/specs/phase0/beacon-chain.md#compute_epoch_at_slot
func epoch*(slot: Slot): Epoch = # aka compute_epoch_at_slot
  ## Return the epoch number at ``slot``.
  if slot == FAR_FUTURE_SLOT: FAR_FUTURE_EPOCH
  else: Epoch(slot div SLOTS_PER_EPOCH)

# https://github.com/ethereum/consensus-specs/blob/v1.4.0-beta.7/specs/phase0/fork-choice.md#compute_slots_since_epoch_start
func since_epoch_start*(slot: Slot): uint64 = # aka compute_slots_since_epoch_start
  ## How many slots since the beginning of the epoch (`[0..SLOTS_PER_EPOCH-1]`)
  (slot mod SLOTS_PER_EPOCH)

template is_epoch*(slot: Slot): bool =
  slot.since_epoch_start == 0

# https://github.com/ethereum/consensus-specs/blob/v1.4.0-beta.7/specs/phase0/beacon-chain.md#compute_start_slot_at_epoch
func start_slot*(epoch: Epoch): Slot = # aka compute_start_slot_at_epoch
  ## Return the start slot of ``epoch``.
  const maxEpoch = Epoch(FAR_FUTURE_SLOT div SLOTS_PER_EPOCH)
  if epoch >= maxEpoch: FAR_FUTURE_SLOT
  else: Slot(epoch * SLOTS_PER_EPOCH)

# https://github.com/ethereum/consensus-specs/blob/v1.4.0-beta.6/specs/phase0/beacon-chain.md#get_previous_epoch
func get_previous_epoch*(current_epoch: Epoch): Epoch =
  ## Return the previous epoch (unless the current epoch is ``GENESIS_EPOCH``).
  if current_epoch == GENESIS_EPOCH:
    current_epoch
  else:
    current_epoch - 1

iterator slots*(epoch: Epoch): Slot =
  let start_slot = start_slot(epoch)
  for slot in start_slot ..< start_slot + SLOTS_PER_EPOCH:
    yield slot

# https://github.com/ethereum/consensus-specs/blob/v1.4.0-beta.7/specs/altair/validator.md#sync-committee
template sync_committee_period*(epoch: Epoch): SyncCommitteePeriod =
  if epoch == FAR_FUTURE_EPOCH: FAR_FUTURE_PERIOD
  else: SyncCommitteePeriod(epoch div EPOCHS_PER_SYNC_COMMITTEE_PERIOD)

template sync_committee_period*(slot: Slot): SyncCommitteePeriod =
  if slot == FAR_FUTURE_SLOT: FAR_FUTURE_PERIOD
  else: SyncCommitteePeriod(slot div SLOTS_PER_SYNC_COMMITTEE_PERIOD)

func since_sync_committee_period_start*(slot: Slot): uint64 =
  ## How many slots since the beginning of the epoch (`[0..SLOTS_PER_SYNC_COMMITTEE_PERIOD-1]`)
  (slot mod SLOTS_PER_SYNC_COMMITTEE_PERIOD)

func since_sync_committee_period_start*(epoch: Epoch): uint64 =
  ## How many slots since the beginning of the epoch (`[0..EPOCHS_PER_SYNC_COMMITTEE_PERIOD-1]`)
  (epoch mod EPOCHS_PER_SYNC_COMMITTEE_PERIOD)

template is_sync_committee_period*(slot: Slot): bool =
  slot.since_sync_committee_period_start() == 0

template is_sync_committee_period*(epoch: Epoch): bool =
  epoch.since_sync_committee_period_start() == 0

template start_epoch*(period: SyncCommitteePeriod): Epoch =
  ## Return the start epoch of ``period``.
  const maxPeriod = SyncCommitteePeriod(
    FAR_FUTURE_EPOCH div EPOCHS_PER_SYNC_COMMITTEE_PERIOD)
  if period >= maxPeriod: FAR_FUTURE_EPOCH
  else: Epoch(period * EPOCHS_PER_SYNC_COMMITTEE_PERIOD)

template start_slot*(period: SyncCommitteePeriod): Slot =
  ## Return the start slot of ``period``.
  const maxPeriod = SyncCommitteePeriod(
    FAR_FUTURE_SLOT div SLOTS_PER_SYNC_COMMITTEE_PERIOD)
  if period >= maxPeriod: FAR_FUTURE_SLOT
  else: Slot(period * SLOTS_PER_SYNC_COMMITTEE_PERIOD)

func proposer_dependent_slot*(epoch: Epoch): Slot =
  if epoch >= 1: epoch.start_slot() - 1 else: Slot(0)

func attester_dependent_slot*(epoch: Epoch): Slot =
  if epoch >= 2: (epoch - 1).start_slot() - 1 else: Slot(0)

func `$`*(t: BeaconTime): string =
  if t.ns_since_genesis >= 0:
    $(timer.nanoseconds(t.ns_since_genesis))
  else:
    "-" & $(timer.nanoseconds(-t.ns_since_genesis))

func `$`*(t: TimeDiff): string =
  if t.nanoseconds >= 0:
    $(timer.nanoseconds(t.nanoseconds))
  else:
    "-" & $(timer.nanoseconds(-t.nanoseconds))

func shortLog*(t: BeaconTime | TimeDiff): string = $t

chronicles.formatIt BeaconTime: it.shortLog
chronicles.formatIt TimeDiff: it.shortLog
chronicles.formatIt Slot: it.shortLog
chronicles.formatIt Epoch: it.shortLog
chronicles.formatIt SyncCommitteePeriod: it.shortLog

const defaultSyncHorizon* =
  (uint64(10*60) + SECONDS_PER_SLOT - 1) div SECONDS_PER_SLOT
