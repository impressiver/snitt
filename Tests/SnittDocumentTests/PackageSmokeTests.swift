// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
@testable import SnittDocument

@Test("SnittDocument target builds and exposes a version")
func documentTargetIsLinkable() {
    #expect(!AppVersion.current.isEmpty)
}
