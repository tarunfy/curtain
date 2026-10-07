// Tuning.swift - every number that changes how the curtain looks and feels.
//
// Units: lengths are screen points (what CSS px maps to on a Mac; one point is
// two physical pixels on Retina). The origin is the top-left corner of the
// screen, y grows downwards like the DOM, and z points out of the screen
// towards you. Time is seconds. Colours are 0...1 RGB.

import simd

public enum Tuning {

    // MARK: Which fabric

    /// The fabric on the rail. Pick one of the looks at the bottom of this
    /// file, or edit them.
    public static let look = beige

    // MARK: Keyboard shortcut (toggles the curtain from any app)

    /// Virtual key code of the key. A few: C 8, K 40, H 4, 0 29, F12 111,
    /// space 49. Full list: Carbon's Events.h, kVK_ANSI_*.
    public static let shortcutKeyCode: UInt32 = 8
    /// Modifier mask: add together command 256, shift 512, option 2048,
    /// control 4096. The default is control + option + command.
    public static let shortcutModifiers: UInt32 = 256 + 2048 + 4096

    // MARK: Tugging the fabric

    /// How close (points) a click must be to a particle to grab the fabric there.
    public static let tugRadius: Float = 60
    /// A tugged point is lifted this far towards you, so the pull shows as a
    /// lit bump rather than a flat shift.
    public static let tugLift: Float = 35

    // MARK: Fling

    /// Let go of the edge faster than this (points per second) and it carries
    /// on to the end of the rail instead of coasting to a stop.
    public static let flingSpeed: Float = 1100

    // MARK: Launch

    /// Seconds the rail takes to come down into place when the app starts,
    /// with the fabric following. 0 skips the drop. Too short a time is
    /// stretched so the rail never outruns the falling fabric.
    public static let dropDuration: Float = 1.4

    // MARK: Sound (synthesized at launch; no audio files)

    /// Master volume, 0...1. 0 is silent; the Mute menu item does the same.
    public static let soundVolume: Float = 0.5
    /// The fabric's swish, which follows how fast it is moving.
    public static let swishVolume: Float = 0.45
    /// The rattle of rings bunching up on the rail.
    public static let rattleVolume: Float = 0.18
    /// The thump of the edge hitting the end of the rail.
    public static let thumpVolume: Float = 0.9

    // MARK: Shadow on the desktop

    /// Width of the soft shadow the curtain casts beside its leading edge.
    public static let shadowWidth: Float = 56
    /// How dark the shadow is at the edge, 0...1.
    public static let shadowStrength: Float = 0.38
    /// Where the shadow falls relative to the edge: down and to the right,
    /// matching the light from the upper left.
    public static let shadowOffset = SIMD2<Float>(6, 10)

    // MARK: Grid

    /// Particles across the curtain. More = finer folds and more CPU.
    public static let columns = 40
    /// Particles down the curtain.
    public static let rows = 30
    /// Unstretched cloth width as a fraction of the rail length. Over 1 gives
    /// the closed curtain slack to hang in gentle waves instead of flat.
    public static let widthFactor: Float = 1.08
    /// Unstretched cloth height as a fraction of the screen height. Over 1 so
    /// the hem hangs off the bottom of the screen instead of ending above it.
    public static let heightFactor: Float = 1.06

    // MARK: Rail and rings

    /// Height of the rail, in points from the top of the screen.
    public static let railY: Float = 0
    /// The rail pokes this far past both screen edges so the closed curtain's
    /// waves never show a sliver of desktop at the sides.
    public static let railOverhang: Float = 14
    /// Closest two rings can get. Sets how wide the open, bunched-up curtain
    /// is: (columns - 1) times this.
    public static let ringMinSpacing: Float = 7
    /// Width of the band at the leading edge you can grab, in points.
    public static let grabWidth: Float = 56

    // MARK: Weight of the curtain in the hand
    //
    // The leading edge is not welded to the mouse. Your hand pulls it through
    // a spring: the edge accelerates towards the hand, lags behind a fast
    // pull, and coasts briefly after a fling. These four numbers are the
    // "mass" you feel.

    /// Pull towards the hand per point of distance, per second squared.
    /// Lower = heavier, laggier; higher = snappier.
    public static let dragStiffness: Float = 55
    /// Resistance to the edge's own speed, per second. Around twice the
    /// square root of dragStiffness stops it overshooting your hand; a bit
    /// less gives a small, heavy-feeling overshoot.
    public static let dragDamping: Float = 13
    /// Fastest the edge will move under your hand, points per second.
    public static let dragMaxSpeed: Float = 1800
    /// Fraction of the edge's speed lost per step once released. Sets how
    /// far a flung curtain coasts: 0.08 is a few dozen points.
    public static let ringCoastFriction: Float = 0.08
    /// Fastest the menu/shortcut slides the leading edge, points per second.
    public static let ringSlideSpeed: Float = 1400

    // MARK: Pleats

    /// The fabric remembers a wave shape, like pressed pleats: columns prefer
    /// alternating depths following a sine of this many columns per wave.
    /// 4 is what the bend constraints like best, giving even, round pleats.
    public static let pleatWavelength = 4
    /// How deep the wave wants to be, as a multiple of the depth the fabric
    /// between two rings needs to fit between them. 1 = exactly that; less
    /// lets the folds find their own, lazier shape.
    public static let pleatDepthScale: Float = 1.0
    /// How unevenly deep the pleats are, 0...1. 0 is perfectly regular. Keep
    /// it small: a shallower pleat has to squash its fabric width to fit.
    public static let pleatVariation: Float = 0.1
    /// Pull towards the preferred depth, per point of distance, per second
    /// squared. Too weak and the fabric buckles into a few huge loops
    /// instead of pleats; too strong and it looks stamped.
    public static let pleatPull: Float = 250
    /// Rows below the rail over which the pleats grow from flat to full
    /// depth, like fabric gathered into a heading tape.
    public static let pleatFadeRows = 3

    // MARK: Time stepping

    /// Fixed physics step. The simulation always advances in whole steps of
    /// this size however fast or slow frames arrive; smaller is more accurate.
    public static let timestep: Float = 1.0 / 120.0
    /// Longest frame gap the simulation will try to catch up on, so a stall
    /// (sleep, heavy load) does not produce a burst of steps.
    public static let maxFrameTime: Double = 0.1
    /// Cap on steps per frame; beyond this the backlog is dropped.
    public static let maxSubsteps = 4
    /// Constraint relaxation passes per step. More = stiffer, less stretchy,
    /// more CPU. 8 is a good balance for a heavy fabric.
    public static let constraintIterations = 8

    // MARK: Forces

    /// Downward acceleration in points per second squared. The screen is
    /// roughly 2 metres of curtain, so real gravity would be about 4000.
    /// Lower reads as heavier, slower-moving fabric.
    public static let gravity: Float = 2500
    /// Fraction of velocity lost every step (air drag). 0 swings forever,
    /// 0.05 feels like moving through syrup.
    public static let damping: Float = 0.02
    /// How fully each constraint type is enforced per pass, 0...1.
    /// Structural = neighbours across and down (the weave itself).
    public static let structuralStiffness: Float = 1.0
    /// Shear = diagonal neighbours. Resists the grid collapsing into diamonds.
    public static let shearStiffness: Float = 0.8
    /// Bend = particles two apart. Low values let the fabric fold into sharp
    /// creases; higher values give wider, rounder pleats. Set 0 to disable.
    public static let bendStiffness: Float = 0.3
    /// Smallest sideways gap between neighbouring columns anywhere down the
    /// fabric. Keeps columns in ring order so the cloth can never fold over
    /// itself into a stuck curl.
    public static let minColumnGap: Float = 2

    // MARK: Wind from the cursor

    /// Cursor speed (points per second) below which it is ignored.
    public static let windMinSpeed: Float = 500
    /// Distance from the cursor within which the fabric feels the gust.
    public static let windRadius: Float = 150
    /// How much of the cursor's motion is handed to the fabric at the cursor.
    public static let windGain: Float = 0.15
    /// Fast motion also pushes the fabric away from you (into the screen):
    /// this much per point of cursor travel, before windGain.
    public static let windDepthGain: Float = 0.6
    /// Largest single gust in points of velocity change per step.
    public static let windMaxImpulse: Float = 6

    // MARK: Sleep

    /// Per-step movement (points) below which a particle counts as still.
    public static let sleepVelocity: Float = 0.015
    /// Consecutive still steps before the simulation stops itself.
    public static let sleepSteps = 45

    // MARK: Lighting (shared by every look)

    /// Direction *towards* the light. y is negative because y grows downwards,
    /// so this is light from the upper left, mostly in front of the fabric.
    public static let lightDirection = SIMD3<Float>(-0.35, -0.45, 0.82)
    /// Darkening inside bunched-up folds, 0...1.
    public static let foldShadowStrength: Float = 0.6
    /// Depth span, in points, that the depth buffer can tell apart. Folds
    /// never get close to this; it only needs to exceed the deepest pleat.
    public static let depthRange: Float = 4000

    // MARK: Texture (shared by every look)

    /// Texture size in texels per side. Powers of two only. 1024 takes about
    /// a tenth of a second to generate at launch.
    public static let textureSize = 1024
    /// Points of fabric covered by one repeat of the texture. Bigger hides
    /// the repetition better but makes the weave coarser.
    public static let textureTile: Float = 600
    /// Threads across one texture repeat; sets how fine the weave is.
    public static let threadsPerTile = 200

    // MARK: Looks

    /// Every look, in the order the Fabric menu lists them.
    public static let looks = [beige, matteBlack, velvetRed]

    /// Heavy matte black. Low sheen, soft shading, reads as thick wool felt.
    public static let matteBlack = FabricLook(
        name: "Matte Black",
        color: SIMD3(0.14, 0.14, 0.15),
        ambient: 0.42, diffuse: 0.85,
        sheenStrength: 0.14, sheenPower: 3.0, sheenColor: SIMD3(0.45, 0.45, 0.48),
        weaveContrast: 0.12, pileContrast: 0.18, napContrast: 0.10, fibreContrast: 0.10)

    /// Warm beige linen-velvet. Shows every fold; light sheen.
    public static let beige = FabricLook(
        name: "Beige",
        color: SIMD3(0.78, 0.68, 0.54),
        ambient: 0.40, diffuse: 0.75,
        sheenStrength: 0.10, sheenPower: 2.5, sheenColor: SIMD3(1.0, 0.96, 0.88),
        weaveContrast: 0.16, pileContrast: 0.09, napContrast: 0.05, fibreContrast: 0.08)

    /// Deep red theatre velvet with a pink sheen on the folds.
    public static let velvetRed = FabricLook(
        name: "Velvet Red",
        color: SIMD3(0.45, 0.04, 0.07),
        ambient: 0.38, diffuse: 0.75,
        sheenStrength: 0.22, sheenPower: 2.5, sheenColor: SIMD3(0.85, 0.40, 0.45),
        weaveContrast: 0.16, pileContrast: 0.22, napContrast: 0.12, fibreContrast: 0.12)
}

/// Everything that makes one fabric look different from another.
public struct FabricLook {
    /// Shown in the Fabric menu.
    public var name: String
    /// Base colour.
    public var color: SIMD3<Float>
    /// Light that reaches everything regardless of angle, 0...1.
    public var ambient: Float
    /// Light that depends on how squarely a point faces the light, 0...1.
    public var diffuse: Float
    /// Velvet sheen: how bright the fabric glows where it turns away from you
    /// (the sides of folds). 0 disables it.
    public var sheenStrength: Float
    /// How tightly the sheen hugs the fold edges; higher = narrower.
    public var sheenPower: Float
    /// Colour of the sheen.
    public var sheenColor: SIMD3<Float>
    /// Texture layers, each a brightness variation 0...1: the thread weave,
    /// soft patches of pile (the crushed look), faint vertical nap streaks,
    /// and per-texel grain.
    public var weaveContrast: Float
    public var pileContrast: Float
    public var napContrast: Float
    public var fibreContrast: Float

    public init(name: String, color: SIMD3<Float>, ambient: Float, diffuse: Float,
                sheenStrength: Float, sheenPower: Float, sheenColor: SIMD3<Float>,
                weaveContrast: Float, pileContrast: Float, napContrast: Float, fibreContrast: Float) {
        self.name = name
        self.color = color
        self.ambient = ambient
        self.diffuse = diffuse
        self.sheenStrength = sheenStrength
        self.sheenPower = sheenPower
        self.sheenColor = sheenColor
        self.weaveContrast = weaveContrast
        self.pileContrast = pileContrast
        self.napContrast = napContrast
        self.fibreContrast = fibreContrast
    }
}
