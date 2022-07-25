# beacon_chain
# Copyright (c) 2018-2022 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# All tests except scenarios, which as compiled separately for mainnet and minimal

import
  ./testutil

when not defined(i386):
  # Avoids "Out of memory" CI failures
  import
    ./test_keymanager_api

summarizeLongTests("AllTests")
