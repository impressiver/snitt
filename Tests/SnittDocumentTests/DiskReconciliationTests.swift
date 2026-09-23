// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Testing
@testable import SnittDocument

/// Reconciling an open document with a sidecar that changed underneath it.
@Suite("Disk reconciliation")
struct DiskReconciliationTests {

    @Test("A window's own save does not read as somebody else's change")
    func ourOwnWriteIsInSync() {
        // The case that decides the whole design. A save IS an external change
        // to the filesystem: the watcher fires, and between the bytes landing
        // and `lastSaved` being updated, disk and `lastSaved` disagree. Judging
        // on that pair alone would have every save look like a conflict with
        // itself. Comparing against `live` first is what makes our own writes
        // free, with no suppression flag and no timing window.
        #expect(DiskReconciliation.decide(onDisk: "new", live: "new", lastSaved: "old")
                == .inSync)
    }

    @Test("Nothing unsaved, so an external edit is adopted")
    func aCleanWindowAdopts() {
        // The reported bug: events.json edited underneath an open editor, and
        // the window went on showing what it read at open. It had to be pointed
        // at another bundle and back before it would re-read.
        #expect(DiskReconciliation.decide(onDisk: "theirs", live: "ours", lastSaved: "ours")
                == .adopt)
    }

    @Test("Unsaved work is never silently overwritten")
    func aDirtyWindowConflicts() {
        // W7's loss, arriving from the other direction. The window holds edits
        // applied but not yet persisted; adopting here would destroy them with
        // no error and no trace, which is exactly the failure class W7 exists
        // to end.
        #expect(DiskReconciliation.decide(onDisk: "theirs", live: "mine", lastSaved: "saved")
                == .conflict)
    }

    @Test("Everything already agreeing is in sync, not an adopt")
    func quiescenceIsInSync() {
        // The steady state, and it must not be `.adopt`: a watcher fires on
        // plenty of writes that change nothing this window cares about, and
        // rebuilding the composition each time would make an idle editor
        // thrash.
        #expect(DiskReconciliation.decide(onDisk: "same", live: "same", lastSaved: "same")
                == .inSync)
    }

    @Test("A dirty window whose unsaved edit MATCHES disk is in sync")
    func convergentEditsDoNotConflict() {
        // Two writers reaching the same value is not a disagreement. Judging
        // dirtiness before content would call this a conflict and ask the
        // person to choose between two identical options.
        #expect(DiskReconciliation.decide(onDisk: "agreed", live: "agreed", lastSaved: "old")
                == .inSync)
    }
}
