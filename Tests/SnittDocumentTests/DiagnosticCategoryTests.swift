import Testing
import SnittDocument

@Test("Every category has a stable wire name")
func categoriesHaveStableNames() {
    // These strings end up in exported diagnostics that a human greps.
    // Renaming one silently breaks every saved bundle and every runbook
    // that mentions it, so the mapping is pinned here deliberately.
    #expect(DiagnosticCategory.permission.rawValue == "permission")
    #expect(DiagnosticCategory.disk.rawValue == "disk")
    #expect(DiagnosticCategory.capture.rawValue == "capture")
    #expect(DiagnosticCategory.compositor.rawValue == "compositor")
    #expect(DiagnosticCategory.automation.rawValue == "automation")
}

@Test("§12's three named faults all exist")
func specNamedFaultsExist() {
    // §12 names permission, disk and compositor explicitly. If a future
    // edit removes one, this fails rather than the omission being noticed
    // when someone needs the category during an incident.
    let names = Set(DiagnosticCategory.allCases.map(\.rawValue))
    #expect(names.isSuperset(of: ["permission", "disk", "compositor"]))
}

@Test("User-actionable faults are separated from ones to report")
func actionabilityIsSplit() {
    // A permission denial is something the user fixes in System Settings;
    // a compositor fault is something they can only report. Telling a user
    // to fix the second, or silently swallowing the first, are both bad.
    #expect(DiagnosticCategory.permission.isUserActionable)
    #expect(DiagnosticCategory.disk.isUserActionable)
    #expect(!DiagnosticCategory.compositor.isUserActionable)
}
