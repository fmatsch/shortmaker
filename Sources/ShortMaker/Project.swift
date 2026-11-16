import Foundation
import AVFoundation
import SwiftUI
import Combine

/// Abspielposition – eigenes Objekt, damit nicht die ganze Oberfläche 30-mal pro Sekunde neu gezeichnet wird.
@MainActor
final class Playhead: ObservableObject {
    @Published var frame = 0
    @Published var playing = false
}

@MainActor
final class Project: ObservableObject {
    // Quelle
    @Published var url: URL?
    @Published var loading = false
    @Published var errorMessage: String?
    private(set) var asset: AVAsset?
    private(set) var frameDuration = CMTime(value: 1, timescale: 30)
    private(set) var fps = 30.0
    private(set) var totalFrames = 0
    private(set) var sourceSize = CGSize(width: 1920, height: 1080)
    @Published var filmstrip: [NSImage] = []

    // Schritt 1
    @Published var step: Step = .select { didSet { stepChanged(from: oldValue) } }
    @Published var markIn: Int?
    @Published var markOut: Int?
    @Published var clips: [Clip] = [] { didSet { clipsChanged(old: oldValue) } }
    @Published var thumbs: [UUID: NSImage] = [:]

    // Schritt 2 / 3
    @Published var tracking: [UUID: Double] = [:]
    @Published var titles: [TitleItem] = [] { didSet { pushState() } }
    @Published var selectedTitle: UUID?
    @Published var words: [Word] = []
    @Published var cues: [SubtitleCue] = [] { didSet { pushState() } }
    @Published var subStyle = SubtitleStyle() { didSet { subStyleChanged(old: oldValue) } }
    @Published var subtitlesStale = false
    @Published var language = "de"
    @Published var whisperProgress: Double?
    @Published var whisperStatus = ""
    @Published var whisperAvailable = Transcriber.isAvailable

    // Export
    @Published var exportProgress: Double?
    @Published var exportedURL: URL?
    private var exportTask: Task<Void, Never>?

    let sourcePlayer = AVPlayer()
    let shortPlayer = AVPlayer()
    let sourceHead = Playhead()
    let shortHead = Playhead()
    let renderState = RenderState()
    private(set) var composition: AVMutableComposition?
    private var observers: [Any] = []
    private var cancellables: Set<AnyCancellable> = []
    private var seekTarget: [ObjectIdentifier: CMTime] = [:]
    private var seeking: Set<ObjectIdentifier> = []
    private var trackTasks: [UUID: Task<Void, Never>] = [:]
    private let transcriber = Transcriber()
    private var imageGenerator: AVAssetImageGenerator?

    init() {
        let interval = CMTime(value: 1, timescale: 60)
        observers.append(sourcePlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] t in
            MainActor.assumeIsolated { self?.tick(self?.sourcePlayer, self?.sourceHead, t) }
        })
        observers.append(shortPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] t in
            MainActor.assumeIsolated { self?.tick(self?.shortPlayer, self?.shortHead, t) }
        })
        shortPlayer.actionAtItemEnd = .pause
        sourcePlayer.actionAtItemEnd = .pause
    }

    private func tick(_ player: AVPlayer?, _ head: Playhead?, _ t: CMTime) {
        guard let player, let head else { return }
        let f = Int((t.seconds / frameDuration.seconds + 0.01).rounded(.down))
        if f != head.frame, !seeking.contains(ObjectIdentifier(player)) { head.frame = max(0, f) }
        let playing = player.rate != 0
        if playing != head.playing { head.playing = playing }
    }

    // MARK: Laden

    func open(_ url: URL) {
        loading = true; errorMessage = nil
        Task {
            do {
                let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
                guard let vt = try await asset.loadTracks(withMediaType: .video).first else { throw CocoaError(.fileReadCorruptFile) }
                let (natural, transform, rate, duration) = try await (vt.load(.naturalSize), vt.load(.preferredTransform), vt.load(.nominalFrameRate), asset.load(.duration))
                let size = natural.applying(transform)
                reset()
                self.asset = asset
                self.url = url
                sourceSize = CGSize(width: abs(size.width), height: abs(size.height))
                frameDuration = Composer.frameDuration(fps: rate)
                fps = 1 / frameDuration.seconds
                totalFrames = max(1, Int((duration.seconds / frameDuration.seconds).rounded(.down)))
                sourcePlayer.replaceCurrentItem(with: AVPlayerItem(asset: asset))
                let gen = AVAssetImageGenerator(asset: asset)
                gen.appliesPreferredTrackTransform = true
                gen.maximumSize = CGSize(width: 320, height: 320)
                gen.requestedTimeToleranceBefore = .zero; gen.requestedTimeToleranceAfter = .zero
                imageGenerator = gen
                loading = false
                await loadFilmstrip(asset)
            } catch {
                loading = false
                errorMessage = "Das Video konnte nicht geladen werden: \(error.localizedDescription)"
            }
        }
    }

    private func reset() {
        sourcePlayer.pause(); shortPlayer.pause()
        shortPlayer.replaceCurrentItem(with: nil)
        trackTasks.values.forEach { $0.cancel() }; trackTasks = [:]
        composition = nil
        clips = []; titles = []; words = []; cues = []; thumbs = [:]; filmstrip = []; tracking = [:]
        markIn = nil; markOut = nil; selectedTitle = nil; subtitlesStale = false; exportedURL = nil
        sourceHead.frame = 0; shortHead.frame = 0
        step = .select
    }

    private func loadFilmstrip(_ asset: AVAsset) async {
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 160, height: 160)
        let n = 24
        var images: [NSImage] = []
        for i in 0..<n {
            let t = Composer.time(frame: totalFrames * i / n, frameDuration)
            guard let cg = try? await gen.image(at: t).image, self.asset === asset else { return }
            images.append(NSImage(cgImage: cg, size: .zero))
            filmstrip = images
        }
    }

    // MARK: Wiedergabe

    func player(for step: Step) -> AVPlayer { step == .select ? sourcePlayer : shortPlayer }
    var activePlayer: AVPlayer { player(for: step) }
    var activeHead: Playhead { step == .select ? sourceHead : shortHead }
    var activeFrames: Int { step == .select ? totalFrames : shortFrames }
    var shortFrames: Int { clips.reduce(0) { $0 + $1.frames } }

    func togglePlay() {
        let p = activePlayer
        if p.rate != 0 { p.pause(); seek(activeHead.frame); return }
        if activeHead.frame >= activeFrames - 1 { seek(0) }
        p.play()
    }

    /// Bildgenaues Springen; bei schnellem Ziehen wird nur das jeweils letzte Ziel angefahren.
    func seek(_ frame: Int, on step: Step? = nil) {
        let step = step ?? self.step
        let p = player(for: step), head = step == .select ? sourceHead : shortHead
        let max = (step == .select ? totalFrames : shortFrames) - 1
        let f = Swift.min(Swift.max(0, frame), Swift.max(0, max))
        head.frame = f
        let id = ObjectIdentifier(p)
        seekTarget[id] = Composer.time(frame: f, frameDuration)
        if !seeking.contains(id) { runSeek(p) }
    }

    private func runSeek(_ p: AVPlayer) {
        let id = ObjectIdentifier(p)
        guard let t = seekTarget[id] else { seeking.remove(id); return }
        seekTarget[id] = nil
        seeking.insert(id)
        p.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in self?.runSeek(p) }
        }
    }

    func stepFrames(_ delta: Int) {
        activePlayer.pause()
        seek(activeHead.frame + delta)
    }

    // MARK: Schritt 1 – Bereiche

    func setIn() { markIn = sourceHead.frame; if let o = markOut, o <= sourceHead.frame { markOut = nil } }
    func setOut() { markOut = sourceHead.frame + 1; if let i = markIn, i >= sourceHead.frame + 1 { markIn = nil } }
    var canAddClip: Bool { if let i = markIn, let o = markOut { return o > i } else { return false } }

    func addClip() {
        guard let i = markIn, let o = markOut, o > i else { return }
        clips.append(Clip(start: i, end: o))
        markIn = nil; markOut = nil
    }

    func loadThumb(_ clip: Clip) {
        guard let gen = imageGenerator else { return }
        let id = clip.id, t = Composer.time(frame: clip.start, frameDuration)
        Task { if let cg = try? await gen.image(at: t).image { thumbs[id] = NSImage(cgImage: cg, size: .zero) } }
    }

    private func clipsChanged(old: [Clip]) {
        for c in clips where old.first(where: { $0.id == c.id })?.start != c.start { loadThumb(c) }
        let structure = { (cs: [Clip]) in cs.map { "\($0.id)-\($0.start)-\($0.end)" } }
        if structure(old) != structure(clips) {
            if !words.isEmpty { subtitlesStale = true }
            if step != .select { Task { await rebuildShort() } }
        }
        for c in clips where c.framing.mode == .track && !c.isTracked && trackTasks[c.id] == nil { startTracking(c) }
        pushState()
    }

    // MARK: Schritt 2 – Short

    private func stepChanged(from old: Step) {
        guard step != old else { return }
        sourcePlayer.pause(); shortPlayer.pause()
        if old == .select { Task { await rebuildShort() } }
    }

    func rebuildShort() async {
        guard let asset, !clips.isEmpty else { shortPlayer.replaceCurrentItem(with: nil); composition = nil; return }
        do {
            let comp = try await Composer.composition(asset: asset, clips: clips, frameDuration: frameDuration)
            composition = comp
            pushState()
            let item = AVPlayerItem(asset: comp)
            item.videoComposition = Composer.videoComposition(for: comp, frameDuration: frameDuration, state: renderState)
            let keep = min(shortHead.frame, max(0, shortFrames - 1))
            shortPlayer.replaceCurrentItem(with: item)
            seek(keep, on: .format)
        } catch { errorMessage = "Die Zeitleiste konnte nicht aufgebaut werden: \(error.localizedDescription)" }
    }

    var snapshot: RenderSnapshot {
        var s = RenderSnapshot(fps: fps, titles: titles, cues: cues, subStyle: subStyle)
        var at = 0
        for c in clips where c.frames > 0 { s.clips.append(.init(tlStart: at, clip: c)); at += c.frames }
        return s
    }

    /// Aktuellen Stand an den Render-Thread geben und das stehende Vorschaubild neu zeichnen.
    func pushState() {
        renderState.snapshot = snapshot
        if shortPlayer.rate == 0, let item = shortPlayer.currentItem, let vc = item.videoComposition {
            item.videoComposition = vc.mutableCopy() as? AVVideoComposition
        }
    }

    /// Clip unter der Abspielposition der Short-Zeitleiste.
    func clipIndex(atShortFrame f: Int) -> Int? {
        var at = 0
        for (i, c) in clips.enumerated() { if f < at + c.frames { return i }; at += c.frames }
        return clips.isEmpty ? nil : clips.count - 1
    }

    func shortStart(ofClip index: Int) -> Int { clips[..<index].reduce(0) { $0 + $1.frames } }

    func startTracking(_ clip: Clip) {
        guard let asset else { return }
        let id = clip.id, fd = frameDuration, start = clip.start, frames = clip.frames
        tracking[id] = 0
        trackTasks[id] = Task {
            let result = try? await Tracker.track(asset: asset, start: start, frames: frames, frameDuration: fd) { p in
                Task { @MainActor [weak self] in if self?.tracking[id] != nil { self?.tracking[id] = p } }
            }
            trackTasks[id] = nil
            tracking[id] = nil
            guard let i = clips.firstIndex(where: { $0.id == id }) else { return }
            if let result, !result.isEmpty { clips[i].track = result; clips[i].trackStart = start }
            else if !Task.isCancelled { clips[i].framing.mode = .manual; errorMessage = "Die Personenverfolgung ist fehlgeschlagen." }
        }
    }

    // MARK: Schritt 3 – Untertitel

    private func subStyleChanged(old: SubtitleStyle) {
        if old.wordsPerCue != subStyle.wordsPerCue, !words.isEmpty { cues = Subtitles.cues(from: words, perCue: subStyle.wordsPerCue) }
        else { pushState() }
    }

    func downloadWhisper() {
        whisperProgress = 0; whisperStatus = "Whisper-Modell wird geladen …"
        Task {
            do {
                try await Transcriber.download { p in Task { @MainActor [weak self] in self?.whisperProgress = p } }
                whisperAvailable = Transcriber.isAvailable
                whisperStatus = ""
            } catch { whisperStatus = "Laden fehlgeschlagen: \(error.localizedDescription)" }
            whisperProgress = nil
        }
    }

    func generateSubtitles() {
        guard let comp = composition else { return }
        whisperProgress = 0; whisperStatus = "Ton wird vorbereitet …"
        let lang = language
        Task {
            do {
                let samples = try await Transcriber.samples(from: comp)
                guard !samples.isEmpty else { throw CocoaError(.fileReadNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "Das Video hat keine Tonspur."]) }
                whisperStatus = "Whisper wird vorbereitet – beim allerersten Mal dauert das einige Minuten …"
                let w = try await transcriber.transcribe(samples: samples, language: lang) { p in
                    Task { @MainActor [weak self] in self?.whisperProgress = p; self?.whisperStatus = "Sprache wird erkannt …" }
                }
                words = w
                cues = Subtitles.cues(from: w, perCue: subStyle.wordsPerCue)
                subtitlesStale = false
                whisperStatus = w.isEmpty ? "Keine Sprache erkannt." : ""
            } catch { whisperStatus = "Fehler: \(error.localizedDescription)" }
            whisperProgress = nil
        }
    }

    func addTitle() {
        var t = TitleItem()
        t.y = 0.16 + 0.08 * Double(titles.count % 4)
        t.end = min(3, Double(shortFrames) / fps)
        titles.append(t)
        selectedTitle = t.id
    }

    // MARK: Export

    func export(to url: URL, quality: Exporter.Quality, hevc: Bool) {
        guard let comp = composition else { return }
        shortPlayer.pause()
        exportProgress = 0; exportedURL = nil
        let snap = snapshot, fd = frameDuration
        exportTask = Task {
            do {
                try await Exporter.export(composition: comp, frameDuration: fd, snapshot: snap, quality: quality, hevc: hevc, to: url) { p in
                    Task { @MainActor [weak self] in if self?.exportProgress != nil { self?.exportProgress = p } }
                }
                exportedURL = url
            } catch is CancellationError {
            } catch { errorMessage = "Export fehlgeschlagen: \(error.localizedDescription)" }
            exportProgress = nil
        }
    }

    func cancelExport() { exportTask?.cancel() }

    // MARK: Demo

    /// Für Tests und Bildschirmfotos:  ShortMaker --demo <video> <1|2|3>  lädt ein Video und legt Beispiel-Clips an.
    func runDemoIfRequested() async {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--demo"), a.count > i + 2, let target = Int(a[i + 2]) else { return }
        open(URL(fileURLWithPath: a[i + 1]))
        while loading || asset == nil { try? await Task.sleep(nanoseconds: 100_000_000) }
        let s = Int(fps)
        clips = [Clip(start: s, end: 4 * s), Clip(start: 9 * s, end: 12 * s), Clip(start: 5 * s, end: 7 * s)].filter { $0.end <= totalFrames }
        if clips.count > 1 { clips[1].framing = Framing(mode: .manual, centerX: 0.7, centerY: 0.5, zoom: 1.3) }
        markIn = 13 * s; markOut = 15 * s
        seek(13 * s + 12)
        guard target > 1 else { return }
        step = .format
        while composition == nil { try? await Task.sleep(nanoseconds: 100_000_000) }
        clips[0].framing.mode = .track
        seek(s)
        guard target > 2 else { return }
        step = .text
        addTitle(); titles[0].text = "So geht\nShortMaker"
        if whisperAvailable { generateSubtitles() }
        seek(2 * s)
    }
}
