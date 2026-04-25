# beacon_chain
# Copyright (c) 2019-2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at http://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at http://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  chronicles, chronos,
  ../spec/forks,
  ../spec/datatypes/gloas,
  ../beacon_clock,
  ./gossip_validation

from ./eth2_processor import ValidationRes

export gossip_validation

logScope:
  topics = "gossip_opt"

type
  LightEnvelopeVerifier* = proc(
      signedEnvelope: gloas.SignedExecutionPayloadEnvelope
    ): Future[void] {.async: (raises: [CancelledError]).}

  LightEnvelopeProcessor* = ref object
    timeParams: TimeParams
    getBeaconTime: GetBeaconTimeFn
    lightEnvelopeVerifier: LightEnvelopeVerifier
    processFut: Future[void].Raising([CancelledError])

proc initLightEnvelopeProcessor*(
    timeParams: TimeParams,
    getBeaconTime: GetBeaconTimeFn,
    lightEnvelopeVerifier: LightEnvelopeVerifier): LightEnvelopeProcessor =
  LightEnvelopeProcessor(
    timeParams: timeParams,
    getBeaconTime: getBeaconTime,
    lightEnvelopeVerifier: lightEnvelopeVerifier)

proc processExecutionPayloadEnvelope*(
    self: LightEnvelopeProcessor,
    signedEnvelope: gloas.SignedExecutionPayloadEnvelope): ValidationRes =
  let wallTime = self.getBeaconTime()
  let (afterGenesis, _) = wallTime.toSlot(self.timeParams)

  if not afterGenesis:
    return errIgnore("Envelope before genesis")

  if not (signedEnvelope.message.slot <=
      (wallTime + MAXIMUM_GOSSIP_CLOCK_DISPARITY).slotOrZero(self.timeParams)):
    return errIgnore("Envelope: slot too high")

  if self.processFut == nil:
    self.processFut = self.lightEnvelopeVerifier(signedEnvelope)

    proc handleFinishedProcess(future: pointer) =
      self.processFut = nil

    self.processFut.addCallback(handleFinishedProcess)

  errIgnore("Validation delegated to sync committee")
