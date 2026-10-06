// K PTT — V2. One behaviour: the button types what you say.
//
// V1 is kept whole in ../v1-archive. It worked, but it grew six behaviours at
// once and became unpredictable in his hands. His instruction was to unplug
// everything and start with one thing, get it okayed, and only then add.
//
// So this is the whole of it:
//
//     click        the microphone opens; one tick when it is really hearing you
//     speak        your words appear as you say them, and are never rewritten
//     click        the last words land, then Enter
//
// There are no modes. There is no hold gesture, no double-tap, no second way
// to do anything. There are exactly two sounds: the tick that means "I can
// hear you", and one low thud that means "that attempt is over".
//
// Everything runs on this Mac. Nothing about his voice leaves it.

import Foundation
import AppKit
import AVFoundation
import MediaPlayer
import CoreAudio
import AudioToolbox
import ApplicationServices

// ---------------------------------------------------------------------------
// Where things live
// ---------------------------------------------------------------------------

let HOME = FileManager.default.homeDirectoryForCurrentUser
let ROOT = ProcessInfo.processInfo.environment["F5_ROOT"].map { URL(fileURLWithPath: $0) } ?? (Bundle.main.bundleURL.pathExtension == "app" ? Bundle.main.bundleURL.deletingLastPathComponent() : HOME.appendingPathComponent("F5"))
let STATE = ROOT.appendingPathComponent("state")
let CONFIG_PATH: URL = {
    if let override = ProcessInfo.processInfo.environment["K_PTT_CONFIG"], !override.isEmpty {
        return URL(fileURLWithPath: override)
    }
    return STATE.appendingPathComponent("config.json")
}()
let EVENT_LOG = STATE.appendingPathComponent("events.jsonl")
let HELPER_LOG = STATE.appendingPathComponent("ptt.log")
let HEALTH_PATH = STATE.appendingPathComponent("health.json")
/// The last thing he said, in plain text, written BEFORE a single character is
/// typed. On 2026-08-20 at 17:09:42 a macOS crash dialog took focus and 292
/// characters — about 48 seconds of his speech — went into the dialog and were
/// gone. Nothing he says should ever be unrecoverable again.
let LAST_DICTATION = STATE.appendingPathComponent("last-dictation.txt")

// ---------------------------------------------------------------------------
// The record. Every claim this helper makes is backed by a line in here.
// ---------------------------------------------------------------------------

let ISO: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
    f.timeZone = TimeZone.current
    return f
}()

let logQueue = DispatchQueue(label: "k.ptt.log")

func appendLine(_ url: URL, _ line: String) {
    logQueue.sync {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(data); try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}

func say(_ text: String) {
    let line = "\(ISO.string(from: Date()))  \(text)"
    print(line); fflush(stdout)
    appendLine(HELPER_LOG, line)
}

var RECORDING = true
func record(_ fields: [String: Any]) {
    guard RECORDING else { return }
    var row = fields
    row["at"] = ISO.string(from: Date())
    if let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]),
       let text = String(data: data, encoding: .utf8) {
        appendLine(EVENT_LOG, text)
        print("EVENT " + text); fflush(stdout)
    }
}

// ---------------------------------------------------------------------------
// Settings — deliberately few. Every one of these earned its place by a
// measurement, and the numbers are the measured ones.
// ---------------------------------------------------------------------------

struct Config: Codable {
    /// The single off switch. There is no "mode" any more.
    var enabled: Bool = true
    var welcomeShown: Bool = false
    var journalMode: Bool = false

    var kBaseURL: String = "http://127.0.0.1:8866"
    var micDeviceName: String = ""
    var headsetName: String = "DellKing PTT Mic"
    var requireHeadset: Bool = false

    /// Show a small floating strip of what the ears are hearing while he
    /// speaks. Display only — it never puts a character in his document.
    var livePreview: Bool = true
    /// Let the strip become a review box: click to edit, select words and
    /// speak their replacement, click the button again to send, or × to
    /// discard. Turning this off restores the original display-only strip.
    var interactiveReview: Bool = true
    /// The page's live hearing was measured at a 450 ms cadence. The old strip
    /// waited 800 ms between checks, which made a short phrase feel stuck.
    var livePreviewIntervalMs: Int = 300
    /// He reads it from across the room: "I'll be using it primarily at a
    /// distance." Bigger than a document font, with room between the lines.
    var fontSize: Int = 22
    var lineSpacing: Int = 9
    /// Below this loudness the microphone is hearing the room, not him.
    /// MEASURED on his headset: quiet is -50.1 dB, his speech averages
    /// -20.6 dB, and the quietest half-second inside real speech is -41.4 dB.
    /// -45 sits 5 dB above the room and 3.6 dB below his quietest speech.
    var speechFloorDb: Int = -65
    /// Applied by the local ears. Enrollment is explicit; no automatic learning.
    var voiceFilterRequired: Bool = false
    var voiceMatchThreshold: Double = 0.60
    /// Press Enter after the words land.
    var pressReturnAfterTyping: Bool = true

    /// Two sounds, and the switch that silences both.
    var feedbackSounds: Bool = true
    /// The silent stream that makes this helper the Now Playing target, kept
    /// off the headset so it never holds that link open.
    var keepAliveSilence: Bool = true
    var silenceOutputDevice: String = "MacBook Pro Speakers"

    /// A capture left open by a forgotten click must not hold the microphone
    /// for ever.
    var maxOpenSeconds: Int = 600
    /// Reopening this Bluetooth link too soon after closing it is what drives
    /// it deaf — 18 rapid opens drove it into a persistently silent state.
    var reopenSettleMs: Int = 250

    /// The ramble pass: tidy a LONG dictation (fillers, false starts,
    /// repeats) with the fast mind before typing it. OFF by default — the
    /// founder's law is that the direct path gains zero felt latency, and
    /// this pass costs model-seconds on long text. `ptt-mode ramble on`
    /// turns it on; the raw words are ALWAYS saved first either way, and
    /// `ptt-mode clean-text` tidies the last dictation after the fact
    /// without ever being on the typing path.
    var cleanRambles: Bool = false
    /// A short direct sentence needs no cleaning and must never wait on a
    /// model. Below this many words the pass is skipped entirely — no model
    /// call, no added milliseconds.
    var rambleMinWords: Int = 40
    /// The pass is bounded: if the fast mind has not answered in this long,
    /// his raw words are typed instead. Cleaning is a favor, never a wait.
    var rambleTimeoutMs: Int = 10000

    init() {}

    /// Hand-edited, so a missing key keeps this field's default rather than
    /// silently resetting everything.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func str(_ k: CodingKeys, _ d: String) -> String {
            (try? c.decodeIfPresent(String.self, forKey: k)).flatMap { $0 } ?? d
        }
        func int(_ k: CodingKeys, _ d: Int) -> Int {
            (try? c.decodeIfPresent(Int.self, forKey: k)).flatMap { $0 } ?? d
        }
        func bool(_ k: CodingKeys, _ d: Bool) -> Bool {
            (try? c.decodeIfPresent(Bool.self, forKey: k)).flatMap { $0 } ?? d
        }
        enabled = bool(.enabled, true)
        welcomeShown = bool(.welcomeShown, false)
        journalMode = bool(.journalMode, false)
        kBaseURL = str(.kBaseURL, "http://127.0.0.1:8866")
        micDeviceName = "" // Input selection belongs to macOS.
        headsetName = str(.headsetName, "DellKing PTT Mic")
        requireHeadset = false // Any system-selected microphone can be used.
        livePreview = bool(.livePreview, true)
        interactiveReview = bool(.interactiveReview, true)
        livePreviewIntervalMs = int(.livePreviewIntervalMs, 300)
        fontSize = int(.fontSize, 22)
        lineSpacing = int(.lineSpacing, 9)
        speechFloorDb = int(.speechFloorDb, -65)
        voiceFilterRequired = bool(.voiceFilterRequired, false)
        voiceMatchThreshold = (try? c.decode(Double.self, forKey: .voiceMatchThreshold)) ?? 0.60
        pressReturnAfterTyping = bool(.pressReturnAfterTyping, true)
        feedbackSounds = bool(.feedbackSounds, true)
        keepAliveSilence = bool(.keepAliveSilence, true)
        silenceOutputDevice = str(.silenceOutputDevice, "MacBook Pro Speakers")
        maxOpenSeconds = int(.maxOpenSeconds, 600)
        reopenSettleMs = int(.reopenSettleMs, 250)
        cleanRambles = bool(.cleanRambles, false)
        rambleMinWords = int(.rambleMinWords, 40)
        rambleTimeoutMs = int(.rambleTimeoutMs, 10000)
    }

    static func load() -> Config {
        guard let data = try? Data(contentsOf: CONFIG_PATH) else { return Config() }
        do { return try JSONDecoder().decode(Config.self, from: data) }
        catch {
            say("settings file could not be read (\(error.localizedDescription)) "
                + "— using defaults until it is fixed: \(CONFIG_PATH.path)")
            return Config()
        }
    }

    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(self) {
            try? FileManager.default.createDirectory(at: STATE, withIntermediateDirectories: true)
            try? data.write(to: CONFIG_PATH, options: .atomic)
        }
    }
}

// ---------------------------------------------------------------------------
// CoreAudio — read only, except for pinning OUR OWN capture device. His system
// defaults are never touched.
// ---------------------------------------------------------------------------

enum Audio {
    static func allDeviceIDs() -> [AudioDeviceID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func name(_ id: AudioDeviceID) -> String {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var out = ""
        withUnsafeMutableBytes(of: &size) { _ in }
        var cf: Unmanaged<CFString>?
        if AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &cf) == noErr,
           let value = cf?.takeRetainedValue() {
            out = value as String
        }
        return out
    }

    static func uid(_ id: AudioDeviceID) -> String {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var cf: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &cf) == noErr,
              let value = cf?.takeRetainedValue() else { return "" }
        return value as String
    }

    static func channels(_ id: AudioDeviceID, input: Bool) -> Int {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0
        else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(
            raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func nominalRate(_ id: AudioDeviceID) -> Double {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var rate: Double = 0
        var size = UInt32(MemoryLayout<Double>.size)
        AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &rate)
        return rate
    }

    static func defaultInput() -> AudioDeviceID {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                   &addr, 0, nil, &size, &id)
        return id
    }

    /// The device whose name contains `needle` with channels in that
    /// direction. Nil simply means the headset is not here.
    static func find(_ needle: String, input: Bool) -> AudioDeviceID? {
        guard !needle.isEmpty else { return nil }
        for id in allDeviceIDs() where channels(id, input: input) > 0 {
            if name(id).localizedCaseInsensitiveContains(needle) { return id }
        }
        return nil
    }

    static func describeAll() {
        print("device                              in  out    rate  transport")
        for id in allDeviceIDs() {
            print(String(format: "%-34@ %3d %4d  %6.0f",
                         name(id) as NSString,
                         channels(id, input: true), channels(id, input: false),
                         nominalRate(id)))
        }
    }
}

// ---------------------------------------------------------------------------
// The microphone. Pinned to the headset; his system default is never changed.
// 16 kHz mono 16-bit — the shape K's ears already eat.
// ---------------------------------------------------------------------------

final class Recorder {
    private var engine: AVAudioEngine?
    private var pcm = Data()
    private var inputSilenced = false
    func silenceInput(_ muted: Bool) {
        lock.lock(); inputSilenced = muted; lock.unlock()
    }
    private let lock = NSLock()
    private(set) var startedAt: Date?
    private(set) var deviceUsed = ""
    private(set) var deviceUID = ""
    private(set) var firstAudioMs: Int?
    private(set) var lastAudioAt: Date?

    /// Fired the instant real audio begins arriving. This is the tick: not
    /// "button pressed" but "I can hear you now".
    var onFirstAudio: (() -> Void)?
    /// The microphone opened and stayed deaf, past every retry. The attempt is
    /// over. Exactly one thud follows, and nothing else.
    var onDeaf: (() -> Void)?

    private var deafTimer: DispatchSourceTimer?
    private var retriesLeft = 0
    private var pinnedDevice = ""
    private static var lastClosedAt: Date?
    static var reopenSettleMs = 250

    var isRunning: Bool { engine != nil }
    var openSeconds: Double { startedAt.map { Date().timeIntervalSince($0) } ?? 0 }

    /// MEASURED 2026-08-20: this Bluetooth microphone sometimes opens
    /// successfully and then delivers NOTHING — engine running, no error, every
    /// frame missing. One quiet reopen fixes it most of the time. Reopening
    /// FAST makes it worse (18 rapid opens drove the link persistently deaf),
    /// so there is exactly one retry, and a settle before any open.
    func start(deviceName: String, retries: Int = 1) -> String? {
        stop()
        silenceInput(false)
        if let closed = Recorder.lastClosedAt {
            let sinceMs = Date().timeIntervalSince(closed) * 1000
            if sinceMs < Double(Recorder.reopenSettleMs) {
                usleep(UInt32((Double(Recorder.reopenSettleMs) - sinceMs) * 1000))
            }
        }
        pinnedDevice = "" // Reopens also follow the current macOS input.
        retriesLeft = retries

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let macInput = Audio.defaultInput()
        deviceUsed = Audio.name(macInput)
        deviceUID = Audio.uid(macInput)

        let inFormat = input.inputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
            return "the microphone reported no usable format"
        }
        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                            sampleRate: 16000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            return "could not build the 16 kHz converter"
        }

        pcm = Data()
        firstAudioMs = nil
        lastAudioAt = nil
        input.installTap(onBus: 0, bufferSize: 2048, format: inFormat) { [weak self] buffer, _ in
            guard let self else { return }
            self.lastAudioAt = Date()
            if self.firstAudioMs == nil, let t0 = self.startedAt {
                self.firstAudioMs = Int(Date().timeIntervalSince(t0) * 1000)
                self.onFirstAudio?()
            }
            let capacity = AVAudioFrameCount(Double(buffer.frameLength)
                                             * 16000.0 / inFormat.sampleRate) + 512
            guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity)
            else { return }
            var fed = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, let channel = out.int16ChannelData, out.frameLength > 0
            else { return }
            self.lock.lock()
            if !self.inputSilenced {
                self.pcm.append(UnsafeBufferPointer(start: channel[0], count: Int(out.frameLength))
                                    .withMemoryRebound(to: UInt8.self) { Data($0) })
            }
            self.lock.unlock()
        }

        startedAt = Date()
        do { try engine.start() }
        catch {
            input.removeTap(onBus: 0)
            startedAt = nil
            return "the microphone would not open: \(error.localizedDescription)"
        }
        self.engine = engine
        armDeafCheck()
        return nil
    }

    /// Normal first audio arrives at 330-530 ms. Nothing by 700 ms means the
    /// stream is dead.
    private func armDeafCheck() {
        deafTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "k.ptt.deaf"))
        timer.schedule(deadline: .now() + .milliseconds(700))
        timer.setEventHandler { [weak self] in
            guard let self, self.engine != nil, self.firstAudioMs == nil else { return }
            guard self.retriesLeft > 0 else {
                record(["kind": "microphone-deaf",
                        "note": "opened but delivered nothing; ending the attempt "
                              + "rather than hammering the link"])
                self.onDeaf?()
                return
            }
            self.retriesLeft -= 1
            // Silent on purpose. Narrating retries talked over turns that were
            // working perfectly well (2026-08-20 09:35).
            record(["kind": "microphone-reopened-quietly", "device": self.pinnedDevice])
            let device = self.pinnedDevice
            if let engine = self.engine {
                engine.inputNode.removeTap(onBus: 0)
                engine.stop()
                self.engine = nil
            }
            Recorder.lastClosedAt = Date()
            _ = self.start(deviceName: device, retries: 0)
        }
        timer.resume()
        deafTimer = timer
    }

    /// The audio so far, as a finished WAV, without stopping. This is what
    /// lets his words be typed while he is still speaking.
    /// Loudness of a stretch of 16-bit audio, as dB below full scale.
    /// Silence is a large negative number; speech is much closer to zero.
    static func level(of pcm: Data) -> Double {
        guard pcm.count >= 2 else { return -120 }
        var sum = 0.0
        var n = 0
        pcm.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for sample in samples {
                let v = Double(sample) / 32768.0
                sum += v * v
                n += 1
            }
        }
        guard n > 0 else { return -120 }
        let rms = (sum / Double(n)).squareRoot()
        return rms > 0 ? 20 * log10(rms) : -120
    }

    /// How loud the last stretch of captured audio was.
    func level(lastSeconds seconds: Double) -> Double {
        lock.lock(); let raw = pcm; lock.unlock()
        let want = Int(seconds * 16000) * 2
        guard raw.count >= 3200 else { return -120 }
        return Recorder.level(of: Data(raw.suffix(min(want, raw.count))))
    }

    /// Cut the long quiet stretches out before the ears ever hear them.
    ///
    /// His report: "when I finish talking it prints the next word in gray that
    /// says yeah… just doing it over and over again." A pause is not silence —
    /// it is breath, a collar moving, the room — and the ears, asked what was
    /// said in two seconds of that, answer with the most likely thing a person
    /// says in a gap: "yeah", "okay", "mm-hmm". The honest fix is not to argue
    /// with the answer but to stop asking the question: a pause longer than
    /// `minPauseMs` is replaced with `keepMs` of true digital silence, which
    /// keeps the sentence boundary and offers nothing to hear.
    ///
    /// Short gaps between words are untouched, so his rhythm is preserved.
    static func trimPauses(_ pcm: Data, floorDb: Double,
                           minPauseMs: Int = 1000,
                           keepMs: Int = 150) -> (audio: Data, removedMs: Int) {
        let frame = 1600 * 2                       // 100 ms at 16 kHz, 16-bit
        guard pcm.count > frame else { return (pcm, 0) }
        var quiet: [Bool] = []
        var at = 0
        while at + frame <= pcm.count {
            quiet.append(level(of: pcm.subdata(in: at ..< at + frame)) < floorDb)
            at += frame
        }
        let minFrames = max(1, minPauseMs / 100)
        let keepFrames = max(0, keepMs / 100)
        var out = Data()
        var removed = 0
        var i = 0
        while i < quiet.count {
            if quiet[i] {
                var j = i
                while j < quiet.count && quiet[j] { j += 1 }
                let run = j - i
                if run >= minFrames {
                    // A real pause: keep a short, clean gap, drop the rest.
                    out.append(Data(count: keepFrames * frame))
                    removed += (run - keepFrames) * 100
                } else {
                    out.append(pcm.subdata(in: i * frame ..< min(pcm.count, j * frame)))
                }
                i = j
            } else {
                var j = i
                while j < quiet.count && !quiet[j] { j += 1 }
                out.append(pcm.subdata(in: i * frame ..< min(pcm.count, j * frame)))
                i = j
            }
        }
        // Whatever did not fill a whole frame at the end.
        let tail = (quiet.count) * frame
        if tail < pcm.count { out.append(pcm.subdata(in: tail ..< pcm.count)) }
        return (out, removed)
    }

    /// How much audio has been captured so far, in seconds.
    var capturedSeconds: Double {
        lock.lock(); let n = pcm.count; lock.unlock()
        return Double(n) / 2.0 / 16000.0
    }

    /// A segment of the audio, from `fromSeconds` to the end. Display only.
    func segment(fromSeconds from: Double) -> Data? {
        guard engine != nil else { return nil }
        lock.lock(); let raw = pcm; lock.unlock()
        let start = min(raw.count, max(0, Int(from * 16000) * 2))
        let body = raw.suffix(from: start)
        guard body.count > 3200 else { return nil }   // under 0.1 s is not speech
        return Recorder.wav(Data(body), rate: 16000)
    }

    /// A copy of the audio, without stopping. Used ONLY by the preview panel;
    /// nothing typed is ever derived from this.
    ///
    /// `lastSeconds` keeps the preview's cost flat. Re-hearing a whole
    /// five-minute recording every 0.8 s costs over a second a time and the
    /// strip would fall further behind the longer he spoke — the opposite of
    /// what it is for. A window is safe HERE, and only here, because the strip
    /// is allowed to rewrite itself: there is no page to reconcile with. The
    /// untouched typing path still hears the whole recording once at the end;
    /// an edited review hears only audio after its last edit boundary.
    func snapshot(lastSeconds: Int = 0) -> Data? {
        guard engine != nil else { return nil }
        lock.lock(); var raw = pcm; lock.unlock()
        guard raw.count > 3200 else { return nil }   // under 0.1 s is not speech
        if lastSeconds > 0 {
            let cap = lastSeconds * 16000 * 2
            if raw.count > cap { raw = raw.suffix(cap) }
        }
        return Recorder.wav(raw, rate: 16000)
    }

    /// Slice a finished 16 kHz mono WAV at the same boundary used by the live
    /// editor. This is how the closing click hears only words spoken after the
    /// last edit, rather than re-hearing and overwriting the edited text.
    static func segment(_ wav: Data, fromSeconds from: Double) -> Data? {
        guard wav.count > 44 else { return nil }
        let raw = Data(wav.dropFirst(44))
        let start = min(raw.count, max(0, Int(from * 16000) * 2))
        let body = Data(raw.suffix(from: start))
        guard body.count > 3200 else { return nil }
        return Recorder.wav(body, rate: 16000)
    }

    @discardableResult
    func stop() -> (wav: Data, seconds: Double)? {
        deafTimer?.cancel(); deafTimer = nil
        guard let engine else { return nil }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        Recorder.lastClosedAt = Date()
        lock.lock(); let raw = pcm; pcm = Data(); lock.unlock()
        startedAt = nil
        return (Recorder.wav(raw, rate: 16000), Double(raw.count) / 2.0 / 16000.0)
    }

    static func wav(_ pcm: Data, rate: Int) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + pcm.count))
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1)
        u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(pcm.count))
        d.append(pcm)
        return d
    }
}

// ---------------------------------------------------------------------------
// The silent stream that wins Now Playing, pinned away from the headset.
// ---------------------------------------------------------------------------

final class Silence {
    private var player: AVAudioPlayer?
    var isRunning: Bool { player?.isPlaying == true }

    func ensure(preferredOutput: String) {
        guard !isRunning else { return }
        start(preferredOutput: preferredOutput)
    }

    func start(preferredOutput: String) {
        stop()
        // Register real media playback through AVAudioPlayer rather than a DSP
        // engine. The silent WAV is generated in memory; macOS chooses output.
        let wav = Recorder.wav(Data(repeating: 0, count: 16000 * 2 * 2), rate: 16000)
        do {
            let candidate = try AVAudioPlayer(data: wav)
            candidate.volume = 0
            candidate.numberOfLoops = -1
            candidate.prepareToPlay()
            if candidate.play() { player = candidate }
        } catch {
            record(["kind": "media-client-start-failed", "error": String(describing: error)])
        }
    }

    func stop() { player?.stop(); player = nil }
}

// ---------------------------------------------------------------------------
// K's ears, through the route that leaves no trace of him anywhere.
// ---------------------------------------------------------------------------

final class KClient {
    var base: String
    private let session: URLSession
    private var capabilityCache: Set<String>?
    private let capabilityLock = NSLock()

    init(base: String) {
        self.base = base
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 20
        cfg.waitsForConnectivity = false
        session = URLSession(configuration: cfg)
    }

    /// No X-K-Client header, ever. That header made K treat this helper as one
    /// of her pages and hand it the microphone, and his own page then told him
    /// his microphone was somewhere else.
    private func call(_ path: String, body: Data?, contentType: String,
                      timeout: TimeInterval) -> (code: Int, json: [String: Any]?) {
        guard let url = URL(string: base + path) else { return (0, nil) }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = body == nil ? "GET" : "POST"
        if let body {
            req.httpBody = body
            req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        var code = 0
        var json: [String: Any]?
        let done = DispatchSemaphore(value: 0)
        session.dataTask(with: req) { data, response, _ in
            code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                json = obj
            }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + timeout + 2)
        return (code, json)
    }

    func state(timeout: TimeInterval = 3) -> [String: Any]? {
        call("/api/state", body: nil, contentType: "", timeout: timeout).json
    }

    func capabilities(refresh: Bool = false) -> Set<String> {
        capabilityLock.lock()
        if !refresh, let cached = capabilityCache { capabilityLock.unlock(); return cached }
        capabilityLock.unlock()
        let listed = (state(timeout: 2)?["capabilities"] as? [Any])?
            .compactMap { $0 as? String } ?? []
        let found = Set(listed)
        capabilityLock.lock(); capabilityCache = found.isEmpty ? nil : found; capabilityLock.unlock()
        return found
    }

    func forgetCapabilities() {
        capabilityLock.lock(); capabilityCache = nil; capabilityLock.unlock()
    }

    var hasQuietDraft: Bool { capabilities().contains("quiet-draft-turn") }

    /// Transcribe only, and leave no trace: no session, nothing in her live
    /// transcript, no row in her ledger. He dictates into Mail and editors —
    /// those sentences are not a conversation with her.
    func draft(_ wav: Data, timeout: TimeInterval = 300)
        -> (code: Int, json: [String: Any]?, quiet: Bool) {
        let quiet = hasQuietDraft
        let route = quiet ? "/api/turn?draft=1&quiet=1" : "/api/turn?draft=1"
        let result = call(route, body: wav, contentType: "audio/wav", timeout: timeout)
        return (result.code, result.json, quiet)
    }

    func enrollmentPreview(_ wav: Data) -> (code: Int, json: [String: Any]?) {
        call("/api/enrollment-preview", body: wav, contentType: "audio/wav", timeout: 15)
    }

    func diagnose(_ wav: Data) -> (code: Int, json: [String: Any]?) {
        call("/api/diagnose", body: wav, contentType: "audio/wav", timeout: 90)
    }

    func voiceSetup(_ action: String, wav: Data) -> (code: Int, json: [String: Any]?) {
        call("/api/voice/" + action, body: wav, contentType: "audio/wav", timeout: 90)
    }

    var isUp: Bool { state(timeout: 2)?["ready"] as? Bool == true }
}

// ---------------------------------------------------------------------------
// Typing, and the two permissions this needs.
// ---------------------------------------------------------------------------

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}

enum Keys {
    static let kReturn: CGKeyCode = 36
    static var trusted: Bool { AXIsProcessTrusted() }

    @discardableResult
    static func requestTrust() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Set by the test suite to count keystrokes instead of pressing real keys.
    nonisolated(unsafe) static var testHook: ((String) -> Void)?

    /// Type at the cursor, exactly as a keyboard would. Unicode goes straight
    /// through, so apostrophes and punctuation arrive intact.
    static func type(_ text: String) {
        guard !text.isEmpty else { return }
        if let hook = testHook { hook(text); return }
        let src = CGEventSource(stateID: .hidSystemState)
        for chunk in Array(text).chunked(into: 12) {
            var utf16 = Array(String(chunk).utf16)
            guard let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false)
            else { continue }
            down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            usleep(1500)
        }
    }

    static func tapReturn() {
        if let hook = testHook { hook("\n"); return }
        let src = CGEventSource(stateID: .hidSystemState)
        CGEvent(keyboardEventSource: src, virtualKey: kReturn, keyDown: true)?
            .post(tap: .cghidEventTap)
        usleep(15_000)
        CGEvent(keyboardEventSource: src, virtualKey: kReturn, keyDown: false)?
            .post(tap: .cghidEventTap)
    }
}

enum Mic {
    /// A refused microphone under launchd is not an error: the engine starts
    /// happily and delivers silence for ever. So it is checked, not assumed.
    static var granted: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static var statusName: String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return "granted"
        case .denied: return "DENIED"
        case .restricted: return "restricted"
        case .notDetermined: return "not yet asked"
        @unknown default: return "unknown"
        }
    }

    static func request(_ done: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { ok in
            DispatchQueue.main.async { done(ok) }
        }
    }
}

// ---------------------------------------------------------------------------
// The words, cleaned.
//
// K's ears occasionally hand back `<unk>` — a placeholder for a sound they
// could not name. Typed literally that puts "<unk><unk>" in his document, so
// it is never typed. It is not something he said.
// ---------------------------------------------------------------------------

enum Focus {
    /// Has his cursor left the window he started dictating into?
    ///
    /// Unknown-before is treated as "not moved": if we never learned where he
    /// started, refusing to type would be a guess, and typing is what he asked
    /// for. Unknown-now IS treated as moved — no front app at all is exactly
    /// the shape a modal dialog makes, which is what swallowed his 48 seconds.
    static func moved(openedPid: pid_t?, nowPid: pid_t?) -> Bool {
        guard let openedPid else { return false }
        guard let nowPid else { return true }
        return nowPid != openedPid
    }
}

enum Text {
    /// The words a person says in a gap rather than in a sentence.
    private static let backchannel: Set<String> = [
        "yeah", "yep", "yes", "okay", "ok", "mm-hmm", "mmhmm", "mhm", "mm",
        "uh-huh", "huh", "hmm", "um", "uh", "so", "right", "thanks",
        "thank you", "bye", "you", "the",
    ]

    /// Is this hearing nothing but a gap-filler?
    ///
    /// MEASURED 2026-08-20 on his own room noise: a 0.8-second stretch of
    /// non-speech makes the ears answer "Okay." at EVERY loudness tested,
    /// from -50 dB to -36 dB, while the same noise at 1.2 s and 2.0 s produces
    /// nothing at all. It is the SHORTNESS of the stretch that invents the
    /// word, not how loud the room is — which is why a loudness gate alone
    /// never caught his "it prints the next word in gray that says yeah".
    static func isJustBackchannel(_ text: String) -> Bool {
        let bare = text.lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: " .,!?;:'\"-\n"))
        guard !bare.isEmpty else { return true }
        if backchannel.contains(bare) { return true }
        let words = bare.split(separator: " ").map(String.init)
        return words.count == 1 && backchannel.contains(words[0])
    }

    static func isNoise(_ word: String) -> Bool {
        let bare = word.lowercased()
        return bare.contains("<unk>") || bare == "<s>" || bare == "</s>"
    }

    static func clean(_ heard: String) -> String {
        heard.split(separator: " ").map(String.init)
            .filter { !isNoise($0) && !$0.isEmpty }
            .joined(separator: " ")
    }
}

// ---------------------------------------------------------------------------
// The ramble pass — "what he meant", derived from "what he said", never
// replacing it.
//
// He speaks in long rambles; the intended message is in there wearing
// fillers, false starts and self-corrections. The fast mind (whatever the
// live loop's settings.json holds) tidies the FINAL whole-recording
// transcript — never mid-speech; the preview strip keeps showing his raw
// words while he talks.
//
// THE HONESTY RAIL, deterministic and unconditional: the cleaned text must
// be his own words in his own order with some of them removed — a
// word-level subsequence of the raw transcript (case and punctuation
// aside). Deleting is the only power the model has. A cleaned text that
// adds a word, changes a word, reorders, finishes a sentence he did not
// finish, or keeps too little of what he said is thrown away and his raw
// words are typed instead. The raw transcript is ALWAYS saved to
// last-dictation.txt before this pass ever runs.
// ---------------------------------------------------------------------------

enum Rambler {
    static let LOOP_SETTINGS = HOME.appendingPathComponent(
        "K/constant K/08_EXPERIENCE/LiveConversation/state/settings.json")
    static let LAST_CLEAN = STATE.appendingPathComponent("last-dictation-clean.txt")
    static let OLLAMA = "http://127.0.0.1:11434"
    static let FALLBACK_MODEL = "qwen3:4b-instruct-2507-q4_K_M"
    /// Below this share of his words surviving, the pass has stopped
    /// tidying and started summarizing — and summarizing is not its job.
    /// When in doubt, keep his words.
    static let KEEP_FLOOR = 0.30

    static let SYSTEM = """
        You tidy one spoken dictation. The text below is a verbatim \
        transcript of a man speaking. Remove only speech debris: filler \
        words (uh, um, you know, I mean, like, basically, anyways), \
        immediate word repeats, false starts he abandoned, and the wrong \
        half of a self-correction (keep the corrected words, drop the \
        corrected-away ones and the correction chatter around them). Keep \
        everything he meant to say, in his own words and his own order. \
        You may ONLY delete words — never add a word, never change a \
        word, never reorder words, never finish a sentence he did not \
        finish. You may fix punctuation and capitalization. If the text \
        is already clean, return it unchanged. Return ONLY the cleaned \
        text, nothing else.
        """

    /// The fast mind the live loop is running right now — one source of
    /// truth, read fresh each time so a model swap there is a model swap
    /// here.
    static func fastMindModel() -> String {
        guard let data = try? Data(contentsOf: LOOP_SETTINGS),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let model = obj["model"] as? String, !model.isEmpty
        else { return FALLBACK_MODEL }
        return model
    }

    /// The rail's view of a text: lowercased words with ALL punctuation
    /// treated as a separator, apostrophes inside a word kept, curly ones
    /// straightened. "It's" and "it’s" are the same word; "word," and
    /// "word" are the same word — and "yesterday—just" is TWO words, so a
    /// model that re-punctuates with dashes is still judged word by word.
    static func tokens(_ text: String) -> [String] {
        let straight = text.replacingOccurrences(of: "\u{2019}", with: "'")
            .lowercased()
        var words: [String] = []
        var current = ""
        for ch in straight {
            if ch.isLetter || ch.isNumber || ch == "'" {
                current.append(ch)
            } else if !current.isEmpty {
                words.append(current); current = ""
            }
        }
        if !current.isEmpty { words.append(current) }
        return words.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
            .filter { !$0.isEmpty }
    }

    /// True when `cleaned` is `raw` with words removed and nothing else —
    /// an ordered subsequence at the word level. This is the whole honesty
    /// guarantee, and it does not depend on the model behaving.
    static func deletionOnly(cleaned: String, raw: String) -> Bool {
        let want = tokens(cleaned)
        guard !want.isEmpty else { return false }
        let have = tokens(raw)
        var matched = 0
        for word in have where matched < want.count {
            if word == want[matched] { matched += 1 }
        }
        return matched == want.count
    }

    struct Outcome {
        let text: String      // what to type — cleaned, or the raw fallback
        let applied: Bool
        let ms: Int
        let model: String
        let why: String       // plain words for the event record
    }

    /// One bounded cleaning pass. Never throws, never blocks past the
    /// timeout, never returns words the transcript does not hold — on any
    /// doubt the answer is his raw text, labeled with why.
    static func clean(_ raw: String, timeoutMs: Int) -> Outcome {
        let model = fastMindModel()
        let started = Date()
        func fallback(_ why: String) -> Outcome {
            Outcome(text: raw, applied: false,
                    ms: Int(Date().timeIntervalSince(started) * 1000),
                    model: model, why: why)
        }
        let rawWords = tokens(raw).count
        let payload: [String: Any] = [
            "model": model,
            "stream": false,
            "messages": [["role": "system", "content": SYSTEM],
                         ["role": "user", "content": raw]],
            "options": ["temperature": 0,
                        "num_ctx": 8192,
                        "num_predict": max(256, rawWords * 3)],
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload),
              let url = URL(string: OLLAMA + "/api/chat") else {
            return fallback("could not build the request")
        }
        var req = URLRequest(url: url,
                             timeoutInterval: Double(timeoutMs) / 1000)
        req.httpMethod = "POST"
        req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let cfg = URLSessionConfiguration.ephemeral
        cfg.waitsForConnectivity = false
        let session = URLSession(configuration: cfg)
        var answer: String?
        let done = DispatchSemaphore(value: 0)
        session.dataTask(with: req) { data, _, _ in
            if let data,
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let message = obj["message"] as? [String: Any],
               let content = message["content"] as? String {
                answer = content
            }
            done.signal()
        }.resume()
        guard done.wait(timeout: .now() + Double(timeoutMs) / 1000 + 1) == .success,
              var cleaned = answer else {
            return fallback("the fast mind did not answer in time — raw words typed")
        }
        // A reasoning model may wrap its thinking in tags; strip them and
        // let the rail judge what is left.
        if let range = cleaned.range(of: "</think>") {
            cleaned = String(cleaned[range.upperBound...])
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            return fallback("the fast mind returned nothing — raw words typed")
        }
        guard deletionOnly(cleaned: cleaned, raw: raw) else {
            return fallback("the cleaned text was not purely his words — raw words typed")
        }
        let kept = tokens(cleaned).count
        guard rawWords == 0 || Double(kept) / Double(rawWords) >= KEEP_FLOOR else {
            return fallback("kept too little of what he said — raw words typed")
        }
        if tokens(cleaned) == tokens(raw) {
            return fallback("already clean")
        }
        return Outcome(text: cleaned, applied: true,
                       ms: Int(Date().timeIntervalSince(started) * 1000),
                       model: model, why: "tidied — deletion-only, verified")
    }
}



// ---------------------------------------------------------------------------
// What the strip shows.
//
// His words, after the first version: "whatever I'm speaking is being
// disappeared and it's constantly changing… the box is not increasing — it
// just includes three lines and that's it."
//
// One cause behind both. The strip was showing the transcript of a rolling
// 30-second window, so words older than 30 seconds fell off the front, every
// pass re-heard the same window and re-rendered it slightly differently, and
// the text could never grow past what 30 seconds of speech fills — about
// three lines. Everything he described follows from that.
//
// So the display is now two parts:
//
//   FROZEN   everything already heard and settled. Written once, never
//            re-rendered, never re-heard. This is the bulk of his dictation
//            and it does not move.
//   LIVE     the current segment only, which may change as the ears revise it.
//
// He sees his whole dictation from the first word, and only the newest stretch
// ever changes in front of him.
// ---------------------------------------------------------------------------

final class PreviewText {
    private(set) var frozen = ""
    private(set) var live = ""
    private(set) var frozenUntil: Double = 0
    private let freezeAfter: Double

    /// A segment boundary is where words get clipped: the next stretch starts
    /// mid-phrase and the ears lose the word that straddled the cut (measured:
    /// "we keep" disappeared from the strip at exactly such a cut). The common
    /// case is handled elsewhere — a second of quiet settles the stretch at a
    /// natural gap, which is where he pauses anyway. This timer is only the
    /// backstop for someone talking without a break, so it is set long enough
    /// to stay out of the way.
    init(freezeAfter seconds: Double = 14) { freezeAfter = seconds }

    /// Everything shown, oldest word first.
    var full: String {
        if frozen.isEmpty { return live }
        if live.isEmpty { return frozen }
        return frozen + " " + live
    }

    /// How many words at the end may still change — the rest is settled.
    var liveWordCount: Int { live.split(separator: " ").count }

    /// Once a stretch has settled, continued room silence is not part of the
    /// next phrase. Keep the next listening boundary beside the live recorder
    /// so speech after a long pause reaches the ears as promptly as speech
    /// after a short one.
    func skipIdleSilence(to seconds: Double) {
        guard live.isEmpty else { return }
        frozenUntil = max(frozenUntil, seconds)
    }

    /// Feed the transcript of the audio from `frozenUntil` up to `now`.
    ///
    /// When that segment has grown past the freeze length it is written into
    /// the frozen part and a fresh segment starts from exactly `now` — the
    /// same instant that was just transcribed, so not a syllable falls between
    /// the two.
    @discardableResult
    func advance(transcript: String, upTo now: Double, force: Bool = false) -> Bool {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        if force || now - frozenUntil >= freezeAfter {
            // Settle the FULLER of the two. The grey on screen may already
            // hold a longer hearing of this same stretch than the one that
            // just came back, and settling the shorter one would take words
            // off the screen at the very moment they are supposed to become
            // permanent — measured: 13 words vanished at a freeze boundary.
            let best = text.count >= live.count ? text : live
            frozen = frozen.isEmpty ? best : frozen + " " + best
            live = ""
            frozenUntil = now
            return true
        }
        // Grey may only append or refine FORWARD.
        //
        // A segment heard on its own, with no run-up, sometimes comes back
        // garbled and much shorter — measured on a real replay, grey collapsed
        // from 22 words to 3 and then back to 27 as the ears stumbled over a
        // mid-sentence start. Settled text never moved, but he still watches
        // twenty words vanish, and that is what he means by "it deletes my
        // previous words".
        //
        // So a shorter guess is treated as a stumble, not as news: the strip
        // keeps what it had until the ears offer at least as much again.
        if live.isEmpty || text.count >= live.count {
            live = text
        }
        return false
    }
}

/// The text becomes authoritative the instant he edits or selects it. From
/// that point onward the recorder only contributes audio captured AFTER the
/// edit boundary, so a final whole-recording hearing can never erase a manual
/// correction or duplicate words already visible in the box.
struct EditableDraftSnapshot {
    let base: String
    let live: String
    let audioFrom: Double
    let voiceSelection: NSRange?
    let voiceSawSpeech: Bool
    let touched: Bool

    var displayed: String { EditableDraft.join(base, live) }

    /// Resolve the last, not-yet-settled audio without changing anything the
    /// user already edited. A spoken correction replaces the selected UTF-16
    /// range; ordinary speech replaces the grey tail.
    func finalText(tail: String?) -> String {
        let heard = tail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let range = voiceSelection {
            guard voiceSawSpeech, !heard.isEmpty else { return base }
            return EditableDraft.replacing(in: base, range: range, with: heard)
        }
        return EditableDraft.join(base, heard.isEmpty ? live : heard)
    }
}

final class EditableDraft {
    private(set) var base = ""
    private(set) var live = ""
    private(set) var audioFrom: Double = 0
    private(set) var voiceSelection: NSRange?
    private(set) var voiceSawSpeech = false
    private(set) var touched = false

    var displayed: String { Self.join(base, live) }

    static func join(_ left: String, _ right: String) -> String {
        let a = left.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = right.trimmingCharacters(in: .whitespacesAndNewlines)
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        return a + " " + b
    }

    static func valid(_ range: NSRange, in text: String) -> Bool {
        range.location != NSNotFound && range.location >= 0 && range.length > 0
            && range.location + range.length <= (text as NSString).length
    }

    static func replacing(in text: String, range: NSRange, with replacement: String) -> String {
        guard valid(range, in: text) else { return text }
        return (text as NSString).replacingCharacters(in: range, with: replacement)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Keyboard editing accepts exactly what is visible and starts a fresh
    /// audio tail at this instant.
    func userChanged(text: String, at seconds: Double) {
        base = text
        live = ""
        audioFrom = seconds
        voiceSelection = nil
        voiceSawSpeech = false
        touched = true
    }

    /// A mouse selection means: keep this visible text, and use the next
    /// spoken phrase as the replacement for precisely this range.
    func selected(text: String, range: NSRange, at seconds: Double) {
        guard Self.valid(range, in: text) else { return }
        base = text
        live = ""
        audioFrom = seconds
        voiceSelection = range
        voiceSawSpeech = false
        touched = true
    }

    func noteVoiceSpeech() { voiceSawSpeech = true }

    /// The same silence rule after an edit or while a selected word is waiting
    /// for its spoken correction. Once correction speech begins, its starting
    /// boundary is fixed so no syllable can be skipped.
    func skipIdleSilence(to seconds: Double) {
        guard live.isEmpty, !voiceSawSpeech else { return }
        audioFrom = max(audioFrom, seconds)
    }

    func updateLive(_ transcript: String) {
        guard voiceSelection == nil else { return }
        let clean = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if live.isEmpty || clean.count >= live.count { live = clean }
    }

    func settleLive(_ transcript: String, at seconds: Double) {
        guard voiceSelection == nil else { return }
        let clean = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let best = clean.count >= live.count ? clean : live
        base = Self.join(base, best)
        live = ""
        audioFrom = seconds
    }

    func replaceSelection(with transcript: String, at seconds: Double) {
        guard let range = voiceSelection else { return }
        base = Self.replacing(in: base, range: range, with: transcript)
        live = ""
        audioFrom = seconds
        voiceSelection = nil
        voiceSawSpeech = false
        touched = true
    }

    func snapshot() -> EditableDraftSnapshot {
        EditableDraftSnapshot(base: base, live: live, audioFrom: audioFrom,
                              voiceSelection: voiceSelection,
                              voiceSawSpeech: voiceSawSpeech, touched: touched)
    }
}

func shouldSettlePreview(modern: Bool, quiet: Bool, quietFor: Double,
                         sawSpeech: Bool, hasLiveWords: Bool) -> Bool {
    if modern { return quiet && sawSpeech && quietFor >= 0.7 }
    return quiet && quietFor >= 1.0 && hasLiveWords
}

/// The UTF-16 boundary after the last complete character shared by two
/// strings. NSTextView selections use UTF-16 offsets, while stopping only at
/// composed-character boundaries avoids cutting an emoji or accented letter
/// in half when the live suffix is revised.
func commonComposedPrefixLength(_ left: String, _ right: String) -> Int {
    let a = left as NSString
    let b = right as NSString
    let limit = min(a.length, b.length)
    var location = 0
    while location < limit {
        let aRange = a.rangeOfComposedCharacterSequence(at: location)
        let bRange = b.rangeOfComposedCharacterSequence(at: location)
        let aPart = a.substring(with: aRange)
        let bPart = b.substring(with: bRange)
        guard aPart == bPart else { break }
        location += aRange.length
    }
    return location
}

// ---------------------------------------------------------------------------
// The preview strip.
//
// His words: "as I speak, I don't see any words typed here, so I don't know
// what all it has captured."
//
// So this shows him. It is a small panel floating above whatever he is writing
// in. The original display-only behavior remains available; interactive review
// additionally lets him edit or select-and-speak before the same closing click.
//
// That separation is the whole point. The preview may be wrong, may flicker,
// may rewrite itself completely — none of it costs him anything, because it is
// a window of ours and not his text. A phantom here is a hint to say the word
// again, not a word in his message.
//
// Showing the panel never takes focus. Clicking its editor can take keyboard
// focus temporarily; the helper remembers and restores the destination app.
// ---------------------------------------------------------------------------

enum ReviewShortcut: Equatable {
    case selectAll, copy, cut, paste, undo, redo
}

/// K PTT is a menu-bar helper, so it has no ordinary Edit menu to translate
/// Command-A/C/X/V into NSText actions. Decode only the standard equivalents;
/// every other key remains AppKit's responsibility.
func reviewShortcut(key: String?, modifiers: NSEvent.ModifierFlags) -> ReviewShortcut? {
    let flags = modifiers.intersection(.deviceIndependentFlagsMask)
    guard flags.contains(.command), !flags.contains(.control), !flags.contains(.option),
          let key = key?.lowercased() else { return nil }
    switch key {
    case "a": return .selectAll
    case "c": return .copy
    case "x": return .cut
    case "v": return .paste
    case "z": return flags.contains(.shift) ? .redo : .undo
    default: return nil
    }
}

final class ReviewTextView: NSTextView {
    /// A keyboard/clipboard selection is for ordinary editing, not the target
    /// of the next spoken correction. The next mouse click or drag explicitly
    /// returns selection ownership to select-and-speak.
    var keyboardSelectionOnly = false

    override func mouseDown(with event: NSEvent) {
        keyboardSelectionOnly = false
        super.mouseDown(with: event)
    }
}

final class ReviewPanel: NSPanel {
    var onShortcut: ((ReviewShortcut) -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let text = firstResponder as? ReviewTextView,
              let shortcut = reviewShortcut(key: event.charactersIgnoringModifiers,
                                            modifiers: event.modifierFlags) else {
            return super.performKeyEquivalent(with: event)
        }

        // This is the safety boundary: once a Command editing action is used,
        // an existing selection must never still mean “replace it when I next
        // speak.” A fresh mouse selection can arm that meaning again.
        text.keyboardSelectionOnly = true
        onShortcut?(shortcut)
        switch shortcut {
        case .selectAll: text.selectAll(nil)
        case .copy: text.copy(nil)
        case .cut: text.cut(nil)
        case .paste: text.paste(nil)
        case .undo: text.undoManager?.undo()
        case .redo: text.undoManager?.redo()
        }
        return true
    }
}

func auroraIsDark(_ appearance: NSAppearance) -> Bool {
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
}

func auroraLiveTextColor() -> NSColor {
    NSColor(srgbRed: 0.39, green: 0.40, blue: 0.43, alpha: 0.74)
}

func auroraMutedControlColor() -> NSColor {
    NSColor(srgbRed: 0.34, green: 0.35, blue: 0.38, alpha: 0.62)
}

func panelPrimaryTextColor() -> NSColor {
    NSColor(srgbRed: 0.10, green: 0.10, blue: 0.11, alpha: 0.96)
}

func auroraStatusColor(_ line: String, warning: Bool = false) -> NSColor {
    if warning {
        // A third colour exists only for a genuine problem, never a normal
        // interaction state.
        return NSColor(srgbRed: 0.88, green: 0.26, blue: 0.28, alpha: 0.96)
    }
    switch line {
    case "Ready for correction", "Hearing correction":
        return NSColor(srgbRed: 0.95, green: 0.79, blue: 0.30, alpha: 0.98)
    default: // Listening and ordinary Editing
        return NSColor(srgbRed: 0.30, green: 0.64, blue: 1.00, alpha: 0.98)
    }
}

/// A genuinely white body. Repeated attempts to coax white out of AppKit's
/// visual-effect materials stayed grey because the material itself adds a
/// desaturating wash. The blur now sits faintly underneath this surface rather
/// than defining its colour.
final class WhiteSurfaceView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        updateColor()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        updateColor()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColor()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func updateColor() {
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.96).cgColor
    }
}

/// One continuous rounded clip plus a neutral one-pixel light catch. Colour
/// belongs only to the live words and state dot; the glass itself stays clear.
final class AuroraBackdropView: NSView {
    private let rim = CAGradientLayer()
    private let rimMask = CAShapeLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        wantsLayer = true
        layer?.cornerRadius = 18
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        rim.startPoint = CGPoint(x: 0, y: 1)
        rim.endPoint = CGPoint(x: 1, y: 0.15)
        rim.mask = rimMask
        rim.zPosition = 100
        layer?.addSublayer(rim)
        updateColors()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rim.frame = bounds
        rimMask.frame = bounds
        rimMask.path = CGPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                              cornerWidth: 17.5, cornerHeight: 17.5,
                              transform: nil)
        rimMask.fillColor = NSColor.clear.cgColor
        rimMask.strokeColor = NSColor.white.cgColor
        rimMask.lineWidth = 1
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        let dark = auroraIsDark(effectiveAppearance)
        rim.colors = dark
            ? [NSColor.white.withAlphaComponent(0.58).cgColor,
               NSColor.white.withAlphaComponent(0.24).cgColor,
               NSColor.white.withAlphaComponent(0.10).cgColor,
               NSColor.white.withAlphaComponent(0.34).cgColor]
            : [NSColor.white.withAlphaComponent(0.95).cgColor,
               NSColor.white.withAlphaComponent(0.48).cgColor,
               NSColor.black.withAlphaComponent(0.12).cgColor,
               NSColor.white.withAlphaComponent(0.62).cgColor]
    }
}

final class AuroraStatusDotView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 3.5
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.cornerRadius = 3.5
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func setColor(_ color: NSColor) {
        layer?.backgroundColor = color.cgColor
        layer?.shadowColor = color.cgColor
        layer?.shadowOpacity = 0.55
        layer?.shadowRadius = 5
        layer?.shadowOffset = .zero
    }
}

final class PreviewStrip: NSObject, NSTextViewDelegate {
    var fontSize: Int = 22
    var lineSpacing: Int = 9
    var onDiscard: (() -> Void)?
    var onSubmit: ((String, NSRange) -> Void)?
    var onTextChanged: ((String, NSRange) -> Void)?
    var onSelectionChanged: ((String, NSRange) -> Void)?
    var onKeyboardCommand: ((String, NSRange, ReviewShortcut) -> Void)?

    private var panel: NSPanel?
    private var scroll: NSScrollView?
    private var textView: NSTextView?
    private var noteView: NSTextField?
    private var statusDotView: AuroraStatusDotView?
    private var closeButton: NSButton?
    private var interactive = false
    private var changingProgrammatically = false
    private var normalInsertionPointColor = NSColor.controlAccentColor
    /// During one dictation the box may grow, but it never shrinks and bounces
    /// as the grey transcript revises itself.
    private var sessionHeight: CGFloat = 76

    private var width: CGFloat {
        min(900, (NSScreen.main?.visibleFrame.width ?? 1200) * 0.68)
    }
    private let padding: CGFloat = 20
    private let minHeight: CGFloat = 76

    /// How tall it may grow before it starts scrolling instead. Most of the
    /// screen, because the whole point is that he can see the whole dictation
    /// — his words: "the box is expanding and I can clearly see all my text
    /// from start to beginning."
    private var maxHeight: CGFloat {
        (NSScreen.main?.visibleFrame.height ?? 800) * 0.62
    }

    private func build() {
        guard panel == nil else { return }
        let width = self.width
        let panel = ReviewPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: minHeight),
                                styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.onShortcut = { [weak self] shortcut in
            guard let self, let textView = self.textView else { return }
            self.setSpeaking(false)
            self.onKeyboardCommand?(textView.string, textView.selectedRange(), shortcut)
        }

        // The effect view used to be the window's root. macOS composites blur
        // outside that view's rounded layer, leaving pale square pixels in the
        // corners. A plain outer view now clips the ENTIRE visual-effect tree,
        // so the window is genuinely rounded rather than a rounded rectangle
        // painted inside a square one.
        let backdrop = AuroraBackdropView(
            frame: NSRect(x: 0, y: 0, width: width, height: minHeight))
        backdrop.autoresizingMask = [.width, .height]

        let material = NSVisualEffectView(frame: backdrop.bounds)
        // Keep only a trace of background softness. The white surface above is
        // now authoritative, so AppKit's native grey can no longer colour it.
        material.material = .underWindowBackground
        material.blendingMode = .behindWindow
        material.state = .active
        material.alphaValue = 0.12
        material.autoresizingMask = [.width, .height]
        backdrop.addSubview(material)

        let whiteSurface = WhiteSurfaceView(frame: backdrop.bounds)
        whiteSurface.autoresizingMask = [.width, .height]
        backdrop.addSubview(whiteSurface)

        let statusDot = AuroraStatusDotView(frame: NSRect(x: 0, y: 0, width: 7, height: 7))
        statusDot.isHidden = true
        backdrop.addSubview(statusDot)

        // In review mode this line says exactly what a click or selection will
        // do. In the old display-only mode it appears only for a warning.
        let note = NSTextField(labelWithString: "")
        note.font = .systemFont(ofSize: 13, weight: .medium)
        note.textColor = auroraMutedControlColor()
        note.drawsBackground = false
        note.isBezeled = false
        note.isHidden = true
        note.autoresizingMask = [.width, .minYMargin]
        backdrop.addSubview(note)

        let close = NSButton(title: "×", target: self, action: #selector(discardPressed))
        close.isBordered = false
        close.font = .systemFont(ofSize: 20, weight: .medium)
        close.contentTintColor = auroraMutedControlColor()
        close.toolTip = "Discard this dictation"
        close.isHidden = true
        close.autoresizingMask = [.minXMargin, .minYMargin]
        backdrop.addSubview(close)

        let scroll = NSScrollView(frame: NSRect(x: padding, y: padding,
                                                width: width - padding * 2,
                                                height: minHeight - padding * 2))
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.autoresizingMask = [.width, .height]

        let text = ReviewTextView(frame: scroll.bounds)
        text.delegate = self
        text.isRichText = false
        text.importsGraphics = false
        text.allowsUndo = true
        text.drawsBackground = false
        text.textContainerInset = .zero
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.containerSize = NSSize(width: scroll.contentSize.width,
                                                   height: .greatestFiniteMagnitude)
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        normalInsertionPointColor = text.insertionPointColor
        scroll.documentView = text
        backdrop.addSubview(scroll)

        panel.contentView = backdrop
        self.panel = panel
        self.scroll = scroll
        self.textView = text
        self.noteView = note
        self.statusDotView = statusDot
        self.closeButton = close
        place(height: minHeight)
    }

    /// The panel sits near the bottom of the screen and grows UPWARD, so the
    /// newest words stay where his eye already is.
    private func place(height: CGFloat) {
        guard let panel, let screen = NSScreen.main else { return }
        let width = self.width
        let visible = screen.visibleFrame
        let bottom = visible.minY + 90
        let frame = NSRect(x: visible.midX - width / 2, y: bottom,
                           width: width, height: height)
        // Window animation made the glass grow first while AppKit laid out the
        // status against the old height. The result looked like the status
        // briefly fell into the words and then chased the top edge. One atomic
        // frame change keeps the glass, status, close button, and text together.
        panel.setFrame(frame, display: true)
    }

    func show(interactive: Bool = false) {
        build()
        self.interactive = interactive
        sessionHeight = minHeight
        place(height: minHeight)
        panel?.ignoresMouseEvents = !interactive
        textView?.isEditable = interactive
        textView?.isSelectable = interactive
        textView?.insertionPointColor = normalInsertionPointColor
        closeButton?.isHidden = !interactive
        noteView?.isHidden = true
        statusDotView?.isHidden = true
        set(NSAttributedString(
            string: "listening…",
            attributes: [.font: NSFont.systemFont(ofSize: CGFloat(fontSize)),
                         .foregroundColor: auroraLiveTextColor()]))
        if interactive { setStatus("Listening") }
        if interactive {
            // A nonactivating panel can receive keyboard input while retaining
            // the destination application's identity for delivery.
            panel?.becomesKeyOnlyIfNeeded = false
            panel?.makeKeyAndOrderFront(nil)
            panel?.makeFirstResponder(textView)
        } else {
            panel?.orderFrontRegardless()
        }
    }

    /// The last few words are the ears' least settled guess, so they are shown
    /// faded — he can see which part is still firming up.
    /// Black is settled and will never change. Grey may still be refined.
    ///
    /// The split used to fade only the last four words, which meant the rest of
    /// the still-changing stretch was painted BLACK and then revised in front
    /// of him — his "it still deletes my previous words sometimes". Now the
    /// line is exactly where the truth is: black is frozen, grey is not.
    func update(black: String, grey: String) {
        guard panel != nil else { return }
        let size = CGFloat(fontSize)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = CGFloat(lineSpacing)
        let out = NSMutableAttributedString(
            string: black.isEmpty ? "" : (grey.isEmpty ? black : black + " "),
            attributes: [.font: NSFont.systemFont(ofSize: size),
                         .foregroundColor: panelPrimaryTextColor(),
                         .paragraphStyle: paragraph])
        if !grey.isEmpty {
            out.append(NSAttributedString(
                string: grey,
                attributes: [.font: NSFont.systemFont(ofSize: size),
                             // Dusty periwinkle keeps the unsettled words
                             // unmistakable without making them look disabled,
                             // and remains readable across light/dark backdrops.
                             .foregroundColor: auroraLiveTextColor(),
                             .paragraphStyle: paragraph]))
        }
        guard out.length > 0 else { return }
        set(out, preservingSelection: interactive)
    }

    func setStatus(_ line: String, warning: Bool = false) {
        build()
        let color = auroraMutedControlColor()
        statusDotView?.setColor(auroraStatusColor(line, warning: warning))
        statusDotView?.isHidden = false
        if noteView?.stringValue == line,
           noteView?.isHidden == false,
           noteView?.textColor == color { return }
        noteView?.stringValue = line
        noteView?.textColor = color
        noteView?.isHidden = false
        resizeForCurrentText()
    }

    var text: String { textView?.string ?? "" }
    var selection: NSRange { textView?.selectedRange() ?? NSRange(location: 0, length: 0) }

    func select(_ range: NSRange) {
        guard let textView else { return }
        let length = (textView.string as NSString).length
        let safe = NSRange(location: min(range.location, length),
                           length: min(range.length, max(0, length - min(range.location, length))))
        changingProgrammatically = true
        textView.setSelectedRange(safe)
        changingProgrammatically = false
        textView.scrollRangeToVisible(safe)
        setSpeaking(false)
    }

    /// Keep keyboard focus and its insertion position, but stop painting the
    /// blue caret while speech is flowing. It returns on the first quiet meter
    /// pass, mouse selection, or keyboard edit, so manual editing still has an
    /// honest landing marker.
    func setSpeaking(_ speaking: Bool) {
        guard interactive, let textView else { return }
        let wanted = speaking ? NSColor.clear : normalInsertionPointColor
        guard textView.insertionPointColor != wanted else { return }
        textView.insertionPointColor = wanted
        textView.needsDisplay = true
    }

    /// Something he needs to read, above his words.
    func note(_ line: String, text: String) {
        build()
        noteView?.stringValue = line
        noteView?.textColor = auroraMutedControlColor()
        noteView?.isHidden = false
        statusDotView?.setColor(auroraStatusColor(line, warning: true))
        statusDotView?.isHidden = false
        set(NSAttributedString(
            string: text,
            attributes: [.font: NSFont.systemFont(ofSize: CGFloat(fontSize)),
                         .foregroundColor: panelPrimaryTextColor()]))
        panel?.orderFrontRegardless()
    }

    /// Set the words and resize the panel to fit them, up to the ceiling.
    private func set(_ attributed: NSAttributedString, preservingSelection: Bool = false) {
        guard let textView, let scroll, let panel else { return }
        let oldSelection = textView.selectedRange()
        changingProgrammatically = true
        if let storage = textView.textStorage {
            // Replacing the entire NSTextStorage every 450 ms made AppKit tear
            // down and rebuild its insertion point even when only the newest
            // grey words had changed. Preserve the unchanged prefix, replace
            // characters only from the first changed composed character, and
            // repaint attributes in place when grey merely settles to black.
            let prefix = commonComposedPrefixLength(storage.string, attributed.string)
            let oldLength = (storage.string as NSString).length
            let newLength = (attributed.string as NSString).length
            storage.beginEditing()
            if storage.string != attributed.string {
                storage.replaceCharacters(
                    in: NSRange(location: prefix, length: oldLength - prefix),
                    with: (attributed.string as NSString).substring(
                        from: min(prefix, newLength)))
            }
            if newLength > 0 {
                attributed.enumerateAttributes(
                    in: NSRange(location: 0, length: newLength), options: []) {
                        attributes, range, _ in
                    storage.setAttributes(attributes, range: range)
                }
            }
            storage.endEditing()
        }
        if interactive {
            textView.typingAttributes = [
                .font: NSFont.systemFont(ofSize: CGFloat(fontSize)),
                .foregroundColor: panelPrimaryTextColor(),
            ]
        }
        if preservingSelection {
            let length = (textView.string as NSString).length
            let location = min(oldSelection.location, length)
            let range = NSRange(location: location,
                                length: min(oldSelection.length, length - location))
            textView.setSelectedRange(range)
        }
        changingProgrammatically = false

        resizeForCurrentText()
        if preservingSelection, textView.selectedRange().length > 0 {
            textView.scrollRangeToVisible(textView.selectedRange())
        } else {
            textView.scrollToEndOfDocument(nil)
        }
        _ = scroll
        _ = panel
    }

    private func resizeForCurrentText() {
        guard let textView, let scroll, let panel else { return }

        let noteHeight: CGFloat = (noteView?.isHidden == false) ? 26 : 0
        let usableWidth = panel.frame.width - padding * 2
        textView.textContainer?.containerSize = NSSize(width: usableWidth,
                                                       height: .greatestFiniteMagnitude)
        // How tall the words actually are at this width.
        var textHeight = minHeight - padding * 2
        _ = usableWidth
        if let layout = textView.layoutManager, let container = textView.textContainer {
            layout.ensureLayout(for: container)
            textHeight = layout.usedRect(for: container).height
        }
        let measured = min(maxHeight, max(minHeight, textHeight + padding * 2 + noteHeight))
        sessionHeight = max(sessionHeight, measured)
        let wanted = sessionHeight
        // Ignore sub-pixel layout churn; resize only for a real new line.
        if wanted > panel.frame.height + 6 { place(height: wanted) }

        if let backdrop = panel.contentView {
            let h = backdrop.bounds.height
            let noteY = h - padding - 18
            statusDotView?.frame = NSRect(x: padding, y: noteY + 6.5,
                                          width: 7, height: 7)
            noteView?.frame = NSRect(x: padding + 14, y: noteY,
                                     width: max(10, usableWidth - 14 - (interactive ? 38 : 0)),
                                     height: 20)
            closeButton?.frame = NSRect(x: h > 0 ? backdrop.bounds.width - padding - 26 : 0,
                                        y: h - padding - 24, width: 28, height: 28)
            scroll.frame = NSRect(x: padding, y: padding, width: usableWidth,
                                  height: max(10, h - padding * 2 - noteHeight))
        }
    }

    @objc private func discardPressed() { onDiscard?() }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.insertNewline(_:)), interactive,
              !textView.hasMarkedText(),
              !(NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false) else { return false }
        guard !textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return true }
        onSubmit?(textView.string, textView.selectedRange())
        return true
    }

    func textDidChange(_ notification: Notification) {
        guard !changingProgrammatically, interactive, let textView else { return }
        setSpeaking(false)
        resizeForCurrentText()
        onTextChanged?(textView.string, textView.selectedRange())
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard !changingProgrammatically, interactive, let textView else { return }
        setSpeaking(false)
        if (textView as? ReviewTextView)?.keyboardSelectionOnly == true {
            return
        }
        let range = textView.selectedRange()
        onSelectionChanged?(textView.string, range)
    }

    func hide() {
        panel?.orderOut(nil)
        noteView?.isHidden = true
        statusDotView?.isHidden = true
        textView?.isEditable = false
        textView?.isSelectable = false
    }

    /// For the tests: how tall it is right now, and its ceiling.
    var currentHeight: CGFloat { panel?.frame.height ?? 0 }
    var ceiling: CGFloat { maxHeight }
    var editorHasFocusForTest: Bool { panel?.firstResponder === textView }
    var caretVisibleForTest: Bool { textView?.insertionPointColor != NSColor.clear }

    /// Drive the exact NSPanel key-equivalent path without synthetic global
    /// keystrokes. Used only by `review-shortcut-test`.
    func focusEditorForTest() -> Bool {
        build()
        guard let panel, let textView else { return false }
        panel.makeKeyAndOrderFront(nil)
        return panel.makeFirstResponder(textView)
    }

    func sendReturnForTest() {
        guard let panel, let textView, let event = NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: panel.windowNumber, context: nil, characters: "\r",
            charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36) else { return }
        textView.interpretKeyEvents([event])
    }

    func sendShortcutForTest(_ key: String,
                             modifiers: NSEvent.ModifierFlags = [.command]) -> Bool {
        guard let panel,
              let event = NSEvent.keyEvent(with: .keyDown, location: .zero,
                                           modifierFlags: modifiers,
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: panel.windowNumber,
                                           context: nil, characters: key,
                                           charactersIgnoringModifiers: key,
                                           isARepeat: false, keyCode: 0) else { return false }
        return panel.performKeyEquivalent(with: event)
    }
}

/// The integration test exercises the real general-pasteboard actions but
/// gives the founder's clipboard back byte-for-byte immediately afterward.
struct PasteboardSnapshot {
    let items: [[(NSPasteboard.PasteboardType, Data)]]

    init(_ pasteboard: NSPasteboard) {
        items = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            }
        }
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let restored: [NSPasteboardItem] = items.map { values in
            let item = NSPasteboardItem()
            for (type, data) in values { item.setData(data, forType: type) }
            return item
        }
        if !restored.isEmpty { pasteboard.writeObjects(restored) }
    }
}

// ---------------------------------------------------------------------------
// The button. One gesture: a press toggles. Releases are ignored entirely,
// so there is no hold, no tap, no double-tap, and nothing to get wrong.
// ---------------------------------------------------------------------------

// macOS turns a Bluetooth media button into HFP hang-up while its microphone is active.
// Observe only that system event; never open a second RFCOMM/SCO connection.
// Unified-log delivery is a compatibility bridge, not a guaranteed Bluetooth event API.
private final class BluetoothLogBuffer { var data = Data() }

final class BluetoothHangupBridge {
    private var process: Process?
    private var output: Pipe?
    private var token = UUID()
    private let queue = DispatchQueue(label: "myf5.bluetooth-hangup")

    static func address(from uid: String) -> String? {
        let pattern = "^(?:[0-9A-Fa-f]{2}[-:]){5}[0-9A-Fa-f]{2}(?=:input$)"
        guard let range = uid.range(of: pattern, options: .regularExpression) else { return nil }
        return String(uid[range]).replacingOccurrences(of: "-", with: ":").uppercased()
    }

    static func matches(message: String, address: String) -> Bool {
        let prefix = "Received call hangup event (AT+CHUP) from device "
        guard message.hasPrefix(prefix) else { return false }
        return String(message.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == address
    }

    func start(microphoneUID: String, onFinish: @escaping () -> Void) {
        stop()
        guard let address = Self.address(from: microphoneUID) else { return }
        let current = UUID(); token = current
        let child = Process(); let pipe = Pipe()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        child.arguments = ["stream", "--style", "ndjson", "--level", "info", "--predicate",
            "process == \"bluetoothd\" AND category == \"Server.Handsfree\" AND eventMessage CONTAINS \"Received call hangup event (AT+CHUP)\""]
        child.standardOutput = pipe; child.standardError = FileHandle.nullDevice
        let buffer = BluetoothLogBuffer()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { handle.readabilityHandler = nil; return }
            self?.queue.async { [weak self] in
                buffer.data.append(chunk)
                if buffer.data.count > 65536 { buffer.data.removeAll(); return }
                while let newline = buffer.data.firstIndex(of: 10) {
                    let line = buffer.data.prefix(upTo: newline); buffer.data.removeSubrange(...newline)
                    guard let event = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                          let message = event["eventMessage"] as? String,
                          Self.matches(message: message, address: address) else { continue }
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.token == current, self.process === child else { return }
                        self.stop(); onFinish()
                    }
                }
            }
        }
        child.terminationHandler = { [weak self] ended in
            DispatchQueue.main.async {
                guard let self, self.token == current, self.process === ended else { return }
                record(["kind": "bluetooth-finish-bridge-exited", "status": ended.terminationStatus])
                self.stop()
            }
        }
        do {
            process = child; output = pipe
            try child.run()
            record(["kind": "bluetooth-finish-bridge-started", "automatic_device": true])
        } catch {
            stop()
            record(["kind": "bluetooth-finish-bridge-unavailable", "error": error.localizedDescription])
        }
    }

    func stop() {
        token = UUID()
        output?.fileHandleForReading.readabilityHandler = nil
        if let process, process.isRunning { process.terminate() }
        process = nil; output = nil
    }
}

enum ButtonEvent: String {
    case play, pause, togglePlayPause, stop, next, previous, seek, other
}

final class Gesture {
    private(set) var open = false
    private var openedAt = Date()
    private var lastPlayAt = -Double.infinity

    var onOpen: (() -> Void)?
    var onClose: ((Double) -> Void)?

    func feed(_ event: ButtonEvent, at now: TimeInterval = Date.timeIntervalSinceReferenceDate) {
        switch event {
        case .play:
            lastPlayAt = now
            toggle()
        case .togglePlayPause: toggle()
        case .pause:
            // Some controls send a quick play/pause press-release pair.
            // Other Bluetooth devices send only pause because our media client
            // is playing. A standalone pause must toggle just like a click.
            guard now - lastPlayAt > 0.25 else {
                record(["kind": "ignored-release", "event": event.rawValue]); return
            }
            toggle()
        case .stop: if open { toggle() }
        case .next, .previous, .seek, .other:
            record(["kind": "ignored", "event": event.rawValue])
        }
    }

    private func toggle() {
        if open {
            let held = Date().timeIntervalSince(openedAt)
            open = false
            record(["kind": "click", "does": "close", "open_ms": Int(held * 1000)])
            onClose?(held)
        } else {
            open = true
            openedAt = Date()
            record(["kind": "click", "does": "open"])
            onOpen?()
        }
    }

    /// A capture left open by a forgotten click must not hold the microphone
    /// for ever.
    func closeIfStuck(maxSeconds: Int) {
        guard open, Date().timeIntervalSince(openedAt) > Double(maxSeconds) else { return }
        record(["kind": "force-close", "reason": "open longer than \(maxSeconds)s"])
        let held = Date().timeIntervalSince(openedAt)
        open = false
        onClose?(held)
    }

    func abandon() {
        guard open else { return }
        open = false
        record(["kind": "abandoned"])
    }
}

// ---------------------------------------------------------------------------
// The helper.
// ---------------------------------------------------------------------------

/// Intercept only the keyboard Play/Pause event, never ordinary typing.
final class KeyboardMediaGate {
    var enabled: () -> Bool = { false }
    var pressed: () -> Void = {}
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    var installed: Bool { tap != nil }

    static func playPauseState(subtype: Int16, data: Int) -> (down: Bool, repeated: Bool)? {
        guard subtype == 8, ((data >> 16) & 0xffff) == 16 else { return nil }
        let state = (data >> 8) & 0xff
        guard state == 0x0a || state == 0x0b else { return nil }
        return (state == 0x0a, (data & 1) != 0)
    }

    func start() {
        guard tap == nil else { return }
        let mask = CGEventMask(1) << 14 // NSEvent.systemDefined media key events
        let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let gate = Unmanaged<KeyboardMediaGate>.fromOpaque(context).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = gate.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                    return Unmanaged.passUnretained(event)
                }
                guard gate.enabled(), let key = NSEvent(cgEvent: event),
                      key.type == .systemDefined,
                      let state = KeyboardMediaGate.playPauseState(subtype: key.subtype.rawValue, data: key.data1) else {
                    return Unmanaged.passUnretained(event)
                }
                if state.down && !state.repeated { gate.pressed() }
                return nil // consume both down and up before browser handling
            }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let port else { return }
        tap = port
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes) }
        CGEvent.tapEnable(tap: port, enable: true)
    }
    deinit {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
    }
}

final class Helper {
    private let bluetoothHangupBridge = BluetoothHangupBridge()
    var config = Config.load()
    let k: KClient
    let recorder = Recorder()
    let silence = Silence()
    let gesture = Gesture()

    private var menuBar: MyF5Menu?
    private var setupActive = false
    private var enrolling = false
    private var enrollmentSaving = false
    private var enrollmentToken = 0
    private var voiceEnrolled = false
    private var roomServiceID = 0
    private var roomCalibrated = false
    private var calibratingRoom = false
    private var armed = false
    private var handlersInstalled = false
    private let keyboardMediaGate = KeyboardMediaGate()
    private var finishing = false
    private var lastButtonEvent = Date.distantPast
    private var lastHandlerRenewal = Date()
    private var renewAfterWake = false
    private var renewAfterAppSwitch = false
    private var activationObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private let work = DispatchQueue(label: "k.ptt.work")
    private let watch = DispatchQueue(label: "k.ptt.watch")

    private var journalForTurn = false
    private var journalEntryID = UUID()
    private var generation = 0
    private let preview = PreviewStrip()
    private let previewQueue = DispatchQueue(label: "k.ptt.preview")
    private var previewTimer: DispatchSourceTimer?
    private var previewInFlight = false
    private var previewText: PreviewText?
    private var editableDraft: EditableDraft?
    private var quietFor: Double = 0
    private var previewSawSpeech = false
    private var previewGreyShownForSegment = false
    /// Which app was in front when the capture opened, and the words waiting
    /// for a home if it is not in front any more.
    private var frontAtOpen: (pid: pid_t, name: String)?
    private var pendingText: String?

    private var signalSources: [DispatchSourceSignal] = []
    private var missedPolls = 0
    private var lastHeadsetSeen: Bool?
    private var standDownReason = "starting up"
    private var lastButtonClaimAt: Date?
    private var micAsked = false
    private var trustAsked = false
    /// A warning never fires twice running.
    private var lastWarning = ""

    init() {
        k = KClient(base: config.kBaseURL)
        config.save()
        Recorder.reopenSettleMs = config.reopenSettleMs
        keyboardMediaGate.enabled = { [weak self] in
            guard let self else { return false }
            return self.config.enabled && self.armed && !self.setupActive && !self.enrolling
        }
        keyboardMediaGate.pressed = { [weak self] in
            record(["kind": "keyboard-media-intercepted"])
            self?.saw(.togglePlayPause)
        }
        preview.onDiscard = { [weak self] in self?.discardCurrent() }
        preview.onSubmit = { [weak self] text, selection in
            guard let self, self.gesture.open, !self.finishing else { return }
            // Real edits are already tracked by onTextChanged. Enter alone
            // must retain final transcription of audio not yet in the preview.
            record(["kind": "review-enter-send", "characters": text.count])
            self.gesture.feed(.stop) // Same close/save/type path as the second button click.
            self.publishHealth()
        }
        preview.onTextChanged = { [weak self] text, selection in
            self?.reviewTextChanged(text, selection: selection)
        }
        preview.onSelectionChanged = { [weak self] text, selection in
            self?.reviewSelectionChanged(text, selection: selection)
        }
        preview.onKeyboardCommand = { [weak self] text, selection, shortcut in
            self?.reviewKeyboardCommand(text, selection: selection, shortcut: shortcut)
        }
    }

    // -- the entire vocabulary: two sounds ------------------------------------
    //
    //   tick   one, when the microphone is really hearing him
    //   thud   one, when an attempt is over with nothing to show
    //
    // Nothing else makes a sound. No sentences, no per-retry narration, no
    // announcement on connect or disconnect. V1 spoke, and a safety message
    // became a nag that talked over a turn that was working.

    private func tick() {
        guard config.feedbackSounds else { return }
        NSSound(named: "Tink")?.play()
    }

    private func thud(_ kind: String) {
        guard lastWarning != kind else {
            record(["kind": "warning-suppressed", "warning": kind])
            return
        }
        lastWarning = kind
        record(["kind": "warned", "warning": kind])
        guard config.feedbackSounds else { return }
        NSSound(named: "Basso")?.play()
    }

    private func clearWarnings() { lastWarning = "" }

    // -- Now Playing ----------------------------------------------------------

    private func installHandlers() {
        guard !handlersInstalled else { return }
        handlersInstalled = true
        let centre = MPRemoteCommandCenter.shared()
        func wire(_ command: MPRemoteCommand, _ event: ButtonEvent) {
            command.isEnabled = true
            command.addTarget { [weak self] _ in self?.saw(event); return .success }
        }
        wire(centre.playCommand, .play)
        wire(centre.pauseCommand, .pause)
        wire(centre.togglePlayPauseCommand, .togglePlayPause)
        wire(centre.stopCommand, .stop)
        wire(centre.nextTrackCommand, .next)
        wire(centre.previousTrackCommand, .previous)
        say("remote command handlers installed")
    }

    private func refreshButtonClaim() {
        if config.keepAliveSilence {
            let hadStream = silence.isRunning
            silence.ensure(preferredOutput: config.silenceOutputDevice)
            if !hadStream, silence.isRunning, lastButtonClaimAt != nil {
                record(["kind": "button-claim-stream-restored"])
            }
        } else if silence.isRunning {
            silence.stop()
        }
        let info = MPNowPlayingInfoCenter.default()
        info.nowPlayingInfo = [
            MPMediaItemPropertyTitle: "MyF5 — push to talk",
            MPMediaItemPropertyArtist: "MyF5",
            MPNowPlayingInfoPropertyPlaybackRate: 1.0,
        ]
        info.playbackState = .playing
        lastButtonClaimAt = Date()
    }

    private func arm(_ reason: String) {
        let newlyArmed = !armed
        armed = true
        standDownReason = ""
        installHandlers()
        keyboardMediaGate.start()
        // This runs on every healthy supervisor pass, not only startup. A
        // browser or media app can steal Now Playing later; refreshing the
        // claim prevents a stale “armed” health report while the button is
        // actually playing/pausing something else.
        refreshButtonClaim()
        guard newlyArmed else { return }
        say("ARMED — the button types what you say (\(reason))")
        record(["kind": "armed", "reason": reason])
    }

    private func disarm(_ reason: String) {
        bluetoothHangupBridge.stop()
        guard armed else { standDownReason = reason; return }
        armed = false
        standDownReason = reason
        if gesture.open { gesture.abandon() }
        stopPreview()
        releaseCapture("stood down")
        let info = MPNowPlayingInfoCenter.default()
        info.playbackState = .stopped
        info.nowPlayingInfo = nil
        silence.stop()
        let centre = MPRemoteCommandCenter.shared()
        for command in [centre.playCommand, centre.pauseCommand,
                        centre.togglePlayPauseCommand, centre.stopCommand,
                        centre.nextTrackCommand, centre.previousTrackCommand] {
            command.isEnabled = false
            command.removeTarget(nil)
        }
        handlersInstalled = false
        preview.hide()
        say("stood down — the button goes back to Music (\(reason))")
        record(["kind": "disarmed", "reason": reason])
    }

    private func saw(_ event: ButtonEvent) {
        DispatchQueue.main.async {
            guard self.config.enabled, !self.setupActive, self.armed else { return }
            self.lastButtonEvent = Date()
            record(["kind": "button-received", "event": event.rawValue])
            self.gesture.feed(event)
            self.publishHealth()
        }
    }

    private var safeToRenew: Bool {
        !gesture.open && !recorder.isRunning && !calibratingRoom && !finishing && pendingText == nil

    }

    private func renewButtonHandlersIfNeeded() {
        guard config.enabled, armed, !setupActive, !enrolling, !enrollmentSaving, safeToRenew else { return }
        let appSwitch = renewAfterAppSwitch
        let maintenance = Date().timeIntervalSince(lastHandlerRenewal) >= 15
            && Date().timeIntervalSince(lastButtonEvent) > 10
        guard renewAfterWake || appSwitch || maintenance else { return }
        let centre = MPRemoteCommandCenter.shared()
        for command in [centre.playCommand, centre.pauseCommand, centre.togglePlayPauseCommand,
                        centre.stopCommand, centre.nextTrackCommand, centre.previousTrackCommand] {
            command.removeTarget(nil)
        }
        handlersInstalled = false
        silence.stop()
        installHandlers()
        refreshButtonClaim()
        lastHandlerRenewal = Date()
        record(["kind": "button-handlers-renewed", "reason": renewAfterWake ? "wake" : (appSwitch ? "application switch" : "idle maintenance")])
        renewAfterWake = false
        renewAfterAppSwitch = false
    }

    private func releaseCapture(_ reason: String) {
        guard recorder.isRunning else { return }
        _ = recorder.stop()
        record(["kind": "capture-released", "reason": reason])
    }

    private func reviewTextChanged(_ text: String, selection: NSRange) {
        guard config.interactiveReview, recorder.isRunning else { return }
        let draft = editableDraft ?? EditableDraft()
        editableDraft = draft
        draft.userChanged(text: text, at: recorder.capturedSeconds)
        quietFor = 0
        previewSawSpeech = false
        previewGreyShownForSegment = false
        preview.setStatus("Editing")
        record(["kind": "review-edited", "characters": text.count,
                "caret": selection.location])
    }

    /// Clipboard/select-all commands mean ordinary keyboard editing. They
    /// deliberately clear any mouse-armed voice replacement before the
    /// command runs, so Command-A → Command-C → more speech appends safely
    /// instead of replacing the whole dictation.
    private func reviewKeyboardCommand(_ text: String, selection: NSRange,
                                       shortcut: ReviewShortcut) {
        guard config.interactiveReview, recorder.isRunning else { return }
        let draft = editableDraft ?? EditableDraft()
        editableDraft = draft
        draft.userChanged(text: text, at: recorder.capturedSeconds)
        quietFor = 0
        previewSawSpeech = false
        previewGreyShownForSegment = false
        preview.setStatus("Editing")
        record(["kind": "review-keyboard-command",
                "command": String(describing: shortcut),
                "selection_characters": selection.length])
    }

    private func reviewSelectionChanged(_ text: String, selection: NSRange) {
        guard config.interactiveReview, recorder.isRunning else { return }
        let draft = editableDraft ?? EditableDraft()
        editableDraft = draft
        if selection.length > 0 {
            draft.selected(text: text, range: selection, at: recorder.capturedSeconds)
            preview.setStatus("Ready for correction")
            record(["kind": "review-selected", "characters": selection.length])
        } else {
            // A plain click is an edit boundary too. Previously only a non-empty
            // selection counted, so later grey revisions could move text under
            // a blue caret and leave the caret pointing at the wrong word.
            let before = draft.snapshot()
            if !before.touched || !before.live.isEmpty || before.voiceSelection != nil {
                draft.userChanged(text: text, at: recorder.capturedSeconds)
                record(["kind": "review-caret-placed", "caret": selection.location])
            }
            preview.setStatus("Editing")
        }
        quietFor = 0
        previewSawSpeech = false
        previewGreyShownForSegment = false
    }

    private func discardCurrent() {
        guard gesture.open || recorder.isRunning else { preview.hide(); return }
        generation += 1
        gesture.abandon()
        stopPreview()
        releaseCapture("discarded with ×")
        editableDraft = nil
        pendingText = nil
        record(["kind": "discarded", "does": "send nothing"])
        clearWarnings()
    }

    // -- click: open ----------------------------------------------------------

    private func beginTyping() {
        let requestedAt = Date()
        journalForTurn = config.journalMode
        journalEntryID = UUID()
        guard config.enabled, !setupActive, !calibratingRoom else { gesture.abandon(); return }
        if let voice = k.state()?["voice"] as? [String: Any],
           voice["enrollment_required"] as? Bool == true {
            gesture.abandon()
            preview.note("Voice enrollment needed — follow the enrollment walkthrough", text: "")
            let noticeGeneration = generation
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, self.generation == noticeGeneration, !self.gesture.open else { return }
                self.preview.hide()
            }
            thud("voice-enrollment-required")
            return
        }
        // A dictation is waiting because focus had moved. This click puts it
        // where he is now, and does not start a new recording.
        if let waiting = pendingText {
            pendingText = nil
            gesture.abandon()
            preview.hide()
            Keys.type(waiting)
            if config.pressReturnAfterTyping { Keys.tapReturn() }
            record(["kind": "typed-after-focus-returned",
                    "characters": waiting.count])
            return
        }
        generation += 1
        let mine = generation
        frontAtOpen = NSWorkspace.shared.frontmostApplication.map {
            ($0.processIdentifier, $0.localizedName ?? "?")
        }
        guard Keys.trusted else {
            thud("no-typing-permission")
            askForTrustIfNeeded()
            gesture.abandon()
            return
        }
        guard Mic.granted else {
            thud("no-microphone-permission")
            askForMicIfNeeded()
            gesture.abandon()
            return
        }
        if config.livePreview {
            startPreview(generation: mine)
            preview.setStatus("Connecting microphone…")
        }
        work.async {
            guard self.gesture.open else {
                record(["kind": "click-gone-before-mic-opened"]); return
            }
            self.recorder.onFirstAudio = { [weak self] in
                record(["kind": "capture-ready", "button_to_audio_ms": Int(Date().timeIntervalSince(requestedAt)*1000)])
                self?.tick()
                DispatchQueue.main.async { self?.clearWarnings(); self?.preview.setStatus("Listening") }
            }
            self.recorder.onDeaf = { [weak self] in
                guard let self else { return }
                DispatchQueue.main.async {
                    self.stopPreview()
                    self.gesture.abandon()
                    self.releaseCapture("microphone stayed deaf")
                    self.thud("microphone-deaf")
                }
            }
            // Reset only a stored mute using the already installed handler.
            // Registering again without input I/O can stall the system listener.
            let micStartAt = Date()
            if let error = self.recorder.start(deviceName: self.config.micDeviceName) {
                record(["kind": "mic-failed", "error": error])
                self.releaseCapture("the microphone would not open")
                DispatchQueue.main.async {
                    self.stopPreview(); self.gesture.abandon(); self.thud("mic-failed") }
                return
            }
            record(["kind": "microphone-open-timing", "elapsed_ms": Int(Date().timeIntervalSince(micStartAt)*1000)])
            let microphoneUID = self.recorder.deviceUID
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == mine, self.gesture.open,
                      self.config.enabled, self.recorder.isRunning else { return }
                self.bluetoothHangupBridge.start(microphoneUID: microphoneUID) { [weak self] in
                    guard let self, self.generation == mine, self.gesture.open,
                          self.config.enabled, self.armed, !self.finishing,
                          !self.setupActive, !self.enrolling else { return }
                    record(["kind": "bluetooth-headset-finish", "device": self.recorder.deviceUsed])
                    self.gesture.feed(.stop)
                }
            }
            record(["kind": "listening", "device": self.recorder.deviceUsed])

        }
    }

    // -- the preview strip: what the ears have so far, shown, never typed -----
    //
    // Every line below is display. It reads a copy of the audio and writes to a
    // panel of ours. It cannot reach his document: nothing here calls Keys, and
    // the typing path does not read anything it produces. If all of it failed,
    // dictation would be exactly what he okayed.

    private func startPreview(generation mine: Int) {
        stopPreview()
        previewText = PreviewText()
        editableDraft = EditableDraft()
        quietFor = 0
        previewSawSpeech = false
        preview.fontSize = config.fontSize
        preview.lineSpacing = config.lineSpacing
        preview.show(interactive: config.interactiveReview)
        let intervalMs = config.interactiveReview
            ? max(250, config.livePreviewIntervalMs) : 800
        let intervalSeconds = Double(intervalMs) / 1000.0
        let timer = DispatchSource.makeTimerSource(queue: previewQueue)
        timer.schedule(deadline: .now() + .milliseconds(intervalMs),
                       repeating: .milliseconds(intervalMs))
        timer.setEventHandler { [weak self] in
            guard let self, !self.previewInFlight else { return }
            guard DispatchQueue.main.sync(execute: {
                self.generation == mine && self.recorder.isRunning && self.gesture.open
            }) else { return }
            let draftBefore = DispatchQueue.main.sync { self.editableDraft?.snapshot() }
            guard let words = DispatchQueue.main.sync(execute: { self.previewText }),
                  let draftBefore else { return }
            let editing = draftBefore.touched
            let from = editing ? draftBefore.audioFrom : words.frozenUntil

            // Is he actually talking? The new path remembers that speech was
            // heard even when the first check after it lands in silence. That
            // is the exact short-word bug: previously, quiet + no grey words
            // returned forever and the word appeared only after he spoke again.
            let recent = self.recorder.level(lastSeconds: 0.6)
            let quiet = recent < Double(self.config.speechFloorDb)
            let state = DispatchQueue.main.sync { () -> (quiet: Double, saw: Bool, voice: Bool) in
                self.preview.setSpeaking(!quiet)
                if quiet {
                    self.quietFor += intervalSeconds
                } else {
                    self.quietFor = 0
                    self.previewSawSpeech = true
                    if draftBefore.voiceSelection != nil {
                        self.editableDraft?.noteVoiceSpeech()
                        self.preview.setStatus("Hearing correction")
                    } else if draftBefore.touched {
                        self.preview.setStatus("Listening")
                    }
                }
                return (self.quietFor, self.previewSawSpeech,
                        self.editableDraft?.snapshot().voiceSawSpeech ?? false)
            }

            let now = self.recorder.capturedSeconds
            let modern = self.config.interactiveReview

            // After a phrase has settled, do not leave the whole remaining
            // pause at the front of the next request. Doing so made resumed
            // speech arrive as "twenty seconds of silence plus one new word",
            // which is why grey appeared to stop after a long pause. Advance
            // only while the meter has seen no speech and there is no live
            // text; the last timer tick still leaves enough run-up to retain
            // the beginning of the next word.
            if modern && quiet && !state.saw {
                // Keep a longer onset buffer: soft starts must survive the
                // UI meter while the speech/identity models gather context.
                let idleBoundary = max(from, now - 1.5)
                DispatchQueue.main.sync {
                    guard self.generation == mine, self.recorder.isRunning else { return }
                    if editing {
                        guard let current = self.editableDraft,
                              current.snapshot().touched == editing,
                              abs(current.snapshot().audioFrom - from) < 0.05 else { return }
                        current.skipIdleSilence(to: idleBoundary)
                    } else {
                        guard abs(words.frozenUntil - from) < 0.05 else { return }
                        words.skipIdleSilence(to: idleBoundary)
                    }
                }
                return
            }

            // A selection changes the meaning of the next speech: it replaces
            // that range and is never also appended at the end.
            if let selected = draftBefore.voiceSelection {
                guard state.voice, quiet, state.quiet >= 0.7, now - from >= 0.45 else { return }
                guard let wav = self.recorder.segment(fromSeconds: from) else { return }
                self.previewInFlight = true
                defer { self.previewInFlight = false }
                let (code, json, _) = self.k.draft(wav, timeout: 20)
                guard code == 200,
                      let heard = json?["heard"] as? String else { return }
                let text = Text.clean(heard)
                // This request is made only after the meter proved he spoke,
                // so "yes", "yeah", or "okay" can be a legitimate one-word
                // correction and must not be thrown away.
                guard !text.isEmpty else { return }
                DispatchQueue.main.async {
                    guard self.generation == mine, self.recorder.isRunning,
                          let current = self.editableDraft,
                          let range = current.snapshot().voiceSelection,
                          NSEqualRanges(range, selected),
                          abs(current.snapshot().audioFrom - from) < 0.05 else { return }
                    current.replaceSelection(with: text, at: now)
                    self.previewSawSpeech = false
                    self.quietFor = 0
                    self.preview.update(black: current.snapshot().base, grey: "")
                    let caret = min(selected.location + (text as NSString).length,
                                    (current.displayed as NSString).length)
                    self.preview.select(NSRange(location: caret, length: 0))
                    self.preview.setStatus("Listening")
                    record(["kind": "voice-replaced", "characters": selected.length,
                            "with_words": text.split(separator: " ").count])
                    self.previewGreyShownForSegment = false
                }
                return
            }

            let settleNow = shouldSettlePreview(modern: modern, quiet: quiet,
                                                quietFor: state.quiet,
                                                sawSpeech: state.saw,
                                                hasLiveWords: !words.live.isEmpty)
            if quiet && !settleNow { return }
            if modern && !state.saw { return }
            // The modern path asks after 0.55 s because actual speech was
            // measured above the gate. The old display-only path retains its
            // original 1.2 s anti-phantom rule byte for byte.
            guard now - from >= (modern ? 0.55 : 1.2) else { return }
            guard let wav = self.recorder.segment(fromSeconds: from) else { return }
            self.previewInFlight = true
            defer { self.previewInFlight = false }
            let (code, json, _) = self.k.draft(wav, timeout: 20)
            guard code == 200, let heard = json?["heard"] as? String else { return }
            let text = Text.clean(heard)
            if text.isEmpty {
                let voice = json?["voice"] as? [String: Any]
                let status = voice?["accepted"] as? Bool == false
                    ? "Listening — gathering speech and voice context"
                    : "Listening — preparing your words"
                DispatchQueue.main.async {
                    guard self.generation == mine, self.recorder.isRunning, !editing else { return }
                    self.preview.setStatus(status)
                }
                return
            }
            // A whole stretch that came back as nothing but "yeah" or "okay" is
            // the ears filling a gap, not him talking. Never shown in grey.
            if !modern, Text.isJustBackchannel(text), now - from < 3.0 {
                record(["kind": "gap-filler-ignored", "heard": text,
                        "stretch_s": round((now - from) * 10) / 10])
                return
            }
            DispatchQueue.main.async {
                guard self.generation == mine, self.recorder.isRunning else { return }
                guard let currentDraft = self.editableDraft else { return }
                // Ignore a result that began before a mouse/keyboard edit.
                let current = currentDraft.snapshot()
                guard current.touched == editing,
                      abs((editing ? current.audioFrom : words.frozenUntil) - from) < 0.05 else {
                    return
                }
                self.preview.setStatus("Listening")
                var froze = false
                if editing {
                    if settleNow || now - from >= 14 {
                        currentDraft.settleLive(text, at: now)
                        froze = true
                    } else {
                        currentDraft.updateLive(text)
                    }
                    let changed = currentDraft.snapshot()
                    self.preview.update(black: changed.base, grey: changed.live)
                    if !changed.live.isEmpty, !self.previewGreyShownForSegment {
                        self.previewGreyShownForSegment = true
                        record(["kind": "preview-grey-visible",
                                "at_s": round(now * 10) / 10,
                                "words": changed.live.split(separator: " ").count])
                    }
                } else {
                    froze = words.advance(transcript: text, upTo: now, force: settleNow)
                    self.preview.update(black: words.frozen, grey: words.live)
                    if !words.live.isEmpty, !self.previewGreyShownForSegment {
                        self.previewGreyShownForSegment = true
                        record(["kind": "preview-grey-visible",
                                "at_s": round(now * 10) / 10,
                                "words": words.live.split(separator: " ").count])
                    }
                }
                if froze {
                    self.previewSawSpeech = false
                    self.quietFor = 0
                    self.previewGreyShownForSegment = false
                    record(["kind": "preview-settled",
                            "at_s": round(now * 10) / 10,
                            "because": settleNow ? "he stopped talking" : "the stretch filled up",
                            "words_settled": editing
                                ? currentDraft.snapshot().base.split(separator: " ").count
                                : words.frozen.split(separator: " ").count])
                }
            }
        }
        timer.resume()
        previewTimer = timer
    }

    private func stopPreview() {
        bluetoothHangupBridge.stop()
        previewTimer?.cancel()
        previewTimer = nil
        previewText = nil
        editableDraft = nil
        previewSawSpeech = false
        previewGreyShownForSegment = false
        quietFor = 0
        // A dictation waiting for a home keeps its panel up: that panel is the
        // only thing telling him his words are safe and one click away.
        if pendingText == nil { preview.hide() }
    }

    // -- click again: finalize the reviewed text, then type it once ------------
    //
    // Nothing appears while he speaks. That is the design, not a limitation.
    //
    // Typing as he spoke needed passes during speech, and those passes had to
    // be reconciled with what was already on the page. Every failure of
    // 2026-08-20 came out of that reconciliation: a phantom word heard from
    // 0.8 s of near-silence, phrases typed twice, a 33-second message reduced
    // to six words, and finally his whole message typed six times over.
    //
    // With ONE transcription and ONE typing event there is nothing to
    // reconcile, so that entire class of failure cannot occur. He hears the
    // tick, he speaks, he clicks, his words appear once.

    private func endTyping(open: Double) {
        finishing = true
        publishHealth()
        let mine = generation
        let journal = journalForTurn
        let journalID = journalEntryID
        let draftAtClose = preview.text
        var review = config.interactiveReview ? editableDraft?.snapshot() : nil
        // A fast closing click may arrive between the spoken correction and
        // the next 450 ms meter check. The audio level is still proof that the
        // selected text received speech, so do not silently ignore it.
        if let r = review, r.voiceSelection != nil, !r.voiceSawSpeech,
           recorder.level(lastSeconds: 0.6) >= Double(config.speechFloorDb) {
            review = EditableDraftSnapshot(base: r.base, live: r.live,
                                           audioFrom: r.audioFrom,
                                           voiceSelection: r.voiceSelection,
                                           voiceSawSpeech: true, touched: r.touched)
        }
        stopPreview()
        work.async {
            defer { DispatchQueue.main.async { self.finishing = false; self.publishHealth() } }
            let firstAudio = self.recorder.firstAudioMs
            let openFor = self.recorder.openSeconds
            guard let (wav, seconds) = self.recorder.stop() else { return }
            // Capture is closed before unmuting: this cannot resume listening.



            if seconds < 0.30 {
                let missing = openFor > 1.0 && seconds < openFor * 0.5
                record(["kind": "nothing-captured",
                        "seconds": round(seconds * 100) / 100,
                        "mic_open_s": round(openFor * 100) / 100,
                        "first_audio_ms": firstAudio ?? -1,
                        "cause": missing ? "the microphone delivered almost nothing"
                                         : "too short to be speech"])
                if missing { DispatchQueue.main.async { self.thud("capture-empty") } }
                return
            }

            let diagnosticFlag = STATE.appendingPathComponent("diagnose-next")
            if FileManager.default.fileExists(atPath: diagnosticFlag.path) {
                try? FileManager.default.removeItem(at: diagnosticFlag)
                let answer = self.k.diagnose(wav)
                var report = answer.json ?? ["error": "Diagnostic request failed", "http": answer.code]
                report["first_audio_ms"] = firstAudio ?? -1
                report["draft_at_close"] = draftAtClose
                report["draft_was_edited"] = review?.touched ?? false
                if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                    let path = STATE.appendingPathComponent("last-audio-diagnostic.json")
                    try? data.write(to: path, options: .atomic)
                    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
                }
                record(["kind": "audio-diagnostic", "http": answer.code])
            }

            func withoutLongPauses(_ audio: Data) -> (Data, Int) {
                let body = audio.count > 44 ? Data(audio.dropFirst(44)) : Data()
                let cut = Recorder.trimPauses(body,
                                              floorDb: Double(self.config.speechFloorDb))
                return (cut.removedMs > 0 ? Recorder.wav(cut.audio, rate: 16000) : audio,
                        cut.removedMs)
            }

            var code = 200
            var quiet = true
            var heardMs = 0
            var voiceDecision: [String: Any]?
            var text = ""

            if let review, review.touched {
                // The visible edited text is the master. Hear only the tail
                // recorded since the last edit/selection, then append it or use
                // it as the selected range's spoken replacement.
                var tail: String?
                if let segment = Recorder.segment(wav, fromSeconds: review.audioFrom) {
                    let (toHear, removedMs) = withoutLongPauses(segment)
                    let askedAt = Date()
                    let answer = self.k.draft(toHear)
                    heardMs = Int(Date().timeIntervalSince(askedAt) * 1000)
                    code = answer.code
                    quiet = answer.quiet
                    if code == 200 {
                        tail = Text.clean((answer.json?["heard"] as? String) ?? "")
                    } else {
                        self.k.forgetCapabilities()
                        record(["kind": "review-tail-unheard", "http": code,
                                "kept": "visible edited text"])
                    }
                    if removedMs > 0 {
                        record(["kind": "pauses-trimmed",
                                "removed_s": round(Double(removedMs) / 100) / 10,
                                "scope": "after last edit"])
                    }
                }
                text = review.finalText(tail: tail)
                record(["kind": "review-committed",
                        "voice_replacement": review.voiceSelection != nil
                            && review.voiceSawSpeech,
                        "characters": text.count])
            } else {
                // Untouched dictation keeps the proven path: one final hearing
                // of the whole recording and one typing event.
                let (toHear, removedMs) = withoutLongPauses(wav)
                if removedMs > 0 {
                    record(["kind": "pauses-trimmed",
                            "removed_s": round(Double(removedMs) / 100) / 10,
                            "of_s": round(seconds * 10) / 10])
                }
                let askedAt = Date()
                let answer = self.k.draft(toHear)
                heardMs = Int(Date().timeIntervalSince(askedAt) * 1000)
                code = answer.code
                quiet = answer.quiet
                voiceDecision = answer.json?["voice"] as? [String: Any]
                text = Text.clean((answer.json?["heard"] as? String) ?? "")
            }

            guard DispatchQueue.main.sync(execute: { self.generation == mine }) else {
                record(["kind": "abandoned", "reason": "a newer click replaced it"])
                return
            }
            guard code == 200 || (review?.touched == true && !text.isEmpty) else {
                self.k.forgetCapabilities()
                record(["kind": "nothing-heard", "http": code, "quiet": quiet,
                        "error": "nothing came back",
                        "seconds": round(seconds * 100) / 100])
                DispatchQueue.main.async { self.thud("nothing-heard") }
                return
            }

            guard !text.isEmpty else {
                if let voice = voiceDecision, voice["accepted"] as? Bool == false,
                   voice["mode"] as? String == "enrolled-speaker" {
                    record(["kind": "voice-rejected", "decision": voice, "device": self.recorder.deviceUsed])
                    DispatchQueue.main.async {
                        self.preview.note("Voice not matched — use Welcome & Voice Setup to enroll with this microphone in a quiet room", text: "")
                        self.thud("voice-not-matched")
                    }
                    return
                }
                record(["kind": "nothing-heard", "http": code, "quiet": quiet,
                        "error": "the recording held no words",
                        "seconds": round(seconds * 100) / 100])
                DispatchQueue.main.async { self.thud("nothing-heard") }
                return
            }

            // Saved BEFORE anything is typed, always, so a dictation can never
            // be lost again — whatever happens next.
            try? text.write(to: LAST_DICTATION, atomically: true, encoding: .utf8)

            // The ramble pass — only after the raw words are safe on disk,
            // only if he switched it on, and only on a LONG dictation: a
            // short direct sentence is typed untouched with zero added
            // milliseconds (no model call happens at all). On any doubt the
            // pass hands back his raw words and says why.
            var toType = text
            if self.config.cleanRambles,
               text.split(separator: " ").count >= self.config.rambleMinWords {
                let outcome = Rambler.clean(text,
                                            timeoutMs: self.config.rambleTimeoutMs)
                record(["kind": "ramble-pass",
                        "applied": outcome.applied,
                        "why": outcome.why,
                        "model": outcome.model,
                        "ms": outcome.ms,
                        "words_raw": Rambler.tokens(text).count,
                        "words_kept": Rambler.tokens(outcome.text).count])
                if outcome.applied {
                    toType = outcome.text
                    try? outcome.text.write(to: Rambler.LAST_CLEAN,
                                            atomically: true, encoding: .utf8)
                }
            }

            if journal {
                do {
                    let file = try JournalStore.save(toType, root: ROOT, id: journalID, audio: wav)
                    record(["kind": "journal-saved", "words": toType.split(separator: " ").count,
                            "file": file.lastPathComponent])
                    DispatchQueue.main.async {
                        self.clearWarnings()
                        self.preview.note("Saved to your journal · " + file.lastPathComponent, text: toType)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                            guard self.generation == mine, !self.gesture.open else { return }
                            self.preview.hide()
                        }
                    }
                } catch {
                    DispatchQueue.main.async {
                        self.preview.note("Journal save failed — copy these words to keep them", text: toType)
                        self.thud("journal-save-failed")
                    }
                }
                return // Journal entries never send keyboard events or depend on cursor focus.
            }

            // Where is his cursor now? If the window that was in front when he
            // started is not in front any more, something else has taken it —
            // a crash dialog, a notification, another app. Typing blind is how
            // 48 seconds of his speech went into a dialog and vanished.
            let opened = DispatchQueue.main.sync { self.frontAtOpen }
            var front = NSWorkspace.shared.frontmostApplication
            let ourPid = ProcessInfo.processInfo.processIdentifier
            if review?.touched == true, front?.processIdentifier == ourPid,
               let opened, opened.pid != ourPid {
                _ = DispatchQueue.main.sync {
                    NSRunningApplication(processIdentifier: opened.pid)?
                        .activate(options: [])
                }
                usleep(150_000)
                front = NSWorkspace.shared.frontmostApplication
                record(["kind": "review-focus-restored",
                        "to": opened.name, "pid": opened.pid])
            }
            let moved = Focus.moved(openedPid: opened?.pid,
                                    nowPid: front?.processIdentifier)
            if moved {
                record(["kind": "focus-moved",
                        "from": opened?.name ?? "?",
                        "to": front?.localizedName ?? "?",
                        "characters": toType.count,
                        "saved_to": LAST_DICTATION.path])
                DispatchQueue.main.async {
                    self.pendingText = toType
                    self.preview.note("focus moved — click to type here, "
                                      + "or your text is saved", text: toType)
                    self.thud("focus-moved")
                }
                return
            }

            // One typing event.
            let typedAt = Date()
            Keys.type(toType)
            if self.config.pressReturnAfterTyping { Keys.tapReturn() }
            record(["kind": "typed",
                    "spoke_s": round(seconds * 100) / 100,
                    "open_s": round(open * 100) / 100,
                    "heard_ms": heardMs,
                    "typed_ms": Int(Date().timeIntervalSince(typedAt) * 1000),
                    "words": toType.split(separator: " ").count,
                    "characters": toType.count,
                    "first_audio_ms": firstAudio ?? -1,
                    "quiet": quiet,
                    "returned": self.config.pressReturnAfterTyping])
            DispatchQueue.main.async { self.clearWarnings() }
        }
    }

    // -- permissions, asked from THIS process so they attach to it -------------

    private func askForTrustIfNeeded() {
        guard !Keys.trusted, !trustAsked else { return }
        trustAsked = true
        record(["kind": "accessibility-prompt",
                "pid": ProcessInfo.processInfo.processIdentifier])
        say("asking macOS for Accessibility permission")
        Keys.requestTrust()
    }

    private func askForMicIfNeeded() {
        guard !Mic.granted, !micAsked else { return }
        micAsked = true
        record(["kind": "microphone-prompt", "status": Mic.statusName])
        say("asking macOS for microphone permission")
        Mic.request { ok in record(["kind": "microphone-answer", "granted": ok]) }
    }

    // -- the supervisor --------------------------------------------------------

    private func installSignalHandlers() {
        for number in [SIGTERM, SIGINT, SIGHUP] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in
                say("shutting down on signal \(number)")
                self?.shutdown("signal \(number)")
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    func shutdown(_ reason: String) {
        stopPreview()
        releaseCapture("shutdown")
        disarm("shutting down")
        record(["kind": "shutdown", "reason": reason])
    }

    private func installMenu() {
        voiceEnrolled = (k.state(timeout: 2)?["voice"] as? [String: Any])?["enrolled"] as? Bool == true
        menuBar = MyF5Menu(status: { [unowned self] in
            (self.config.enabled, self.setupActive || self.finishing || self.gesture.open || self.pendingText != nil,
             self.voiceEnrolled, self.setupActive ? "voice setup" : (!self.config.enabled ? "Music controls" : (self.armed ? (self.config.journalMode ? "Journal · Ready" : "Dictation · Ready") : self.standDownReason)))
        }, toggle: { [unowned self] in
            self.menuBar?.dismissWelcome()
            self.config.enabled.toggle(); self.config.save()
            self.generation += 1; self.pendingText = nil
            self.preview.hide()
            if !self.config.enabled { self.disarm("Music controls selected") }
            self.supervise()
        }, beginSetup: { [unowned self] in
            guard !self.gesture.open, !self.finishing, !self.calibratingRoom, self.pendingText == nil else { return false }
            self.voiceEnrolled = (self.k.state(timeout: 2)?["voice"] as? [String: Any])?["enrolled"] as? Bool == true
            self.setupActive = true; self.disarm("voice setup"); self.publishHealth(); return true
        }, endSetup: { [unowned self] completed in
            self.enrollmentToken += 1; self.setupActive = false
            if completed { self.config.enabled = true }
            self.config.welcomeShown = true; self.config.save(); self.supervise()
        }, enroll: { [unowned self] progress, done in
            self.enrollmentToken += 1
            let token = self.enrollmentToken
            let profileURL = STATE.appendingPathComponent("voice-profile.json")
            let previousProfile = try? Data(contentsOf: profileURL)
            self.enrolling = true; self.publishHealth()
            self.work.async {
                let recorder = Recorder()
                var error = recorder.start(deviceName: "")
                let deadline = Date().addingTimeInterval(65)
                let previewGate = DispatchSemaphore(value: 1)
                var lastPreview = 0.0
                while error == nil && recorder.capturedSeconds < 60 && Date() < deadline {
                    let current = DispatchQueue.main.sync { self.enrollmentToken == token }
                    if !current { _ = recorder.stop(); DispatchQueue.main.async { self.enrolling = false; self.publishHealth() }; return }
                    let seconds = recorder.capturedSeconds
                    let level = recorder.level(lastSeconds: 0.5)
                    DispatchQueue.main.async { progress(seconds, level, nil) }
                    if seconds >= 1.5, seconds-lastPreview >= 1.5,
                       previewGate.wait(timeout: .now()) == .success {
                        lastPreview = seconds
                        if let wav = recorder.snapshot() {
                            DispatchQueue.global(qos: .userInitiated).async {
                                defer { previewGate.signal() }
                                let reply = self.k.enrollmentPreview(wav)
                                let words = reply.json?["heard"] as? String
                                DispatchQueue.main.async {
                                    guard self.enrollmentToken == token, self.enrolling else { return }
                                    progress(seconds, level, words)
                                }
                            }
                        } else { previewGate.signal() }
                    }
                    usleep(100_000)
                }
                let recorded = recorder.stop()
                // Drain the single preview request before profile enrollment.
                // The audio is already closed, and the main UI remains responsive.
                DispatchQueue.main.async { progress(61, -160, nil) }
                previewGate.wait()
                previewGate.signal()
                let current = DispatchQueue.main.sync { () -> Bool in self.enrolling = false; self.enrollmentSaving = self.enrollmentToken == token; self.publishHealth(); return self.enrollmentToken == token }
                guard current else { return }
                if error == nil, let recorded, recorded.seconds >= 15 {
                    let capped = Recorder.wav(Data(recorded.wav.dropFirst(44).prefix(60 * 16000 * 2)), rate: 16000)
                    let answer = self.k.voiceSetup("enroll", wav: capped)
                    if answer.code != 200 { error = answer.json?["error"] as? String ?? "Voice service unavailable" }
                } else if error == nil { error = "Not enough microphone audio. Please try again." }
                DispatchQueue.main.async {
                    self.enrollmentSaving = false
                    guard self.enrollmentToken == token else {
                        if let previousProfile {
                            try? previousProfile.write(to: profileURL, options: .atomic)
                            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: profileURL.path)
                        } else { try? FileManager.default.removeItem(at: profileURL) }
                        self.supervise()
                        return
                    }
                    self.voiceEnrolled = error == nil || self.voiceEnrolled
                    done(error); self.publishHealth()
                }
            }
        }, cancelEnrollment: { [unowned self] in self.enrollmentToken += 1 },
        recalibrate: { [unowned self] in
            guard !self.setupActive, !self.gesture.open, !self.finishing else { return }
            self.roomCalibrated = false; self.supervise()
        }, permissions: { (Mic.granted, Keys.trusted) }, requestMic: {
            if Mic.statusName == "not yet asked" { Mic.request { _ in } }
            else { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!) }
        }, requestTyping: { _ = Keys.requestTrust(); NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!) },
        saveSettings: { [unowned self] values in
            if let v = values["journalMode"] as? Bool { self.config.journalMode = v }
            if let v = values["fontSize"] as? Int { self.config.fontSize = v }
            if let v = values["lineSpacing"] as? Int { self.config.lineSpacing = v }
            if let v = values["livePreview"] as? Bool { self.config.livePreview = v }
            if let v = values["interactiveReview"] as? Bool { self.config.interactiveReview = v }
            if let v = values["feedbackSounds"] as? Bool { self.config.feedbackSounds = v }
            if let v = values["pressReturnAfterTyping"] as? Bool { self.config.pressReturnAfterTyping = v }
            if let v = values["voiceFilterRequired"] as? Bool { self.config.voiceFilterRequired = v }
            if let v = values["noiseReduction"] as? Bool {
                let data = try? JSONSerialization.data(withJSONObject: ["enabled": v])
                try? data?.write(to: STATE.appendingPathComponent("noise-trial.json"), options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: STATE.appendingPathComponent("noise-trial.json").path)
            }
            self.config.save()
        })
        if !config.welcomeShown {
            config.welcomeShown = true; config.save()
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self.menuBar?.showWelcome() }
        }
    }

    func run() {
        installMenu()
        installSignalHandlers()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                self?.renewAfterWake = true
            }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
                guard let self, self.config.enabled, !self.setupActive else { return }
                self.renewAfterAppSwitch = true
                self.renewButtonHandlersIfNeeded()
                self.publishHealth()
            }
        gesture.onOpen = { [weak self] in self?.beginTyping() }
        gesture.onClose = { [weak self] open in self?.endTyping(open: open) }
        say("K PTT v2 up — the button types what you say. log=\(EVENT_LOG.path)")
        // The panel measures itself against the screen. Under launchd there is
        // no key window, so it is worth proving the service can see a screen at
        // all rather than finding out from a strip that never grows.
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            record(["kind": "screen",
                    "usable": "\(Int(f.width))x\(Int(f.height))",
                    "panel_ceiling_pt": Int(f.height * 0.62)])
        } else {
            say("WARNING: no screen visible to this process — the preview strip "
                + "cannot size itself and will stay small")
            record(["kind": "screen", "usable": "NONE"])
        }
        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.supervise()
        }
        supervise()
    }

    private var lastConfigStamp: Date?

    private func publishHealth() {
        menuBar?.refresh()
        var health: [String: Any] = [
            "version": 2,
            "journal_mode": config.journalMode,
            "pid": ProcessInfo.processInfo.processIdentifier,
            "enabled": config.enabled,
            "armed": armed,
            "capturing": recorder.isRunning || calibratingRoom || enrolling,
            "setting_up": setupActive || enrollmentSaving,
            "handlers_installed": handlersInstalled,
            "keyboard_media_interceptor": keyboardMediaGate.installed,
            "voice_enrolled": voiceEnrolled,
            "calibrating_room": calibratingRoom,
            "dictation_open": gesture.open,
            "finishing": finishing,
            "pending_text": pendingText != nil,
            "last_button_at": ISO.string(from: lastButtonEvent),
            "last_handler_renewal": ISO.string(from: lastHandlerRenewal),
            "interactive_review": config.interactiveReview,
            "trusted": Keys.trusted,
            "microphone": Mic.statusName,
            "standing_down_because": armed ? "" : standDownReason,
            "at": ISO.string(from: Date()),
        ]
        if let lastButtonClaimAt {
            health["button_claim_at"] = ISO.string(from: lastButtonClaimAt)
        }
        if let data = try? JSONSerialization.data(withJSONObject: health,
                                                  options: [.sortedKeys, .prettyPrinted]) {
            try? data.write(to: HEALTH_PATH, options: .atomic)
        }
    }

    private func calibrateRoom() {
        guard !setupActive, !enrolling, !calibratingRoom, !gesture.open, !finishing, pendingText == nil else { return }
        calibratingRoom = true
        publishHealth()
        preview.note("Measuring room noise for 3 seconds — please stay quiet", text: "")
        work.async {
            let room = Recorder()
            var errorText: String?
            if let error = room.start(deviceName: self.config.micDeviceName) {
                errorText = error
            } else {
                // Wait for actual input, then collect three seconds. Separate
                // recorder: none of this baseline can enter a dictation.
                let deadline = Date().addingTimeInterval(6)
                while room.capturedSeconds < 3 && Date() < deadline { usleep(50_000) }
                if let (wav, seconds) = room.stop(), seconds >= 1 {
                    let answer = self.k.voiceSetup("calibrate", wav: wav)
                    if answer.code != 200 { errorText = answer.json?["error"] as? String ?? "room check failed" }
                } else { errorText = "no room audio" }
            }
            DispatchQueue.main.async {
                self.calibratingRoom = false
                // A failed baseline does not turn identity filtering off.
                self.roomCalibrated = true
                self.preview.hide()
                record(["kind": "room-calibration", "ok": errorText == nil,
                        "error": errorText ?? ""])
                self.publishHealth()
            }
        }
    }

    private func supervise() {
        if let attrs = try? FileManager.default.attributesOfItem(atPath: CONFIG_PATH.path),
           let stamp = attrs[.modificationDate] as? Date, stamp != lastConfigStamp {
            lastConfigStamp = stamp
            config = Config.load()
            k.base = config.kBaseURL
            Recorder.reopenSettleMs = config.reopenSettleMs
        }
        gesture.closeIfStuck(maxSeconds: config.maxOpenSeconds)
        renewButtonHandlersIfNeeded()
        publishHealth()

        guard config.enabled, !setupActive, !enrolling, !enrollmentSaving else { return disarm(setupActive ? "voice setup" : "switched off") }

        let headsetHere = Audio.find(config.headsetName, input: true) != nil
        if headsetHere != lastHeadsetSeen {
            lastHeadsetSeen = headsetHere
            record(["kind": headsetHere ? "headset-connected" : "headset-gone"])
            if headsetHere { clearWarnings() }
        }
        if config.requireHeadset, !headsetHere { return disarm("headset not connected") }
        if !Keys.trusted && !config.journalMode { askForTrustIfNeeded(); return disarm("no Accessibility permission") }
        if !Mic.granted { askForMicIfNeeded(); return disarm("no microphone permission") }

        watch.async {
            let service = self.k.state(timeout: 2)
            let up = service?["ready"] as? Bool == true
            let voice = service?["voice"] as? [String: Any]
            DispatchQueue.main.async {
                guard self.config.enabled, !self.setupActive, !self.enrolling, !self.enrollmentSaving else { return }
                if let voice { self.voiceEnrolled = voice["enrolled"] as? Bool == true }
                if up {
                    self.missedPolls = 0
                    let instance = service?["instance"] as? Int ?? 0
                    if instance != self.roomServiceID {
                        self.roomServiceID = instance
                        self.roomCalibrated = false
                    }
                    if let voice, voice["required"] as? Bool == true, !self.roomCalibrated {
                        // Ears restarts invalidate the previous room baseline.
                        self.calibrateRoom()
                        return
                    }
                    // Say what was actually checked, not what is usually true.
                    self.arm(self.config.requireHeadset
                             ? "K's ears are up and the headset is here"
                             : "K's ears are up (the headset check is switched off)")
                } else {
                    self.missedPolls += 1
                    if self.missedPolls >= 3 { self.disarm("K's service is not answering") }
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Command line
// ---------------------------------------------------------------------------

/// The audio out of a WAV, wherever its data chunk actually begins.
func wavBody(_ file: Data) -> Data? {
    var off = 12
    let bytes = [UInt8](file)
    while off + 8 <= bytes.count {
        let id = String(bytes: bytes[off..<off+4], encoding: .ascii) ?? ""
        let size = Int(UInt32(bytes[off+4]) | UInt32(bytes[off+5]) << 8
                       | UInt32(bytes[off+6]) << 16 | UInt32(bytes[off+7]) << 24)
        if id == "data" {
            let start = off + 8
            return file.subdata(in: start ..< min(start + size, file.count))
        }
        off += 8 + size + (size & 1)
    }
    return nil
}

func serviceHealth() -> [String: Any]? {
    guard let data = try? Data(contentsOf: HEALTH_PATH),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    if let at = obj["at"] as? String, let stamp = ISO.date(from: at),
       Date().timeIntervalSince(stamp) > 30 { return nil }
    return obj
}

final class EnrollmentCancellation: NSObject, NSWindowDelegate {
    var cancelled = false
    var modalWelcome = false
    @objc func startWelcome() { NSApplication.shared.stopModal(withCode: .alertFirstButtonReturn) }
    @objc func cancel() { cancelled = true }
    @objc func cancelWelcome() {
        NSApplication.shared.stopModal(withCode: .alertSecondButtonReturn)
    }
    func closeButton(action: Selector) -> NSButton {
        let button = NSButton(title: "×", target: self, action: action)
        button.isBordered = false
        button.font = NSFont.systemFont(ofSize: 26, weight: .medium)
        button.toolTip = "Cancel enrollment"
        button.setAccessibilityLabel("Cancel enrollment")
        button.keyEquivalent = "\u{1b}"
        return button
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        cancelled = true
        if modalWelcome { cancelWelcome() }
        return true
    }
}

func usage() {
    print("""
    ptt-helper — the button types what you say.

      ptt-helper run              the service (what launchd starts)
      ptt-helper status           what it is doing right now
      ptt-helper on | off         turn the button on or off
      ptt-helper journal on|off  save entries to journal, or type at cursor
      ptt-helper review on|off    editable review box, or original strip
      ptt-helper enroll           save your voice profile (30 seconds solo)
      ptt-helper voice-status     voice enrollment and room baseline
      ptt-helper voice-forget     delete the saved voice profile
      ptt-helper last             show the last thing you dictated
      ptt-helper ramble on|off    tidy LONG dictations before typing (raw
                                  is always saved; short ones never wait)
      ptt-helper clean-text       tidy the last dictation now, on demand
                                  (or: clean-text <file.txt>)

    Checking:
      ptt-helper selftest         its own tests
      ptt-helper audio            the audio devices
      ptt-helper mic-latency      how long the headset takes to wake up
      ptt-helper dictate-file <wav>       run the hearing path against a file
      ptt-helper permission       who actually has permission
      ptt-helper permission-reset clear a stale permission so macOS asks again
    """)
}

let args = Array(CommandLine.arguments.dropFirst())
let command = args.first ?? "run"

switch command {
case "voice-status", "voice-forget":
    let client = KClient(base: Config.load().kBaseURL)
    let answer = command == "voice-forget"
        ? client.voiceSetup("forget", wav: Data("forget".utf8)).json
        : client.state()?["voice"] as? [String: Any]
    if let answer, let data = try? JSONSerialization.data(withJSONObject: answer, options: [.prettyPrinted, .sortedKeys]),
       let line = String(data: data, encoding: .utf8) { print(line); exit(0) }
    print("F5's speech service is not answering."); exit(1)

case "enroll":
    let enrollmentApp = NSApplication.shared
    enrollmentApp.setActivationPolicy(.accessory)
    enrollmentApp.activate(ignoringOtherApps: true)
    let welcomeCancellation = EnrollmentCancellation()
    welcomeCancellation.modalWelcome = true
    let welcome = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 570, height: 300),
                           styleMask: [.titled, .closable], backing: .buffered, defer: false)
    welcome.title = "MyF5 — learn your voice"
    welcome.delegate = welcomeCancellation
    let introduction = NSTextField(wrappingLabelWithString: "Let’s learn your voice.\n\nUse your usual microphone in a quiet room. Read the paragraph in the recording window for 30 seconds. Only a local voice profile is saved, not the recording.\n\nCancel or × stops setup without changing your saved profile.")
    introduction.font = NSFont.systemFont(ofSize: 17)
    introduction.frame = NSRect(x: 24, y: 76, width: 522, height: 180)
    welcome.contentView?.addSubview(introduction)
    let start = NSButton(title: "Start Recording", target: welcomeCancellation,
                         action: #selector(EnrollmentCancellation.startWelcome))
    start.bezelStyle = .rounded
    start.keyEquivalent = "\r"
    start.frame = NSRect(x: 322, y: 24, width: 220, height: 36)
    welcome.contentView?.addSubview(start)
    let cancelSetup = NSButton(title: "Cancel", target: welcomeCancellation,
                               action: #selector(EnrollmentCancellation.cancelWelcome))
    cancelSetup.bezelStyle = .rounded
    cancelSetup.frame = NSRect(x: 24, y: 24, width: 140, height: 36)
    welcome.contentView?.addSubview(cancelSetup)
    let welcomeCross = welcomeCancellation.closeButton(action: #selector(EnrollmentCancellation.cancelWelcome))
    welcomeCross.frame = NSRect(x: 528, y: 260, width: 32, height: 32)
    welcomeCross.autoresizingMask = [.minXMargin, .minYMargin]
    welcome.contentView?.addSubview(welcomeCross)
    welcome.center()
    welcome.makeKeyAndOrderFront(nil)
    let setupChoice = enrollmentApp.runModal(for: welcome)
    welcome.orderOut(nil)
    guard setupChoice == .alertFirstButtonReturn else { print("Enrollment cancelled; no recording started."); exit(0) }
    let config = Config.load()
    if let health = serviceHealth(),
       ["capturing", "dictation_open", "finishing", "pending_text"].contains(where: { health[$0] as? Bool == true }) {
        print("Finish the current dictation or room calibration before enrolling."); exit(1)
    }
    if !Mic.granted {
        Mic.request { _ in }
        let until = Date().addingTimeInterval(30)
        while !Mic.granted && Date() < until { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        if !Mic.granted { print("Grant Microphone permission to K PTT, then enroll again."); exit(1) }
        // Continue after macOS approval.
    }
    let enrollment = Recorder()
    print("Speak alone for 30 seconds using your usual microphone. Keep music and other speakers quiet for enrollment.")
    print("Read several sentences in your normal voice. This learns who you are, not what you say.")
    if let error = enrollment.start(deviceName: config.micDeviceName) { print(error); exit(1) }
    let cancellation = EnrollmentCancellation()
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 380), styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.title = "MyF5 — recording your voice"
    window.delegate = cancellation
    let paragraph = NSTextField(wrappingLabelWithString: "Read aloud at a comfortable pace:\n\nI am setting up my voice for MyF5. When I press the play button, I want to dictate in my own words. I can speak at a comfortable pace and use a normal tone. This recording helps the app recognize my voice when other people are nearby. After setup, I can review the words before sending them. I am reading several different sentences so the app can learn the sound of my voice.\n\nKeep speaking naturally until the recording finishes.")
    paragraph.frame = NSRect(x: 24, y: 75, width: 572, height: 240)
    paragraph.font = NSFont.systemFont(ofSize: 17)
    window.contentView?.addSubview(paragraph)
    let cancel = NSButton(title: "Cancel Recording", target: cancellation, action: #selector(EnrollmentCancellation.cancel))
    cancel.frame = NSRect(x: 210, y: 22, width: 200, height: 36)
    cancel.bezelStyle = .rounded
    window.contentView?.addSubview(cancel)
    let cross = cancellation.closeButton(action: #selector(EnrollmentCancellation.cancel))
    cross.frame = NSRect(x: 574, y: 338, width: 32, height: 32)
    cross.autoresizingMask = [.minXMargin, .minYMargin]
    window.contentView?.addSubview(cross)
    window.center()
    window.makeKeyAndOrderFront(nil)
    let until = Date().addingTimeInterval(35)
    while !cancellation.cancelled && enrollment.capturedSeconds < 30 && Date() < until {
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    window.orderOut(nil)
    if cancellation.cancelled {
        _ = enrollment.stop()
        print("Enrollment cancelled. No new voice profile was saved.")
        exit(0)
    }
    guard let (wav, seconds) = enrollment.stop(), seconds >= 15 else { print("Not enough microphone audio; retry."); exit(1) }
    print("Checking and saving your voice profile…")
    let result = KClient(base: config.kBaseURL).voiceSetup("enroll", wav: wav)
    if result.code != 200 { print(result.json?["error"] as? String ?? "F5's speech service is unavailable."); exit(1) }
    print("Your voice is enrolled. Audio was not saved; the voice embedding stays locally in ~/F5/state/voice-profile.json.")
    exit(0)

case "audio":
    Audio.describeAll()
    exit(0)

case "on", "off":
    var c = Config.load()
    c.enabled = (command == "on")
    c.save()
    print("the button is \(c.enabled ? "ON — it types what you say" : "OFF — it goes back to Music")")
    print("(takes effect within two seconds; no restart needed)")
    exit(0)

case "status":
    let c = Config.load()
    print("K:         \(c.kBaseURL)  \(KClient(base: c.kBaseURL).isUp ? "up" : "not answering")")
    print("headset:   \(Audio.find(c.headsetName, input: true) != nil ? "connected" : "not connected")")
    if let health = serviceHealth() {
        print("service:   running, pid \((health["pid"] as? Int) ?? 0)")
        if (health["armed"] as? Bool) == true {
            print("button:    YOURS — click, talk, click again")
        } else {
            print("button:    not yours right now — it goes to Music")
            print("           because: \((health["standing_down_because"] as? String) ?? "?")")
            print("           nothing has crashed; it comes back by itself")
        }
        let trusted = (health["trusted"] as? Bool) ?? false
        print("typing:    \(trusted ? "allowed" : "NOT allowed — approve K PTT in Accessibility")")
        let mic = (health["microphone"] as? String) ?? "?"
        print("hearing:   \(mic)\(mic == "granted" ? "" : "  <- capture would be silent")")
    } else {
        print("service:   NOT running — start it with ./install.sh")
    }
    print("enter key: \(c.pressReturnAfterTyping ? "pressed for you" : "not pressed")")
    print("review:    \(c.interactiveReview ? "ON — edit, select-and-speak, send, or discard" : "off — original display-only strip")")
    let rambleLine = c.cleanRambles
        ? "ON — dictations over \(c.rambleMinWords) words are tidied before typing (raw always saved)"
        : "off — it types exactly what you say (./ptt-mode ramble on to tidy long rambles)"
    print("ramble:    \(rambleLine)")
    if let voice = KClient(base: c.kBaseURL).state()?["voice"] as? [String: Any] {
        print("voice:     \(voice["required"] as? Bool == true ? (voice["enrolled"] as? Bool == true ? "YOUR voice only (best effort)" : "enrollment needed — ./button enroll") : "filter off")")
        print("room:      \(voice["calibrated"] as? Bool == true ? "baseline measured" : "baseline pending")")
    }
    print("config:    \(CONFIG_PATH.path)")
    exit(0)

case "diagnose-next":
    let flag = STATE.appendingPathComponent("diagnose-next")
    try? Data().write(to: flag, options: .atomic)
    print("One-shot diagnostic enabled. Finish a short dictation (under 60 seconds).")
    print("Only the local comparison text is saved; raw audio is discarded. Normal typing remains protected.")
    exit(0)

case "journal":
    var config = Config.load()
    if args.count > 1, ["on", "off"].contains(args[1]) {
        if let health = serviceHealth(), ["capturing", "dictation_open", "finishing", "pending_text", "setting_up"].contains(where: { health[$0] as? Bool == true }) {
            print("Finish or discard the current draft before switching modes."); exit(1)
        }
        config.journalMode = args[1] == "on"; config.save()
    }
    print(config.journalMode ? "Journal mode: completed entries are saved locally; nothing is typed at the cursor." : "Cursor dictation: journal saving is off.")
    print("Journal folder: " + ROOT.appendingPathComponent("Journal").path)
    exit(0)

case "review":
    var c = Config.load()
    switch args.count > 1 ? args[1] : "status" {
    case "on":
        c.interactiveReview = true
        c.save()
        print("interactive review is ON.")
        print("Click text to edit it; select words and speak to replace them;")
        print("click the button again to send, or × to discard everything.")
    case "off":
        c.interactiveReview = false
        c.save()
        print("interactive review is OFF — the original display-only strip is back.")
    default:
        print("interactive review is \(c.interactiveReview ? "ON" : "OFF").")
        print("  ./ptt-mode review on|off  to change it")
    }
    print("(takes effect on the next dictation; no restart needed)")
    exit(0)

case "ramble":
    var c = Config.load()
    switch args.count > 1 ? args[1] : "status" {
    case "on":
        c.cleanRambles = true
        c.save()
        print("ramble tidying is ON.")
        print("A dictation of \(c.rambleMinWords) words or more is tidied by the")
        print("fast mind before it is typed — fillers, false starts and repeats")
        print("come out; every typed word is one you spoke, in your order.")
        print("Your raw words are ALWAYS saved first: ./ptt-mode last")
        print("Short dictations are typed instantly, untouched.")
    case "off":
        c.cleanRambles = false
        c.save()
        print("ramble tidying is OFF — the button types exactly what you say.")
        print("You can still tidy after the fact, any time: ./ptt-mode clean-text")
    default:
        print("ramble tidying is \(c.cleanRambles ? "ON" : "OFF").")
        print("  ./ptt-mode ramble on|off  to change it")
        print("  ./ptt-mode clean-text     tidies the last dictation on demand")
    }
    exit(0)

case "clean-text":
    // The exact shipped cleaning path, run over a text file — or over the
    // last dictation when no file is named. This is how a ramble gets
    // tidied AFTER the fact with zero cost on the typing path, and it is
    // the seam the bench measures through.
    let c = Config.load()
    let source = args.count > 1 ? URL(fileURLWithPath: args[1]) : LAST_DICTATION
    guard let raw = try? String(contentsOf: source, encoding: .utf8),
          !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        print("nothing to clean at \(source.path)")
        exit(1)
    }
    let outcome = Rambler.clean(raw.trimmingCharacters(in: .whitespacesAndNewlines),
                                timeoutMs: c.rambleTimeoutMs)
    let receipt: [String: Any] = [
        "applied": outcome.applied, "ms": outcome.ms, "model": outcome.model,
        "why": outcome.why,
        "words_raw": Rambler.tokens(raw).count,
        "words_kept": Rambler.tokens(outcome.text).count,
        "text": outcome.text,
    ]
    if let data = try? JSONSerialization.data(withJSONObject: receipt,
                                              options: [.sortedKeys]),
       let line = String(data: data, encoding: .utf8) {
        print(line)
    }
    exit(outcome.applied ? 0 : 3)

case "permission":
    if let health = serviceHealth() {
        print("The running service, pid \((health["pid"] as? Int) ?? 0):")
        print("   Accessibility (typing): \(((health["trusted"] as? Bool) ?? false) ? "GRANTED" : "NOT GRANTED")")
        print("   Microphone (hearing):   \((health["microphone"] as? String) ?? "?")")
    } else {
        print("The service is not running, so its permissions are unknown.")
    }
    print("")
    print("This command is a DIFFERENT process and its answer does not matter:")
    print("   Accessibility: \(Keys.trusted ? "granted" : "not granted") (inherited from your terminal)")
    exit(0)

case "permission-reset":
    for service in ["Accessibility", "Microphone"] {
        let reset = Process()
        reset.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        reset.arguments = ["reset", service, "com.k.ptt"]
        try? reset.run(); reset.waitUntilExit()
    }
    print("cleared the old permissions for K PTT. Now restart the helper:")
    print("   launchctl kickstart -k gui/$(id -u)/com.k.ptt")
    exit(0)

case "trim-pauses":
    // The bench's view of what the helper now does before the final hearing.
    guard args.count > 2 else { print("usage: ptt-helper trim-pauses <in.wav> <out.wav>"); exit(2) }
    guard let inFile = try? Data(contentsOf: URL(fileURLWithPath: args[1])),
          let inBody = wavBody(inFile) else { print("could not read \(args[1])"); exit(1) }
    let cfgT = Config.load()
    let trimmed = Recorder.trimPauses(inBody, floorDb: Double(cfgT.speechFloorDb))
    try? Recorder.wav(trimmed.audio, rate: 16000).write(to: URL(fileURLWithPath: args[2]))
    print(String(format: "TRIM: %.1fs -> %.1fs (removed %.1fs of pause, floor %d dB)",
                 Double(inBody.count) / 2 / 16000,
                 Double(trimmed.audio.count) / 2 / 16000,
                 Double(trimmed.removedMs) / 1000, cfgT.speechFloorDb))
    exit(0)

case "grab-ambient":
    // Capture a few seconds of HIS room through HIS headset, so the pause-noise
    // bench uses the real thing rather than digital silence.
    let cfgA = Config.load()
    let recA = Recorder()
    if let error = recA.start(deviceName: cfgA.micDeviceName) {
        print("could not open the microphone: \(error)"); exit(1)
    }
    print("recording 6 seconds of room noise — say nothing…")
    sleep(6)
    guard let got = recA.stop() else { print("nothing captured"); exit(1) }
    let out = args.count > 1 ? args[1] : "/tmp/ambient.wav"
    try? got.wav.write(to: URL(fileURLWithPath: out))
    print(String(format: "wrote %@ — %.1f s at %.1f dB", out as NSString,
                 got.seconds, Recorder.level(of: got.wav.dropFirst(44))))
    exit(0)

case "levels":
    // What is silence and what is speech, on HIS headset, in real numbers.
    // The strip needs this to stop showing guesses over a quiet stretch.
    let cfgL = Config.load()
    print("measuring the headset's quiet level — say nothing for 4 seconds…")
    let recL = Recorder()
    if let error = recL.start(deviceName: cfgL.micDeviceName) {
        print("could not open the microphone: \(error)"); exit(1)
    }
    sleep(4)
    let quiet = recL.level(lastSeconds: 3)
    _ = recL.stop()
    print(String(format: "  quiet on this headset : %.1f dB", quiet))
    if args.count > 1, let file = try? Data(contentsOf: URL(fileURLWithPath: args[1])),
       let body = wavBody(file) {
        print(String(format: "  speech in %@ : %.1f dB",
                     (args[1] as NSString).lastPathComponent as NSString,
                     Recorder.level(of: body)))
        // and the quietest half-second inside that speech, which is the real
        // floor a gate has to sit under
        var quietest = 0.0
        let step = 8000 * 2
        var at = 0
        var first = true
        while at + step <= body.count {
            let l = Recorder.level(of: body.subdata(in: at ..< at + step))
            if first || l < quietest { quietest = l; first = false }
            at += step
        }
        print(String(format: "  quietest half-second inside that speech : %.1f dB", quietest))
    }
    exit(0)

case "mic-latency":
    let c = Config.load()
    for round in 1...3 {
        let rec = Recorder()
        if let error = rec.start(deviceName: c.micDeviceName) {
            print("round \(round): \(error)"); exit(1)
        }
        sleep(3)
        let first = rec.firstAudioMs
        let result = rec.stop()
        print("round \(round): first audio after \(first.map { "\($0) ms" } ?? "never"), "
              + "captured \(String(format: "%.2f", result?.seconds ?? 0)) s of a 3 s hold")
        sleep(2)
    }
    exit(0)

case "probe-headers":
    // Regression guard for a real defect: sending an X-K-Client header made K
    // treat this helper as one of her pages, hand it the microphone, and tell
    // him on his own page that his microphone was somewhere else.
    guard args.count > 1 else { print("usage: ptt-helper probe-headers <url>"); exit(2) }
    let probe = KClient(base: args[1])
    let answer = probe.draft(Recorder.wav(Data(repeating: 0, count: 3200), rate: 16000),
                             timeout: 10)
    print("posted; server answered \(answer.code)")
    exit(0)

case "preview-replay":
    // The shipped display path, driven by a recording instead of his voice:
    // the same PreviewStrip, the same PreviewText, the same segment-and-freeze
    // logic, the same 800 ms cadence, hearing through the same quiet route.
    // Prints the panel's real height so growth is measured, not assumed.
    guard args.count > 1 else { print("usage: ptt-helper preview-replay <wav>"); exit(2) }
    guard let file = try? Data(contentsOf: URL(fileURLWithPath: args[1])),
          let body = wavBody(file) else { print("could not read \(args[1])"); exit(1) }
    let cfgR = Config.load()
    let clientR = KClient(base: cfgR.kBaseURL)
    let appR = NSApplication.shared
    appR.setActivationPolicy(.accessory)
    let stripR = PreviewStrip()
    stripR.fontSize = cfgR.fontSize
    stripR.lineSpacing = cfgR.lineSpacing
    let wordsR = PreviewText()
    stripR.show()
    let frontR = NSWorkspace.shared.frontmostApplication
    print("screen: \(NSScreen.main.map { "\(Int($0.visibleFrame.width))x\(Int($0.visibleFrame.height))" } ?? "NONE")   "
          + "front: \(frontR?.localizedName ?? "?")")
    // %s takes a C string; handing it an NSString is a wild pointer and a
    // segfault. %@ is the one for objects.
    print("     at   shown settled     panel  newest words")
    let totalR = Double(body.count) / 2.0 / 16000.0
    var atR = 0.8
    var lastShown = ""
    var shrinks = 0, heightsR: [CGFloat] = []
    var lastBlack = "", blackChanged = 0, lastWords = 0
    var greyEverShown = Set<String>()
    while atR < totalR {
        let from = Int(wordsR.frozenUntil * 16000) * 2
        let to = min(body.count, Int(atR * 16000) * 2)
        if to > from + 3200 {
            let (code, json, _) = clientR.draft(
                Recorder.wav(Data(body[from..<to]), rate: 16000), timeout: 30)
            if code == 200, let heard = json?["heard"] as? String {
                let text = Text.clean(heard)
                if !text.isEmpty {
                    wordsR.advance(transcript: text, upTo: atR)
                    stripR.update(black: wordsR.frozen, grey: wordsR.live)
                    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                    // Grey refining itself smaller is fine and expected — the
                    // ears drop a filler word as they hear more. What must
                    // never happen is settled text moving (checked below) or
                    // the whole display losing a real chunk of his speech.
                    let nowWords = wordsR.full.split(separator: " ").count
                    if lastWords - nowWords > 4 {
                        shrinks += 1
                        print("      ^ lost \(lastWords - nowWords) words here")
                    }
                    lastWords = nowWords
                    // THE LAW: a word shown in grey must end up settled in
                    // black, or in the final text. It may never simply vanish.
                    for w in wordsR.live.split(separator: " ") {
                        greyEverShown.insert(String(w).lowercased()
                            .trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;:")))
                    }
                    // black text is append-only
                    if !wordsR.frozen.hasPrefix(lastBlack) { blackChanged += 1 }
                    lastBlack = wordsR.frozen
                    lastShown = wordsR.full
                    heightsR.append(stripR.currentHeight)
                    print(String(format: "%6.1fs %7d %7d %7.0fpt  %@", atR,
                                 wordsR.full.split(separator: " ").count,
                                 wordsR.frozen.split(separator: " ").count,
                                 stripR.currentHeight,
                                 String(wordsR.full.suffix(46)) as NSString))
                }
            }
        }
        atR += 0.8
    }
    print("")
    print("  words shown at the end   \(wordsR.full.split(separator: " ").count)")
    print("  settled (black) words    \(lastBlack.split(separator: " ").count)")
    print("  settled text changed     \(blackChanged) times (must be 0)")
    print("  lost a chunk of speech   \(shrinks) times (must be 0)")
    // Everything ever shown in grey must be accounted for: settled on screen,
    // or present in the final whole-recording hearing that gets typed.
    let (fc2, fj2, _) = clientR.draft(Recorder.wav(body, rate: 16000), timeout: 300)
    let finalText = ((fj2?["heard"] as? String) ?? "").lowercased()
    let shownNow = wordsR.full.lowercased()
    // The real loss to guard against is not "a wrong guess disappeared" —
    // grey correcting itself is the point of grey. It is a stretch he ACTUALLY
    // SAID never reaching the strip at all. So: what is in the final hearing
    // of the whole recording that the strip never showed him?
    var vanished: [String] = []
    let shownWords = Set(shownNow.split(separator: " ").map {
        String($0).trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;:")) })
    var run: [String] = []
    for w in finalText.split(separator: " ") {
        let bare = String(w).trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;:"))
        if bare.isEmpty { continue }
        if shownWords.contains(bare) {
            if run.count >= 2 { vanished.append(run.joined(separator: " ")) }
            run = []
        } else {
            run.append(bare)
        }
    }
    if run.count >= 2 { vanished.append(run.joined(separator: " ")) }
    print("  stretches he said but never saw  \(vanished.count) (must be 0)")
    for v in vanished.prefix(4) { print("      missing: \(v)") }
    print("  final display : \(shownNow)")
    print("  final hearing : \(finalText)")
    _ = fc2
    print("  panel grew               \(Int(heightsR.first ?? 0)) pt -> \(Int(heightsR.last ?? 0)) pt "
          + "(ceiling \(Int(stripR.ceiling)) pt)")
    let grewOK = (heightsR.last ?? 0) > (heightsR.first ?? 0) + 20
    let ok = grewOK && shrinks == 0 && blackChanged == 0 && vanished.isEmpty
    print("  " + (ok ? "PASS — nothing shown was lost, settled words never moved, box grew"
                     : "FAIL — " + (blackChanged > 0 ? "settled text changed"
                                    : !vanished.isEmpty ? "grey words vanished"
                                    : grewOK ? "text was lost" : "the box did not grow")))
    stripR.hide()
    exit(ok ? 0 : 1)

case "review-shortcut-test":
    // Real NSPanel → first responder → NSTextView command handling. The
    // founder's clipboard is restored before this process exits.
    RECORDING = false
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let pasteboard = NSPasteboard.general
    let savedPasteboard = PasteboardSnapshot(pasteboard)
    var failures = 0
    func checkShortcut(_ name: String, _ okay: Bool) {
        print((okay ? "  ok    " : "  FAIL  ") + name)
        if !okay { failures += 1 }
    }

    let strip = PreviewStrip()
    var keyboardCommands: [ReviewShortcut] = []
    var voiceSelections = 0
    strip.onKeyboardCommand = { _, _, shortcut in keyboardCommands.append(shortcut) }
    strip.onSelectionChanged = { _, range in
        if range.length > 0 { voiceSelections += 1 }
    }
    strip.show(interactive: true)
    checkShortcut("review automatically receives keyboard focus", strip.editorHasFocusForTest)
    let original = "alpha beta gamma"
    strip.update(black: original, grey: "")
    checkShortcut("the real review editor becomes first responder",
                  strip.focusEditorForTest())
    strip.select(NSRange(location: 3, length: 0))
    strip.setSpeaking(true)
    checkShortcut("speech hides only the blue insertion caret",
                  !strip.caretVisibleForTest && strip.selection.location == 3)
    strip.setSpeaking(false)
    checkShortcut("quiet speech meter restores the same caret position",
                  strip.caretVisibleForTest && strip.selection.location == 3)

    checkShortcut("the panel handles Command-A", strip.sendShortcutForTest("a"))
    checkShortcut("Command-A selects the whole review",
                  strip.selection.location == 0
                  && strip.selection.length == (original as NSString).length)
    checkShortcut("Command-A is keyboard-only, never a spoken replacement",
                  keyboardCommands == [.selectAll] && voiceSelections == 0)

    pasteboard.clearContents()
    pasteboard.setString("pasted safely", forType: .string)
    checkShortcut("the panel handles Command-V", strip.sendShortcutForTest("v"))
    checkShortcut("Command-V replaces the selected text", strip.text == "pasted safely")
    checkShortcut("the panel handles Command-Z", strip.sendShortcutForTest("z"))
    checkShortcut("Command-Z restores the previous text", strip.text == original)

    let beta = (original as NSString).range(of: "beta")
    strip.select(beta)
    pasteboard.clearContents()
    checkShortcut("the panel handles Command-C", strip.sendShortcutForTest("c"))
    checkShortcut("Command-C copies the selected word",
                  pasteboard.string(forType: .string) == "beta")
    checkShortcut("the panel handles Command-X", strip.sendShortcutForTest("x"))
    checkShortcut("Command-X cuts the selected word", !strip.text.contains("beta"))

    var submissions = 0
    strip.onSubmit = { _, _ in submissions += 1 }
    strip.sendReturnForTest()
    checkShortcut("Return submits the focused draft once", submissions == 1)
    strip.hide()
    savedPasteboard.restore(to: pasteboard)
    print(failures == 0 ? "all review shortcuts passed" : "\(failures) shortcut checks failed")
    exit(failures == 0 ? 0 : 1)

case "review-test":
    // A visual, harmless copy of the review box: no microphone, no typing,
    // and no document receives anything. It stays up long enough to inspect
    // mouse selection, keyboard editing, the status line, and ×.
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let strip = PreviewStrip()
    strip.fontSize = Config.load().fontSize
    strip.lineSpacing = Config.load().lineSpacing
    strip.onDiscard = { strip.hide(); NSApplication.shared.terminate(nil) }
    strip.onTextChanged = { text, _ in
        strip.setStatus("Editing")
        print("edited: \(text)")
    }
    strip.onSelectionChanged = { _, range in
        strip.setStatus(range.length > 0 ? "Ready for correction" : "Editing")
        print("selected \(range.length) characters")
    }
    strip.show(interactive: true)
    strip.update(black: "Send the quarterly numbers on ",
                 grey: "Friday after lunch, then continue dictating here.")
    strip.setStatus("Listening")
    Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { _ in
        strip.hide(); NSApplication.shared.terminate(nil)
    }
    app.run()
    exit(0)

case "preview-test":
    // Shows the strip for a few seconds with sample text, and checks that it
    // never takes focus — his cursor must stay in whatever he is writing in.
    let front = NSWorkspace.shared.frontmostApplication
    print("front before: \(front?.localizedName ?? "?") (pid \(front?.processIdentifier ?? 0))")
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let strip = PreviewStrip()
    strip.show()
    // A real dictation's worth of words, arriving the way they arrive.
    let sentence = ["I have been thinking about the way we handle the evening review",
                    "and whether it needs to change.",
                    "The main thing is that nothing should be lost between what I say",
                    "and what actually gets written down.",
                    "We keep the parts that work and polish the ones that do not.",
                    "No jargons, no heavy text, just plain English that he can read quickly.",
                    "Remind me to send the quarterly numbers to the accountant on Friday.",
                    "Do not restart her service while another agent is using the machine.",
                    "I want the microphone pinned to the headset without changing my output.",
                    "Please check the ledger against the transcript before you file anything."]
    var sofar = ""
    var heights: [CGFloat] = []
    var grew = 0
    for (i, part) in sentence.enumerated() {
        sofar += (sofar.isEmpty ? "" : " ") + part
        strip.update(black: sofar, grey: "")
        RunLoop.main.run(until: Date().addingTimeInterval(0.55))
        let h = strip.currentHeight
        if let last = heights.last, h > last + 1 { grew += 1 }
        heights.append(h)
        let now = NSWorkspace.shared.frontmostApplication
        print(String(format: "  %3d words  panel %4.0f pt  %@", sofar.split(separator: " ").count, h,
                     (now?.processIdentifier == front?.processIdentifier
                      ? "focus unchanged" : "FOCUS MOVED") as NSString))
        _ = i
    }
    print("")
    print("  grew \(grew) times, from \(Int(heights.first ?? 0)) pt to \(Int(heights.last ?? 0)) pt "
          + "(ceiling \(Int(strip.ceiling)) pt)")
    let words = sofar.split(separator: " ").count
    print("  \(words) words " + (words >= 60 ? "(a real dictation's worth)" : "(TOO SHORT A TEST)"))
    if heights.last! < heights.first! + 20 { print("  FAIL — the panel did not grow") }
    strip.hide()
    RunLoop.main.run(until: Date().addingTimeInterval(0.4))
    let after = NSWorkspace.shared.frontmostApplication
    print("front after:  \(after?.localizedName ?? "?") (pid \(after?.processIdentifier ?? 0))")
    print(after?.processIdentifier == front?.processIdentifier
          ? "PASS — focus never moved" : "FAIL — focus moved")
    exit(after?.processIdentifier == front?.processIdentifier ? 0 : 1)

case "last":
    // "or your text is saved" — this is where. Prints it, so he can copy it.
    guard let text = try? String(contentsOf: LAST_DICTATION, encoding: .utf8),
          !text.isEmpty else {
        print("Nothing saved yet. (\(LAST_DICTATION.path))")
        exit(1)
    }
    if let when = (try? FileManager.default.attributesOfItem(atPath: LAST_DICTATION.path))?[.modificationDate] as? Date {
        print("Your last dictation, from \(ISO.string(from: when)):\n")
    }
    print(text)
    print("\n(saved at \(LAST_DICTATION.path))")
    exit(0)

case "dictate-file":
    guard args.count > 1 else { print("usage: ptt-helper dictate-file <wav>"); exit(2) }
    let c = Config.load()
    guard let audio = try? Data(contentsOf: URL(fileURLWithPath: args[1])) else {
        print("could not read \(args[1])"); exit(1)
    }
    let client = KClient(base: c.kBaseURL)
    print("K advertises: \(client.capabilities().sorted().joined(separator: ", "))")
    let t0 = Date()
    let (code, json, quiet) = client.draft(audio)
    print("route used: /api/turn?draft=1\(quiet ? "&quiet=1" : "")")
    print("http \(code) in \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
    print("heard: \((json?["heard"] as? String) ?? "(nothing)")")
    print("reply carried 'hearing' key: \(json?["hearing"] != nil)")
    print("reply carried 'state' key:   \(json?["state"] != nil)")
    exit(code == 200 ? 0 : 1)

case "selftest":
    RECORDING = false
    var failures = 0
    func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        print((ok ? "  ok    " : "  FAIL  ") + name)
        if !ok { failures += 1; if !detail.isEmpty { print("        " + detail) } }
    }

    check("keyboard Play/Pause down recognized", KeyboardMediaGate.playPauseState(subtype: 8, data: (16 << 16) | (0x0a << 8))?.down == true)
    check("keyboard Play/Pause release recognized", KeyboardMediaGate.playPauseState(subtype: 8, data: (16 << 16) | (0x0b << 8))?.down == false)
    check("keyboard media repeat recognized", KeyboardMediaGate.playPauseState(subtype: 8, data: (16 << 16) | (0x0a << 8) | 1)?.repeated == true)
    check("volume and ordinary keys pass through", KeyboardMediaGate.playPauseState(subtype: 8, data: (0 << 16) | (0x0a << 8)) == nil && KeyboardMediaGate.playPauseState(subtype: 0, data: (16 << 16) | (0x0a << 8)) == nil)

    // The audio container K's ears expect.
    let pcm = Data(repeating: 0, count: 3200)
    let wav = Recorder.wav(pcm, rate: 16000)
    check("wav is a 44-byte header plus the audio", wav.count == pcm.count + 44)
    check("wav starts RIFF", Array(wav[0..<4]) == Array("RIFF".utf8))
    check("wav says WAVE", Array(wav[8..<12]) == Array("WAVE".utf8))
    check("wav declares one channel", wav[22] == 1 && wav[23] == 0)
    check("wav declares 16000 Hz", UInt32(wav[24]) | UInt32(wav[25]) << 8
          | UInt32(wav[26]) << 16 | UInt32(wav[27]) << 24 == 16000)
    check("wav declares 16 bits", wav[34] == 16 && wav[35] == 0)

    // ONE gesture: a click toggles, and a release means nothing at all.
    var opens = 0, closes = 0
    var lastOpen = 0.0
    check("Bluetooth address follows hyphenated macOS input UID",
          BluetoothHangupBridge.address(from: "AA-BB-CC-DD-EE-FF:input") == "AA:BB:CC:DD:EE:FF")
    check("Bluetooth address follows colon-separated macOS input UID",
          BluetoothHangupBridge.address(from: "aa:bb:cc:dd:ee:ff:input") == "AA:BB:CC:DD:EE:FF")
    check("Mac built-in microphone does not start Bluetooth bridge",
          BluetoothHangupBridge.address(from: "BuiltInMicrophoneDevice") == nil)
    check("Bluetooth output UID does not enable microphone finish bridge",
          BluetoothHangupBridge.address(from: "AA-BB-CC-DD-EE-FF:output") == nil)
    check("Headset hangup matches the recording microphone",
          BluetoothHangupBridge.matches(message: "Received call hangup event (AT+CHUP) from device AA:BB:CC:DD:EE:FF", address: "AA:BB:CC:DD:EE:FF"))
    check("Another headset cannot finish this recording",
          !BluetoothHangupBridge.matches(message: "Received call hangup event (AT+CHUP) from device 11:22:33:44:55:66", address: "AA:BB:CC:DD:EE:FF"))
    check("Connection and codec messages cannot finish a draft",
          !BluetoothHangupBridge.matches(message: "Received voice disconnection event for device AA:BB:CC:DD:EE:FF", address: "AA:BB:CC:DD:EE:FF"))

    let g = Gesture()
    g.onOpen = { opens += 1 }
    g.onClose = { held in closes += 1; lastOpen = held }

    g.feed(.play)
    check("a click opens the microphone", opens == 1 && g.open)
    g.feed(.pause)
    check("letting go does nothing at all", closes == 0 && g.open,
          "there is no hold gesture in v2")
    g.feed(.pause); g.feed(.pause)
    check("nor does letting go repeatedly", closes == 0 && g.open)
    usleep(300_000)
    g.feed(.play)
    check("the next click closes and sends", closes == 1 && !g.open)
    check("the time it was open is reported", lastOpen > 0.25)
    g.feed(.pause)
    check("the release after that is still nothing", closes == 1 && opens == 1)
    g.feed(.play)
    check("and the one after opens again", opens == 2 && g.open)

    var bluetoothOpens = 0, bluetoothCloses = 0
    let bluetooth = Gesture()
    bluetooth.onOpen = { bluetoothOpens += 1 }
    bluetooth.onClose = { _ in bluetoothCloses += 1 }
    bluetooth.feed(.pause, at: 100)
    check("Bluetooth pause-only command opens dictation", bluetooth.open && bluetoothOpens == 1)
    bluetooth.feed(.pause, at: 102)
    check("Bluetooth pause-only second press finishes dictation", !bluetooth.open && bluetoothCloses == 1)
    bluetooth.feed(.play, at: 104)
    bluetooth.feed(.pause, at: 104.1)
    check("Bluetooth quick release does not close dictation", bluetooth.open && bluetoothCloses == 1)
    bluetooth.feed(.pause, at: 106)
    check("Bluetooth semantic pause finishes after speaking", !bluetooth.open && bluetoothCloses == 2)

    opens = 0; closes = 0
    let stuck = Gesture()
    stuck.onOpen = { opens += 1 }
    stuck.onClose = { _ in closes += 1 }
    stuck.feed(.play)
    usleep(50_000)
    stuck.closeIfStuck(maxSeconds: 0)
    check("a capture left open for ever is closed", closes == 1 && !stuck.open)
    stuck.closeIfStuck(maxSeconds: 0)
    check("and only once", closes == 1)

    opens = 0; closes = 0
    let dropped = Gesture()
    dropped.onOpen = { opens += 1 }
    dropped.onClose = { _ in closes += 1 }
    dropped.feed(.play)
    dropped.abandon()
    check("an abandoned capture sends nothing", closes == 0 && !dropped.open)

    // The words, cleaned. K's ears occasionally return <unk> placeholders;
    // typed literally they land "<unk><unk>" in his document.
    check("<unk> is never typed", Text.clean("hello <unk> world") == "hello world")
    check("a run of <unk> types nothing", Text.clean("<unk> <unk>").isEmpty)
    check("ordinary words are untouched",
          Text.clean("Remind me on Friday.") == "Remind me on Friday.")
    check("<unk> inside a longer token is caught too",
          Text.clean("a <unk>b c") == "a c")

    // The strip must accumulate, not churn. His words: "whatever I'm speaking
    // is being disappeared and it's constantly changing."
    let pt = PreviewText(freezeAfter: 20)
    _ = pt.advance(transcript: "I have been thinking about the evening review", upTo: 5)
    check("the first words show", pt.full == "I have been thinking about the evening review")
    // The ears revise the live stretch — that is allowed, it is the tail.
    _ = pt.advance(transcript: "I have been thinking about the evening review and whether", upTo: 9)
    check("the live stretch may be revised",
          pt.full == "I have been thinking about the evening review and whether")
    check("nothing is frozen yet", pt.frozen.isEmpty)
    // Past the freeze length it is written down for good.
    let froze = pt.advance(transcript: "I have been thinking about the evening review and whether it needs to change.",
                           upTo: 21)
    check("past the freeze length the words settle", froze && !pt.frozen.isEmpty)
    let settled = pt.frozen
    check("the settled text is the whole stretch so far",
          settled == "I have been thinking about the evening review and whether it needs to change.")
    check("the live stretch starts empty again", pt.live.isEmpty)
    check("and the next segment starts exactly where that one ended",
          pt.frozenUntil == 21, "\(pt.frozenUntil)")

    // THE POINT: new words ADD to the old ones, they do not replace them.
    _ = pt.advance(transcript: "The main thing is that nothing should be lost", upTo: 26)
    check("older words are still there", pt.full.hasPrefix(settled),
          pt.full)
    check("and the new ones are added after them",
          pt.full.hasSuffix("The main thing is that nothing should be lost"), pt.full)
    check("the settled part did not change", pt.frozen == settled)
    // Even when the ears re-hear the live stretch differently, the frozen part
    // must not move — this is what stops his words vanishing.
    _ = pt.advance(transcript: "The main thing is nothing should be lost between what I say", upTo: 30)
    check("a revision of the tail never disturbs the settled text",
          pt.frozen == settled && pt.full.hasPrefix(settled), pt.full)
    check("the display keeps growing", pt.full.count > settled.count)

    var empty = PreviewText()
    _ = empty.advance(transcript: "   ", upTo: 3)
    check("an empty hearing changes nothing", empty.full.isEmpty)

    // He stops talking: the grey must go black without him clicking, so he can
    // see his last words registered. ("Should I wait for it to turn from gray
    // to black?" — he should not have to wonder.)
    let stopped = PreviewText(freezeAfter: 8)
    _ = stopped.advance(transcript: "and that is the last thing I wanted to say", upTo: 3)
    check("mid-sentence it is still grey", stopped.frozen.isEmpty && !stopped.live.isEmpty)
    let settled2 = stopped.advance(transcript: "and that is the last thing I wanted to say",
                                   upTo: 4, force: true)
    check("a second of quiet settles it to black", settled2)
    check("the words are the same, only now they are settled",
          stopped.frozen == "and that is the last thing I wanted to say"
          && stopped.live.isEmpty, stopped.frozen)
    check("nothing is left grey to wonder about", stopped.liveWordCount == 0)

    // Once those words are settled, a long remaining pause belongs to neither
    // the old phrase nor the next one. Keeping the boundary beside the live
    // recorder lets the next word appear in grey without re-hearing the pause.
    let stoppedText = stopped.full
    stopped.skipIdleSilence(to: 30)
    check("idle silence advances the next preview boundary",
          stopped.frozenUntil == 30, "\(stopped.frozenUntil)")
    check("advancing silence never changes settled words",
          stopped.full == stoppedText, stopped.full)

    // A short phrase followed by silence must be heard even when no earlier
    // preview pass produced grey words. This is the reported "it waits for my
    // next word" defect in one deterministic assertion.
    check("a spoken short phrase flushes during the following pause",
          shouldSettlePreview(modern: true, quiet: true, quietFor: 0.9,
                              sawSpeech: true, hasLiveWords: false))
    check("room silence alone never asks the ears for a word",
          !shouldSettlePreview(modern: true, quiet: true, quietFor: 2.0,
                               sawSpeech: false, hasLiveWords: false))
    check("the reversible old preview keeps its original rule",
          !shouldSettlePreview(modern: false, quiet: true, quietFor: 2.0,
                               sawSpeech: true, hasLiveWords: false))

    // Once edited, the box is the source of truth. Final tail hearing may add
    // new words, but it cannot rewrite the correction.
    let edited = EditableDraft()
    edited.userChanged(text: "Send it on Thursday", at: 4.0)
    edited.updateLive("after lunch")
    check("speech after a keyboard edit appears as a grey tail",
          edited.displayed == "Send it on Thursday after lunch")
    let editedFinal = edited.snapshot().finalText(tail: "after lunch please")
    check("the final tail preserves the keyboard correction",
          editedFinal == "Send it on Thursday after lunch please", editedFinal)

    let replaced = EditableDraft()
    let original = "Send it on Friday after lunch"
    let friday = (original as NSString).range(of: "Friday")
    replaced.selected(text: original, range: friday, at: 3.0)
    replaced.noteVoiceSpeech()
    let correction = replaced.snapshot().finalText(tail: "Thursday")
    check("spoken words replace the selected word",
          correction == "Send it on Thursday after lunch", correction)
    check("a spoken replacement is not also appended",
          correction.components(separatedBy: "Thursday").count == 2, correction)

    let untouchedSelection = EditableDraft()
    untouchedSelection.selected(text: original, range: friday, at: 3.0)
    check("selecting without speaking changes nothing on send",
          untouchedSelection.snapshot().finalText(tail: nil) == original)

    let liveReplacement = EditableDraft()
    liveReplacement.selected(text: original, range: friday, at: 3.0)
    liveReplacement.noteVoiceSpeech()
    liveReplacement.replaceSelection(with: "Thursday", at: 4.2)
    liveReplacement.updateLive("please")
    check("dictation continues after a spoken correction",
          liveReplacement.displayed == "Send it on Thursday after lunch please",
          liveReplacement.displayed)

    let waitingCorrection = EditableDraft()
    waitingCorrection.selected(text: original, range: friday, at: 3.0)
    waitingCorrection.skipIdleSilence(to: 22.0)
    check("silence before a spoken correction is skipped",
          waitingCorrection.snapshot().audioFrom == 22.0)
    waitingCorrection.noteVoiceSpeech()
    waitingCorrection.skipIdleSilence(to: 30.0)
    check("the correction boundary freezes as soon as speech begins",
          waitingCorrection.snapshot().audioFrom == 22.0)

    check("a stable caret prefix uses NSTextView UTF-16 offsets",
          commonComposedPrefixLength("hello world", "hello there") == 6)
    check("the caret prefix never splits a composed character",
          commonComposedPrefixLength("👍🏽 ready", "👍🏽 really")
              == ("👍🏽 rea" as NSString).length)
    check("Command-A reaches Select All without an Edit menu",
          reviewShortcut(key: "a", modifiers: [.command]) == .selectAll)
    check("Command-C/X/V reach the native editing actions",
          reviewShortcut(key: "c", modifiers: [.command]) == .copy
          && reviewShortcut(key: "x", modifiers: [.command]) == .cut
          && reviewShortcut(key: "v", modifiers: [.command]) == .paste)
    check("Command-Z and Command-Shift-Z preserve undo and redo",
          reviewShortcut(key: "z", modifiers: [.command]) == .undo
          && reviewShortcut(key: "z", modifiers: [.command, .shift]) == .redo)
    check("nonstandard Command-Option shortcuts stay with AppKit",
          reviewShortcut(key: "a", modifiers: [.command, .option]) == nil)

    let copiedSelection = EditableDraft()
    copiedSelection.selected(text: original, range: friday, at: 3.0)
    copiedSelection.userChanged(text: original, at: 3.2) // keyboard command boundary
    copiedSelection.updateLive("and keep talking")
    check("a keyboard command disarms spoken replacement",
          copiedSelection.snapshot().voiceSelection == nil)
    check("speech after copying a selection appends instead of replacing it",
          copiedSelection.displayed == original + " and keep talking",
          copiedSelection.displayed)

    // The gap-fillers the ears invent over a pause. MEASURED: 0.8 s of his own
    // room noise becomes "Okay." at every loudness from -50 dB to -36 dB.
    check("a lone 'Okay.' is a gap-filler", Text.isJustBackchannel("Okay."))
    check("so is 'Yeah'", Text.isJustBackchannel("Yeah"))
    check("so is 'yeah.' with punctuation", Text.isJustBackchannel("yeah."))
    check("so is 'mm-hmm'", Text.isJustBackchannel("mm-hmm"))
    check("so is 'Thank you'", Text.isJustBackchannel("Thank you"))
    check("an empty hearing counts as one too", Text.isJustBackchannel("   "))
    check("a real sentence is NOT a gap-filler",
          !Text.isJustBackchannel("Okay, so the main thing is this."))
    check("a sentence that merely starts with one is kept",
          !Text.isJustBackchannel("Yeah I think we should ship it"))
    check("his actual words are never mistaken for a filler",
          !Text.isJustBackchannel("We keep the parts that work"))

    // The ramble pass's honesty rail. Deterministic — the model never gets
    // a vote: cleaned text must be his words, his order, deletions only.
    let ramble = "So um I was thinking, you know, we should we should ship "
               + "the the report on Friday, no wait, on Thursday actually."
    check("deleting fillers and repeats passes the rail",
          Rambler.deletionOnly(cleaned: "I was thinking we should ship the "
                               + "report on Thursday.", raw: ramble))
    check("an added word fails the rail",
          !Rambler.deletionOnly(cleaned: "We should definitely ship the "
                                + "report on Thursday.", raw: ramble))
    check("a changed word fails the rail",
          !Rambler.deletionOnly(cleaned: "We should send the report on "
                                + "Thursday.", raw: ramble))
    check("reordered words fail the rail",
          !Rambler.deletionOnly(cleaned: "On Thursday we should ship the "
                                + "report.", raw: ramble))
    check("a finished sentence he did not finish fails the rail",
          !Rambler.deletionOnly(cleaned: "We should ship the report on "
                                + "Thursday and Friday too.", raw: ramble))
    check("re-punctuating and re-capitalizing is allowed",
          Rambler.deletionOnly(cleaned: "we should ship the report, on "
                               + "thursday", raw: ramble))
    check("an empty cleaning fails the rail",
          !Rambler.deletionOnly(cleaned: "   ", raw: ramble))
    check("curly and straight apostrophes are the same word",
          Rambler.deletionOnly(cleaned: "it's done", raw: "it\u{2019}s uh done"))
    check("the rail's word view drops edge punctuation only",
          Rambler.tokens("Well, it's -- it's done.") ==
          ["well", "it's", "it's", "done"])

    // The loudness gate that stops the strip inventing words over a silence.
    // MEASURED on his headset: the quiet room is -50.1 dB, his speech averages
    // -20.6 dB, and the quietest half-second inside real speech is -41.4 dB.
    // The gate sits at -45: above the room, below his quietest speech.
    var silence = Data(count: 16000 * 2)                   // one second of nothing
    check("a silent second reads as silence", Recorder.level(of: silence) < -45,
          String(format: "%.1f dB", Recorder.level(of: silence)))
    var speech = Data()
    for i in 0..<16000 {                                   // a second of speech-level tone
        let v = Int16(sin(Double(i) * 0.07) * 6000)
        withUnsafeBytes(of: v.littleEndian) { speech.append(contentsOf: $0) }
    }
    check("speech-level sound reads as speech", Recorder.level(of: speech) > -45,
          String(format: "%.1f dB", Recorder.level(of: speech)))
    let gate: Double = -45, room: Double = -50.1, spoke: Double = -20.6, quietest: Double = -41.4
    check("his measured room level would be gated", room < gate)
    check("his measured speech would not be gated", spoke > gate)
    check("even his quietest speech stays above the gate", quietest > gate)

    // Focus protection. On 2026-08-20 at 17:09:42, 292 characters went into a
    // macOS crash dialog that had taken focus, and were lost.
    check("same app in front means type as normal",
          Focus.moved(openedPid: 501, nowPid: 501) == false)
    check("a different app in front means DO NOT type",
          Focus.moved(openedPid: 501, nowPid: 902) == true)
    check("no app in front at all counts as moved — that is a dialog's shape",
          Focus.moved(openedPid: 501, nowPid: nil) == true)
    check("not knowing where he started is not a reason to refuse",
          Focus.moved(openedPid: nil, nowPid: 902) == false)

    // Typing goes through one seam, so the tests can watch it.
    var keystrokes: [String] = []
    Keys.testHook = { keystrokes.append($0) }
    Keys.type("hello there")
    check("typing reaches the keyboard seam", keystrokes.joined() == "hello there")
    keystrokes = []
    Keys.type("")
    check("typing nothing presses nothing", keystrokes.isEmpty)
    Keys.tapReturn()
    check("Enter is a keystroke too", keystrokes == ["\n"])
    Keys.testHook = nil

    // Settings survive a round trip, and a missing key keeps its default.
    if CONFIG_PATH.path.hasSuffix("state/config.json") {
        print("  skip  settings round-trip (would write the live file; "
              + "re-run with K_PTT_CONFIG=/tmp/x.json)")
    } else {
        var probe = Config(); probe.pressReturnAfterTyping = false; probe.save()
        check("settings round-trip", Config.load().pressReturnAfterTyping == false)
        try? "{\"enabled\":false}".write(to: CONFIG_PATH, atomically: true, encoding: .utf8)
        let partial = Config.load()
        check("a hand-edited file keeps every other default",
              partial.enabled == false && partial.pressReturnAfterTyping == true
              && partial.interactiveReview == true
              && partial.livePreviewIntervalMs == 300
              && partial.micDeviceName.isEmpty && !partial.requireHeadset
              && partial.maxOpenSeconds == 600)
        try? FileManager.default.removeItem(at: CONFIG_PATH)
    }

    let journalTestRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    do {
        let entryID = UUID(); let when = Date(timeIntervalSince1970: 1791200000)
        let path = try JournalStore.save("First thought — café.", root: journalTestRoot, date: when, id: entryID)
        _ = try JournalStore.save("First thought — café.", root: journalTestRoot, date: when, id: entryID)
        _ = try JournalStore.save("Second thought.", root: journalTestRoot, date: when)
        let entries = try String(contentsOf: path, encoding: .utf8)
        check("journal append retains earlier entries and Unicode", entries.contains("First thought — café.") && entries.contains("Second thought."))
        check("retry does not duplicate a journal entry", entries.components(separatedBy: "First thought — café.").count == 2)
        let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
        check("journal entries are owner-only", attributes[.posixPermissions] as? Int == 0o600)
        let tomorrow = try JournalStore.save("Tomorrow.", root: journalTestRoot, date: when.addingTimeInterval(86400))
        check("journal separates days", tomorrow != path)
        let audioID = UUID(); let sample = Recorder.wav(Data(repeating: 0, count: 32000), rate: 16000)
        let paired = try JournalStore.save("Paired recording.", root: journalTestRoot, date: when, id: audioID, audio: sample)
        _ = try JournalStore.save("Paired recording.", root: journalTestRoot, date: when, id: audioID, audio: sample)
        let audioFolder = paired.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("audio")
        let recording = audioFolder.appendingPathComponent(audioID.uuidString + ".wav")
        check("journal preserves WAV and links paired audio", try Data(contentsOf: recording) == sample && String(contentsOf: paired, encoding: .utf8).contains("../audio/" + recording.lastPathComponent))
        check("journal recording is owner-only", try FileManager.default.attributesOfItem(atPath: recording.path)[.posixPermissions] as? Int == 0o600)
        check("journal audio retry is idempotent", try FileManager.default.contentsOfDirectory(atPath: audioFolder.path).count == 1)

        check("teleprompter follows spoken text", TeleprompterProgress.wordsRead(expected: ["Hello", "MyF5", "I’m", "teaching", "you"], heard: "Hello MyF5 I'm teaching") == 4)
    check("teleprompter does not advance on silence", TeleprompterProgress.wordsRead(expected: ["Hello", "MyF5", "I’m"], heard: "") == 0)
    check("teleprompter tolerates a missed word", TeleprompterProgress.wordsRead(expected: ["The", "blue", "notebook", "is", "on", "the", "table"], heard: "The notebook is on the table") == 7)
    check("journal uses year month day folders", path.lastPathComponent == "journal.md" && path.pathComponents.suffix(6).first == "Journal" && path.deletingLastPathComponent().lastPathComponent == "text")
    } catch { check("journal storage succeeds", false, error.localizedDescription) }
    try? FileManager.default.removeItem(at: journalTestRoot)

    print(failures == 0 ? "\nall tests passed" : "\n\(failures) FAILED")
    exit(failures == 0 ? 0 : 1)

case "-h", "--help", "help":
    usage(); exit(0)

case "run":
    break

default:
    usage(); exit(2)
}

setvbuf(stdout, nil, _IOLBF, 0)
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let helper = Helper()
helper.run()
app.run()
