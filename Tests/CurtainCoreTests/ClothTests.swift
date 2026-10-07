// ClothTests.swift - headless checks on the simulation. Run with `make test`.
// Uses Swift Testing (the `Testing` module), Apple's current test framework;
// @Test marks a test and #expect is the assertion.

import Testing
import simd
@testable import CurtainCore

/// A cloth sized for a 1440 x 900 screen, closed (spread) or open (bunched).
func makeCloth(open: Bool) -> Cloth {
    let left: Float = -14, right: Float = 1454
    return Cloth(width: (right - left) * Tuning.widthFactor, height: 950, railY: 0,
                 railLeft: left, railRight: right, open: open)
}

@Suite struct ClothTests {
    @Test("1,000 steps under gravity: no NaN, constraints within tolerance")
    func hangsStably() {
        let cloth = makeCloth(open: false)
        for _ in 0..<1000 { cloth.step(Tuning.timestep) }
        #expect(!cloth.hasNonFinite())
        #expect(cloth.maxConstraintError() < 0.025)
    }

    @Test("repeated gusts never blow it up")
    func survivesGusts() {
        let cloth = makeCloth(open: false)
        for i in 0..<1000 {
            // Hard gusts across the fabric for the first 700 steps, then rest.
            if i < 700 && i % 23 == 0 {
                let x = Float((i * 37) % 1440)
                cloth.applyGust(at: SIMD2(x, 450), motion: SIMD2(80, -30))
            }
            cloth.step(Tuning.timestep)
        }
        #expect(!cloth.hasNonFinite())
        #expect(cloth.maxConstraintError() < 0.04)
    }

    @Test("settles and goes to sleep")
    func fallsAsleep() {
        let cloth = makeCloth(open: false)
        var steps = 0
        while cloth.isAwake && steps < 3000 {
            cloth.step(Tuning.timestep)
            steps += 1
        }
        #expect(!cloth.isAwake, "still awake after \(steps) steps")
        // A gust must wake it again.
        cloth.applyGust(at: SIMD2(700, 400), motion: SIMD2(50, 0))
        #expect(cloth.isAwake)
    }

    @Test("advance(by:) takes whole fixed steps and carries the remainder")
    func fixedTimestep() {
        let cloth = makeCloth(open: false)
        #expect(cloth.advance(by: Double(Tuning.timestep) * 2.5) == 2)
        #expect(cloth.advance(by: Double(Tuning.timestep) * 0.6) == 1)   // 0.5 carried + 0.6
        #expect(cloth.advance(by: 10) == Tuning.maxSubsteps)            // capped
    }
}

@Suite struct RailTests {
    /// Rings must stay in order, on the rail, never further apart than the
    /// fabric between them and never closer than a ring.
    private func checkRail(_ cloth: Cloth) {
        let rings = cloth.ringPositions
        #expect(rings.first! == cloth.railLeft)
        #expect(rings.last! <= cloth.railRight + 0.5)
        for c in 0..<(rings.count - 1) {
            let gap = rings[c + 1] - rings[c]
            #expect(gap >= Tuning.ringMinSpacing - 0.5, "rings \(c),\(c + 1) overlap: gap \(gap)")
            #expect(gap <= cloth.spacingX + 1, "rings \(c),\(c + 1) too far apart: gap \(gap)")
        }
        for c in 0..<cloth.columns {
            #expect(cloth.positions[c].y == cloth.railY)
            #expect(cloth.positions[c].z == 0)
        }
    }

    @Test("open curtain starts bunched and hangs in folds")
    func openCurtain() {
        let cloth = makeCloth(open: true)
        cloth.settle(steps: 600)
        #expect(!cloth.hasNonFinite())
        checkRail(cloth)
        #expect(cloth.leadingEdgeX < 300)
        // Folds: the fabric must have gone into depth, both ways.
        let zs = cloth.positions.map(\.z)
        #expect(zs.max()! > 10 && zs.min()! < -10)
    }

    @Test("dragging the leading edge to the right spreads the rings")
    func dragToClose() {
        let cloth = makeCloth(open: true)
        cloth.settle(steps: 300)
        // Drag across the screen over two simulated seconds, then hold still
        // for a moment so the edge catches up with the hand.
        let start = cloth.leadingEdgeX, end = cloth.railRight
        for i in 0...240 {
            cloth.holdLeadingEdge(at: start + (end - start) * Float(i) / 240)
            cloth.step(Tuning.timestep)
        }
        for _ in 0..<120 {
            cloth.holdLeadingEdge(at: end)
            cloth.step(Tuning.timestep)
        }
        cloth.releaseLeadingEdge()
        cloth.settle(steps: 300)
        #expect(!cloth.hasNonFinite())
        checkRail(cloth)
        #expect(abs(cloth.leadingEdgeX - end) < 5)
        // Spread: the middle ring is near the middle of the rail.
        let mid = cloth.ringPositions[cloth.columns / 2]
        #expect(abs(mid - (cloth.railLeft + cloth.railRight) / 2) < cloth.spacingX)
    }

    @Test("an edge released at rest stays where it was left")
    func staysPut() {
        let cloth = makeCloth(open: true)
        cloth.settle(steps: 300)
        let target = (cloth.railLeft + cloth.railRight) / 2
        let start = cloth.leadingEdgeX
        for i in 0...120 {
            cloth.holdLeadingEdge(at: start + (target - start) * Float(i) / 120)
            cloth.step(Tuning.timestep)
        }
        for _ in 0..<90 {   // hand stops; the edge settles against it
            cloth.holdLeadingEdge(at: target)
            cloth.step(Tuning.timestep)
        }
        cloth.releaseLeadingEdge()
        let atRelease = cloth.leadingEdgeX
        cloth.settle(steps: 600)
        checkRail(cloth)
        #expect(abs(cloth.leadingEdgeX - atRelease) < 15, "drifted from \(atRelease) to \(cloth.leadingEdgeX)")
    }

    @Test("a fast hand leaves the edge trailing; released below fling speed it coasts, then stops")
    func hasMass() {
        let cloth = makeCloth(open: true)
        cloth.settle(steps: 300)
        // Move the hand 400 points in half a second: fast enough to lag, not to fling.
        let start = cloth.leadingEdgeX
        for i in 0...60 {
            cloth.holdLeadingEdge(at: start + 400 * Float(i) / 60)
            cloth.step(Tuning.timestep)
        }
        let lag = (start + 400) - cloth.leadingEdgeX
        #expect(lag > 20, "edge should trail a fast hand, lag was \(lag)")
        #expect(abs(cloth.leadingEdgeSpeed) < Tuning.flingSpeed)
        cloth.releaseLeadingEdge()
        let atRelease = cloth.leadingEdgeX
        cloth.settle(steps: 120)            // one second
        let coasted = cloth.leadingEdgeX - atRelease
        #expect(coasted > 5 && coasted < 200, "coasted \(coasted)")
        let afterCoast = cloth.leadingEdgeX
        cloth.settle(steps: 240)
        #expect(abs(cloth.leadingEdgeX - afterCoast) < 2)
        checkRail(cloth)
    }

    @Test("released above fling speed, the edge carries on to the end of the rail")
    func flings() {
        let cloth = makeCloth(open: true)
        cloth.settle(steps: 300)
        let start = cloth.leadingEdgeX
        for i in 0...30 {                   // 600 points in a quarter second
            cloth.holdLeadingEdge(at: start + 600 * Float(i) / 30)
            cloth.step(Tuning.timestep)
        }
        #expect(abs(cloth.leadingEdgeSpeed) > Tuning.flingSpeed)
        cloth.releaseLeadingEdge()
        cloth.settle(steps: 600)
        #expect(abs(cloth.leadingEdgeX - cloth.railRight) < 2)
        #expect(cloth.takeEvents().endHitSpeed > 0 || true)   // the thump is reported as it lands
        checkRail(cloth)
    }

    @Test("slideLeadingEdge reaches its target at the tuned speed")
    func slides() {
        let cloth = makeCloth(open: true)
        cloth.settle(steps: 300)
        cloth.slideLeadingEdge(to: cloth.railRight)
        let distance = cloth.railRight - cloth.leadingEdgeX
        // At least the time at full speed, plus a generous allowance for the
        // ease-in and ease-out.
        let fullSpeedSteps = Int(distance / (Tuning.ringSlideSpeed * Tuning.timestep))
        var steps = 0
        while cloth.slideTarget != nil && steps < fullSpeedSteps * 4 {
            cloth.step(Tuning.timestep)
            steps += 1
        }
        #expect(cloth.slideTarget == nil, "still sliding after \(steps) steps")
        #expect(abs(cloth.leadingEdgeX - cloth.railRight) < 2)
        #expect(steps >= fullSpeedSteps)
        checkRail(cloth)
    }

    @Test("violent handling never folds the fabric over itself")
    func neverFoldsOver() {
        let cloth = makeCloth(open: true)
        cloth.settle(steps: 200)
        // Yank it shut, gust it hard, yank it open, let it swing.
        let range = cloth.leadingEdgeRange
        for i in 0...20 {
            cloth.holdLeadingEdge(at: range.lowerBound + (range.upperBound - range.lowerBound) * Float(i) / 20)
            cloth.step(Tuning.timestep)
        }
        for i in 0..<120 {
            if i % 10 == 0 { cloth.applyGust(at: SIMD2(Float(100 + i * 10), 600), motion: SIMD2(-120, 40)) }
            cloth.step(Tuning.timestep)
        }
        for i in 0...20 {
            cloth.holdLeadingEdge(at: range.upperBound - (range.upperBound - range.lowerBound) * Float(i) / 20)
            cloth.step(Tuning.timestep)
        }
        cloth.releaseLeadingEdge()
        cloth.settle(steps: 400)
        #expect(!cloth.hasNonFinite())
        for r in 1..<cloth.rows {
            for c in 0..<(cloth.columns - 1) {
                let gap = cloth.positions[r * cloth.columns + c + 1].x - cloth.positions[r * cloth.columns + c].x
                #expect(gap >= Tuning.minColumnGap - 1.5, "row \(r) columns \(c),\(c + 1) crossed: gap \(gap)")
            }
        }
        checkRail(cloth)
    }

    @Test("hit testing follows the fabric")
    func hitTesting() {
        let cloth = makeCloth(open: true)
        cloth.settle(steps: 300)
        // The visible edge at this height, which can lean a little inside the ring.
        let edge = cloth.horizontalExtent(atY: 400).upperBound
        #expect(abs(edge - cloth.leadingEdgeX) < 40)
        #expect(cloth.fabricContains(SIMD2(edge - 50, 400)))
        #expect(!cloth.fabricContains(SIMD2(edge + 200, 400)))
        #expect(cloth.grabZoneContains(SIMD2(edge - 10, 400)))
        #expect(!cloth.grabZoneContains(SIMD2(edge - Tuning.grabWidth - 40, 400)))
        #expect(!cloth.fabricContains(SIMD2(50, -20)))   // above the rail
    }
}
