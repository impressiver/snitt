import Foundation

/// A selected span of the timeline, in SOURCE time.
///
/// D56 (M5f Task 4) separates two things `TrimGesture` used to conflate: a
/// drag on the timeline SELECTS, and cutting is a decision made afterwards,
/// applied TO a selection. `Selection` is that in-between state.
///
/// UI state only, deliberately the opposite of `Cut`: a `Selection` is
/// never written to `edit.json`, never survives closing and reopening the
/// document, and `EditDecisionList` has no field for it at all — nothing
/// about the document changes until a `Cut` is actually made. Selecting is
/// looking; only cutting edits.
///
/// Lives in `SnittDocument`, not the view layer, because it crosses the
/// same module boundary `TimeRange`/`Cut` already do: `TrimGesture` (this
/// module) is what a drag's end result feeds into, and
/// `EditorTimelineState`/`TimelineView` (`SnittApp`) are what turn that
/// into a `Selection`, hold onto it, render it, and eventually decide
/// whether to cut it. A type only one side of that boundary needed would
/// stay local to that side; this one is the value handed across it.
public struct Selection: Equatable, Sendable {
    public var range: TimeRange

    public init(range: TimeRange) {
        self.range = range
    }
}
