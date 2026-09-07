import Testing
import Foundation
@testable import snitt_mcp
import SnittAutomation

/// The `initialize` result carries server-level instructions (S5, D63).
///
/// The defect these were written against: the result named the protocol
/// version and the server, and said nothing about what the server is FOR.
/// A tool list answers "how do I call this" at call time; an agent that never
/// considers recording a screen never reads it. MCP's `instructions` field is
/// where the answer to "why would I" goes, and it was unset.
@Suite
struct InitializeTests {
    @Test("initialize returns instructions, not just a protocol version")
    func initializeCarriesInstructions() throws {
        let payload = initializeResult()
        let instructions = try #require(payload["instructions"] as? String)
        #expect(instructions.count > 200)
        // The handshake fields must survive alongside it — extracting the
        // payload into a function is exactly where one would get dropped.
        #expect(payload["protocolVersion"] as? String == "2024-11-05")
        #expect((payload["serverInfo"] as? [String: Any])?["name"] as? String == "snitt")
    }

    @Test("The instructions describe the loop, not just the product")
    func instructionsNameTheWorkflow() throws {
        let text = try #require(initializeResult()["instructions"] as? String)
        // A one-line "Snitt records screens" would pass a mere non-empty check
        // and buy nothing: what an agent lacks is the sequence, above all that
        // it cannot watch the result and must inspect it instead.
        for step in ["snitt_start_recording", "snitt_add_marker",
                     "snitt_stop_recording", "snitt_inspect"] {
            #expect(text.contains(step), "instructions omit \(step)")
        }
    }

    @Test("Every tool the instructions name really exists")
    func instructionsCiteOnlyRealTools() throws {
        // Prose describing a tool surface drifts from it — the failure S5
        // names, and the one thing here that is mechanically checkable. §10's
        // version handshake covers the wire protocol, not the documentation,
        // so this is the only guard against instructions that confidently
        // tell an agent to call a tool that was renamed or never existed.
        let text = try #require(initializeResult()["instructions"] as? String)
        let real = Set(MCPBridge.toolDefinitions().map(\.name))
        let cited = Set(
            text.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "_") })
                .map(String.init)
                .filter { $0.hasPrefix("snitt_") })
        #expect(!cited.isEmpty)
        #expect(cited.isSubset(of: real), "instructions cite absent tools: \(cited.subtracting(real))")
    }
}
