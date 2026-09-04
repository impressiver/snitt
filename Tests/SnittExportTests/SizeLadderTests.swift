import Testing
@testable import SnittExport

@Test("The ladder descends monotonically and never repeats a rung")
func ladderDescends() {
    let rungs = SizeLadder.rungs(baseFPS: 15)
    #expect(rungs.count >= 4)
    #expect(rungs.first?.framesPerSecond == 15)
    #expect(rungs.first?.scaleMultiplier == 1.0)
    for (a, b) in zip(rungs, rungs.dropFirst()) {
        // Each rung must be no better than the last on both axes, and
        // strictly worse on at least one. A ladder with a repeated rung
        // burns a full re-encode producing a byte-identical file.
        #expect(b.framesPerSecond <= a.framesPerSecond)
        #expect(b.scaleMultiplier <= a.scaleMultiplier)
        #expect(b != a)
    }
}

@Test("The ladder is bounded")
func ladderBounded() {
    // Each rung is a full re-encode. An unbounded ladder on a long recording
    // runs for minutes with no progress visible to the caller.
    #expect(SizeLadder.rungs(baseFPS: 15).count <= 6)
}

@Test("A low base frame rate does not produce rungs above it")
func ladderRespectsBase() {
    // Asking for 5fps and getting a 15fps first rung would make the GIF
    // larger than the caller asked for before targeting even begins.
    #expect(SizeLadder.rungs(baseFPS: 5).allSatisfy { $0.framesPerSecond <= 5 })
}
