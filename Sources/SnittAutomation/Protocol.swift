// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import Foundation
import SnittDocument

public enum AutomationProtocol {
    /// Bumped whenever the wire format changes incompatibly. The server refuses
    /// mismatches rather than guessing (§10).
    ///
    /// 2 — added `.mark` and `StartOptions.workingDirectory`. The new request
    /// case is why this is a bump and not an additive change: an old app cannot
    /// decode `.mark` and would report `internal_error`, where §10 wants a
    /// refusal that says what to do.
    ///
    /// v2 was later amended again to add `.inspect`/`.inspected`, still without
    /// a further bump: v2 has never shipped — `main` has no `SnittAutomation`
    /// at all, and both PRs that would introduce it are unmerged — so there is
    /// no released v2 client whose compatibility a bump would protect. A future
    /// reader should not mistake this for a forgotten bump; it is deliberate,
    /// for the same reason `.stopped(health:)` amended v2 rather than bumping.
    ///
    /// v2 was amended a third time to add `.trim`/`.trimmed` and
    /// `.export`/`.exported`, for the same reason: still no released v2
    /// client. Trim and export run in the app rather than the CLI, for the
    /// same reason `.inspect` does — the client cannot assume it can read
    /// the bundle (§4.9): the output directory is user-configurable and,
    /// even at its current default (`~/Documents/Snitt`), may still be
    /// pointed at a TCC-gated location like `~/Desktop`.
    ///
    /// v2 was amended a fourth time to add `maxSizeBytes` to `.export`
    /// (M3d), for the same reason: still no released v2 client.
    ///
    /// v2 was amended a fifth time to add `.diagnostics`/`.diagnosticsWritten`
    /// (M5a, Task 6), for the same reason: still no released v2 client.
    /// Diagnostics runs in the app rather than the CLI for a different
    /// reason than `.inspect`/`.trim`/`.export` do — not TCC, but process
    /// scope: `OSLogStore(scope: .currentProcessIdentifier)` (spike S8)
    /// reads back only the calling process's own log entries, so a CLI-side
    /// implementation would bundle the CLI's own handful of lines and none
    /// of the app's.
    ///
    /// v2 was amended a sixth time to add `crashReportingEnabled` and
    /// `crashReports` to `DiagnosticsReport` (§12's opt-in local crash
    /// reporting), for the same reason: still no released v2 client. Both
    /// fields are non-optional, so a NEW client decoding an OLD app's
    /// response would fail `keyNotFound` — acceptable only because there is
    /// no old client to break; a real v2 release would need this amendment
    /// to be additive-and-optional instead, or a bump.
    /// 3 — added `.crop`/`.cropped`. A bump rather than another additive
    /// amendment: unlike every earlier change to v2, **v0.1.0 has shipped**, so
    /// there IS a released client whose compatibility a silent case addition
    /// would break — an old app receiving `.crop` cannot decode it and reports
    /// `internal_error` where §10 wants a refusal that says what to do.
    ///
    /// The blast radius is small because D63 now embeds `snitt` and `snitt-mcp`
    /// inside `Snitt.app`, so client and app ship and update together; a
    /// mismatched pair means someone is running a loose binary from an old
    /// build, which is exactly the case the handshake should refuse loudly.
    ///
    /// 4: added `.transcript` and `.addNarration` (D107). A bump for the same
    /// reason 3 was: these are new REQUEST cases, and v3 has shipped in every
    /// release from v0.3.0 onward, so there ARE released v3 clients. The
    /// `.pauseRecording`/`.resumeRecording` note below gave itself licence to
    /// amend v3 without bumping and said that licence "expires the moment v3
    /// ships". It shipped, and these are the first cases added since, so it
    /// expires here.
    ///
    /// Worth stating plainly, because the paragraphs above imply more than a
    /// bump delivers: `AutomationServer` decodes the whole request BEFORE it
    /// compares versions, so a NEW client's new case still reaches an OLD app
    /// as a decode failure rather than as `upgrade_required`. What the bump
    /// actually buys is the other direction, a new app refusing an old client
    /// outright, rather than serving it a surface that has moved underneath
    /// it. Fixing the first direction means handshaking before sending, which
    /// is a round trip on every call and its own decision.
    ///
    /// The two fields added to `.export` in the same change are NOT what
    /// earned this bump: they are optional and additive, and
    /// `ResponseWireCompatibilityTests` proves that shape decodes both ways.
    ///
    /// **D104, D105 and D106 all landed on v3 and were right not to bump**,
    /// which is worth spelling out because three no-bumps followed by a bump
    /// reads like an inconsistency and is not. Each of them added optional
    /// fields, new CASES in `AutomationError.Code`, or new arguments the
    /// frontends divide away before a request is built; none added a request
    /// case an old app's decoder has never heard of. That is the line this
    /// number has always drawn, and these two cross it.
    ///
    /// D106's lenient `Code` decoder is a different axis and does not soften
    /// this one. It lets an unknown error code degrade instead of failing the
    /// whole response, which is about a RESPONSE an old CLIENT reads; the bump
    /// is about a REQUEST an old APP cannot decode at all. The same trick is
    /// not available here: an unknown `Body` case has no sensible value to
    /// degrade to, and the refusal the version check already produces is a
    /// better answer than guessing at one.
    public static let version = 4
}

public struct StartOptions: Codable, Sendable, Equatable {
    public var bundleIdentifier: String?
    /// A window id from THIS session's `listTargets`, naming exactly one
    /// window. Without it, an app with several windows is ambiguous and the
    /// agent path refuses rather than guessing (see
    /// `TargetResolutionError.ambiguousWindows`).
    public var windowID: UInt32?
    public var displayID: UInt32?
    public var microphone: Bool
    public var systemAudio: Bool
    public var maxDurationSeconds: Double?
    /// Terms the speech recogniser should expect to hear (D81).
    ///
    /// Supplied when the recording STARTS because that is when the caller knows
    /// them — an agent about to demonstrate `KeptRanges` knows it is going to
    /// say "KeptRanges", and no general model has heard the word. Stored in the
    /// recording's metadata, so a transcription that happens later, or again,
    /// still has them.
    public var vocabulary: [String]?
    /// The client's working directory, used to discover git context (§7).
    ///
    /// Filled by the CLI, not the app: `Snitt.app`'s own directory is `/`, so it
    /// cannot know which repository a recording is about. Hotkey recordings have
    /// no working directory and therefore no git context, which is correct —
    /// pressing a key is not associated with a checkout.
    public var workingDirectory: String?

    public init(bundleIdentifier: String? = nil,
                windowID: UInt32? = nil,
                displayID: UInt32? = nil,
                microphone: Bool = false,
                systemAudio: Bool = true,
                maxDurationSeconds: Double? = nil,
                workingDirectory: String? = nil,
                vocabulary: [String]? = nil) {
        self.bundleIdentifier = bundleIdentifier
        self.windowID = windowID
        self.displayID = displayID
        self.microphone = microphone
        self.systemAudio = systemAudio
        self.maxDurationSeconds = maxDurationSeconds
        self.workingDirectory = workingDirectory
        self.vocabulary = vocabulary
    }
}

public struct AutomationRequest: Codable, Sendable {
    public enum Body: Codable, Sendable {
        case handshake
        case listTargets
        case startRecording(StartOptions)
        case stopRecording(sessionID: String)
        case status
        case mark(sessionID: String, label: String?)
        case inspect(bundlePath: String)
        case trim(bundlePath: String, start: Double?, end: Double?, auto: Bool)
        /// A `nil` rect REMOVES the crop, which is distinct from cropping to
        /// the full frame only in what reaches disk.
        case crop(bundlePath: String, rect: CropRect?)
        /// M5e/D53. Amends v3 rather than bumping it again: v3 has not
        /// shipped, so there is no released client for these to break — the
        /// same reasoning v2 used for every addition before v0.1.0 existed,
        /// and it expires the moment v3 ships.
        case pauseRecording(sessionID: String)
        case resumeRecording(sessionID: String)
        /// `inline` asks for the frame itself in the response, not just a path.
        ///
        /// Off by default, deliberately. Returning pixels makes "screen content
        /// leaves this machine" the default rather than something the caller
        /// chooses: an MCP host is usually a cloud model. `screenshotForAgent`
        /// already calls a screenshot "the most obviously sensitive thing this
        /// surface could hand out" and puts that on Snitt rather than the
        /// caller, and §5.6 already makes rendering captured input opt-in for
        /// the same reason.
        case screenshot(sessionID: String, label: String?, inline: Bool = false)
        /// An input event the OS never saw, reported by whoever caused it
        /// (M5e follow-on). `x`/`y` are fractions of the recorded window, and
        /// are nil for a `keystroke`, which happens at no particular place.
        ///
        /// Fractions ON THE WIRE, whatever the caller typed: D105 lets both
        /// frontends take pixels of a frame the caller names, and they divide
        /// before building this. A fraction is the only form that stays true
        /// across the window, the capture and a downscaled screenshot at once.
        case reportInput(sessionID: String, kind: String,
                         x: Double?, y: Double?, label: String?)
        /// D57's automatic trim. Carries the resolved criteria rather than a
        /// preset name, so the CLI's per-criterion flags and its `--preset`
        /// arrive here as the same thing and the app has one code path.
        case autoDeepTrim(bundlePath: String, criteria: DeepTrimCriteria)
        /// What an export would produce, without producing it. A separate verb
        /// rather than a flag on `export`, because it answers a different
        /// question and needs no output path.
        case estimateExport(bundlePath: String, scale: Double, format: String)
        /// What this recording SAYS, read back as lines (D107).
        ///
        /// A verb of its own rather than a field on `.inspect`, for the reason
        /// `Transcript` is its own sidecar and not rows in `events.json`: a
        /// ten-minute narration is a thousand words, and bloating every
        /// "how long is this and what is in it" call with them buys nothing.
        case transcript(bundlePath: String)
        /// What is sitting in the output directory (D108).
        ///
        /// Amends v4 rather than bumping again: v4 has not shipped, so there
        /// is no released v4 client for a new case to break. That is the same
        /// licence every addition to v2 and v3 took before their releases
        /// existed, and it expires the moment v4 ships.
        ///
        /// Runs in the app, like `.inspect`, for the same reason: the output
        /// directory is user-configurable, the client cannot be assumed able
        /// to read it (§4.9), and the client does not know where it points in
        /// the first place.
        case listRecordings(limit: Int?)
        /// Narration WRITTEN into a recording at a moment in it (D107, D100).
        ///
        /// In scope despite §4.8's record-only rule, which bounds what Snitt
        /// does to the world, "it does not click, type, or navigate, and it
        /// does not upload", not what may enter a recording. A person
        /// narrates with a microphone; an agent has no voice, so this is its
        /// microphone. D49 already grants agents markers carrying a
        /// transcript.
        ///
        /// `atSeconds` is SOURCE time, the clock every transcript word is on
        /// and the clock `.marked` and `.screenshotTaken` report. The
        /// editor's own `+` gesture takes OUTPUT time and converts, because a
        /// playhead reads in output time; nothing on this side has a playhead,
        /// and an agent's other handles on the recording are already source
        /// times.
        case addNarration(bundlePath: String, text: String, atSeconds: Double)
        case export(bundlePath: String, format: String, outputPath: String,
                    scale: Double, chapters: Bool, subtitles: Bool, maxSizeBytes: Int?,
                    /// Output size to target. `.source` keeps the recording's
                    /// own dimensions, which is what every export did before
                    /// there was a choice.
                    resolution: ExportResolution,
                    /// D64: draw reported clicks onto the video.
                    ///
                    /// Still a choice rather than a consequence of having
                    /// logged them, since a recording's clicks are data (§4.5),
                    /// but D105 flipped which way both frontends choose when
                    /// nobody says. §5.6's opt-in governs input Snitt CAUGHT,
                    /// where the hazard is a token the person at the keyboard
                    /// never handed over. A reported click was handed over by
                    /// its own caller, and only reported clicks can be drawn
                    /// at all (`ClickOverlay`: a click the tap saw carries no
                    /// position), so defaulting this on cannot surface
                    /// anything the caller did not supply.
                    clicks: Bool,
                    /// D107: draw the transcript as burned-in captions.
                    ///
                    /// NOT `subtitles`, which is already taken and means
                    /// something else entirely: that flag writes a `.vtt`
                    /// sidecar from MARKER transcripts, while this burns the
                    /// SPEECH transcript into the frames. Two things called
                    /// subtitles on one verb would be a trap; they are
                    /// different sources, different outputs and different
                    /// answers to "why is my demo not captioned".
                    ///
                    /// **`nil` means the document decides**, which is what
                    /// makes this an override rather than a default. These
                    /// live in `edit.json` as `showSubtitles`/`showMarkers`
                    /// because a person sets them in the editor and they
                    /// travel with the bundle; a `Bool` defaulting to `false`
                    /// would make an agent's export silently drop captions a
                    /// person had already turned on. Never written back:
                    /// see `EditDecisionList.drawing(captions:markerBanners:)`.
                    ///
                    /// **Deliberately not given D105's treatment**, which
                    /// flipped `clicks` on above. That was the right move
                    /// there because `clicks` has nothing in the document to
                    /// defer to, so SOMEBODY had to pick a default and "draw
                    /// what the caller itself reported" is the better pick.
                    /// These two do have somewhere to defer to, and deferring
                    /// beats any default: on would override a person who
                    /// turned captions off, off would override a person who
                    /// turned them on.
                    ///
                    /// Optional and additive: absent decodes to `nil` on an
                    /// app that predates them, which is the behaviour those
                    /// apps already had.
                    captions: Bool? = nil,
                    /// D107: draw marker labels as banners.
                    markerBanners: Bool? = nil)
        /// `outputPath` arrives already resolved against the CALLER's working
        /// directory (`PathResolver.resolve`, done by the CLI before this is
        /// sent) — never the app's, whose own cwd is not the caller's (M3c
        /// finding #3, the same reason `.trim`/`.export`'s paths are
        /// pre-resolved).
        case diagnostics(outputPath: String)
    }

    public var protocolVersion: Int
    public var body: Body

    public init(protocolVersion: Int = AutomationProtocol.version, body: Body) {
        self.protocolVersion = protocolVersion
        self.body = body
    }
}

public struct TargetSummary: Codable, Sendable, Equatable {
    public var id: UInt32
    public var kind: String
    public var title: String?
    public var applicationName: String?
    public var bundleIdentifier: String?

    public init(id: UInt32, kind: String, title: String?,
                applicationName: String?, bundleIdentifier: String?) {
        self.id = id
        self.kind = kind
        self.title = title
        self.applicationName = applicationName
        self.bundleIdentifier = bundleIdentifier
    }
}

public struct HandshakeInfo: Codable, Sendable, Equatable {
    public var protocolVersion: Int
    public var appVersion: String
    public init(protocolVersion: Int, appVersion: String) {
        self.protocolVersion = protocolVersion
        self.appVersion = appVersion
    }
}

public struct StatusInfo: Codable, Sendable, Equatable {
    public var recording: Bool
    public var sessionID: String?
    /// WALL time since the session started, including any time paused — the
    /// same clock `maxDuration` is measured on, so an agent can tell how close
    /// it is to the cap.
    public var elapsedSeconds: Double?
    /// D53: an agent that pauses, crashes and is restarted has no other way to
    /// discover it left a session paused. `recording` alone reads as "yes" for
    /// a paused session, which is true and useless.
    public var paused: Bool
    /// How much of `elapsedSeconds` was spent paused. `elapsed - paused` is the
    /// footage.
    public var pausedSeconds: Double?
    /// D104: what an agent is permitted to do, before it tries.
    ///
    /// Optional because it is additive on a shipped wire format: an app that
    /// predates the field sends no key, and `ResponseWireCompatibilityTests`
    /// proves a newer client still decodes that. `nil` therefore means "this
    /// app cannot say", which is not the same as "nothing is permitted": a
    /// caller that sees nil should fall back to the behaviour it had before,
    /// which is to call and read `consent_required` if it comes.
    public var consent: ConsentInfo?

    public init(recording: Bool, sessionID: String?, elapsedSeconds: Double?,
                paused: Bool = false, pausedSeconds: Double? = nil,
                consent: ConsentInfo? = nil) {
        self.recording = recording
        self.sessionID = sessionID
        self.elapsedSeconds = elapsedSeconds
        self.paused = paused
        self.pausedSeconds = pausedSeconds
        self.consent = consent
    }
}

/// Which grants are in force right now, so an agent can plan instead of guess
/// (D104).
///
/// `StatusInfo` answered only "is something recording", so the single way to
/// learn that agent recording was switched off, or that full-display capture
/// was never enabled, was to call a tool and read `consent_required` back off
/// the failure. That error is well-hinted and this is a gap rather than a trap,
/// but it costs a failed call on every cold start and it arrives too late to be
/// planned around: an agent that wanted a display and may not have one would
/// rather choose a window than discover a refusal mid-recording.
///
/// Reports state, never changes it. Nothing here is a request for permission:
/// §5.3's opt-in is a person's to give, in front of the machine.
public struct ConsentInfo: Codable, Sendable, Equatable {
    /// §5.3's global opt-in: may an agent record at all. Everything else here
    /// is subordinate to it.
    public var agentRecording: Bool
    /// Whether a whole display may be recorded, as opposed to one application's
    /// window. Separate because agreeing that agents may record is not agreeing
    /// to hand over the whole screen.
    public var fullDisplay: Bool

    /// The three states of D95's unattended grant, as a string an agent can
    /// branch on: never set up, in force, or expired and awaiting renewal.
    public enum Unattended: String, Codable, Sendable {
        case off
        case active
        case lapsed
    }

    /// D95's unattended grant reported ON ITS OWN TERMS, independent of
    /// `agentRecording`.
    ///
    /// Deliberately NOT `UnattendedRecordingGrant.status(now:)`, which folds
    /// the global opt-in in and returns `.off` for two different situations: a
    /// person who never enabled unattended recording, and a person who did but
    /// whose agent-recording switch is off. One word for both would send an
    /// agent to fix the wrong thing. It would ask for agent recording, get it,
    /// and only then find it still may not record unwatched. Kept separate, the
    /// two fields compose; `unattendedPermitted` is that composition already
    /// done.
    public var unattended: Unattended
    /// Days left before a person must re-confirm the grant at the machine.
    /// Present only while `unattended` is `.active`, because it is the only
    /// state in which a number means anything.
    public var unattendedDaysRemaining: Int?
    /// The composed answer: may an agent record with nobody at the keyboard
    /// right now. The field to branch on; the two above say why.
    ///
    /// Stored rather than computed so it crosses the wire, and built only by
    /// the initialiser below, because `unattended != .off` is the wrong test
    /// and reads as the right one. `UnattendedRecordingGrant.Status.isActive`
    /// exists for the same reason, and this is that reasoning one layer out.
    public var unattendedPermitted: Bool

    /// The one way to build this, so the composition above cannot be got wrong
    /// at a call site.
    public init(grant: UnattendedRecordingGrant, fullDisplay: Bool, now: Date) {
        self.agentRecording = grant.agentRecordingEnabled
        self.fullDisplay = fullDisplay
        switch grant.standingStatus(now: now) {
        case .off:
            self.unattended = .off
            self.unattendedDaysRemaining = nil
        case .active(let days):
            self.unattended = .active
            self.unattendedDaysRemaining = days
        case .lapsed:
            self.unattended = .lapsed
            self.unattendedDaysRemaining = nil
        }
        self.unattendedPermitted = grant.status(now: now).isActive
    }
}

public struct AutomationError: Codable, Sendable, Equatable, Error {
    /// The agent-facing contract. An agent branches on this, never on `message`.
    /// Adding a case is safe; renaming one is a breaking protocol change.
    ///
    /// D106 split `internal_error`. It had become a catch-all across three
    /// unrelated classes, 27 sites in `AutomationHost` alone, and an agent
    /// receiving it could not tell "fix your request" from "this recording is
    /// beyond saving" from "wait a second and ask again", which are the only
    /// three things it could usefully do about a failure. The three codes are
    /// named for the ANSWER, not for the subsystem that produced it.
    public enum Code: String, Codable, Sendable, CaseIterable {
        case consentRequired = "consent_required"
        case upgradeRequired = "upgrade_required"
        case noSuchSession = "no_such_session"
        case alreadyRecording = "already_recording"
        case targetNotFound = "target_not_found"
        case permissionDenied = "permission_denied"
        /// The CALL was wrong: a missing field, an unknown enum value, a
        /// number outside its range, a range whose end precedes its start.
        /// Change the arguments and send it again; sending the same ones
        /// again cannot work.
        ///
        /// Also what an MCP argument error carries. Before D106 those were
        /// bare prose with no code at all: the largest class of real agent
        /// mistakes was the one class the taxonomy did not reach.
        case invalidArguments = "invalid_arguments"
        /// The RECORDING cannot serve this request, and repeating it
        /// unchanged never will: a corrupt `edit.json`, a `capture.mov` with
        /// no video track, a trim that removes every frame, an input log
        /// with nothing to trim against.
        ///
        /// Distinct from `invalidArguments` because the caller's request was
        /// well-formed, and distinct from `internalError` because nothing
        /// went wrong unexpectedly. Some of these are recoverable by a
        /// DIFFERENT request (widen the trim, then export again) and the
        /// hint says which; none is recoverable by this one.
        case unusableRecording = "unusable_recording"
        /// Nothing is wrong. Snitt is mid-transition (starting or stopping a
        /// recording, or waiting on the first frame) and the same request
        /// will very likely succeed in a moment.
        ///
        /// It earns its own code because it is the only failure an agent
        /// should RETRY, and it was previously indistinguishable from the
        /// failures it must not: the hint already said "try again in a
        /// moment" while the code said `internal_error`.
        case busy = "busy"
        /// The recording is OPEN IN SNITT'S EDITOR, and a person may be
        /// editing it. The request was well-formed and the recording is fine;
        /// it is refused so it cannot be silently overwritten by the window's
        /// next save (W4).
        ///
        /// It earns its own code under the same rule as `busy` — the codes are
        /// named for the ANSWER, and no existing one gives the right one.
        /// `invalidArguments` says "sending these again cannot work", and the
        /// identical request succeeds the moment the window closes.
        /// `unusableRecording` blames a recording that is undamaged. `busy`
        /// says "nothing is wrong, retry shortly", and this is the one failure
        /// an agent must NOT spin on: it clears when a PERSON closes the
        /// window, not on its own.
        ///
        /// The answer is: close the window, or make the edit in the editor.
        case bundleOpenInEditor = "bundle_open_in_editor"
        /// Something unexpected. Neither the request nor the recording is
        /// known to be at fault, so there is no advice beyond the hint, which
        /// carries the underlying error.
        ///
        /// After D106 this is the residue, not the default. A new failure
        /// site belongs here only when none of the three above fits.
        case internalError = "internal_error"

        /// An unrecognised code decodes as `.internalError` rather than
        /// throwing.
        ///
        /// Synthesized `RawRepresentable` decoding throws `dataCorrupted` on
        /// an unknown string, which makes every future addition to this enum
        /// a breaking change for every already-released client: the app sends
        /// a code the client has never heard of and the whole response fails
        /// to decode, surfacing as `malformedResponse` rather than as the
        /// failure it actually was. D106 adds three cases at once and would
        /// have done exactly that.
        ///
        /// `.internalError` is the right fallback precisely because of what
        /// D106 makes it mean: "something unexpected, no advice to give". A
        /// client degrades to the single code it already had for these
        /// failures, which is the behaviour it had before the split: the
        /// taxonomy is lost, not the response.
        ///
        /// **It protects the NEXT addition, not this one.** This decoder ships
        /// inside D106, so a client released BEFORE it still has the strict
        /// synthesized decoder and still throws `dataCorrupted` on
        /// `invalid_arguments`, `unusable_recording` or `busy`. Nothing here
        /// can reach back and fix that; the limit is stated rather than left
        /// for someone to discover. It is tolerable for the same reason the
        /// `.crop` bump's blast radius was small (D63): `snitt` and
        /// `snitt-mcp` are embedded in `Snitt.app` and update with it, so a
        /// client old enough to hit this is a loose binary on `PATH`, and it
        /// fails loudly as `malformedResponse` ("Snitt and snitt-mcp are out
        /// of sync") rather than silently.
        public init(from decoder: any Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Code(rawValue: raw) ?? .internalError
        }
    }

    public var code: Code
    public var message: String
    public var hint: String?

    public init(code: Code, message: String, hint: String? = nil) {
        self.code = code
        self.message = message
        self.hint = hint
    }

    /// Distinct, non-zero exit codes so a shell script can branch without parsing
    /// JSON. Success is 0.
    ///
    /// §15 makes these a public interface, so every number here is frozen:
    /// D106 appends 17-19 and moves nothing. A script that branched on 16
    /// still means `internal_error`; what changed is which failures now carry
    /// a different code (and therefore a different number) instead.
    public static let exitCode: [Code: Int32] = [
        .consentRequired: 10,
        .upgradeRequired: 11,
        .noSuchSession: 12,
        .alreadyRecording: 13,
        .targetNotFound: 14,
        .permissionDenied: 15,
        .internalError: 16,
        .invalidArguments: 17,
        .unusableRecording: 18,
        .busy: 19,
        .bundleOpenInEditor: 20,
    ]
}

/// Renders §12.1's health metrics for display, omitting any metric that is
/// absent rather than reporting it as null or zero.
///
/// Shared by both frontends (§4.8: the CLI and the MCP server must not
/// diverge) so "absent means absent" is enforced in exactly one place. A nil
/// `CaptureHealth` — or a nil field within one — yields no key at all: an
/// agent branching on key PRESENCE must see a dead microphone as absent, not
/// as a reported measurement of zero or `null`.
public func healthFields(_ health: CaptureHealth?) -> [String: Double] {
    guard let health else { return [:] }
    var fields: [String: Double] = [:]
    if let v = health.meanFrameVariance { fields["meanFrameVariance"] = v }
    if let m = health.micRMS { fields["micRMS"] = m }
    if let s = health.systemAudioRMS { fields["systemAudioRMS"] = s }
    return fields
}

/// Renders `ExportManifest`'s size-budget honesty for display — the same
/// property this milestone spent its whole effort making `maxSizeMet` report
/// truthfully, one layer up: a human-readable summary is not "the JSON has
/// the field," it is a sentence a reader (or an agent) actually sees.
///
/// Shared by both frontends (§4.8, same reasoning as `healthFields`): if the
/// CLI and the MCP server each wrote their own wording, one of them would
/// eventually drift into announcing success sentences for a file that
/// missed its budget, silently. Returns `nil` when there is nothing to say —
/// no target was requested, or the target was met — so a caller appends this
/// only when it is non-nil rather than always emitting a trailing clause.
public func sizeBudgetNote(_ manifest: ExportManifest) -> String? {
    guard manifest.maxSizeMet == false, let maxSizeBytes = manifest.maxSizeBytes else {
        return nil
    }
    let actualMB = Double(manifest.byteSize) / 1_000_000
    let requestedMB = Double(maxSizeBytes) / 1_000_000
    return "over budget: \(String(format: "%.1f", actualMB)) MB > "
         + "\(String(format: "%.1f", requestedMB)) MB requested"
}

/// Says, in one sentence, that some vocabulary never reached the recogniser.
///
/// Shared by both frontends for the same reason `healthFields` and
/// `sizeBudgetNote` are (§4.8: the CLI and the MCP server must not diverge). A
/// silent truncation is the defect D104 fixes, and two hand-written renderings
/// would be two chances for one of them to go quiet again.
///
/// Returns `nil` when there is nothing to say (no vocabulary was sent, or all
/// of it was kept), so a caller appends this only when it is non-nil rather
/// than always emitting a trailing clause.
public func vocabularyNote(_ dropped: Int?) -> String? {
    guard let dropped, dropped > 0 else { return nil }
    let terms = dropped == 1 ? "term" : "terms"
    // Names the two reasons, because they need different fixes: a caller over
    // the limit should shorten the list, and a caller with a 300-character
    // paste should find what it pasted.
    return "\(dropped) vocabulary \(terms) did not reach the recogniser "
         + "(over the \(Vocabulary.limit)-term limit, or longer than "
         + "\(Vocabulary.maximumTermLength) characters)."
}

/// Says what an agent may NOT do right now, in one sentence, or nothing at all.
///
/// Shared for the same reason as `vocabularyNote`. Deliberately silent when
/// everything is permitted: a status line that recited its grants on every call
/// would train a reader to skip the line that matters.
///
/// Unattended is reported only when agent recording is ON. Below that it is not
/// the actionable half. A person has to enable agent recording first, and
/// naming a second switch they cannot usefully reach yet is noise in front of
/// the one they can.
public func consentNote(_ consent: ConsentInfo?) -> String? {
    guard let consent else { return nil }
    var clauses: [String] = []
    if !consent.agentRecording {
        clauses.append("agent recording is off, so every tool will refuse")
    } else {
        if !consent.fullDisplay {
            clauses.append("full-display recording is not allowed; record a window")
        }
        switch consent.unattended {
        case .active: break
        case .off:
            clauses.append("unattended recording was never enabled")
        case .lapsed:
            clauses.append("the unattended grant has lapsed and needs renewing "
                         + "in front of the machine")
        }
    }
    guard !clauses.isEmpty else { return nil }
    return clauses.joined(separator: "; ")
         + ". A person changes these in Snitt's settings."
}

public enum AutomationResponse: Codable, Sendable, Equatable {
    case handshake(HandshakeInfo)
    case targets([TargetSummary])
    /// `vocabularyDropped` counts the terms in `StartOptions.vocabulary` that
    /// never reached the recogniser (D104).
    ///
    /// `Vocabulary`'s own doc comment promises that "truncating is reported
    /// rather than silent", and `Vocabulary.prepare` duly returns the count.
    /// Nothing carried it to the caller, so an agent that listed 150 terms got
    /// an ordinary success and never learned that 50 of them were not biasing
    /// anything. Reported at START because that is when the truncation happens,
    /// and because it is the last moment a caller can still shorten its list
    /// and record again cheaply.
    ///
    /// `nil` means no vocabulary was supplied at all, which is a different
    /// answer from `0`: zero says terms were sent and every one was kept.
    ///
    /// Optional, and additive on a shipped wire format: see `.screenshotTaken`
    /// below and `ResponseWireCompatibilityTests`, which proves the older app's
    /// payload still decodes rather than assuming it.
    case started(sessionID: String, target: String, vocabularyDropped: Int? = nil)
    /// `health` was added to an already-Codable case without bumping
    /// `AutomationProtocol.version`. That is correct, not an oversight: v2 has
    /// never shipped — `main` has no `SnittAutomation` at all, and both PRs
    /// that would introduce it are unmerged — so there is no released v2
    /// client to stay compatible with. Amending an unreleased version is the
    /// right move; bumping to 3 would falsely imply a compatibility break
    /// against a version nobody has.
    case stopped(bundlePath: String, health: CaptureHealth?)
    case status(StatusInfo)
    case failure(AutomationError)
    case marked(timeSeconds: Double)
    case inspected(InspectReport)
    case trimmed(TrimSummary)
    case cropped(CropSummary)
    case autoTrimmed(AutoTrimSummary)
    case estimated([ExportEstimate])
    /// `imagePNG` is the frame itself, downscaled, and is present only when the
    /// caller asked for it with `inline`.
    ///
    /// It travels over the wire rather than being read from `path` because the
    /// frontends are thin clients (§4.9): a screenshot is written inside the
    /// `.snitt` bundle, which lives in the app's user-configurable output
    /// directory behind the Files-and-Folders TCC service. A frontend that
    /// opened the file itself would work on the developer's machine and return
    /// nothing on a user's, which is the same trap that once made `.stopped`
    /// omit health everywhere.
    ///
    /// Optional, and additive: `ResponseWireCompatibilityTests` proves an app
    /// that predates this field still decodes. That proof is required rather
    /// than assumed, because `.stopped`'s "v2 has never shipped" reasoning
    /// expired once v2 shipped.
    case screenshotTaken(path: String, timeSeconds: Double, imagePNG: Data? = nil)
    case exported(ExportManifest)
    case diagnosticsWritten(DiagnosticsReport)
    /// D107. `transcriptRead`, not `transcript`, because the request case is
    /// already called that and reading a switch with two `.transcript`s in it
    /// is a puzzle nobody needs to solve twice.
    case transcriptRead(TranscriptReport)
    case narrationAdded(NarrationSummary)
    case recordings(RecordingList)
}

/// What a trim produced, for a caller that cannot inspect `edit.json` itself
/// (the same reason `ExportManifest` exists — see its doc comment).
/// What a crop did, in PIXELS as well as fractions.
///
/// An agent cannot look at the video (§8's reason `snitt inspect` exists), so
/// "0.5 x 0.5" is not an answer it can act on — it needs the dimensions its
/// export will actually have, which is also what `--max-size` reasons about.
public struct CropSummary: Codable, Sendable, Equatable {
    public var crop: CropRect?
    public var pixelWidth: Int
    public var pixelHeight: Int

    public init(crop: CropRect?, pixelWidth: Int, pixelHeight: Int) {
        self.crop = crop
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

/// What an automatic trim removed (D57).
public struct AutoTrimSummary: Codable, Sendable, Equatable {
    /// Spans this run removed. Zero is a normal outcome, not a failure — the
    /// recording simply had no dead air by the criteria asked for.
    public var spans: Int
    public var seconds: Double
    /// Cuts in the recording afterwards, INCLUDING any that were already
    /// there. Reported separately from `spans` because re-running is expected
    /// and a caller needs to distinguish "added nothing" from "there is
    /// nothing here".
    public var totalCuts: Int
    /// Output duration after the trim.
    public var remainingSeconds: Double

    public init(spans: Int, seconds: Double, totalCuts: Int, remainingSeconds: Double) {
        self.spans = spans
        self.seconds = seconds
        self.totalCuts = totalCuts
        self.remainingSeconds = remainingSeconds
    }
}

public struct TrimSummary: Codable, Sendable, Equatable {
    public var keptSeconds: Double
    public var cutSeconds: Double
    public var cuts: [TimeRange]

    public init(keptSeconds: Double, cutSeconds: Double, cuts: [TimeRange]) {
        self.keptSeconds = keptSeconds
        self.cutSeconds = cutSeconds
        self.cuts = cuts
    }
}
