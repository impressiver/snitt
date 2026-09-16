// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Foundation
import SnittDocument

/// Whether an export can copy the recorded samples instead of re-encoding them.
///
/// **`.source` should mean source.** Exporting at source resolution re-encoded
/// the picture, which is slow and — measured on a real recording — throws away
/// data nobody asked to lose: 2030 KB of source came back as 823 KB. Copying
/// the samples is both the faster answer and the more honest one.
///
/// Measured on a 4112×2580 capture with a cut at 5.37s, deliberately chosen not
/// to be a keyframe: **1.112s re-encoding versus 0.023s copying**, and the first
/// decoded frames of each are identical to within 0.1 of mean luma. AVFoundation
/// resolves the mid-GOP splice itself, so cut points do not need snapping to
/// sync samples and the export still matches the preview exactly — which §9
/// requires and which a silent snap would have violated.
///
/// **This is a whitelist, and it must stay one.** Passthrough bypasses
/// `BuiltComposition.videoComposition` entirely, so it is only correct when that
/// composition is provably a no-op. Anything that draws, transforms or resizes
/// disqualifies it. `PassthroughEligibilityTests` pins the full field set of
/// `EditDecisionList` so that adding a field to the EDL fails a test rather than
/// silently defaulting into the fast path.
public enum PassthroughEligibility {

    /// Why an export had to re-encode. Returned rather than a bare `Bool` so a
    /// caller can say which reason applied — "it was slow" with no explanation
    /// is the kind of thing that gets debugged twice.
    public enum Disqualifier: String, Equatable, Sendable {
        case resolutionChange
        case sizeLimit
        case clickOverlay
        case crop
        case audioMix
        case scaled
        case burnedInText
        case overdub
    }

    /// Nil when the samples can be copied; otherwise the first reason they cannot.
    ///
    /// - Parameters:
    ///   - resolution: anything but `.source` rescales, which is a re-encode by
    ///     definition.
    ///   - maxSizeBytes: a size ceiling is a request to spend bitrate to hit a
    ///     target, which copying cannot do.
    ///   - clicks: click rings are drawn by the composition's animation tool.
    ///     Note this asks whether marks will actually be DRAWN, not whether the
    ///     document has clicks in it — a recording full of clicks exported with
    ///     the overlay off is still eligible.
    ///   - edl: `crop` transforms the picture.
    ///   - hasAudioMix: whether the BUILT composition carries a mix, which is
    ///     the authoritative answer rather than a re-derivation. An earlier
    ///     version asked the EDL and reasoned that only `gain` mattered,
    ///     because "a muted track is expressed by leaving it out of the
    ///     composition". That is not how this builder works —
    ///     `CompositionBuilder` keeps the track and sets its volume to 0
    ///     through the mix — so muting a track and exporting produced a file
    ///     byte-identical to the unmuted one. `CompositionBuilderTests` caught
    ///     it. Asking the composition cannot drift from what the builder did;
    ///     re-deriving the condition already had.
    ///   - scale: the factor the composition was BUILT at. The size ladder
    ///     rebuilds smaller and then exports with no size ceiling, so a
    ///     predicate that only looked at `maxSizeBytes` would wave a
    ///     half-size composition through and copy the full-size samples into
    ///     it — an export silently ignoring the rung it just computed.
    public static func disqualifier(resolution: ExportResolution,
                                    maxSizeBytes: Int?,
                                    clicks: [ClickMark],
                                    edl: EditDecisionList,
                                    hasAudioMix: Bool,
                                    scale: Double = 1.0) -> Disqualifier? {
        if scale != 1.0 { return .scaled }
        if resolution != .source { return .resolutionChange }
        if maxSizeBytes != nil { return .sizeLimit }
        if !clicks.isEmpty { return .clickOverlay }
        if let crop = edl.crop, !crop.isFullFrame { return .crop }
        // Captions and marker banners are drawn INTO the frames, so a
        // composition carrying either is not a no-op however little else
        // changed. Both asked separately rather than as one flag: the reason
        // an export re-encoded is worth being able to state.
        if edl.showSubtitles || edl.showMarkers { return .burnedInText }
        // A take is audio `capture.mov` does not contain, so there are no
        // encoded samples to copy for the stretch it covers. Checked BEFORE
        // `hasAudioMix` because it is a different fact with a different
        // remedy: a mix means the levels changed, this means part of a track
        // would be missing from the file.
        if edl.hasOverdubs { return .overdub }
        if hasAudioMix { return .audioMix }
        return nil
    }

    public static func isEligible(resolution: ExportResolution,
                                  maxSizeBytes: Int?,
                                  clicks: [ClickMark],
                                  edl: EditDecisionList,
                                  hasAudioMix: Bool,
                                  scale: Double = 1.0) -> Bool {
        disqualifier(resolution: resolution, maxSizeBytes: maxSizeBytes,
                     clicks: clicks, edl: edl, hasAudioMix: hasAudioMix,
                     scale: scale) == nil
    }

    /// Every `EditDecisionList` field this predicate has actually considered.
    ///
    /// Exists so a new field cannot join the EDL and quietly inherit "eligible".
    /// The test that compares this against the type's real fields is the guard;
    /// this list is the record of what was thought about.
    ///
    /// - `schemaVersion` — bookkeeping, no effect on the picture.
    /// - `cuts` — the composition's time ranges. Measured safe to copy across,
    ///   including mid-GOP.
    /// - `trackStates` — reaches this predicate as `hasAudioMix`, asked of the
    ///   built composition. Both `muted` and `gain` produce a mix.
    /// - `crop` — disqualifies unless full-frame.
    /// - `showClicks` — reaches this predicate as `clicks`, already resolved to
    ///   the marks that will be drawn.
    /// - `showSubtitles`, `showMarkers` — both burn text into the frames, so
    ///   both disqualify. Read from the EDL rather than resolved to drawable
    ///   items first, because an empty transcript still means the caption
    ///   layer runs, and a predicate that waved that through would depend on
    ///   whether anyone happened to speak.
    /// - `voiceover` — a THIRD audio track the capture does not contain, so
    ///   there are no samples to copy for it. Passthrough copies what is
    ///   already encoded; narration recorded afterwards is not. Exporting it
    ///   as eligible would produce a file with the picture and the original
    ///   audio and no narration at all, which is the silent-wrong-output
    ///   failure this predicate exists to prevent.
    public static let consideredEDLFields: Set<String> = [
        "schemaVersion", "cuts", "trackStates", "crop", "showClicks",
        "showSubtitles", "showMarkers", "overdubs",
    ]
}
