// CurtainView.swift - the Metal view filling the overlay window. It owns the
// cloth and the renderer, runs the simulation from the display timer, and
// turns mouse input into curtain interaction.

import AppKit
import MetalKit
import CurtainCore

final class CurtainView: MTKView {
    private let renderer: Renderer
    private(set) var cloth: Cloth
    private var mesh: ClothMesh
    private(set) var isDragging = false     // the edge or the fabric is in hand
    private var isTugging = false            // ...specifically the fabric
    private var grabOffset: Float = 0
    private var snapshotTaken = false
    /// Called whenever the curtain's open/closed state may have changed.
    var onStateChange: (() -> Void)?

    let sound = SoundEngine()
    private let haptics = NSHapticFeedbackManager.defaultPerformer

    private var lastFrameTime = CACurrentMediaTime()
    private let launchTime = CACurrentMediaTime()
    /// How far above the screen the rail starts at launch, before it is
    /// lowered into place; 0 once it has arrived.
    private var dropHeight: Float = 0
    private var lastCursor: (point: SIMD2<Float>, time: CFTimeInterval)?

    /// What is under the cursor, for choosing the cursor image.
    private enum Zone { case outside, fabric, grab, dragging }
    private var zone = Zone.outside

    init(frame: NSRect) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("This Mac has no Metal device")
        }
        renderer = Renderer(device: device, look: initialLook())
        dropHeight = Float(frame.height) * Tuning.heightFactor + 20
        cloth = CurtainView.makeCloth(for: frame.size, lift: -dropHeight)
        mesh = ClothMesh(cloth: cloth)
        super.init(frame: frame, device: device)

        colorPixelFormat = .bgra8Unorm
        depthStencilPixelFormat = .depth32Float   // folds can pass in front of each other
        framebufferOnly = snapshotPath == nil     // snapshots need to read the frame back
        // Transparent clear colour: wherever nothing is drawn, the desktop shows.
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        // MTKView's backing CAMetalLayer is opaque (black) unless told otherwise.
        layer?.isOpaque = false
        autoresizingMask = [.width, .height]

        // MTKView runs a display-synchronised timer and calls draw(_:) at this
        // rate while isPaused is false. The moment the cloth falls asleep we
        // pause it, so an idle curtain costs nothing; input wakes it again.
        preferredFramesPerSecond = CurtainView.displayRefreshRate
        enableSetNeedsDisplay = false
        isPaused = false
        debugLog("rendering at up to \(preferredFramesPerSecond) fps")
    }

    /// The main display's refresh rate: 120 on a ProMotion screen, 60 on most.
    private static var displayRefreshRate: Int {
        max(OverlayWindow.mainScreen.maximumFramesPerSecond, 30)
    }

    required init(coder: NSCoder) { fatalError("not used") }

    /// Put y=0 at the top, like the DOM. AppKit's default is y=0 at the bottom.
    override var isFlipped: Bool { true }

    /// A click on a window that is not key normally just activates it and is
    /// otherwise dropped. We want that first click to count as a grab.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private static func makeCloth(for size: CGSize, lift: Float) -> Cloth {
        let railLeft = -Tuning.railOverhang
        let railRight = Float(size.width) + Tuning.railOverhang
        let cloth = Cloth(width: (railRight - railLeft) * Tuning.widthFactor,
                          height: Float(size.height) * Tuning.heightFactor,
                          railY: Tuning.railY, railLeft: railLeft, railRight: railRight,
                          open: !startClosed)
        cloth.railLift = Tuning.dropDuration > 0 ? lift : 0
        cloth.settle(steps: 240)   // two seconds of hanging, so the first frame is calm
        return cloth
    }

    /// Start over with a cloth sized for the current screen.
    func resetCloth() {
        dropHeight = 0
        cloth = CurtainView.makeCloth(for: bounds.size, lift: 0)
        mesh = ClothMesh(cloth: cloth)
        preferredFramesPerSecond = CurtainView.displayRefreshRate
        wake()
    }

    /// Draw one frame now, e.g. after a Space switch, even while asleep.
    func redraw() {
        draw()
    }

    /// Lower the rail into place after launch, with the fabric hanging from
    /// it. The rail speeds up at a constant rate for the first half of the
    /// way and slows at the same rate for the second, never accelerating
    /// faster than 80% of gravity: any faster and the fabric cannot fall as
    /// fast as the rail descends, so it crumples, as a real curtain would.
    /// The curtain is stepped throughout, so it is physics that carries the
    /// cloth, not an animation of the cloth.
    private func updateDrop(now: CFTimeInterval) {
        guard dropHeight > 0 else { return }
        let height = dropHeight
        var duration = Tuning.dropDuration
        var acceleration = 4 * height / (duration * duration)
        let limit = 0.8 * Tuning.gravity
        if acceleration > limit {
            acceleration = limit
            duration = (4 * height / acceleration).squareRoot()
        }
        let t = Float(now - launchTime)
        let travelled: Float
        if t < duration / 2 {
            travelled = 0.5 * acceleration * t * t
        } else if t < duration {
            let remaining = duration - t
            travelled = height - 0.5 * acceleration * remaining * remaining
        } else {
            travelled = height
        }
        cloth.railLift = -(height - travelled)
        if t >= duration {
            cloth.railLift = 0
            dropHeight = 0
        }
    }

    // MARK: Open and close

    /// Closed means the leading edge is past the middle of the rail, or is
    /// on its way there.
    var isClosed: Bool {
        let range = cloth.leadingEdgeRange
        let x = cloth.slideTarget ?? cloth.leadingEdgeX
        return x > (range.lowerBound + range.upperBound) / 2
    }

    /// Slide the rings to the other end; the fabric follows through physics.
    func toggle() {
        guard !isDragging else { return }
        let range = cloth.leadingEdgeRange
        cloth.slideLeadingEdge(to: isClosed ? range.lowerBound : range.upperBound)
        wake()
        onStateChange?()
        debugLog(isClosed ? "closing" : "opening")
    }

    // MARK: Frames

    override func draw(_ dirtyRect: NSRect) {
        let now = CACurrentMediaTime()
        let elapsed = now - lastFrameTime
        lastFrameTime = now

        updateDrop(now: now)
        cloth.advance(by: elapsed)
        mesh.update(from: cloth)
        renderer.render(mesh: mesh, in: self)
        playback()

        let overdue = snapshotDeadline.map { now - launchTime > $0 } ?? false
        if let path = snapshotPath, !snapshotTaken, !cloth.isAwake || overdue {
            // One more frame, captured, before pausing.
            snapshotTaken = true
            renderer.snapshotHandler = { Snapshot.save(texture: $0, to: path) }
            return
        }
        if !cloth.isAwake {
            isPaused = true
            debugLog("cloth settled; rendering paused")
        }
    }

    private func wake() {
        cloth.wake()
        if isPaused {
            lastFrameTime = CACurrentMediaTime()
            isPaused = false
            debugLog("cloth woke up")
        }
    }

    /// Turn what the cloth did this frame into sound and haptics.
    private func playback() {
        let events = cloth.takeEvents()
        sound.setRunning(cloth.isAwake)
        let edgeLevel = abs(cloth.leadingEdgeSpeed) / Tuning.dragMaxSpeed
        let fabricLevel = cloth.fabricSpeed / 2500
        sound.setSwish(cloth.isAwake ? max(edgeLevel, fabricLevel) : 0)
        sound.click(count: events.ringClicks)
        if events.endHitSpeed > 0 {
            sound.thump(speed: events.endHitSpeed)
            haptics.perform(.levelChange, performanceTime: .now)
            onStateChange?()
        }
    }

    /// The fabric on the rail, switchable from the menu.
    var look: FabricLook {
        get { renderer.look }
        set { renderer.look = newValue; redraw() }
    }

    // MARK: Mouse

    /// Every cursor move anywhere on screen arrives here in view coordinates,
    /// whether or not the window is currently catching the mouse. Fast moves
    /// over visible fabric become gusts; the cursor image follows what is
    /// under it. `overFabric` is false when another window covers the fabric
    /// at that point, so working in a window on top of a closed curtain does
    /// not keep stirring it.
    func cursorMoved(to point: NSPoint, overFabric: Bool) {
        let now = CACurrentMediaTime()
        let p = SIMD2<Float>(Float(point.x), Float(point.y))
        updateZone(at: p)

        defer { lastCursor = (p, now) }
        guard overFabric, let last = lastCursor else { return }
        let dt = Float(now - last.time)
        guard dt > 0, dt < 0.1 else { return }   // after a pause the first move is a jump, not a gust
        let motion = p - last.point
        guard length(motion) / dt >= Tuning.windMinSpeed else { return }

        cloth.applyGust(at: p, motion: motion)
        wake()
    }

    private func updateZone(at p: SIMD2<Float>) {
        let new: Zone
        if isDragging { new = .dragging }
        else if cloth.grabZoneContains(p) { new = .grab }
        else if cloth.fabricContains(p) { new = .fabric }
        else { new = .outside }
        guard new != zone else { return }
        zone = new
        switch zone {
        case .grab, .fabric: NSCursor.openHand.set()
        case .dragging: NSCursor.closedHand.set()
        case .outside: NSCursor.arrow.set()
        }
    }

    /// Is this point on fabric? The window catches the mouse only where it is.
    func curtainContains(_ point: NSPoint) -> Bool {
        cloth.fabricContains(SIMD2(Float(point.x), Float(point.y)))
    }

    override func mouseDown(with event: NSEvent) {
        let p = location(of: event)
        if cloth.grabZoneContains(p) {
            isDragging = true
            isTugging = false
            grabOffset = cloth.leadingEdgeX - p.x
            cloth.holdLeadingEdge(at: p.x + grabOffset)
            debugLog("grabbed the leading edge at \(Int(p.x)),\(Int(p.y))")
        } else if cloth.holdFabric(at: p) {
            isDragging = true
            isTugging = true
            debugLog("tugging the fabric at \(Int(p.x)),\(Int(p.y))")
        } else {
            return   // on fabric but nothing to hold: just absorb the click
        }
        haptics.perform(.alignment, performanceTime: .now)
        updateZone(at: p)
        wake()
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        let p = location(of: event)
        if isTugging {
            cloth.moveHeldFabric(to: p)
        } else {
            cloth.holdLeadingEdge(at: p.x + grabOffset)
        }
        wake()
    }

    override func mouseUp(with event: NSEvent) {
        guard isDragging else { return }
        isDragging = false
        if isTugging {
            cloth.releaseFabric()
            isTugging = false
        } else {
            cloth.releaseLeadingEdge()
            debugLog("released the leading edge at x=\(Int(cloth.leadingEdgeX))")
        }
        (window as? OverlayWindow)?.cursorMoved()
        onStateChange?()
    }

    private func location(of event: NSEvent) -> SIMD2<Float> {
        let p = convert(event.locationInWindow, from: nil)
        return SIMD2(Float(p.x), Float(p.y))
    }
}
