# beacon_chain
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  stew/bitops2,
  ../consensus_object_pools/spec_cache,
  "."/[fork_choice_types, proto_array]

from ../consensus_object_pools/blockchain_dag import
  slashed, effective_balance, unslashed_balance, ForkChoiceInfoOffset

type SlotInfo = object
  blck: BlockRef
  support: Gwei
  equivocating: Gwei

template slot(info: SlotInfo): Slot =
  info.blck.slot

template root(info: SlotInfo): Eth2Digest =
  info.blck.root

func get_blocks_for_confirmation_info(
    blck: BlockRef, terminal_bid: BlockId,
    current_slot: Slot): seq[SlotInfo] =
  let low_slot = max(
    max((max(current_slot.epoch, 1.Epoch) - 1).start_slot, 1.Slot) - 1,
    terminal_bid.slot)
  result = newSeqOfCap[SlotInfo]((current_slot - low_slot + 1).int)

  # Add through everything including the latest block at low_slot
  var bs = blck.atSlot(current_slot)
  while bs.blck != nil and bs.slot > low_slot:
    result.add SlotInfo(blck: bs.blck)
    bs = bs.parentOrSlot
  while bs.blck != nil and not bs.isProposed:
    result.add SlotInfo(blck: bs.blck)
    bs = bs.parentOrSlot
  if bs.blck != nil:
    result.add SlotInfo(blck: bs.blck)

  # Ensure that we are descending from the terminal block
  while bs.blck != nil and bs.slot > terminal_bid.slot:
    bs = bs.parentOrSlot
  if bs.blck == nil or bs.blck.root != terminal_bid.root:
    result.reset()  # Terminal block is not canonical

type ConfirmationInfo = object
  blck: BlockRef

func get_confirmation_info(
    self: ForkChoiceBackend, balance_source: BalanceCheckpoint,
    blck: BlockRef, terminal_bid: BlockId,
    current_slot: Slot): seq[ConfirmationInfo] =
  var info = get_blocks_for_confirmation_info(blck, terminal_bid, current_slot)
  if info.len == 0:
    return @[]
  let low_slot = current_slot + 1 - info.lenu64

  template val_info: ValidatorInfo = balance_source.validators
  let
    num_vals = min(self.votes.len, val_info.balances.len)
    assigned_slots_start = [
      val_info.spliced_epochs[0].start_slot,
      val_info.spliced_epochs[1].start_slot]
  for val_index in 0 ..< num_vals:
    template validator: ForkChoiceBalance = val_info.balances[val_index]
    template vote: VoteTracker = self.votes[val_index]
    if vote.slot == FAR_FUTURE_SLOT:
      discard
    elif vote.slot >= low_slot:
      let i = current_slot - vote.slot
      if vote.slot > info[i].slot and vote.current_root == info[i].root:
        info[i].support += validator.unslashed_balance







type Index = fork_choice_types.Index

func get_ancestors(
    blck: BlockRef, terminal_root: Eth2Digest,
    current_slot: Slot): seq[BlockRef] =
  ## Return a list of ancestors of ``blck`` inclusive until
  ## ``terminal_root`` inclusive.
  if blck == nil:
    return @[]
  let
    high_slot = blck.slot
    low_slot = (max(current_slot.epoch, 1.Epoch) - 1).start_slot
  result = newSeqOfCap[BlockRef]((current_slot - low_slot + 1).int)
  var blck = blck
  for slot in countdown(current_slot, low_slot):
    result.add(blck)

    if blck.root == terminal_root:



func get_block_support(
    self: ForkChoiceBackend, balance_source: BalanceCheckpoint,
    blckRef: BlockRef, current_slot: Slot): array[2 * SLOTS_PER_EPOCH, int64] =
  let start_slot = (max(current_slot.epoch, 1.Epoch) - 1).start_slot
  var
    bids = newSeqOfCap[BlockId]((current_slot - start_slot + 1).int)
    bs = blckRef.atSlot(current_slot)
  while bs.blck != nil and bs.slot >= start_slot:
    bids.add bs.blck.bid
    bs = bs.parentOrSlot
  let low_slot = current_slot - bids.lenu64 + 1

  var support_in_empty_slots = newSeq[Gwei](bids.len)

  template val_info: ValidatorInfo = balance_source.validators
  let
    assigned_slots_start = [
      val_info.spliced_epochs[0].start_slot,
      val_info.spliced_epochs[1].start_slot]
    num_vals = min(self.votes.len, val_info.balances.len)
  for val_index in 0 ..< num_vals:
    template validator: ForkChoiceBalance = val_info.balances[val_index]
    template vote: VoteTracker = self.votes[val_index]
    if vote.slot in low_slot .. current_slot:
      let i = current_slot - vote.slot
      if vote.slot > bids[i].slot and vote.current_root == bids[i].root:
        support_in_empty_slots[i] += validator.unslashed_balance
    elif vote.slot == FAR_FUTURE_SLOT:
      i


const
  FirstAssignedSlotOffset = ForkChoiceInfoOffset + 1  # See blockchain_dag.nim
  SecondAssignedSlotOffset = EvenAssignedSlotOffset + SLOTS_PER_EPOCH.bitWidth
  AssignedSlotMask = (distinctBase(1.Gwei) shl SLOTS_PER_EPOCH.bitWidth) - 1
  SlotAssignmentsMask =
    (AssignedSlotMask shl FirstAssignedSlotOffset) or
    (AssignedSlotMask shl SecondAssignedSlotOffset)

template lastBit*(epoch: Epoch): int =
  (distinctBase(epoch) and 1'u64).int

template assigned_slot(
    balance: ForkChoiceBalance, offset: static range[0, 1]): uint64 =
  when offset == 0:
    (balance.uint64 shr FirstAssignedSlotOffset) and AssignedSlotMask
  else:
    (balance.uint64 shr SecondAssignedSlotOffset) and AssignedSlotMask

func splice_assigned_slots*(
    balances: var seq[ForkChoiceBalance], offset: int,
    shufflingRef: ShufflingRef) =
  for slot in shufflingRef.epoch.slots:
    let slot_mask = slot.since_epoch_start shl offset
    for committee_index in get_committee_indices(shufflingRef):
      for _, valIdx in shufflingRef.get_beacon_committee(slot, committee_index):
        if valIdx < balances.len.ValidatorIndex:
          balances[valIdx] = ForkChoiceBalance(
            balances[valIdx].uint64 or slot_mask)

func transfer_assigned_slots_to(
    src: seq[ForkChoiceBalance], dst: var seq[ForkChoiceBalance]) =
  let numValidators = min(src.len, dst.len)
  for valIdx in 0 ..< numValidators:
    dst[valIdx] = ForkChoiceBalance(
      (distinctBase(dst[valIdx]) and (not SlotAssignmentsMask)) or
      (distinctBase(src[valIdx]) and SlotAssignmentsMask))

func transfer_assigned_slots_to*(src: ValidatorInfo, dst: var ValidatorInfo) =
  src.balances.transfer_assigned_slots_to(dst.balances)
  dst.spliced_epochs = src.spliced_epochs
  dst.spliced_dependent_roots = src.spliced_dependent_roots

func get_block_support_between_slots(
    self: ForkChoiceBackend, balance_source: BalanceCheckpoint,
    block_root: Eth2Digest, slots: Slice[Slot]): Gwei =
  ## Return support of the block within ``slots``.
  for val_index, vote in self.votes:
    if val_index < balance_source.validators.balances.len and
        vote.slot in slots and vote.current_root == block_root:
      result += balance_source.validators.balances[val_index].unslashed_balance

func is_full_validator_set_covered(slots: Slice[Slot]): bool =
  ## Return ``true`` if the range within ``slots`` includes an entire epoch.
  let
    start_full_epoch = (slots.a + (SLOTS_PER_EPOCH - 1)).epoch
    end_full_epoch = (slots.b + 1).epoch
  start_full_epoch < end_full_epoch

func adjust_committee_weight_estimate_to_ensure_safety(estimate: Gwei): Gwei =
  ## Return adjusted ``estimate`` of the weight of a committee for a sequence
  ## of slots not covering a full epoch.
  # Per mille value to add to the estimation of the committee weight across a
  # range of slots not covering a full epoch in order to ensure the safety of
  # the confirmation rule with high probability.
  # See https://gist.github.com/saltiniroberto/9ee53d29c33878d79417abb2b4468c20
  # for an explanation about the value chosen.
  const COMMITTEE_WEIGHT_ESTIMATION_ADJUSTMENT_FACTOR = 5'u64
  estimate div 1000 * (1000 + COMMITTEE_WEIGHT_ESTIMATION_ADJUSTMENT_FACTOR)

func estimate_committee_weight_between_slots(
    total_active_balance: Gwei, slots: Slice[Slot]): Gwei =
  ## Return estimate of the total weight of committees within ``slots``.
  let committee_weight = total_active_balance div SLOTS_PER_EPOCH
  if slots.a > slots.b:
    # Sanity check
    Gwei(0)
  elif is_full_validator_set_covered(slots):
    # If an entire epoch is covered by the range,
    # return the total active balance
    total_active_balance
  elif slots.a.epoch == slots.b.epoch:
    committee_weight * slots.len.uint64
  else:
    let
      # First, calculate the number of committees in the end epoch
      num_slots_in_end_epoch = slots.b.since_epoch_start + 1
      # Next, calculate the number of slots remaining in the end epoch
      remaining_slots_in_end_epoch = SLOTS_PER_EPOCH - num_slots_in_end_epoch
      # Then, calculate the number of slots in the start epoch
      num_slots_in_start_epoch = SLOTS_PER_EPOCH - slots.a.since_epoch_start

      end_epoch_weight_estimate = committee_weight * num_slots_in_end_epoch
      start_epoch_weight_estimate =
        (committee_weight div SLOTS_PER_EPOCH) *
        num_slots_in_start_epoch * remaining_slots_in_end_epoch

    # A range that spans an epoch boundary, but does not span any full epoch
    # needs pro-rata calculation
    adjust_committee_weight_estimate_to_ensure_safety(
      start_epoch_weight_estimate + end_epoch_weight_estimate)

func get_equivocation_score(
    self: ForkChoiceBackend, balance_source: BalanceCheckpoint,
    slots: Slice[Slot], current_slot: Slot): Gwei =
  ## Return total weight of equivocating participants of all committees
  ## in the slots within ``slots``.
  let
    current_epoch = current_slot.epoch
    (even_epoch, odd_epoch) =
      if current_epoch > GENESIS_EPOCH:
        if current_epoch.isEven:
          (current_epoch, current_epoch - 1)
        else:
          (current_epoch - 1, current_epoch)
      else:
        (current_epoch, current_epoch)
  if even_epoch notin balance_source.validators.spliced_epochs or
      odd_epoch notin balance_source.validators.spliced_epochs:
    return Gwei(0)  # Error in forkChoiceNextShuffling

  let
    even_start = even_epoch.start_slot
    odd_start = odd_epoch.start_slot
  for val_index, vote in self.votes:
    if vote.slot == FAR_FUTURE_SLOT and
        val_index < balance_source.validators.balances.len:
      let
        validator = balance_source.validators.balances[val_index]
        even_slot = even_start + validator.even_epoch_assigned_slot
        odd_slot = odd_start + validator.odd_epoch_assigned_slot
      if even_slot in slots or odd_slot in slots:
        result += validator.effective_balance

func compute_adversarial_weight(
    self: ForkChoiceBackend, balance_source: BalanceCheckpoint,
    slots: Slice[Slot], current_slot: Slot): Gwei =
  ## Return maximum possible adversarial weight in the committees of the slots
  ## within ``slots``.
  let
    maximum_weight = estimate_committee_weight_between_slots(
      balance_source.total_active_balance, slots)
    max_adversarial_weight =
      maximum_weight div 100 * self.confirmation_byzantine_threshold

    # Discount total weight of equivocating validators.
    equivocation_score =
      self.get_equivocation_score(balance_source, slots, current_slot)
  if max_adversarial_weight > equivocation_score:
    max_adversarial_weight - equivocation_score
  else:
    Gwei(0)

func get_adversarial_weight(
    self: ForkChoiceBackend, balance_source: BalanceCheckpoint,
    node, parent_node: ProtoNode, current_slot: Slot): Gwei =
  ## Return maximum adversarial weight that can support the block.
  if node.bid.slot.epoch > parent_node.bid.slot.epoch:
    # Use the first epoch slot as the start slot when crossing epoch boundary.
    let start_slot = node.bid.slot.epoch.start_slot
    self.compute_adversarial_weight(
      balance_source, start_slot ..< current_slot, current_slot)
  else:
    self.compute_adversarial_weight(
      balance_source, node.bid.slot ..< current_slot, current_slot)

func compute_empty_slot_support_discount(
    self: ForkChoiceBackend, balance_source: BalanceCheckpoint,
    node, parent_node: ProtoNode, current_slot: Slot): Gwei =
  ## Return weight that can be discounted during the safety threshold
  ## computation if there are empty slots preceding the block.
  # No empty slot.
  if parent_node.bid.slot + 1 == node.bid.slot:
    return Gwei(0)

  let
    # Discount votes supporting the parent block if they are
    # from the committees of empty slots.
    parent_support_in_empty_slots = self.get_block_support_between_slots(
      balance_source, parent_node.bid.root,
      parent_node.bid.slot + 1 ..< node.bid.slot)
    # Adversarial weight is not discounted.
    adversarial_weight = self.compute_adversarial_weight(
      balance_source, parent_node.bid.slot + 1 ..< node.bid.slot, current_slot)
  if parent_support_in_empty_slots > adversarial_weight:
    parent_support_in_empty_slots - adversarial_weight
  else:
    Gwei(0)

func get_support_discount(
    self: ForkChoiceBackend, balance_source: BalanceCheckpoint,
    node, parent_node: ProtoNode, current_slot: Slot): Gwei =
  ## Return weight that can be discounted during the safety threshold
  ## computation for the block.

  # Empty slot support discount
  self.compute_empty_slot_support_discount(
    balance_source, node, parent_node, current_slot)

func is_one_confirmed(
    self: ForkChoiceBackend, balance_source: BalanceCheckpoint,
    node, parent_node: ProtoNode, current_slot: Slot): bool =
  ## Return ``true`` if and only if the block is LMD-GHOST safe.
  let
    support = node.fcrSupport.Gwei
    proposer_score = calculateProposerBoost(balance_source.total_active_balance)
    maximum_support = estimate_committee_weight_between_slots(
      balance_source, parent_node.bid.slot + 1 ..< current_slot)
    support_discount = self.get_support_discount(
      balance_source, node, parent_node, current_slot)
    adversarial_weight = self.get_adversarial_weight(
      balance_source, node, parent_node, current_slot)

  # Returns whether the following condition is true using only
  # integer arithmetic:
  # support / maximum_support >
  #   0.5 * (1 + (proposer_score - support_discount) / maximum_support) +
  #   adversarial_weight / maximum_support
  2 * support + support_discount >
  maximum_support + proposer_score + 2 * adversarial_weight

func is_confirmed_chain_safe*(
    self: ForkChoice, current_slot: Slot): bool =
  ## Return ``true`` if and only if all blocks of the confirmed chain starting
  ## from current_epoch_observed_justified.checkpoint are LMD-GHOST safe.
  template confirmed_root: Eth2Digest = self.backend.confirmed.root
  template previous_epoch_observed_justified: BalanceCheckpoint =
    self.backend.current_epoch_observed_justified
  template current_epoch_observed_justified: BalanceCheckpoint =
    self.checkpoints.justified

  # Check if the confirmed_root was pruned / finality has advanced beyond it.
  var
    low_slot {.noinit.}: Slot
    node = self.backend.proto_array[confirmed_root].valueOr:
      return false

  # Check if the confirmed_root is descendant of
  # current_epoch_observed_justified.checkpoint.
  if not self.backend.proto_array.is_ancestor(
      node, current_epoch_observed_justified.checkpoint.root,
      current_epoch_observed_justified.checkpoint.epoch.start_slot, low_slot):
    return false

  let current_epoch = current_slot.epoch
  if current_epoch_observed_justified.checkpoint.epoch + 1 >= current_epoch:
    # Exclude the justified checkpoint block if it is from the previous epoch
    # as then this block will always be canonical in this case.
    inc low_slot
  else:
    # Limit reconfirmation to the checkpoint block
    # as if it's successful, reconfirmation of the ancestors is implied.
    doAssert current_epoch >= 1.Epoch
    low_slot = (current_epoch - 1).start_slot

  # Run is_one_confirmed for each block in the confirmed chain with the
  # previous epoch balance source.
  while node.bid.slot >= low_slot:
    let parent_node = self.backend.proto_array.parentNode(node).valueOr:
      break
    if not self.backend.is_one_confirmed(
        previous_epoch_observed_justified, node, parent_node, current_slot):
      return false
    node = parent_node
  true

func get_current_target_score(
    self: ForkChoiceBackend, target_node: ProtoNode): Gwei =
  ## Return the estimate of FFG support of the current epoch target
  ## by using LMD-GHOST votes.
  result = target_node.weight

  # If target has a descendant that received proposer boost score, discount it
  template proposer_boost_root: Eth2Digest =
    self.proto_array.previousProposerBoostRoot
  if not proposer_boost_root.isZero:
    var boosted_node = self.backend.proto_array[proposer_boost_root].valueOr:
      return
    while boosted_node.bid.slot > target_node.bid.slot:
      boosted_node = self.backend.proto_array.parentNode(boosted_node).valueOr:
        return
    if boosted_node.bid.root == target_node.bid.root:
      result -= self.proto_array.previousProposerBoostScore

func compute_honest_ffg_support_for_current_target(
    self: ForkChoiceBackend, target: Checkpoint,
    total_active_balance: Gwei, current_slot: Slot): Gwei =
  ## Compute honest FFG support of the current epoch target.
  let
    current_epoch = current_slot.epoch

    # Compute FFG support for the target
    ffg_support_for_checkpoint = self.get_current_target_score(head_node)

    # Compute total FFG weight till current slot exclusive
    ffg_weight_till_now = estimate_committee_weight_between_slots(
      total_active_balance, current_epoch.start_slot ..< current_slot)

    # Compute remaining honest FFG weight
    remaining_ffg_weight = total_active_balance - ffg_weight_till_now
    remaining_honest_ffg_weight = Gwei(
      (remaining_ffg_weight div 100) *
      (100 - self.confirmation_byzantine_threshold))

    # Compute min honest FFG support
    min_honest_ffg_support = ffg_support_for_checkpoint - min(
      Gwei(ffg_weight_till_now div 100 * self.confirmation_byzantine_threshold),
      ffg_support_for_checkpoint)

  Gwei(min_honest_ffg_support + remaining_honest_ffg_weight)

func will_no_conflicting_checkpoint_be_justified(
    self: ForkChoiceBackend, target: Checkpoint,
    total_active_balance: Gwei, current_slot: Slot): bool =
  ## Return ``true`` if and only if no checkpoint conflicting with the
  ## current target can ever be justified.

  # If the target is unrealized justified then no conflicting checkpoint
  # can be justified.
  if target == self.backend.proto_array.unrealized_justified:
    return true

  let honest_ffg_support = self.compute_honest_ffg_support_for_current_target(
    target, total_active_balance, current_slot)
  3 * honest_ffg_support >= 1 * total_active_balance

func will_current_target_be_justified(
    self: ForkChoiceBackend, target: Checkpoint,
    total_active_balance: Gwei, current_slot: Slot): bool =
  ## Return ``true`` if and only if the current target will
  ## eventually be justified.
  let honest_ffg_support = self.compute_honest_ffg_support_for_current_target(
    target, total_active_balance, current_slot)
  3 * honest_ffg_support >= 2 * total_active_balance

func get_current_target(
    self: ForkChoiceBackend,
    head_node: ProtoNode, current_slot: Slot): Checkpoint =
  let
    current_epoch = current_slot.epoch
    low_slot = current_epoch.start_slot + 1
  var target_node = head_node
  while target_node.bid.slot >= low_slot:
    target_node = self.backend.proto_array.parentNode(target_node).valueOr:
      break
  Checkpoint(epoch: current_epoch, root: target_node.bid.root)

proc find_latest_confirmed_descendant(
    self: ForkChoiceBackend,
    head_idx: Index, head_node, confirmed_node: ProtoNode, finalized: Checkpoint,
    total_active_balance: Gwei, current_slot: Slot): BlockId =
  ## Return the most recent confirmed block in the suffix of the canonical chain
  ## starting from ``confirmed_node``.
  let
    current_epoch = current_slot.epoch
    target = self.get_current_target(head_node, current_slot)

  if confirmed_node.bid.slot.epoch + 1 == current_epoch:
    var prev_idx {.noinit.}: Index
    let
      prev_node = self.proto_array[self.previous_slot_head, prev_idx].valueOr:
        self.proto_array[finalized.root, prev_idx].valueOr:
          return BlockId(slot: finalized.epoch.start_slot, root: finalized.root)

    template unrealized_justified(node: ProtoNode, idx: Index): Checkpoint =
      self.proto_array.currentEpochTips.getOrDefault(
        idx, node.checkpoints).justified
    if prev_node.checkpoints.justified.epoch + 2 >= current_epoch and (
        current_slot.is_epoch or (
          self.will_no_conflicting_checkpoint_be_justified(
            target, total_active_balance, current_slot) and (
              prev_node.unrealized_justified(prev_idx).epoch + 1 >= current_epoch or
              head_node.unrealized_justified(head_node).epoch + 1 >= current_epoch))):



  confirmed_node.bid

proc get_latest_confirmed*(
    self: ForkChoiceBackend, finalized: Checkpoint, current_slot: Slot,
    get_current_target_state: GetCurrentTargetProc): BlockId =
  ## Return the most recent confirmed block by executing the FCR algorithm.

  # Revert to finalized block if either of the following is true:
  # 1) [...]
  # 2) the latest confirmed block doesn't belong to the canonical chain,
  # 3) [...]
  var head_idx {.noinit.}: Index
  let head_node = self.proto_array[head.bid.root, head_idx].valueOr:
    return BlockId(slot: finalized.epoch.start_slot, root: finalized.root)
  var confirmed_node = head_node
  while confirmed_node.bid.root != self.confirmed.root and
      confirmed_node.bid.root != finalized.root:
    confirmed_node = self.proto_array.parentNode(confirmed_node).valueOr:
      return BlockId(slot: finalized.epoch.start_slot, root: finalized.root)

  # Restart the confirmation chain if each of the following conditions are true:
  # 1) it is the start of the current epoch,
  # 2) epoch of self.current_epoch_observed_justified.checkpoint equals to the
  #    previous epoch,
  # 3) self.current_epoch_observed_justified.checkpoint equals to unrealized
  #    justification of the head,
  # 4) confirmed block is older than the block of
  #    self.current_epoch_observed_justified.checkpoint.
  template current_epoch_justified: Checkpoint =
    self.current_epoch_observed_justified.checkpoint
  template head_unrealized_justified: Checkpoint =
    self.proto_array.currentEpochTips.getOrDefault(
      head_idx, head_node.checkpoints).justified
  let current_epoch = current_slot.epoch
  if current_slot.is_epoch and
      current_epoch_justified.epoch + 1 >= current_epoch and
      current_epoch_justified == head_unrealized_justified and
      confirmed_node.bid.slot < current_epoch_justified.epoch.start_slot:
    confirmed_node = self.proto_array[current_epoch_justified.root].valueOr:
      return BlockId(slot: finalized.epoch.start_slot, root: finalized.root)

  # Attempt to further advance the latest confirmed block.
  if confirmed_node.bid.slot.epoch + 1 >= current_epoch:
    self.find_latest_confirmed_descendant(
      head_idx, head_node, confirmed_node, finalized,
      current_slot, get_current_target_state)
  else:
    confirmed_node.bid
