// Cloth.swift - the simulation. A grid of particles joined by distance
// constraints, stepped with Verlet integration. Pure maths, no AppKit, so the
// tests can run it headless.
//
// Verlet in one paragraph: instead of storing a velocity per particle we keep
// the previous position; velocity is (current - previous). Each step moves a
// particle by that velocity plus gravity, then the constraints nudge particles
// back toward their rest distances. Because corrections edit positions
// directly and velocity is derived from them, the result is very stable.
//
// The top row of particles are the rings. They sit on the rail (fixed y and
// z) and only ever move sideways, and only because a neighbouring ring pulls
// or pushes them: never further apart than the fabric between them allows,
// never closer than a ring's thickness. The hanging fabric cannot shove them
// along, which is what gives the curtain its "stays where you left it" feel.
// Ring 0 is fixed at the left end of the rail; the last ring is the leading
// edge you drag.
//
// Pleats: the fabric remembers a wave shape across its width, like pressed
// pleats. Each column has a preferred depth that depends on how tightly its
// rings are bunched, and the links that run across the fabric take their rest
// lengths from that shape, so they hold the pleats instead of fighting them.
// In the few rows just below the rail the pleats are gathered flat, as fabric
// is in a heading tape.

import simd

public final class Cloth {
    public let columns: Int
    public let rows: Int
    /// Rest distance between neighbouring particles across and down.
    public let spacingX: Float
    public let spacingY: Float
    public let railY: Float
    public let railLeft: Float
    public let railRight: Float

    /// Particle positions, row-major: index = row * columns + column.
    /// Row 0 is the rings.
    public private(set) var positions: [SIMD3<Float>]
    /// Positions one step ago.
    private var previous: [SIMD3<Float>]

    /// A distance constraint between two particles.
    private struct Link {
        enum Kind: UInt8 {
            case down         // same column, one row apart: the warp threads
            case bendDown     // same column, two rows apart
            case across       // same row, one column apart: the weft threads
            case bendAcross   // same row, two columns apart
            case shear        // diagonal
        }
        let a: Int32
        let b: Int32
        let stiffness: Float
        let kind: Kind
    }
    private var links: [Link] = []
    /// Current rest length of each link. Fixed for the vertical kinds,
    /// recomputed every step from the pleat shape for the others.
    private var rest: [Float] = []

    /// Each column's phase in the pleat wave (0, +1, 0, -1 ...), with a fixed
    /// wobble so the pleats are not perfectly regular.
    private let pleatShape: [Float]
    /// Each column's preferred depth right now.
    private var pleatTarget: [Float]

    /// While the leading edge is being dragged, where the hand is. The edge
    /// is pulled towards it, not welded to it: see driveLeadingEdge().
    private var heldX: Float?
    /// While the menu/shortcut is sliding the leading edge, where it is going.
    public private(set) var slideTarget: Float?
    /// The leading ring's sideways speed, points per second. The only ring
    /// with momentum; the rest are placed by the chain.
    private var edgeVelocity: Float = 0
    /// A fabric particle pinned to the hand (a tug), and where it is held.
    private var heldParticle: Int?
    private var heldPosition = SIMD3<Float>()
    /// Vertical offset of the whole rail, for lowering it into place at launch.
    public var railLift: Float = 0

    /// Things that happened during the last steps, for sound and haptics.
    public struct Events {
        /// Ring pairs that came together on the rail.
        public var ringClicks = 0
        /// Speed at which the leading edge hit the end of the rail, if it did.
        public var endHitSpeed: Float = 0
    }
    private var pending = Events()
    /// Fastest any particle moved in the last step, points per second.
    public private(set) var fabricSpeed: Float = 0

    private var accumulator: Float = 0
    private var stillSteps = 0
    /// False once the fabric has stopped moving. advance(by:) then does nothing
    /// until something wakes it.
    public private(set) var isAwake = true

    /// A cloth of the given unstretched size hanging from a rail at y = railY
    /// that runs from railLeft to railRight, starting bunched up (`open`) or
    /// spread across the rail.
    public init(width: Float, height: Float, railY: Float,
                railLeft: Float, railRight: Float, open: Bool) {
        columns = Tuning.columns
        rows = Tuning.rows
        spacingX = width / Float(columns - 1)
        spacingY = height / Float(rows - 1)
        self.railY = railY
        self.railLeft = railLeft
        self.railRight = railRight

        pleatShape = (0..<columns).map { c in
            let wobble = sin(Float(c) * 12.9898 + 4.1414) * 0.5 + 0.5     // 0...1, fixed per column
            let amplitude = 1 - Tuning.pleatVariation * wobble
            return sin(Float(c) * 2 * .pi / Float(Tuning.pleatWavelength)) * amplitude
        }
        pleatTarget = Array(repeating: 0, count: columns)

        let ringSpacing = open ? Tuning.ringMinSpacing : (railRight - railLeft) / Float(columns - 1)
        positions = []
        positions.reserveCapacity(columns * rows)
        for r in 0..<rows {
            for c in 0..<columns {
                positions.append(SIMD3(railLeft + Float(c) * ringSpacing, railY + Float(r) * spacingY, 0))
            }
        }
        previous = positions

        func link(_ a: Int, _ b: Int, _ stiffness: Float, _ kind: Link.Kind) {
            guard stiffness > 0 else { return }
            links.append(Link(a: Int32(a), b: Int32(b), stiffness: stiffness, kind: kind))
        }
        for r in 0..<rows {
            for c in 0..<columns {
                let i = r * columns + c
                if r + 1 < rows { link(i, i + columns, Tuning.structuralStiffness, .down) }
                if r + 2 < rows { link(i, i + 2 * columns, Tuning.bendStiffness, .bendDown) }
                guard r > 0 else { continue }   // rings have no sideways links; the rail handles them
                if c + 1 < columns { link(i, i + 1, Tuning.structuralStiffness, .across) }
                if c + 2 < columns { link(i, i + 2, Tuning.bendStiffness, .bendAcross) }
                if c + 1 < columns && r + 1 < rows {
                    link(i, i + columns + 1, Tuning.shearStiffness, .shear)
                    link(i + 1, i + columns, Tuning.shearStiffness, .shear)
                }
            }
        }
        rest = Array(repeating: 0, count: links.count)

        // Start already in the pleat shape so the first frames are calm.
        // (Every stored property has a value by now, which Swift insists on
        // before a method may be called from an initializer.)
        updatePleats()
        for r in 1..<rows {
            for c in 0..<columns {
                positions[r * columns + c].z = pleatTarget[c] * Cloth.pleatFade(row: r)
            }
        }
        previous = positions
    }

    // MARK: The leading edge

    /// Where the leading edge (the last ring) is on the rail.
    public var leadingEdgeX: Float { positions[columns - 1].x }

    /// Sideways speed of the leading edge, points per second.
    public var leadingEdgeSpeed: Float { edgeVelocity }

    /// Where the leading edge can be: fully open (rings packed) to fully closed.
    public var leadingEdgeRange: ClosedRange<Float> {
        (railLeft + Float(columns - 1) * Tuning.ringMinSpacing)...railRight
    }

    /// Hold the leading edge towards x (a drag in progress). Everything else
    /// follows through the constraints.
    public func holdLeadingEdge(at x: Float) {
        heldX = clamp(x)
        slideTarget = nil
        wake()
    }

    /// Let go of the edge. Released faster than Tuning.flingSpeed it carries
    /// on to the end of the rail by itself.
    public func releaseLeadingEdge() {
        heldX = nil
        if abs(edgeVelocity) > Tuning.flingSpeed {
            slideTarget = edgeVelocity > 0 ? leadingEdgeRange.upperBound : leadingEdgeRange.lowerBound
        }
    }

    /// Collect what happened since the last call.
    public func takeEvents() -> Events {
        defer { pending = Events() }
        return pending
    }

    // MARK: Tugging

    /// Pin the fabric particle nearest to p (x, y) to the hand, lifted a
    /// little towards the viewer. Returns false if nothing is close enough.
    @discardableResult
    public func holdFabric(at p: SIMD2<Float>) -> Bool {
        var best = -1
        var bestDistSq = Tuning.tugRadius * Tuning.tugRadius
        for i in columns..<positions.count {
            let d = SIMD2(positions[i].x, positions[i].y) - p
            let distSq = length_squared(d)
            if distSq < bestDistSq { bestDistSq = distSq; best = i }
        }
        guard best >= 0 else { return false }
        heldParticle = best
        heldPosition = SIMD3(p.x, p.y, positions[best].z + Tuning.tugLift)
        wake()
        return true
    }

    public func moveHeldFabric(to p: SIMD2<Float>) {
        guard heldParticle != nil else { return }
        heldPosition.x = p.x
        heldPosition.y = p.y
        wake()
    }

    public func releaseFabric() {
        heldParticle = nil
    }

    /// Slide the leading edge to x (menu/shortcut).
    public func slideLeadingEdge(to x: Float) {
        slideTarget = clamp(x)
        wake()
    }

    public var isHeld: Bool { heldX != nil }

    private func clamp(_ x: Float) -> Float {
        min(max(x, leadingEdgeRange.lowerBound), leadingEdgeRange.upperBound)
    }

    // MARK: Hit testing

    /// The fabric's left and right extent at a given height.
    public func horizontalExtent(atY y: Float) -> ClosedRange<Float> {
        let r = min(max(Int((y - railY) / spacingY), 0), rows - 1)
        var left = Float.greatestFiniteMagnitude, right = -Float.greatestFiniteMagnitude
        for c in 0..<columns {
            let x = positions[r * columns + c].x
            left = min(left, x)
            right = max(right, x)
        }
        return left...right
    }

    /// Is this point on fabric?
    public func fabricContains(_ p: SIMD2<Float>) -> Bool {
        guard p.y >= railY else { return false }
        let extent = horizontalExtent(atY: p.y)
        return p.x >= extent.lowerBound - 2 && p.x <= extent.upperBound + 2
    }

    /// Is this point within grabbing distance of the leading edge?
    public func grabZoneContains(_ p: SIMD2<Float>) -> Bool {
        guard p.y >= railY else { return false }
        let edge = horizontalExtent(atY: p.y).upperBound
        return p.x >= edge - Tuning.grabWidth && p.x <= edge + 8
    }

    // MARK: Stepping

    /// Advance by `elapsed` seconds of wall time using whole fixed steps, with
    /// the remainder carried over to the next call. Returns the number of
    /// steps taken (0 while asleep).
    @discardableResult
    public func advance(by elapsed: Double) -> Int {
        guard isAwake else { return 0 }
        accumulator += Float(min(elapsed, Tuning.maxFrameTime))
        var steps = 0
        while accumulator >= Tuning.timestep && steps < Tuning.maxSubsteps {
            step(Tuning.timestep)
            accumulator -= Tuning.timestep
            steps += 1
        }
        if steps == Tuning.maxSubsteps { accumulator = 0 }   // too far behind: drop the backlog
        return steps
    }

    /// Run the simulation quietly for a while, e.g. so a freshly made curtain
    /// is already hanging in folds on its first frame.
    public func settle(steps: Int) {
        for _ in 0..<steps { step(Tuning.timestep) }
    }

    /// One fixed step: move the leading edge and the rings, integrate the
    /// fabric, relax the constraints, check for sleep.
    public func step(_ dt: Float) {
        let keep = 1 - Tuning.damping
        let dt2 = dt * dt

        // Rings carry no momentum: they are wherever the rail chain and the
        // leading edge put them this step, and stop the instant that stops.
        for c in 0..<columns {
            previous[c] = positions[c]
        }
        driveLeadingEdge(dt)
        solveRail()
        updatePleats()

        // Fabric: gravity, drag, and the pull toward the pleat shape.
        for i in columns..<positions.count {
            let p = positions[i]
            let velocity = (p - previous[i]) * keep
            let wanted = pleatTarget[i % columns] * Cloth.pleatFade(row: i / columns)
            let acceleration = SIMD3<Float>(0, Tuning.gravity, Tuning.pleatPull * (wanted - p.z))
            previous[i] = p
            positions[i] = p + velocity + acceleration * dt2
        }
        if let held = heldParticle {
            positions[held] = heldPosition
            previous[held] = heldPosition
        }

        for pass in 0..<Tuning.constraintIterations {
            relaxLinks(reversed: pass % 2 == 1)
            keepColumnsInOrder()
        }

        var maxMoveSq: Float = 0
        for i in 0..<positions.count {
            maxMoveSq = max(maxMoveSq, length_squared(positions[i] - previous[i]))
        }
        fabricSpeed = maxMoveSq.squareRoot() / dt
        if maxMoveSq < Tuning.sleepVelocity * Tuning.sleepVelocity {
            stillSteps += 1
            if stillSteps >= Tuning.sleepSteps { isAwake = false }
        } else {
            stillSteps = 0
        }
    }

    /// Move the leading ring: pulled towards the hand or the slide target by a
    /// spring with damping and a speed cap, which is what gives the curtain its
    /// weight, or coasting to a stop with friction once released.
    private func driveLeadingEdge(_ dt: Float) {
        let last = columns - 1
        let x = positions[last].x
        if let goal = heldX ?? slideTarget {
            let maxSpeed = heldX != nil ? Tuning.dragMaxSpeed : Tuning.ringSlideSpeed
            let acceleration = Tuning.dragStiffness * (goal - x) - Tuning.dragDamping * edgeVelocity
            edgeVelocity += acceleration * dt
            edgeVelocity = min(max(edgeVelocity, -maxSpeed), maxSpeed)
            if slideTarget != nil && abs(goal - x) < 0.5 && abs(edgeVelocity) < 5 {
                slideTarget = nil
                edgeVelocity = 0
            }
        } else {
            edgeVelocity *= 1 - Tuning.ringCoastFriction
            if abs(edgeVelocity) < 1 { edgeVelocity = 0 }
        }
        var next = x + edgeVelocity * dt
        let range = leadingEdgeRange
        if next <= range.lowerBound || next >= range.upperBound {
            next = min(max(next, range.lowerBound), range.upperBound)
            if abs(edgeVelocity) > 60 { pending.endHitSpeed = max(pending.endHitSpeed, abs(edgeVelocity)) }
            edgeVelocity = 0   // hit the end of the rail
        }
        positions[last].x = next
    }

    /// Put the rings where the rail chain says: each gap between neighbours
    /// stays between a ring's thickness and the width of fabric between them
    /// (a rope, not a rod: slack is fine). A chain with a driven end can be
    /// solved exactly in two sweeps: from the leading edge leftwards, so a pull
    /// or push travels the whole chain at once, then from the fixed first ring
    /// rightwards to catch anything that crossed it. Rings that are not in
    /// violation do not move, which is what makes a released curtain stay put.
    private func solveRail() {
        let last = columns - 1
        let minGap = Tuning.ringMinSpacing, maxGap = spacingX
        let driven = heldX != nil || slideTarget != nil
        var touchingBefore = 0
        for c in 0..<last where positions[c + 1].x - positions[c].x <= minGap + 0.5 { touchingBefore += 1 }

        positions[last].x = min(max(positions[last].x, railLeft), railRight)
        for c in stride(from: last - 1, through: 1, by: -1) {
            let next = positions[c + 1].x
            positions[c].x = min(max(positions[c].x, next - maxGap), next - minGap)
        }
        positions[0].x = railLeft
        for c in 1...last where !(c == last && driven) {
            let prev = positions[c - 1].x
            positions[c].x = min(max(positions[c].x, prev + minGap), prev + maxGap)
        }
        for c in 0..<columns {
            positions[c].y = railY + railLift
            positions[c].z = 0
        }

        var touchingAfter = 0
        for c in 0..<last where positions[c + 1].x - positions[c].x <= minGap + 0.5 { touchingAfter += 1 }
        pending.ringClicks += max(touchingAfter - touchingBefore, 0)
    }

    // MARK: Pleats

    /// Pleats are gathered flat at the rings and reach full depth a few rows down.
    private static func pleatFade(row: Int) -> Float {
        min(Float(row) / Float(Tuning.pleatFadeRows), 1)
    }

    /// Depth the pleat shape gives column c at row r.
    private func templateZ(column c: Int, row r: Int) -> Float {
        pleatTarget[c] * Cloth.pleatFade(row: r)
    }

    /// Work out how deep each column wants to be, then the rest length of
    /// every link that runs across the fabric.
    ///
    /// Two neighbouring columns are a fixed width of fabric apart; if their
    /// rings are closer than that, the difference has to go into depth:
    /// sqrt(fabric² - gap²). A column at the peak of the wave takes all of it,
    /// one at a crossing takes none.
    ///
    /// Links across the fabric then get the length the pleat shape implies.
    /// In the gathered heading rows that is shorter than the true fabric
    /// width (the fabric is bunched into the tape); lower down the true width
    /// applies and the shape only decides the bend links.
    private func updatePleats() {
        for c in 0..<columns {
            let gapLeft = c > 0 ? positions[c].x - positions[c - 1].x : spacingX
            let gapRight = c + 1 < columns ? positions[c + 1].x - positions[c].x : gapLeft
            let gap = min(gapLeft, gapRight)
            let depth = (max(spacingX * spacingX - gap * gap, 0)).squareRoot()
            pleatTarget[c] = pleatShape[c] * depth * Tuning.pleatDepthScale
        }

        for (k, link) in links.enumerated() {
            let a = Int(link.a), b = Int(link.b)
            let ca = a % columns, ra = a / columns, cb = b % columns, rb = b / columns
            switch link.kind {
            case .down:
                rest[k] = spacingY
            case .bendDown:
                rest[k] = 2 * spacingY
            case .across, .shear, .bendAcross:
                // Weft threads keep their true length except in the gathered
                // heading; shear and bend links follow the pleat shape all the
                // way down, so they hold its waves rather than resist them.
                let gathered = ra < Tuning.pleatFadeRows
                if link.kind == .across && !gathered {
                    rest[k] = spacingX
                } else {
                    let dx = positions[cb].x - positions[ca].x           // between the two rings
                    let dy = Float(rb - ra) * spacingY
                    let dz = templateZ(column: cb, row: rb) - templateZ(column: ca, row: ra)
                    rest[k] = (dx * dx + dy * dy + dz * dz).squareRoot()
                }
            }
        }
    }

    // MARK: Constraints

    /// One Gauss-Seidel pass: visit every link and move its two particles
    /// toward the rest distance. Rings (row 0) are immovable here; a ring's
    /// partner takes the whole correction. Alternate passes run in reverse so
    /// the visiting order does not push the fabric steadily one way.
    private func relaxLinks(reversed: Bool) {
        let ringCount = columns
        let held = heldParticle ?? -1
        positions.withUnsafeMutableBufferPointer { p in
            let order = reversed ? stride(from: links.count - 1, through: 0, by: -1) : stride(from: 0, through: links.count - 1, by: 1)
            for k in order {
                let link = links[k]
                let a = Int(link.a), b = Int(link.b)
                let delta = p[b] - p[a]
                let dist = length(delta)
                if dist < 1e-6 { continue }
                let correction = delta * ((dist - rest[k]) / dist * link.stiffness)
                if a < ringCount || a == held {
                    p[b] -= correction
                } else if b == held {
                    p[a] += correction
                } else {
                    p[a] += correction * 0.5
                    p[b] -= correction * 0.5
                }
            }
        }
    }

    /// No fold-overs: the fabric hangs from its rings in order, so a column
    /// may never swing past its neighbour. Without this a fast pull can tuck
    /// a column behind the next one, and the resulting curl is stable and
    /// never shakes out. Solved exactly: a cascade along the row pushing
    /// offenders right, another pushing them left, and the average of the
    /// two, which still satisfies every gap (the constraints are linear) and
    /// never shoves a row bodily one way.
    private var orderScratch: [Float] = []
    private func keepColumnsInOrder() {
        let minGap = Tuning.minColumnGap
        if orderScratch.count != columns * 2 { orderScratch = Array(repeating: 0, count: columns * 2) }
        positions.withUnsafeMutableBufferPointer { p in
            orderScratch.withUnsafeMutableBufferPointer { scratch in
                for r in 1..<rows {
                    let row = r * columns
                    var crossed = false
                    for c in 0..<(columns - 1) where p[row + c + 1].x - p[row + c].x < minGap { crossed = true; break }
                    if !crossed { continue }
                    for c in 0..<columns {
                        scratch[c] = p[row + c].x                 // pushed-right solution
                        scratch[columns + c] = p[row + c].x       // pushed-left solution
                    }
                    for c in 1..<columns {
                        scratch[c] = max(scratch[c], scratch[c - 1] + minGap)
                    }
                    for c in stride(from: columns - 2, through: 0, by: -1) {
                        scratch[columns + c] = min(scratch[columns + c], scratch[columns + c + 1] - minGap)
                    }
                    for c in 0..<columns {
                        p[row + c].x = (scratch[c] + scratch[columns + c]) * 0.5
                    }
                }
            }
        }
    }

    // MARK: External influences

    /// A gust at `point` (x, y in cloth space) from something moving by
    /// `motion` points: nearby particles gain velocity in that direction and
    /// get pushed away from the viewer in proportion to the speed.
    public func applyGust(at point: SIMD2<Float>, motion: SIMD2<Float>) {
        let speed = length(motion)
        guard speed > 0 else { return }
        var impulse = SIMD3<Float>(motion.x, motion.y, -speed * Tuning.windDepthGain) * Tuning.windGain
        let magnitude = length(impulse)
        if magnitude > Tuning.windMaxImpulse { impulse *= Tuning.windMaxImpulse / magnitude }

        let radiusSq = Tuning.windRadius * Tuning.windRadius
        for i in columns..<positions.count {
            let offset = SIMD2(positions[i].x, positions[i].y) - point
            let distSq = length_squared(offset)
            if distSq >= radiusSq { continue }
            let falloff = 1 - distSq / radiusSq
            // Moving `previous` backwards is how you add velocity in Verlet.
            previous[i] -= impulse * falloff
        }
        wake()
    }

    public func wake() {
        isAwake = true
        stillSteps = 0
    }

    // MARK: Checks (used by the tests)

    public func hasNonFinite() -> Bool {
        positions.contains { !$0.x.isFinite || !$0.y.isFinite || !$0.z.isFinite }
    }

    /// Largest |actual - rest| / rest over the structural and shear links,
    /// against each link's current rest length. Bend links are soft by design
    /// and left out.
    public func maxConstraintError() -> Float {
        var worst: Float = 0
        for (k, link) in links.enumerated() where link.stiffness >= Tuning.shearStiffness {
            let dist = length(positions[Int(link.b)] - positions[Int(link.a)])
            worst = max(worst, abs(dist - rest[k]) / rest[k])
        }
        return worst
    }

    /// Ring x positions, left to right.
    public var ringPositions: [Float] { (0..<columns).map { positions[$0].x } }
}
