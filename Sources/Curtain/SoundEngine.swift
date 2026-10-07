// SoundEngine.swift - the curtain's sounds, synthesized on the fly.
//
// Three sounds, none of them files: a swish of filtered noise whose level
// follows how fast the fabric is moving, a dry click for rings knocking
// together on the rail, and a low thump when the edge hits the end. The
// audio engine only runs while the cloth is awake, so an idle curtain is
// silent in every sense. Playing sound needs no permission on macOS.

import AVFoundation
import CurtainCore

final class SoundEngine {
    private struct Voice {
        enum Kind { case click, thump }
        let kind: Kind
        let amplitude: Float
        var age: Float = 0
        var phase: Float = 0
    }

    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode?
    private var sampleRate: Float = 44100

    // Shared between the main thread (which asks for sounds) and the audio
    // thread (which makes them). The lock is held for microseconds.
    private let lock = NSLock()
    private var swishTarget: Float = 0
    private var queued: [Voice] = []
    private var lastClick: CFTimeInterval = 0

    // Audio-thread state.
    private var voices: [Voice] = []
    private var swish: Float = 0
    private var filtered: Float = 0
    private var noiseState: UInt32 = 0x9E37_79B9

    var muted = false {
        didSet { if muted { setRunning(false) } }
    }

    init() {
        let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        sampleRate = Float(rate)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1) else { return }
        let node = AVAudioSourceNode(format: format) { [unowned self] _, _, frameCount, bufferList in
            self.render(frames: Int(frameCount), into: bufferList)
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = Tuning.soundVolume
        source = node
    }

    /// Start or pause the engine. Paused, it costs nothing.
    func setRunning(_ running: Bool) {
        if running && !muted {
            if !engine.isRunning {
                do { try engine.start() } catch { debugLog("audio failed to start: \(error)") }
            }
        } else if engine.isRunning {
            engine.pause()
        }
    }

    /// How hard the fabric is moving right now, 0...1.
    func setSwish(_ level: Float) {
        lock.lock(); swishTarget = min(max(level, 0), 1); lock.unlock()
    }

    /// Rings knocking together. Rings touch almost every step while the
    /// curtain bunches up, so clicks are spaced out and the count only makes
    /// each one a little louder; otherwise it sounds like a machine gun.
    func click(count: Int) {
        guard count > 0 else { return }
        let now = CACurrentMediaTime()
        guard now - lastClick > 0.11 else { return }
        lastClick = now
        enqueue(Voice(kind: .click, amplitude: min(0.2 + 0.08 * Float(count), 0.6)))
    }

    /// The edge hitting the end of the rail at this speed (points per second).
    func thump(speed: Float) {
        enqueue(Voice(kind: .thump, amplitude: min(speed / 1500, 1)))
    }

    private func enqueue(_ voice: Voice) {
        lock.lock(); queued.append(voice); lock.unlock()
    }

    // MARK: Audio thread

    private func render(frames: Int, into list: UnsafeMutablePointer<AudioBufferList>) {
        lock.lock()
        let target = swishTarget
        if !queued.isEmpty { voices.append(contentsOf: queued); queued.removeAll(keepingCapacity: true) }
        lock.unlock()

        let buffers = UnsafeMutableAudioBufferListPointer(list)
        guard let out = buffers[0].mData?.assumingMemoryBound(to: Float.self) else { return }
        let dt = 1 / sampleRate

        for frame in 0..<frames {
            // White noise from a tiny xorshift generator.
            noiseState ^= noiseState << 13
            noiseState ^= noiseState >> 17
            noiseState ^= noiseState << 5
            let noise = Float(Int32(bitPattern: noiseState)) / Float(Int32.max)

            // Swish: the level eases toward its target over ~50 ms, and the
            // noise is low-passed, opening up (brighter) as the fabric speeds
            // up. The level is cubed so gentle motion is nearly silent.
            swish += (target - swish) * 0.0004
            filtered += (noise - filtered) * (0.01 + 0.12 * swish)
            var sample = filtered * swish * swish * swish * Tuning.swishVolume

            for v in voices.indices {
                voices[v].age += dt
                let age = voices[v].age
                switch voices[v].kind {
                case .click:
                    sample += noise * exp(-age * 350) * voices[v].amplitude * Tuning.rattleVolume
                case .thump:
                    let frequency = max(75 - age * 120, 40)
                    voices[v].phase += frequency * 2 * .pi * dt
                    sample += sin(voices[v].phase) * exp(-age * 12) * voices[v].amplitude * Tuning.thumpVolume
                }
            }
            out[frame] = max(min(sample, 1), -1)
        }
        voices.removeAll { $0.kind == .click ? $0.age > 0.04 : $0.age > 0.5 }
    }
}
