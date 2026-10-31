// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.

import AppKit

/// A cartoon "window with a face" for the welcome window. Drawn rather than
/// imported, because the thing it depicts is literally what Snitt records —
/// a window — so the mascot IS the product's own subject matter wearing a
/// face, not an unrelated illustration bolted beside it.
///
/// **Coordinate space.** Every geometric constant in this file (`Design`) is
/// written in a fixed 112x86 design space with Y INCREASING DOWNWARD, because
/// that is how the numbers read naturally when laid out ("the title bar sits
/// at y 23", "the eyes sit below that at y 46"). `isFlipped` returns `true`
/// so this view's own coordinate system already matches that convention —
/// the alternative (leaving the view unflipped and flipping every constant,
/// or flipping a transform at draw time) would mean every number in this
/// file disagrees with the comment describing it. All drawing here goes
/// through `MascotView.scale(_:)`, which maps the 112x86 design rect onto
/// `bounds` (150x115 at the natural size, generalised to whatever size the
/// owner actually gives the view — §"Resizing" below), so nothing downstream
/// of that one function needs to know the view was ever a different size.
///
/// **Appearance.** This view does NOT follow `NSApp.effectiveAppearance`.
/// `EditorChromePalette`'s rule is that CHROME follows the system appearance
/// and MEDIA SURFACES do not, because a media surface's own content should
/// carry the colour rather than compete with it — and what this view depicts
/// is a window, which in every other place this codebase draws one
/// (`TimelineView`, `EditorChromePalette.mediaWell`) is treated as media, not
/// chrome. Both colourways still have to exist, because the welcome window's
/// OWN background differs by context (a light marketing-style panel versus a
/// dark one), and a dark-frame mascot pinned permanently would read as a
/// hole in a light window exactly the way `EditorChromePalette`'s doc comment
/// describes for the uncoloured video well. The owner picks with `palette`;
/// this view never reads the system appearance to decide for itself.
///
/// Why the two colourways are not just a palette swap of the same shapes:
/// amber eyes glow convincingly against a dark frame because dark is what
/// makes something read as LIT. The same amber on a pale frame does not read
/// as lit, it reads as an animal's iris looking out of a paper window — which
/// is why `onLight` moves the warmth onto the FRAME instead and gives the
/// eyes a white sclera with a dark pupil, the same construction every
/// cartoon eye on a light background actually uses.
///
/// **No tear, no sulk, ever.** An earlier version of this mascot answered a
/// poke with a 2.8 second sulk and a tear that dripped twice. The product
/// owner's reaction was that it made them feel bad for clicking their own
/// app's mascot, which is the opposite of what a welcome-window character is
/// for. The poke response in this file is deliberately quick (an "ouch",
/// then a grin, then back to idle — see `poke(_:)`) and ends in something
/// cheerful. If you are reading this because you are about to add a tear,
/// a droop, or anything that lingers after the ouch: don't, that's the
/// regression this comment exists to prevent.
@MainActor
final class MascotView: NSView {

    // MARK: - Owner-facing API

    /// Which of the two fixed colourways to draw. Set by the owner, who
    /// knows what background it is sitting on — see this type's doc comment
    /// for why the view does not decide this for itself from the system
    /// appearance.
    var palette: Palette = .onDark {
        didSet {
            guard oldValue != palette else { return }
            refresh()
        }
    }

    /// 0...1. How close the owner's pointer is to whatever makes this
    /// mascot "want" the Record button — the owner decides what counts
    /// (hover proximity, a hotkey half-pressed, anything), this view only
    /// draws the result.
    ///
    /// Clamped on write rather than trusted, because the owner is free to
    /// hand this a hover-distance ratio that briefly overshoots 0...1
    /// (easing curves do that), and an eye ry outside the shapes this file
    /// was designed around is not something worth drawing.
    /// The ONLY place this value is clamped — `faceGeometry(mood:keenness:)`
    /// and `currentFaceScale` both trust it arrives already in 0...1, rather
    /// than each re-clamping their own copy. A second clamp downstream of
    /// this one would be defensive code with nothing left to defend against,
    /// which is exactly the kind of survivor `Scripts/mutate.sh`'s own doc
    /// comment calls out: it cannot fail, so it would inflate the kill count
    /// without proving anything.
    var keenness: Double = 0 {
        didSet {
            let clamped = min(max(keenness, 0), 1)
            if clamped != keenness {
                keenness = clamped
                return
            }
            guard clamped != oldValue else { return }
            refresh()
        }
    }

    /// True while the owner's pointer sits over the Record button. The face
    /// bobs gently while this is set — see `applyNodding()` — and composes
    /// with, rather than replaces, whatever the gaze is doing (§"Head turn"
    /// in the spec this view implements): the nod is an ADDITIVE animation
    /// on `faceLayer.position.y`, layered on top of the model value the
    /// gaze/head-turn logic already owns, exactly so one does not have to
    /// know about the other.
    var isNodding: Bool = false {
        didSet {
            guard oldValue != isNodding else { return }
            applyNodding()
        }
    }

    /// What the idle timer (or a poke) currently has this mascot doing.
    /// Read-only: the owner never sets this directly, including for a poke
    /// — a poke happens because the user activated one of the two buttons
    /// this view owns over its own eyes (`leftPokeButtonForTesting` /
    /// `rightPokeButtonForTesting`), not because the owner told it to. The
    /// owner's only two levers are `keenness` and `isNodding`, both of which
    /// describe something the OWNER knows (where its own Record button is)
    /// and neither of which is a mood.
    private(set) var mood: Mood = .idle

    enum Palette {
        case onDark
        case onLight
    }

    /// `wink` and the two `poke*` cases are the only asymmetric ones —
    /// everything else treats both eyes alike, which is what lets
    /// `faceGeometry(mood:keenness:)` stay one small switch instead of a
    /// pair of independent per-eye state machines.
    enum Mood: Equatable {
        case idle
        case blink
        case wink
        case happy
        case surprised
        case pokeLeft
        case pokeRight
    }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize { Design.naturalSize }

    // MARK: - Layers

    private let frameLayer = CAShapeLayer()
    private let titleLineLayer = CAShapeLayer()
    private let dotLayers = [CAShapeLayer(), CAShapeLayer(), CAShapeLayer()]
    private let recordCutoutLayer = CAShapeLayer()
    private let recordRingLayer = CAShapeLayer()
    private let recordDotLayer = CAShapeLayer()

    /// Everything that moves together for a head turn and scales together
    /// for keenness: both eyes, both pupils, the mouth. The frame, title
    /// line, traffic dots and record light are deliberately NOT inside this
    /// layer — a window does not lean when the thing drawn inside it turns
    /// to look at you.
    private let faceLayer = CALayer()
    private let leftEyeLayer = CAShapeLayer()
    private let rightEyeLayer = CAShapeLayer()
    private let leftPupilLayer = CAShapeLayer()
    private let rightPupilLayer = CAShapeLayer()
    private let mouthLayer = CAShapeLayer()

    // MARK: - Poke targets

    private let leftPokeButton = NSButton()
    private let rightPokeButton = NSButton()

    enum PokeSide {
        case left
        case right
    }

    // MARK: - State

    /// The clamped gaze unit vector, in DESIGN units — see
    /// `Self.clampedGazeUnit(fromEyeMidpoint:toward:)` for what "clamped"
    /// means and why the distance it is clamped against is measured in this
    /// view's own 112x86 units rather than screen points.
    private var gazeUnit = CGVector.zero

    // `nonisolated(unsafe)`: every write happens on the main actor like
    // everything else in this view, but `deinit` on a `@MainActor` class is
    // itself NOT guaranteed to run isolated (deallocation can happen from
    // any thread) — `PlayerLayerView`'s own doc comment on this exact
    // problem is why that view tears down in `viewWillMove(toWindow:)`
    // instead. The spec this view implements asks for cleanup in BOTH
    // `viewDidMoveToWindow` and `deinit`; `Timer.invalidate()` is documented
    // safe to call from any thread, which is what makes reaching it from a
    // nonisolated `deinit` a reasonable, narrow exception rather than a
    // general escape hatch.
    private nonisolated(unsafe) var idleTimer: Timer?
    private nonisolated(unsafe) var moodRevertTimer: Timer?
    private nonisolated(unsafe) var pokeRecoveryTimer: Timer?
    private nonisolated(unsafe) var pokeGrinTimer: Timer?

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setUp()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    private func setUp() {
        wantsLayer = true
        guard let root = layer else { return }

        for shape in [frameLayer, titleLineLayer] + dotLayers
            + [recordCutoutLayer, recordRingLayer, recordDotLayer] {
            root.addSublayer(shape)
            disableImplicitAnimations(shape)
        }
        frameLayer.lineWidth = 1.5
        titleLineLayer.lineWidth = 1.5
        titleLineLayer.fillColor = nil
        for dot in dotLayers { dot.strokeColor = nil }
        recordRingLayer.fillColor = nil
        recordRingLayer.lineWidth = 1.6

        root.addSublayer(faceLayer)
        disableImplicitAnimations(faceLayer)
        for shape in [leftEyeLayer, rightEyeLayer, leftPupilLayer, rightPupilLayer, mouthLayer] {
            faceLayer.addSublayer(shape)
            disableImplicitAnimations(shape)
        }
        mouthLayer.fillColor = nil
        mouthLayer.lineWidth = 2.6
        mouthLayer.lineCap = .round
        mouthLayer.lineJoin = .round

        setUpPokeButtons()
        refresh()
    }

    private func setUpPokeButtons() {
        for (button, label, action) in [
            (leftPokeButton, "Poke the left eye", #selector(leftPoked)),
            (rightPokeButton, "Poke the right eye", #selector(rightPoked)),
        ] {
            button.isBordered = false
            button.title = ""
            button.target = self
            button.action = action
            button.setAccessibilityLabel(label)
            addSubview(button)
        }
    }

    @objc private func leftPoked() { poke(.left) }
    @objc private func rightPoked() { poke(.right) }

    // MARK: - Layout

    override func layout() {
        super.layout()
        rebuildGeometry()
    }

    /// Everything that depends on `bounds.size` — the frame, title line,
    /// dots, record light, the poke buttons' hit rects, and (because the
    /// face sits inside the same canvas) the face layer's own anchor.
    /// Shape/colour state (mood, keenness, gaze) is untouched here;
    /// `refresh()` and `applyGaze()` own that.
    private func rebuildGeometry() {
        let scale = Design.scale(for: bounds.size)

        frameLayer.path = Self.scale(
            CGPath(roundedRect: Design.frameRect, cornerWidth: 9, cornerHeight: 9, transform: nil),
            by: scale)

        let titlePath = CGMutablePath()
        titlePath.move(to: CGPoint(x: Design.frameRect.minX, y: 23))
        titlePath.addLine(to: CGPoint(x: Design.frameRect.maxX, y: 23))
        titleLineLayer.path = Self.scale(titlePath, by: scale)

        for (dot, center) in zip(dotLayers, Design.dotCenters) {
            dot.path = Self.scale(circlePath(center: center, radius: 2.2), by: scale)
        }

        recordCutoutLayer.path = Self.scale(circlePath(center: Design.recordCenter, radius: 11), by: scale)
        recordRingLayer.path = Self.scale(circlePath(center: Design.recordCenter, radius: 9), by: scale)
        recordDotLayer.path = Self.scale(circlePath(center: Design.recordCenter, radius: 5), by: scale)

        // The face canvas spans the whole view; the anchor sits at the
        // face's own centre so `faceLayer.transform` scales and translates
        // around THAT point rather than the view's corner. With the anchor
        // set this way, a child layer's `position`/`path` expressed in plain
        // scaled-design-units equals its position in the view's own space —
        // see this type's doc comment on `faceLayer` for why nothing below
        // it needs to re-derive that.
        faceLayer.bounds = CGRect(origin: .zero, size: bounds.size)
        let faceCenter = Self.scale(Design.faceCenter, by: scale)
        faceLayer.anchorPoint = CGPoint(x: faceCenter.x / max(bounds.width, 1),
                                         y: faceCenter.y / max(bounds.height, 1))
        faceLayer.position = faceCenter

        layoutPokeButtons(scale: scale)
        refresh()
    }

    private func layoutPokeButtons(scale: CGVector) {
        for (button, center) in [(leftPokeButton, Design.leftEyeCenter),
                                  (rightPokeButton, Design.rightEyeCenter)] {
            let point = Self.scale(center, by: scale)
            button.frame = CGRect(x: point.x - 13, y: point.y - 13, width: 26, height: 26)
        }
    }

    private func disableImplicitAnimations(_ layer: CALayer) {
        // Every structural update in this file (`refresh()`) is a discrete
        // jump between named states, not a transition — a blink's 130ms hold
        // is a TIMER duration, not an easing duration. The handful of things
        // that genuinely animate (gaze, head turn, the nod, the record
        // light's pulse, the poke's wince) add their own explicit
        // `CABasicAnimation`s below, which would otherwise race Core
        // Animation's default ~0.25s implicit action on the same keys.
        layer.actions = ["position": NSNull(), "path": NSNull(), "transform": NSNull(),
                          "opacity": NSNull(), "fillColor": NSNull(), "strokeColor": NSNull()]
    }

    // MARK: - Resolved state (the part tests exercise)

    /// Every per-eye/mouth decision this view currently draws, as a pure
    /// function of `mood` and `keenness`. Kept separate from the layers
    /// themselves so a test can assert on the DECISION ("idle gives both
    /// eyes open") without decoding a `CGPath`.
    struct FaceGeometry: Equatable {
        var leftEyeRy: Double
        var rightEyeRy: Double
        var leftPupilRadius: Double
        var rightPupilRadius: Double
        var mouth: MouthStyle
    }

    enum MouthStyle: Equatable {
        case idle, wink, happy, surprised, pokedLeft, pokedRight

        /// The exact path string from the spec this view was built against.
        /// Kept as the literal strings, not re-derived from the `CGPath`
        /// construction in `MouthGeometry`, so a mutant that quietly swapped
        /// two of the hand-built curves would still be caught by a test
        /// that merely compares this string — the string and the drawing
        /// are two independent transcriptions of the same design decision.
        var svgPath: String {
            switch self {
            case .idle: return "M44 61c3.6 3.4 11.4 3.4 15 0"
            case .wink: return "M43 60c4 4.6 12 4.6 16 0"
            case .happy: return "M42 59c4.6 7 13.4 7 18 0"
            case .surprised: return "M47.6 62a3.9 4.5 0 1 0 7.8 0a3.9 4.5 0 1 0 -7.8 0"
            case .pokedLeft: return "M43.5 60.6q3.7 -1.2 7.4 0.8t7.4 1.4"
            case .pokedRight: return "M43.5 62.8q3.7 1.4 7.4 -0.8t7.4 -1.4"
            }
        }
    }

    private static func faceGeometry(mood: Mood, keenness: Double) -> FaceGeometry {
        let base: FaceGeometry
        switch mood {
        case .idle:
            base = FaceGeometry(leftEyeRy: 6.4, rightEyeRy: 6.4,
                                 leftPupilRadius: 1.8, rightPupilRadius: 1.8, mouth: .idle)
        case .blink:
            base = FaceGeometry(leftEyeRy: 0.7, rightEyeRy: 0.7,
                                 leftPupilRadius: 0, rightPupilRadius: 0, mouth: .idle)
        case .wink:
            base = FaceGeometry(leftEyeRy: 0.7, rightEyeRy: 6.4,
                                 leftPupilRadius: 0, rightPupilRadius: 1.8, mouth: .wink)
        case .happy:
            base = FaceGeometry(leftEyeRy: 4, rightEyeRy: 4,
                                 leftPupilRadius: 1.8, rightPupilRadius: 1.8, mouth: .happy)
        case .surprised:
            base = FaceGeometry(leftEyeRy: 7.6, rightEyeRy: 7.6,
                                 leftPupilRadius: 1.6, rightPupilRadius: 1.6, mouth: .surprised)
        case .pokeLeft:
            // Wide and startled on the OTHER eye, never narrowed — a
            // narrowed other eye reads as resentment, which is the exact
            // complaint that rewrote this response (see this file's top
            // doc comment on the sulk that preceded it).
            base = FaceGeometry(leftEyeRy: 0.5, rightEyeRy: 7.4,
                                 leftPupilRadius: 0, rightPupilRadius: 1.6, mouth: .pokedLeft)
        case .pokeRight:
            base = FaceGeometry(leftEyeRy: 7.4, rightEyeRy: 0.5,
                                 leftPupilRadius: 1.6, rightPupilRadius: 0, mouth: .pokedRight)
        }
        // Keenness is the owner's signal, not the mascot's own — it must
        // lose to anything the mascot is already doing on its own (a blink,
        // a wink, the poke's flinch), or the eyes would fight over two
        // different reasons to change shape at once. `mood == .idle` is
        // sufficient to gate this, with no separate "poked" flag needed:
        // every non-idle case above, poke included, is its own `Mood`.
        guard mood == .idle else { return base }
        // `keenness` arrives already clamped to 0...1 — see that property's
        // own doc comment for why this does not re-clamp it.
        let k = keenness
        var geometry = base
        geometry.leftEyeRy += k * Design.keennessEyeRy
        geometry.rightEyeRy += k * Design.keennessEyeRy
        geometry.leftPupilRadius += k * Design.keennessPupilRadius
        geometry.rightPupilRadius += k * Design.keennessPupilRadius
        if k > 0.5 { geometry.mouth = .happy }
        return geometry
    }

    private var currentGeometry: FaceGeometry { Self.faceGeometry(mood: mood, keenness: keenness) }

    private var currentFaceScale: Double {
        // Only idle keenness scales the face — see `faceGeometry`'s guard
        // for why the same gate applies here.
        guard mood == .idle else { return 1 }
        return 1 + keenness * Design.keennessScale
    }

    // MARK: - Drawing the resolved state

    private func refresh() {
        let colors = PaletteColors.colors(for: palette)
        let geometry = currentGeometry

        frameLayer.fillColor = colors.frameFill.cgColor
        frameLayer.strokeColor = colors.frameStroke.cgColor
        titleLineLayer.strokeColor = colors.titleLine.cgColor
        for dot in dotLayers { dot.fillColor = colors.dots.cgColor }
        recordCutoutLayer.fillColor = colors.recordCutout.cgColor
        recordRingLayer.strokeColor = colors.recordRingAndDot.cgColor
        recordDotLayer.fillColor = colors.recordRingAndDot.cgColor

        let scale = Design.scale(for: bounds.size)
        leftEyeLayer.path = Self.scale(eyeShape(center: Design.leftEyeCenter, ry: geometry.leftEyeRy), by: scale)
        rightEyeLayer.path = Self.scale(eyeShape(center: Design.rightEyeCenter, ry: geometry.rightEyeRy), by: scale)
        leftEyeLayer.fillColor = colors.eyeFill(open: geometry.leftEyeRy >= Design.shutEyeThreshold).cgColor
        rightEyeLayer.fillColor = colors.eyeFill(open: geometry.rightEyeRy >= Design.shutEyeThreshold).cgColor
        leftEyeLayer.strokeColor = colors.eyeStroke?.cgColor
        rightEyeLayer.strokeColor = colors.eyeStroke?.cgColor
        leftEyeLayer.lineWidth = 1
        rightEyeLayer.lineWidth = 1

        leftPupilLayer.path = Self.scale(circlePath(center: Design.leftEyeCenter, radius: geometry.leftPupilRadius), by: scale)
        rightPupilLayer.path = Self.scale(circlePath(center: Design.rightEyeCenter, radius: geometry.rightPupilRadius), by: scale)
        leftPupilLayer.fillColor = colors.pupil.cgColor
        rightPupilLayer.fillColor = colors.pupil.cgColor

        mouthLayer.path = Self.scale(MouthGeometry.path(for: geometry.mouth), by: scale)
        mouthLayer.strokeColor = colors.mouth.cgColor

        let faceScale = CGFloat(currentFaceScale)
        faceLayer.transform = CATransform3DScale(headTurnTransform(), faceScale, faceScale, 1)

        applyGaze(animated: false)
        applyRecordLightPulse()
    }

    /// An ellipse whose `ry` can be effectively zero (a shut eye) — CGPath's
    /// ellipse constructor handles a degenerate height fine, so no special
    /// case is needed for a blink beyond passing the small `ry` through.
    private func eyeShape(center: CGPoint, ry: Double) -> CGPath {
        let ry = CGFloat(ry)
        return CGPath(ellipseIn: CGRect(x: center.x - 5, y: center.y - ry, width: 10, height: ry * 2),
                      transform: nil)
    }

    private func circlePath(center: CGPoint, radius: Double) -> CGPath {
        let radius = max(CGFloat(radius), 0.0001)
        return CGPath(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                         width: radius * 2, height: radius * 2), transform: nil)
    }

    // MARK: - Scaling

    /// Maps a point/path from this file's fixed 112x86 design space onto
    /// however big `bounds` actually is. At the view's declared natural size
    /// (150x115) this is exactly the 150/112 by 115/86 scale the spec calls
    /// for; generalising it to `bounds.size` rather than hardcoding those
    /// two numbers means a window that, say, Auto Layout squeezes slightly
    /// still draws a correctly proportioned mascot instead of a clipped one.
    private static func scale(_ path: CGPath, by scale: CGVector) -> CGPath {
        var transform = CGAffineTransform(scaleX: scale.dx, y: scale.dy)
        return path.copy(using: &transform) ?? path
    }

    private static func scale(_ point: CGPoint, by scale: CGVector) -> CGPoint {
        CGPoint(x: point.x * scale.dx, y: point.y * scale.dy)
    }

    // MARK: - Gaze and head turn

    /// Which colourway suits an appearance.
    ///
    /// The DRAWING does not follow the appearance - it is always a
    /// window-shaped object, per this type's own doc comment - but it needs
    /// two colourways because the pane behind it does follow. Amber eyes read
    /// as lit on a dark frame and as an animal iris on a pale one, which is
    /// why the light version moves the colour onto the frame instead.
    static func palette(for appearance: NSAppearance) -> Palette {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .onDark : .onLight
    }

    /// Re-derived rather than set once at build time, so switching the system
    /// appearance with the window open does not leave a pale face on a dark
    /// pane. `EditorChromePalette` is the precedent for reading
    /// `bestMatch(from:)` at the moment of use.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        palette = Self.palette(for: effectiveAppearance)
    }

    /// Look at `point`, in this view's own coordinates.
    ///
    /// THE OWNER DRIVES THIS; the view does not track the pointer itself.
    /// A tracking area on this view can only ever see the pointer while it is
    /// inside these 150x115 points, so the eyes would follow for the last
    /// inch and ignore the rest of the window. The welcome window already
    /// watches the whole window to work out how near the pointer is to its
    /// Record button, so it is the one with the information.
    ///
    /// Having BOTH would also be a visible bug rather than merely redundant:
    /// a tracking area's `mouseExited` fires when the pointer leaves the
    /// mascot, so the eyes would snap front every time the pointer moved off
    /// the face and stayed in the window.
    func lookAt(_ point: NSPoint) {
        setGaze(toViewPoint: point)
    }

    /// Return the eyes to centre, for when the pointer leaves the window.
    func lookAway() {
        gazeUnit = .zero
        applyGaze(animated: true)
    }

    private func setGaze(toViewPoint point: NSPoint) {
        let scale = Design.scale(for: bounds.size)
        let designPoint = CGPoint(x: point.x / max(scale.dx, 0.0001), y: point.y / max(scale.dy, 0.0001))
        gazeUnit = Self.clampedGazeUnit(fromEyeMidpoint: Design.eyeMidpoint, toward: designPoint)
        applyGaze(animated: true)
    }

    /// A unit-ish vector from `midpoint` toward `point`, both in this view's
    /// own 112x86 design units, scaled by `min(1, distance / reach)` so a
    /// pointer anywhere beyond `reach` away produces exactly the same vector
    /// as one sitting right at `reach` — the clamp this view's gaze depends
    /// on to keep a pupil inside its eye regardless of how far outside the
    /// view the pointer gets reported.
    ///
    /// `reach` is measured in DESIGN units rather than screen points,
    /// matching every other distance in this file; at this view's natural
    /// size that is somewhat smaller than the "~210 points" a person reading
    /// past this view's own geometry might expect, but the two sizes differ
    /// by less than 1.5%, and using a second unit system just for this one
    /// number would be the real surprise.
    static func clampedGazeUnit(fromEyeMidpoint midpoint: CGPoint, toward point: CGPoint,
                                reach: CGFloat = 210) -> CGVector {
        let dx = point.x - midpoint.x
        let dy = point.y - midpoint.y
        let distance = (dx * dx + dy * dy).squareRoot()
        guard distance > 0.0001 else { return .zero }
        let factor = min(1, distance / reach)
        return CGVector(dx: (dx / distance) * factor, dy: (dy / distance) * factor)
    }

    private func headTurnTransform() -> CATransform3D {
        let offset = CGVector(dx: gazeUnit.dx * Design.headTurnFactor.dx,
                              dy: gazeUnit.dy * Design.headTurnFactor.dy)
        let scale = Design.scale(for: bounds.size)
        return CATransform3DMakeTranslation(offset.dx * scale.dx, offset.dy * scale.dy, 0)
    }

    /// Applies the current `gazeUnit` to the pupils (fast, 110ms — "the eyes
    /// dart first") and to `faceLayer`'s own transform (slow, 240ms — "the
    /// head follows"). The two different durations on two different layers
    /// are what makes this read as a head TURNING rather than the whole
    /// picture sliding; see this view's doc comment on `faceLayer`.
    private func applyGaze(animated: Bool) {
        let scale = Design.scale(for: bounds.size)
        let pupilOffset = CGVector(dx: gazeUnit.dx * Design.pupilGazeFactor.dx * scale.dx,
                                   dy: gazeUnit.dy * Design.pupilGazeFactor.dy * scale.dy)

        let headTarget = headTurnTransform()
        let faceScale = CGFloat(currentFaceScale)
        let fullTransform = CATransform3DScale(headTarget, faceScale, faceScale, 1)

        guard animated else {
            leftPupilLayer.path = Self.scale(circlePath(center: Design.leftEyeCenter, radius: currentGeometry.leftPupilRadius), by: scale)
            rightPupilLayer.path = Self.scale(circlePath(center: Design.rightEyeCenter, radius: currentGeometry.rightPupilRadius), by: scale)
            leftPupilLayer.position = CGPoint(x: pupilOffset.dx, y: pupilOffset.dy)
            rightPupilLayer.position = CGPoint(x: pupilOffset.dx, y: pupilOffset.dy)
            faceLayer.transform = fullTransform
            return
        }

        let pupilMove = CABasicAnimation(keyPath: "position")
        pupilMove.duration = Design.pupilEase
        pupilMove.timingFunction = CAMediaTimingFunction(name: .easeOut)
        pupilMove.fromValue = leftPupilLayer.presentation()?.position ?? leftPupilLayer.position
        leftPupilLayer.position = CGPoint(x: pupilOffset.dx, y: pupilOffset.dy)
        pupilMove.toValue = leftPupilLayer.position
        leftPupilLayer.add(pupilMove, forKey: "gazeMove")

        let rightMove = pupilMove.copy() as! CABasicAnimation
        rightMove.fromValue = rightPupilLayer.presentation()?.position ?? rightPupilLayer.position
        rightPupilLayer.position = CGPoint(x: pupilOffset.dx, y: pupilOffset.dy)
        rightMove.toValue = rightPupilLayer.position
        rightPupilLayer.add(rightMove, forKey: "gazeMove")

        let headMove = CABasicAnimation(keyPath: "transform")
        headMove.duration = Design.headEase
        headMove.timingFunction = CAMediaTimingFunction(name: .easeOut)
        headMove.fromValue = faceLayer.presentation()?.transform ?? faceLayer.transform
        faceLayer.transform = fullTransform
        headMove.toValue = faceLayer.transform
        faceLayer.add(headMove, forKey: "headTurn")
    }

    // MARK: - Nodding

    private static let nodKey = "nod"

    /// A gentle, continuous bob while `isNodding` is true, ADDED on top of
    /// whatever `faceLayer.transform`/`position` already holds for the head
    /// turn, rather than replacing it — see `isNodding`'s doc comment.
    private func applyNodding() {
        guard isNodding else {
            faceLayer.removeAnimation(forKey: Self.nodKey)
            return
        }
        guard faceLayer.animation(forKey: Self.nodKey) == nil else { return }
        let scale = Design.scale(for: bounds.size)
        let nod = CAKeyframeAnimation(keyPath: "position.y")
        nod.values = [0, Design.nodAmount * scale.dy, 0]
        nod.keyTimes = [0, 0.5, 1]
        nod.duration = Design.nodCycle
        nod.isAdditive = true
        nod.repeatCount = .infinity
        nod.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        faceLayer.add(nod, forKey: Self.nodKey)
    }

    // MARK: - Record light pulse

    private static let pulseKey = "pulse"

    private func applyRecordLightPulse() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            recordRingLayer.removeAnimation(forKey: Self.pulseKey)
            recordDotLayer.removeAnimation(forKey: Self.pulseKey)
            recordRingLayer.opacity = 1
            recordDotLayer.opacity = 1
            return
        }
        guard recordDotLayer.animation(forKey: Self.pulseKey) == nil else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.45
        pulse.duration = 1.1
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        recordRingLayer.add(pulse, forKey: Self.pulseKey)
        recordDotLayer.add(pulse.copy() as! CABasicAnimation, forKey: Self.pulseKey)
    }

    // MARK: - Mood timer (idle behaviour the view owns)

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            scheduleNextIdleMoodChange()
        } else {
            invalidateAllTimers()
        }
    }

    deinit {
        idleTimer?.invalidate()
        moodRevertTimer?.invalidate()
        pokeRecoveryTimer?.invalidate()
        pokeGrinTimer?.invalidate()
    }

    private func invalidateAllTimers() {
        idleTimer?.invalidate(); idleTimer = nil
        moodRevertTimer?.invalidate(); moodRevertTimer = nil
        pokeRecoveryTimer?.invalidate(); pokeRecoveryTimer = nil
        pokeGrinTimer?.invalidate(); pokeGrinTimer = nil
    }

    /// Target/selector, not a closure: `Timer.scheduledTimer`'s closure
    /// overload takes a plain `@Sendable` closure in this SDK overlay, which
    /// cannot touch main-actor state — `StatusItemController.update` hits
    /// the same wall and resolves it the same way.
    private func scheduleNextIdleMoodChange() {
        idleTimer?.invalidate()
        let delay = Double.random(in: 1.8...5.4)
        idleTimer = Timer.scheduledTimer(timeInterval: delay, target: self,
                                         selector: #selector(idleTimerFired),
                                         userInfo: nil, repeats: false)
    }

    @objc private func idleTimerFired() {
        beginTransientMood(Self.randomTransientMood())
    }

    /// Weighted so a blink is roughly 4 times as likely as any one of the
    /// other three expressions — "about 4 in 7" from the spec this view
    /// implements, written as a 7-way draw rather than a `Double` weight
    /// table because there are only four outcomes and the draw is easier to
    /// read back from the numbers than a set of normalised probabilities
    /// would be.
    private static func randomTransientMood() -> Mood {
        switch Int.random(in: 0..<7) {
        case 0, 1, 2, 3: return .blink
        case 4: return .wink
        case 5: return .happy
        default: return .surprised
        }
    }

    private static func holdDuration(for mood: Mood) -> TimeInterval {
        switch mood {
        case .blink: return 0.130
        case .wink: return 0.440
        case .happy, .surprised: return 0.820
        case .idle, .pokeLeft, .pokeRight: return 0
        }
    }

    private func beginTransientMood(_ mood: Mood) {
        self.mood = mood
        refresh()
        moodRevertTimer?.invalidate()
        moodRevertTimer = Timer.scheduledTimer(timeInterval: Self.holdDuration(for: mood), target: self,
                                               selector: #selector(moodRevertTimerFired),
                                               userInfo: nil, repeats: false)
    }

    @objc private func moodRevertTimerFired() {
        mood = .idle
        refresh()
        scheduleNextIdleMoodChange()
    }

    // MARK: - The poke

    /// The whole "ouch": a brief asymmetric flinch, then a grin, then back
    /// to idle — about 850ms end to end, and no part of it lingers past
    /// that. Every timer this sequence starts is invalidated FIRST, so
    /// poking again mid-ouch restarts cleanly from the top rather than
    /// layering a second recovery on top of the first one's.
    private func poke(_ side: PokeSide) {
        invalidateAllTimers()
        mood = side == .left ? .pokeLeft : .pokeRight
        refresh()
        animateWince()

        pokeRecoveryTimer = Timer.scheduledTimer(timeInterval: 0.430, target: self,
                                                 selector: #selector(pokeRecoveryTimerFired),
                                                 userInfo: nil, repeats: false)
    }

    @objc private func pokeRecoveryTimerFired() {
        mood = .happy
        refresh()
        pokeGrinTimer = Timer.scheduledTimer(timeInterval: 0.400, target: self,
                                             selector: #selector(pokeGrinTimerFired),
                                             userInfo: nil, repeats: false)
    }

    @objc private func pokeGrinTimerFired() {
        mood = .idle
        refresh()
        scheduleNextIdleMoodChange()
    }

    /// One sharp recoil with a little overshoot on the way back, decaying
    /// to rest over the same 430ms the poked eye stays shut. On the WHOLE
    /// view's layer, not the face's — a poke is something that happens to
    /// the mascot bodily, not an expression the face alone makes.
    private func animateWince() {
        guard let root = layer else { return }
        let keyframes = CAKeyframeAnimation(keyPath: "transform")
        let recoil = CATransform3DConcat(CATransform3DMakeTranslation(-4, 2, 0),
                                         CATransform3DMakeRotation(-3 * .pi / 180, 0, 0, 1))
        let overshoot = CATransform3DConcat(CATransform3DMakeTranslation(1.2, -0.6, 0),
                                            CATransform3DMakeRotation(0.8 * .pi / 180, 0, 0, 1))
        keyframes.values = [CATransform3DIdentity, recoil, overshoot, CATransform3DIdentity]
        keyframes.keyTimes = [0, 0.18, 0.62, 1]
        keyframes.duration = 0.430
        keyframes.timingFunction = CAMediaTimingFunction(name: .easeOut)
        root.add(keyframes, forKey: "wince")
    }

    // MARK: - Design constants

    private enum Design {
        static let naturalSize = NSSize(width: 150, height: 115)
        static let designSize = CGSize(width: 112, height: 86)

        static func scale(for size: NSSize) -> CGVector {
            CGVector(dx: max(size.width, 1) / designSize.width,
                     dy: max(size.height, 1) / designSize.height)
        }

        static let frameRect = CGRect(x: 5, y: 9, width: 92, height: 68)
        static let dotCenters = [CGPoint(x: 14, y: 16), CGPoint(x: 22, y: 16), CGPoint(x: 30, y: 16)]
        static let recordCenter = CGPoint(x: 93, y: 19)

        static let leftEyeCenter = CGPoint(x: 41, y: 46)
        static let rightEyeCenter = CGPoint(x: 62, y: 46)
        static let eyeMidpoint = CGPoint(x: 51.5, y: 46)
        /// Roughly the centroid of both eyes and the mouth — not load
        /// bearing for correctness (nothing compares against it), only for
        /// where keenness's face-scale and the head-turn transform pivot.
        static let faceCenter = CGPoint(x: 51.5, y: 52)

        /// Below this `ry` an eye is drawn fully shut rather than merely
        /// narrowed — used only by `onLight`'s eye-fill switch (see
        /// `PaletteColors.eyeFill`), since `onDark` keeps one eye colour
        /// regardless of how open the eye is.
        static let shutEyeThreshold: Double = 1.2

        static let pupilGazeFactor = CGVector(dx: 2.3, dy: 2.7)
        static let headTurnFactor = CGVector(dx: 3.2, dy: 2.65)
        static let pupilEase: CFTimeInterval = 0.110
        static let headEase: CFTimeInterval = 0.240

        static let nodAmount: CGFloat = 2.6
        static let nodCycle: CFTimeInterval = 0.760

        static let keennessEyeRy: Double = 1.7
        static let keennessPupilRadius: Double = 0.25
        static let keennessScale: Double = 0.06
    }

    private enum MouthGeometry {
        /// Hand-transcribed from each `MouthStyle.svgPath` string rather
        /// than parsed at runtime: there are exactly six of these, they
        /// never change at runtime, and a tiny general SVG path parser
        /// would be more code, and a new way to get the geometry wrong, for
        /// a one-time translation that is easy to check by hand against the
        /// six fixed strings in `MouthStyle.svgPath`.
        static func path(for style: MouthStyle) -> CGPath {
            let path = CGMutablePath()
            switch style {
            case .idle:
                path.move(to: CGPoint(x: 44, y: 61))
                path.addCurve(to: CGPoint(x: 59, y: 61),
                              control1: CGPoint(x: 47.6, y: 64.4), control2: CGPoint(x: 55.4, y: 64.4))
            case .wink:
                path.move(to: CGPoint(x: 43, y: 60))
                path.addCurve(to: CGPoint(x: 59, y: 60),
                              control1: CGPoint(x: 47, y: 64.6), control2: CGPoint(x: 55, y: 64.6))
            case .happy:
                path.move(to: CGPoint(x: 42, y: 59))
                path.addCurve(to: CGPoint(x: 60, y: 59),
                              control1: CGPoint(x: 46.6, y: 66), control2: CGPoint(x: 55.4, y: 66))
            case .surprised:
                path.addPath(CGPath(ellipseIn: CGRect(x: 47.6, y: 57.5, width: 7.8, height: 9), transform: nil))
            case .pokedLeft:
                path.move(to: CGPoint(x: 43.5, y: 60.6))
                path.addQuadCurve(to: CGPoint(x: 50.9, y: 61.4), control: CGPoint(x: 47.2, y: 59.4))
                path.addQuadCurve(to: CGPoint(x: 58.3, y: 62.8), control: CGPoint(x: 54.6, y: 63.4))
            case .pokedRight:
                path.move(to: CGPoint(x: 43.5, y: 62.8))
                path.addQuadCurve(to: CGPoint(x: 50.9, y: 62.0), control: CGPoint(x: 47.2, y: 64.2))
                path.addQuadCurve(to: CGPoint(x: 58.3, y: 60.6), control: CGPoint(x: 54.6, y: 59.8))
            }
            return path
        }
    }

    /// The two fixed colourways. Decimal `NSColor(srgbRed:green:blue:)`
    /// triples transcribed from the spec's hex values, matching how
    /// `SnittPalette` already writes its own constants rather than adding a
    /// hex-parsing initialiser this file would be the only caller of.
    private struct PaletteColors {
        let frameFill: NSColor
        let frameStroke: NSColor
        let titleLine: NSColor
        let dots: NSColor
        let eyeOpenFill: NSColor
        let eyeShutFill: NSColor
        let eyeStroke: NSColor?
        let pupil: NSColor
        let mouth: NSColor
        let recordCutout: NSColor
        let recordRingAndDot: NSColor

        func eyeFill(open: Bool) -> NSColor { open ? eyeOpenFill : eyeShutFill }

        static func colors(for palette: Palette) -> PaletteColors {
            switch palette {
            case .onDark:
                return PaletteColors(
                    frameFill: NSColor(srgbRed: 0.1686, green: 0.1765, blue: 0.1961, alpha: 1),
                    frameStroke: NSColor(srgbRed: 0.2392, green: 0.2510, blue: 0.2784, alpha: 1),
                    titleLine: NSColor(srgbRed: 0.2392, green: 0.2510, blue: 0.2784, alpha: 1),
                    dots: NSColor(srgbRed: 0.2902, green: 0.3020, blue: 0.3333, alpha: 1),
                    eyeOpenFill: NSColor(srgbRed: 1.0, green: 0.7216, blue: 0.3020, alpha: 1),
                    eyeShutFill: NSColor(srgbRed: 1.0, green: 0.7216, blue: 0.3020, alpha: 1),
                    eyeStroke: nil,
                    pupil: NSColor(srgbRed: 0.1137, green: 0.1176, blue: 0.1294, alpha: 1),
                    mouth: NSColor(srgbRed: 1.0, green: 0.7216, blue: 0.3020, alpha: 1),
                    recordCutout: NSColor(srgbRed: 0.1137, green: 0.1176, blue: 0.1294, alpha: 1),
                    recordRingAndDot: NSColor(srgbRed: 1.0, green: 0.3725, blue: 0.3412, alpha: 1))
            case .onLight:
                return PaletteColors(
                    frameFill: NSColor(srgbRed: 0.9922, green: 0.9490, blue: 0.8824, alpha: 1),
                    frameStroke: NSColor(srgbRed: 0.9098, green: 0.7686, blue: 0.5529, alpha: 1),
                    titleLine: NSColor(srgbRed: 0.9098, green: 0.7686, blue: 0.5529, alpha: 1),
                    dots: NSColor(srgbRed: 0.8627, green: 0.6941, blue: 0.4627, alpha: 1),
                    eyeOpenFill: .white,
                    eyeShutFill: NSColor(srgbRed: 0.8510, green: 0.7059, blue: 0.4941, alpha: 1),
                    eyeStroke: NSColor(srgbRed: 0.8510, green: 0.7059, blue: 0.4941, alpha: 1),
                    pupil: NSColor(srgbRed: 0.2627, green: 0.2078, blue: 0.1216, alpha: 1),
                    mouth: NSColor(srgbRed: 0.6627, green: 0.4549, blue: 0.1647, alpha: 1),
                    recordCutout: NSColor(srgbRed: 0.9922, green: 0.9490, blue: 0.8824, alpha: 1),
                    recordRingAndDot: NSColor(srgbRed: 0.8784, green: 0.2667, blue: 0.2314, alpha: 1))
            }
        }
    }

    // MARK: - Test seams

    var leftEyeRyForTesting: Double { currentGeometry.leftEyeRy }
    var rightEyeRyForTesting: Double { currentGeometry.rightEyeRy }
    var leftPupilRadiusForTesting: Double { currentGeometry.leftPupilRadius }
    var rightPupilRadiusForTesting: Double { currentGeometry.rightPupilRadius }
    var mouthPathForTesting: String { currentGeometry.mouth.svgPath }
    var faceScaleForTesting: Double { currentFaceScale }
    var gazeOffsetForTesting: CGVector {
        CGVector(dx: gazeUnit.dx * Design.pupilGazeFactor.dx, dy: gazeUnit.dy * Design.pupilGazeFactor.dy)
    }
    var leftPokeButtonForTesting: NSButton { leftPokeButton }
    var rightPokeButtonForTesting: NSButton { rightPokeButton }

    func setMoodForTesting(_ mood: Mood) {
        invalidateAllTimers()
        self.mood = mood
        refresh()
    }

    func pokeForTesting(_ side: PokeSide) { poke(side) }

    func simulateGazeForTesting(pointerDesignUnits point: CGPoint) {
        gazeUnit = Self.clampedGazeUnit(fromEyeMidpoint: Design.eyeMidpoint, toward: point)
        applyGaze(animated: false)
    }
}
