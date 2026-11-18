import Foundation
import AVFoundation
import CoreVideo

/// Findet harte Bildschnitte (Wechsel der Einstellung) über Farbverteilung und grobes Helligkeitsraster.
enum CutDetector {
    /// Quellbilder im Bereich [start, start + frames), an denen eine neue Einstellung beginnt.
    static func detect(asset: AVAsset, start: Int, frames: Int, frameDuration fd: CMTime,
                       progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> [Int] {
        guard frames > 2, let vt = try await asset.loadTracks(withMediaType: .video).first else { return [] }
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: vt, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 36,
        ])
        out.alwaysCopiesSampleData = false
        reader.add(out)
        reader.timeRange = CMTimeRange(start: Composer.time(frame: start, fd), duration: Composer.time(frame: frames, fd))
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }

        var scores: [Double] = []           // scores[i]: Unterschied zwischen Bild i-1 und i
        var prev: Features?
        while let sb = out.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
            let f = features(pb)
            scores.append(prev.map { score($0, f) } ?? 0)
            prev = f
            if scores.count % 30 == 0 { progress(min(1, Double(scores.count) / Double(frames))) }
            if scores.count >= frames { break }
        }
        reader.cancelReading()
        progress(1)
        return cuts(in: scores, fps: 1 / max(fd.seconds, 0.001)).map { start + $0 }
    }

    /// Spitzen, die deutlich über ihrer Umgebung liegen – Kameraschwenks und Blitze steigen langsamer bzw. nur kurz an.
    static func cuts(in scores: [Double], fps: Double) -> [Int] {
        let minGap = max(2, Int(fps * 0.4))
        var result: [Int] = []
        guard scores.count > 2 else { return [] }
        for i in 1..<scores.count {
            let s = scores[i]
            guard s > 0.3 else { continue }
            let lo = max(1, i - 8), hi = min(scores.count - 1, i + 8)
            let around = (lo...hi).filter { $0 != i }.map { scores[$0] }.sorted()
            let median = around.isEmpty ? 0 : around[around.count / 2]
            guard s > 3 * median + 0.08, s >= around.last ?? 0 else { continue }
            if let last = result.last, i - last < minGap { continue }
            result.append(i)
        }
        return result
    }

    struct Features {
        var hist: [Float]       // 4×4×4 Farbbereiche, normiert
        var grid: [Float]       // 16×9 Helligkeitsfelder, 0…1
    }

    private static func score(_ a: Features, _ b: Features) -> Double {
        var h: Float = 0
        for k in a.hist.indices { h += abs(a.hist[k] - b.hist[k]) }
        var g: Float = 0
        for k in a.grid.indices { g += abs(a.grid[k] - b.grid[k]) }
        g /= Float(a.grid.count)
        return Double(0.6 * h / 2 + 0.4 * min(1, g * 3))
    }

    private static func features(_ pb: CVPixelBuffer) -> Features {
        CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), bpr = CVPixelBufferGetBytesPerRow(pb)
        var hist = [Float](repeating: 0, count: 64), grid = [Float](repeating: 0, count: 144), cnt = [Float](repeating: 0, count: 144)
        guard let raw = CVPixelBufferGetBaseAddress(pb) else { return Features(hist: hist, grid: grid) }
        let base = raw.assumingMemoryBound(to: UInt8.self)
        for y in 0..<h {
            let row = base + y * bpr, gy = min(8, y * 9 / h)
            for x in 0..<w {
                let p = row + x * 4
                let b = Int(p[0]), g = Int(p[1]), r = Int(p[2])
                hist[(r >> 6) * 16 + (g >> 6) * 4 + (b >> 6)] += 1
                let cell = gy * 16 + min(15, x * 16 / w)
                grid[cell] += (0.2126 * Float(r) + 0.7152 * Float(g) + 0.0722 * Float(b)) / 255
                cnt[cell] += 1
            }
        }
        let n = Float(max(1, w * h))
        for k in hist.indices { hist[k] /= n }
        for k in grid.indices { grid[k] /= max(1, cnt[k]) }
        return Features(hist: hist, grid: grid)
    }
}
