// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Foundation
import Testing
@testable import SnittAutomation

/// The guard S5 says is missing.
///
/// S5 names the hazard directly: "prose drifts from the flags it describes —
/// the failure §10's version handshake exists to catch, with no equivalent for
/// documentation." This is that equivalent. It cannot check that prose is
/// TRUE, but it can check the three ways this text actually went wrong:
/// naming a tool that does not exist, failing to name one that does, and
/// keeping a claim after the code stopped honouring it.
@Suite
struct ServerInstructionsTests {

    private var instructions: String { MCPBridge.serverInstructions }
    private var toolNames: Set<String> { Set(MCPBridge.toolDefinitions().map(\.name)) }

    /// Every `snitt_…` identifier the instructions mention.
    private var mentioned: Set<String> {
        var found: Set<String> = []
        var scanner = Substring(instructions)
        while let range = scanner.range(of: "snitt_") {
            let rest = scanner[range.lowerBound...]
            let name = rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
            found.insert(String(name))
            scanner = scanner[range.upperBound...]
        }
        return found
    }

    @Test("Every tool the instructions name actually exists")
    func namedToolsResolve() {
        let missing = mentioned.subtracting(toolNames)
        // A renamed or removed tool leaves the instructions telling an agent to
        // call something that will fail — and the agent has no way to tell that
        // the documentation is wrong rather than its own request.
        #expect(missing.isEmpty, "instructions name tools that do not exist: \(missing.sorted())")
    }

    @Test("The tools that make up the workflow are all named")
    func theWorkflowIsComplete() {
        // The drift that actually happened: capabilities were added and the
        // instructions were not touched, so agents were never told the loop had
        // grown a tidy-up step. Adding a tool to this list forces a mention.
        let workflow: Set<String> = [
            "snitt_start_recording", "snitt_report_input", "snitt_mark",
            "snitt_stop_recording", "snitt_trim", "snitt_auto_deep_trim",
            "snitt_crop", "snitt_inspect", "snitt_export",
        ]
        let unmentioned = workflow.subtracting(mentioned)
        #expect(unmentioned.isEmpty,
                "the loop does not mention: \(unmentioned.sorted())")
    }

    @Test("It does not tell agents to get Snitt running first")
    func doesNotClaimSnittMustAlreadyBeRunning() {
        // It said "Snitt.app must already be running... if it is not running
        // there is nobody to start it" for as long as that was true, and kept
        // saying it after launch-on-demand made it false. An agent that
        // believes it either refuses to try or asks a person to open an app
        // that would have opened itself.
        let text = instructions.lowercased()
        #expect(!text.contains("must already be running"),
                "still claims Snitt has to be running first")
        #expect(!text.contains("nobody to start it"))
        // And says the true thing in its place, since silence would leave an
        // agent to guess.
        #expect(text.contains("starts it") || text.contains("start it"),
                "does not say that calling a tool starts Snitt")
    }

    @Test("It says what the server is FOR, not only how to call it")
    func itAnswersWhyNotOnlyHow() {
        // S5's disclosure half: "a tool list answers 'how do I call this'; it
        // does not answer 'why would I record my screen'." If this text
        // collapses into a list of verbs, the tool schemas already did that job
        // and this one is unfilled.
        // The OPENING paragraph, not the text anywhere: an earlier version of
        // this asserted the word "demo" appeared somewhere, and "demo" also
        // occurs down in step 6 — so gutting the opening to "Snitt records a
        // macOS window." passed it. The purpose has to arrive before the verbs,
        // because an agent that stops reading after one line has read only that.
        let opening = (instructions.components(separatedBy: "\n\n").first ?? "").lowercased()
        #expect(opening.contains("pull request") || opening.contains("bug")
                || opening.contains("before-and-after"),
                "the opening names no concrete use: \(opening)")
        let text = instructions.lowercased()
        #expect(text.contains("does not click") || text.contains("films"),
                "does not set the boundary that Snitt records rather than drives")
    }

    @Test("The privacy warning an agent cannot infer survives")
    func chromeWarningIsPresent() {
        // A browser's tab strip names every other open tab in every frame. An
        // agent cannot see the recording, so it will never notice.
        #expect(instructions.lowercased().contains("tab"),
                "drops the window-chrome warning entirely")
    }

    @Test("The advice is to record a clean window, not to crop a dirty one")
    func cleanWindowComesFirst() throws {
        // The warning survived for a long time in a weaker form: it said the
        // tab strip leaks and to crop it out before sharing. That is
        // remediation, and remediation is the wrong shape for this.
        //
        // A crop removes the SAME rectangle from every frame. It can take away
        // chrome that sat still for the whole recording; it cannot take back a
        // notification that arrived at 0:12, a title that changed, or a
        // bookmark bar that appeared when a page loaded. A window with nothing
        // in it to leak needs no crop and cannot be got wrong.
        //
        // `contains("tab")` above does not catch the difference: the old
        // crop-it-afterwards wording satisfied it perfectly.
        let text = instructions.lowercased()
        #expect(text.contains("app mode") || text.contains("--app="),
                "does not name the window that has no tab strip to leak")
        #expect(text.contains("--user-data-dir"),
                "app mode without a throwaway profile still carries the person's session")

        // Ordering is the claim. Making the window has to come before the tool
        // that starts filming, or it reads as something to consider later.
        let makeIt = try #require(text.range(of: "make the window"),
                                  "the loop never says to make a window")
        let startIt = try #require(text.range(of: "snitt_start_recording"))
        #expect(makeIt.lowerBound < startIt.lowerBound,
                "the loop starts recording before it says what to record")
    }

    @Test("The tool that starts a recording carries the warning too")
    func theToolItselfSaysIt() throws {
        // The instructions are read once, at connect. A tool description is
        // read at the moment of use, which for this is the moment it stops
        // being fixable — the frame is captured or it is not.
        let start = try #require(
            MCPBridge.toolDefinitions().first { $0.name == "snitt_start_recording" })
        let text = start.description.lowercased()
        #expect(text.contains("tab strip"), "the leak is not named where it happens")
        #expect(text.contains("app mode"), "names the leak and not the way out of it")
    }
}
