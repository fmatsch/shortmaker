import Foundation
import AVFoundation
import CoreImage
import CoreML
import Vision
import WhisperKit

// MARK: - Modelle finden

enum ModelLocator {
    static var supportDirectory: URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("ShortMaker", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func url(_ relative: String) -> URL? {
        var candidates: [URL] = []
        if let res = Bundle.main.resourceURL { candidates.append(res.appendingPathComponent("Models")) }
        candidates.append(supportDirectory.appendingPathComponent("Models"))
        candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Models"))
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        candidates.append(exe.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Models"))
        return candidates.map { $0.appendingPathComponent(relative) }.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}

// MARK: - Zeitleiste zusammensetzen

enum Composer {
    static func frameDuration(fps: Float) -> CMTime {
        for (rate, d) in [(23.976, CMTime(value: 1001, timescale: 24000)), (29.97, CMTime(value: 1001, timescale: 30000)), (59.94, CMTime(value: 1001, timescale: 60000))]
        where abs(Double(fps) - rate) < 0.01 { return d }
        let r = max(1, Int32(fps.rounded()))
        return abs(fps - Float(r)) < 0.01 ? CMTime(value: 1, timescale: r) : CMTime(seconds: 1 / Double(max(fps, 1)), preferredTimescale: 90000)
    }

    static func time(frame: Int, _ fd: CMTime) -> CMTime { CMTimeMultiply(fd, multiplier: Int32(frame)) }

    /// Reiht die gewählten Bereiche bildgenau aneinander (Bild und Ton).
    static func composition(asset: AVAsset, clips: [Clip], frameDuration fd: CMTime) async throws -> AVMutableComposition {
        let comp = AVMutableComposition()
        guard let vSrc = try await asset.loadTracks(withMediaType: .video).first,
              let v = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw CocoaError(.fileReadCorruptFile) }
        v.preferredTransform = try await vSrc.load(.preferredTransform)
        let aSrc = try await asset.loadTracks(withMediaType: .audio).first
        let a = aSrc == nil ? nil : comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        var at = CMTime.zero
        for c in clips where c.frames > 0 {
            let range = CMTimeRange(start: time(frame: c.start, fd), duration: time(frame: c.frames, fd))
            try v.insertTimeRange(range, of: vSrc, at: at)
            if let aSrc, let a { try? a.insertTimeRange(range, of: aSrc, at: at) }
            at = at + range.duration
        }
        return comp
    }

    /// Dieselbe Bildkette für Vorschau und Export.
    static func videoComposition(for comp: AVAsset, frameDuration fd: CMTime, state: RenderState, enhance: ((CIImage) -> CIImage?)? = nil) -> AVVideoComposition {
        let vc = AVMutableVideoComposition(asset: comp) { request in
            let img = Renderer.frame(source: request.sourceImage, time: request.compositionTime.seconds, snap: state.snapshot, enhance: enhance)
            request.finish(with: img, context: nil)
        }
        vc.renderSize = ShortFormat.size
        vc.frameDuration = fd
        return vc
    }
}

// MARK: - Personen verfolgen

enum Tracker {
    /// Bildmitte der Hauptperson für jedes Bild des Bereichs (x von links, y von oben, 0…1), geglättet.
    static func track(asset: AVAsset, start: Int, frames: Int, frameDuration fd: CMTime, progress: @escaping @Sendable (Double) -> Void) async throws -> [CGPoint] {
        guard frames > 0, let vt = try await asset.loadTracks(withMediaType: .video).first else { return [] }
        let size = try await vt.load(.naturalSize).applying(try await vt.load(.preferredTransform))
        let ar = abs(size.height) / max(1, abs(size.width))
        let w = 480, h = max(2, Int((480 * ar).rounded()) & ~1)
        let vc = AVMutableVideoComposition(propertiesOf: asset)   // richtet gedrehte Aufnahmen auf
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderVideoCompositionOutput(videoTracks: [vt], videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
        ])
        out.videoComposition = vc
        out.alwaysCopiesSampleData = false
        reader.add(out)
        reader.timeRange = CMTimeRange(start: Composer.time(frame: start, fd), duration: Composer.time(frame: frames, fd))
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }

        let fps = 1 / max(fd.seconds, 0.001)
        let step = max(1, Int(fps / 10))
        var raw: [CGPoint?] = [], cuts: Set<Int> = []
        var prevLuma = -1.0, last: CGPoint?, index = 0
        while let sb = out.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
            let l = meanLuma(pb)
            if prevLuma >= 0, abs(l - prevLuma) > 0.14 { cuts.insert(index); last = nil }   // harter Schnitt im Material
            prevLuma = l
            var found: CGPoint?
            if index % step == 0 || cuts.contains(index) {
                let faces = VNDetectFaceRectanglesRequest(), humans = VNDetectHumanRectanglesRequest()
                humans.upperBodyOnly = false
                try? VNImageRequestHandler(cvPixelBuffer: pb, options: [:]).perform([faces, humans])
                var cands = (faces.results ?? []).map { (CGPoint(x: $0.boundingBox.midX, y: 1 - $0.boundingBox.midY), Double($0.boundingBox.width * $0.boundingBox.height)) }
                if cands.isEmpty {   // kein Gesicht: Körper nehmen, Kopfhöhe schätzen
                    cands = (humans.results ?? []).map { (CGPoint(x: $0.boundingBox.midX, y: 1 - ($0.boundingBox.maxY - $0.boundingBox.height * 0.2)), Double($0.boundingBox.width * $0.boundingBox.height) * 0.4) }
                }
                // größte Person, aber der bisherigen treu bleiben
                func score(_ c: (CGPoint, Double)) -> Double {
                    guard let l = last else { return c.1 }
                    return c.1 / (1 + 4 * Double(hypot(c.0.x - l.x, c.0.y - l.y)))
                }
                if let best = cands.max(by: { score($0) < score($1) }) { found = best.0; last = found }
            }
            raw.append(found)
            index += 1
            if index % 15 == 0 { progress(min(1, Double(index) / Double(frames))) }
        }
        while raw.count < frames { raw.append(nil) }
        progress(1)

        // Lücken füllen (halten, am Abschnittsanfang rückwärts), dann glätten – je Abschnitt zwischen Schnitten
        var xs = [Double](repeating: 0.5, count: raw.count), ys = xs
        var bounds = [0] + cuts.sorted() + [raw.count]
        bounds = Array(Set(bounds)).sorted()
        for (a, b) in zip(bounds, bounds.dropFirst()) where b > a {
            let first = (a..<b).first { raw[$0] != nil }.flatMap { raw[$0] } ?? CGPoint(x: 0.5, y: 0.4)
            var cur = first
            for i in a..<b { if let p = raw[i] { cur = p }; xs[i] = cur.x; ys[i] = cur.y }
            let r = max(2, Int(fps * 0.5))
            for _ in 0..<3 { smooth(&xs, a, b, r); smooth(&ys, a, b, r) }
        }
        return (0..<raw.count).map { CGPoint(x: xs[$0], y: ys[$0]) }
    }

    private static func smooth(_ v: inout [Double], _ a: Int, _ b: Int, _ r: Int) {
        var prefix = [0.0]
        for i in a..<b { prefix.append(prefix.last! + v[i]) }
        for i in a..<b {
            let lo = max(a, i - r), hi = min(b - 1, i + r)
            v[i] = (prefix[hi - a + 1] - prefix[lo - a]) / Double(hi - lo + 1)
        }
    }

    private static func meanLuma(_ pb: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), bpr = CVPixelBufferGetBytesPerRow(pb)
        guard let raw = CVPixelBufferGetBaseAddress(pb) else { return 0 }
        let base = raw.assumingMemoryBound(to: UInt8.self)
        var sum = 0.0, n = 0.0
        for y in stride(from: 0, to: h, by: 4) { for x in stride(from: 0, to: w, by: 4) {
            let p = base + y * bpr + x * 4
            sum += 0.2126 * Double(p[2]) + 0.7152 * Double(p[1]) + 0.0722 * Double(p[0]); n += 1
        } }
        return sum / max(n, 1) / 255
    }
}

// MARK: - KI-Hochskalierung

/// 4×-Hochskalierung mit Real-ESRGAN (realesr-general-x4v3, Core ML, lokal), kachelweise mit Überlappung.
final class AIUpscaler: @unchecked Sendable {
    static let tile = 256, pad = 16, scale = 4
    static var isAvailable: Bool { ModelLocator.url("RealESRGAN/RealESRGAN-x4v3.mlpackage") != nil }
    private let model: MLModel
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let lock = NSLock()
    private let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    static func load() async throws -> AIUpscaler {
        guard let pkg = ModelLocator.url("RealESRGAN/RealESRGAN-x4v3.mlpackage") else { throw CocoaError(.fileNoSuchFile) }
        let compiled = ModelLocator.supportDirectory.appendingPathComponent("RealESRGAN-x4v3.mlmodelc")
        if !FileManager.default.fileExists(atPath: compiled.path) {
            let tmp = try await MLModel.compileModel(at: pkg)
            try? FileManager.default.removeItem(at: compiled)
            try FileManager.default.moveItem(at: tmp, to: compiled)
        }
        let cfg = MLModelConfiguration(); cfg.computeUnits = .all
        return AIUpscaler(model: try MLModel(contentsOf: compiled, configuration: cfg))
    }

    private init(model: MLModel) { self.model = model }

    /// Für die Bildkette: Ausschnitt (Ursprung 0/0) → 4-fach vergrößertes Bild.
    func enhance(_ image: CIImage) -> CIImage? {
        lock.lock(); defer { lock.unlock() }
        let w = Int(image.extent.width), h = Int(image.extent.height)
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
        guard let src = pb else { return nil }
        context.render(image, to: src, bounds: CGRect(x: 0, y: 0, width: w, height: h), colorSpace: srgb)
        guard let out = try? upscale4x(src) else { return nil }
        return CIImage(cvPixelBuffer: out, options: [.colorSpace: srgb])
    }

    func upscale4x(_ src: CVPixelBuffer) throws -> CVPixelBuffer {
        let w = CVPixelBufferGetWidth(src), h = CVPixelBufferGetHeight(src)
        let S = Self.scale, T = Self.tile, P = Self.pad, core = T - 2 * P
        var dst: CVPixelBuffer?
        CVPixelBufferCreate(nil, w * S, h * S, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &dst)
        guard let out = dst else { throw CocoaError(.fileWriteUnknown) }
        CVPixelBufferLockBaseAddress(src, .readOnly); CVPixelBufferLockBaseAddress(out, [])
        defer { CVPixelBufferUnlockBaseAddress(src, .readOnly); CVPixelBufferUnlockBaseAddress(out, []) }
        let sBase = CVPixelBufferGetBaseAddress(src)!.assumingMemoryBound(to: UInt8.self), sBpr = CVPixelBufferGetBytesPerRow(src)
        let dBase = CVPixelBufferGetBaseAddress(out)!.assumingMemoryBound(to: UInt8.self), dBpr = CVPixelBufferGetBytesPerRow(out)

        let input = try MLMultiArray(shape: [1, 3, NSNumber(value: T), NSNumber(value: T)], dataType: .float16)
        let inPtr = input.dataPointer.assumingMemoryBound(to: Float16.self)
        let plane = T * T
        var cy = 0
        while cy < h {
            var cx = 0
            while cx < w {
                for ty in 0..<T {   // Eingabekachel mit Randwiederholung (RGB, 0…1)
                    let sy = min(h - 1, max(0, cy - P + ty))
                    let row = sBase + sy * sBpr
                    for tx in 0..<T {
                        let px = row + min(w - 1, max(0, cx - P + tx)) * 4
                        let i = ty * T + tx
                        inPtr[i] = Float16(Float(px[2]) / 255)
                        inPtr[plane + i] = Float16(Float(px[1]) / 255)
                        inPtr[2 * plane + i] = Float16(Float(px[0]) / 255)
                    }
                }
                let res = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["input": MLFeatureValue(multiArray: input)]))
                guard let o = res.featureValue(for: "output")?.multiArrayValue else { throw CocoaError(.coderValueNotFound) }
                let st = o.strides.map(\.intValue)
                let isHalf = o.dataType == .float16
                let hp = o.dataPointer.assumingMemoryBound(to: Float16.self), fp = o.dataPointer.assumingMemoryBound(to: Float.self)
                @inline(__always) func val(_ c: Int, _ y: Int, _ x: Int) -> Float {
                    let idx = c * st[1] + y * st[2] + x * st[3]
                    return isHalf ? Float(hp[idx]) : fp[idx]
                }
                let cw = min(core, w - cx), ch = min(core, h - cy)
                for oy in 0..<(ch * S) {
                    let drow = dBase + (cy * S + oy) * dBpr
                    for ox in 0..<(cw * S) {
                        let ty = P * S + oy, tx = P * S + ox
                        let d = drow + (cx * S + ox) * 4
                        d[2] = UInt8(max(0, min(255, val(0, ty, tx) * 255 + 0.5)))
                        d[1] = UInt8(max(0, min(255, val(1, ty, tx) * 255 + 0.5)))
                        d[0] = UInt8(max(0, min(255, val(2, ty, tx) * 255 + 0.5)))
                        d[3] = 255
                    }
                }
                cx += core
            }
            cy += core
        }
        return out
    }
}

// MARK: - Whisper

final class Transcriber: @unchecked Sendable {
    static let variant = "openai_whisper-large-v3-v20240930_turbo_632MB"
    static var modelFolder: URL? {
        if let u = ModelLocator.url("whisper-large-v3-turbo") { return u }
        if let saved = UserDefaults.standard.string(forKey: "whisperFolder"), FileManager.default.fileExists(atPath: saved + "/AudioEncoder.mlmodelc") {
            return URL(fileURLWithPath: saved)
        }
        let dl = ModelLocator.supportDirectory.appendingPathComponent("Models/models/argmaxinc/whisperkit-coreml/\(variant)")
        return FileManager.default.fileExists(atPath: dl.appendingPathComponent("AudioEncoder.mlmodelc").path) ? dl : nil
    }
    static var isAvailable: Bool { modelFolder != nil }

    private var kit: WhisperKit?

    /// Lädt das Modell einmalig von Hugging Face (ca. 630 MB) nach Application Support.
    static func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        let base = ModelLocator.supportDirectory.appendingPathComponent("Models")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let folder = try await WhisperKit.download(variant: variant, downloadBase: base) { progress($0.fractionCompleted) }
        UserDefaults.standard.set(folder.path, forKey: "whisperFolder")
    }

    /// Ton der Zeitleiste als Mono-Float mit 16 kHz.
    static func samples(from asset: AVAsset) async throws -> [Float] {
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { return [] }
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(out)
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }
        var samples: [Float] = []
        while let sb = out.copyNextSampleBuffer(), let bb = CMSampleBufferGetDataBuffer(sb) {
            let len = CMBlockBufferGetDataLength(bb)
            var chunk = [Float](repeating: 0, count: len / 4)
            _ = chunk.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: len, destination: $0.baseAddress!) }
            samples += chunk
        }
        return samples
    }

    func transcribe(samples: [Float], language: String, progress: @escaping @Sendable (Double) -> Void) async throws -> [Word] {
        if kit == nil {
            guard let folder = Self.modelFolder else { throw CocoaError(.fileNoSuchFile) }
            kit = try await WhisperKit(WhisperKitConfig(modelFolder: folder.path, verbose: false, logLevel: .none, prewarm: false, load: true, download: false))
        }
        let duration = Double(samples.count) / 16000
        var opts = DecodingOptions(task: .transcribe, language: language == "auto" ? nil : language, temperature: 0,
                                   detectLanguage: language == "auto", wordTimestamps: true, chunkingStrategy: .vad)
        opts.skipSpecialTokens = true
        let results = try await kit!.transcribe(audioArray: samples, decodeOptions: opts, callback: nil) { segs in
            if let end = segs.last?.end { progress(min(1, Double(end) / max(duration, 1))) }
        }
        let clean = { (s: String) in s.replacingOccurrences(of: "<\\|[^|]*\\|>", with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines) }
        var words: [Word] = []
        for seg in results.flatMap(\.segments) {
            let ws = (seg.words ?? []).map { Word(text: clean($0.word), start: Double($0.start), end: Double($0.end)) }.filter { !$0.text.isEmpty }
            if ws.isEmpty {     // keine Wortzeiten: Segment gleichmäßig aufteilen
                let parts = clean(seg.text).split(separator: " ").map(String.init)
                let d = Double(seg.end - seg.start) / Double(max(parts.count, 1))
                words += parts.enumerated().map { Word(text: $1, start: Double(seg.start) + Double($0) * d, end: Double(seg.start) + Double($0 + 1) * d) }
            } else { words += ws }
        }
        // Satzzeichen ohne eigenes Wort an das vorige Wort hängen
        var merged: [Word] = []
        for w in words {
            if !merged.isEmpty, w.text.allSatisfy({ $0.isPunctuation }) { merged[merged.count - 1].text += w.text; merged[merged.count - 1].end = w.end }
            else { merged.append(w) }
        }
        return merged
    }
}

// MARK: - Export

enum Exporter {
    enum Quality: String, CaseIterable, Identifiable {
        case fast, ai
        var id: String { rawValue }
        var title: String { self == .fast ? "Schnell (Lanczos + Schärfen)" : "KI (Real-ESRGAN, langsam)" }
    }

    static func export(composition: AVAsset, frameDuration: CMTime, snapshot: RenderSnapshot, quality: Quality, hevc: Bool, to url: URL,
                       progress: @escaping @Sendable (Double) -> Void) async throws {
        let state = RenderState()
        state.snapshot = snapshot
        var enhance: ((CIImage) -> CIImage?)?
        if quality == .ai { let up = try await AIUpscaler.load(); enhance = { up.enhance($0) } }
        let preset = hevc ? AVAssetExportPresetHEVCHighestQuality : AVAssetExportPresetHighestQuality
        guard let session = AVAssetExportSession(asset: composition, presetName: preset) else { throw CocoaError(.fileWriteUnknown) }
        session.videoComposition = Composer.videoComposition(for: composition, frameDuration: frameDuration, state: state, enhance: enhance)
        session.outputURL = url
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        try? FileManager.default.removeItem(at: url)
        let poll = Task { while !Task.isCancelled { progress(Double(session.progress)); try? await Task.sleep(nanoseconds: 200_000_000) } }
        defer { poll.cancel() }
        await withTaskCancellationHandler { await session.export() } onCancel: { session.cancelExport() }
        if session.status != .completed { throw session.error ?? CancellationError() }
        progress(1)
    }
}
