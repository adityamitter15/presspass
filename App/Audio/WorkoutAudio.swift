import AVFoundation
import Foundation

/// The workout's sounds, synthesised in code: no audio files. A soft tick for
/// each counted rep, a two-note rise at every tenth, a duller low note for a
/// shallow attempt, a three-note phrase at the finish and one bright note for
/// "Go". In Voice mode it also speaks each rep number.
///
/// Use from the main queue. The audio session is `.playback` with
/// `.mixWithOthers`, active only between `begin` and `end`.
final class WorkoutAudio {
    private let mode: AppSettings.SoundMode
    private let isMuted: Bool

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let synthesizer = AVSpeechSynthesizer()
    private let voice = AVSpeechSynthesisVoice(language: "en-GB") ?? AVSpeechSynthesisVoice(language: "en-US")

    private static let sampleRate = 44_100.0
    private let format = AVAudioFormat(standardFormatWithSampleRate: WorkoutAudio.sampleRate, channels: 1)!

    private var sounds: [Sound: AVAudioPCMBuffer] = [:]
    private var isRunning = false

    private enum Sound: Hashable {
        case tick, milestone, shallow, finish, go
    }

    init(mode: AppSettings.SoundMode, isMuted: Bool = AppEnvironment.current.isMuted) {
        self.mode = mode
        self.isMuted = isMuted
    }

    private var isSilent: Bool { isMuted || mode == .off }

    // MARK: Session

    /// Activates the audio session and starts the engine. Does nothing when
    /// sound is off or muted.
    func begin() {
        guard !isSilent, !isRunning else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)

            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            sounds = Self.makeSounds(format: format)
            try engine.start()
            player.play()
            isRunning = true
        } catch {
            isRunning = false
        }
    }

    /// Stops speaking, lets a sound that is still playing finish, then stops
    /// the engine and releases the audio session.
    func end(after delay: TimeInterval = 1.4) {
        guard isRunning else { return }
        isRunning = false
        synthesizer.stopSpeaking(at: .immediate)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [engine, player] in
            player.stop()
            engine.stop()
            engine.detach(player)
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    // MARK: Events

    /// A counted rep: a tick, a rise at every tenth, and the number spoken in Voice mode.
    func rep(_ count: Int) {
        play(count > 0 && count % 10 == 0 ? .milestone : .tick)
        speak("\(count)")
    }

    /// A descent that was not low enough.
    func shallowAttempt() {
        play(.shallow)
    }

    func go() {
        play(.go)
        speak("Go")
    }

    func finish() {
        play(.finish)
    }

    // MARK: Playback

    private func play(_ sound: Sound) {
        guard !isSilent, isRunning, let buffer = sounds[sound] else { return }
        if !engine.isRunning { try? engine.start() }
        player.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
        if !player.isPlaying { player.play() }
    }

    /// Speaks `text`, cutting off whatever is still being said so the voice
    /// never falls behind the reps.
    private func speak(_ text: String) {
        guard mode == .voice, !isMuted, isRunning else { return }
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = min(AVSpeechUtteranceDefaultSpeechRate * 1.15, AVSpeechUtteranceMaximumSpeechRate)
        utterance.volume = 1
        utterance.preUtteranceDelay = 0
        utterance.postUtteranceDelay = 0
        synthesizer.speak(utterance)
    }

    // MARK: Synthesis

    private static func makeSounds(format: AVAudioFormat) -> [Sound: AVAudioPCMBuffer] {
        let c5 = 523.25, e5 = 659.25, g5 = 783.99, b5 = 987.77
        return [
            // A short, soft tick: a quiet high sine with a very fast decay.
            .tick: buffer(format, [Note(frequency: 1_480, duration: 0.07, gain: 0.32, decay: 55)], harmonics: 0.15),
            // A two-note rise.
            .milestone: buffer(format, [
                Note(frequency: e5, duration: 0.14, gain: 0.4, decay: 11),
                Note(frequency: b5, duration: 0.3, gain: 0.42, decay: 8, start: 0.11),
            ], harmonics: 0.25),
            // A duller, lower note: mostly the fundamental, quick to fade.
            .shallow: buffer(format, [Note(frequency: 196, duration: 0.26, gain: 0.5, decay: 13)], harmonics: 0.05),
            // Three notes going up.
            .finish: buffer(format, [
                Note(frequency: c5, duration: 0.2, gain: 0.38, decay: 9),
                Note(frequency: e5, duration: 0.2, gain: 0.38, decay: 9, start: 0.16),
                Note(frequency: g5, duration: 0.5, gain: 0.42, decay: 5.5, start: 0.32),
            ], harmonics: 0.25),
            // One bright note.
            .go: buffer(format, [Note(frequency: 1_567.98, duration: 0.3, gain: 0.34, decay: 9)], harmonics: 0.35),
        ]
    }

    private struct Note {
        let frequency: Double
        let duration: Double
        let gain: Double
        /// Exponential decay rate per second.
        let decay: Double
        var start: Double = 0
    }

    /// Mixes the notes into one mono buffer: a sine plus a touch of its
    /// octave, a 3 ms attack and an exponential decay.
    private static func buffer(_ format: AVAudioFormat, _ notes: [Note], harmonics: Double) -> AVAudioPCMBuffer {
        let rate = format.sampleRate
        let total = notes.map { $0.start + $0.duration }.max() ?? 0
        let frames = AVAudioFrameCount(total * rate) + 1
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let samples = buffer.floatChannelData![0]
        for index in 0..<Int(frames) { samples[index] = 0 }

        for note in notes {
            let first = Int(note.start * rate)
            let count = Int(note.duration * rate)
            for step in 0..<count where first + step < Int(frames) {
                let time = Double(step) / rate
                let attack = min(time / 0.003, 1)
                let release = min((note.duration - time) / 0.01, 1)
                let envelope = attack * release * exp(-note.decay * time)
                let phase = 2 * Double.pi * note.frequency * time
                let wave = sin(phase) + harmonics * sin(2 * phase)
                samples[first + step] += Float(wave / (1 + harmonics) * envelope * note.gain)
            }
        }
        return buffer
    }
}
