import Foundation
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import UniformTypeIdentifiers
import Vision
import AppKit

enum ThumbFormat: String, CaseIterable, Identifiable {
    case short, wide
    var id: String { rawValue }
    var title: String { self == .short ? "Short (9:16)" : "Video (16:9)" }
    var size: CGSize { self == .short ? ShortFormat.size : CGSize(width: 1920, height: 1080) }
}

struct ThumbnailSettings: Equatable {
    var format = ThumbFormat.short
    var frame = 0                 // Bild auf der Short-Zeitleiste
    var text = ""
    var style: TextStyle = .outline
    var color = RGBA.white
    var accent = RGBA.yellow
    var size = 0.13               // Schrifthöhe als Anteil der kürzeren Bildseite
    var x = 0.5, y = 0.72
    var uppercase = true
    var tilt = false
    var zoom = 1.0                // zusätzlich zum Ausschnitt aus Schritt 2
    var vivid = 0.5
    var vignette = 0.35
    var shade = 0.45
    var ai = true
}

struct ThumbSuggestion: Identifiable {
    var frame: Int
    var image: NSImage
    var id: Int { frame }
}

enum ThumbnailComposer {
    /// Entfernt *Sternchen* und liefert die markierten Bereiche (in UTF-16-Einheiten wie NSString).
    static func accents(in raw: String, uppercase: Bool) -> (String, [NSRange]) {
        var out = "", ranges: [NSRange] = [], start: Int?, len = 0
        for ch in raw {
            if ch == "*" {
                if let s = start { if len > s { ranges.append(NSRange(location: s, length: len - s)) }; start = nil } else { start = len }
                continue
            }
            let c = uppercase ? String(ch).uppercased() : String(ch)
            out += c
            len += (c as NSString).length
        }
        if let s = start, len > s { ranges.append(NSRange(location: s, length: len - s)) }
        return (out, ranges)
    }

    /// Ein Vorschaubild: Ausschnitt wie im Short, kräftigere Farben, Vignette, Abdunklung hinter dem Text und Text im Social-Media-Stil.
    static func compose(still: CIImage, clip: Clip, sourceFrame: Int, settings s: ThumbnailSettings,
                        enhance: ((CIImage, CGRect) -> CIImage?)?) -> CIImage {
        let size = s.format.size, canvas = CGRect(origin: .zero, size: size)
        let src = still.transformed(by: CGAffineTransform(translationX: -still.extent.minX, y: -still.extent.minY))
        var out = CIImage(color: .black).cropped(to: canvas)
        let center = clip.center(atSourceFrame: sourceFrame)

        if s.format == .short && clip.framing.mode == .fit {
            var img = Renderer.fit(src, center: center, zoom: clip.framing.zoom)
            if s.zoom > 1.001 {
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                img = img.transformed(by: CGAffineTransform(translationX: c.x, y: c.y).scaledBy(x: s.zoom, y: s.zoom).translatedBy(x: -c.x, y: -c.y))
            }
            out = img.composited(over: out)
        } else {
            let zoom = (s.format == .short ? clip.framing.zoom : 1) * s.zoom
            let rect = Renderer.cropRect(sourceSize: src.extent.size, center: center, zoom: zoom, aspect: size.width / size.height)
                .integral.intersection(src.extent)
            var img = src.cropped(to: rect).transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
            if let enhance, rect.height < size.height - 1, let e = enhance(img, rect) { img = e }
            let scale = max(size.height / img.extent.height, size.width / img.extent.width)
            img = Renderer.scaled(img, to: scale)
            if scale > 1.05 {
                let f = CIFilter.sharpenLuminance()
                f.inputImage = img; f.sharpness = Float(min(0.6, 0.25 + 0.2 * (scale - 1))); f.radius = 1.6
                img = f.outputImage ?? img
            }
            out = img.composited(over: out)
        }
        out = out.cropped(to: canvas)

        if s.vivid > 0.01 {
            let cc = CIFilter.colorControls()
            cc.inputImage = out; cc.saturation = Float(1 + 0.35 * s.vivid); cc.contrast = Float(1 + 0.12 * s.vivid); cc.brightness = Float(0.02 * s.vivid)
            out = cc.outputImage ?? out
            let v = CIFilter.vibrance(); v.inputImage = out; v.amount = Float(0.5 * s.vivid)
            out = v.outputImage ?? out
        }
        if s.vignette > 0.01 {
            let v = CIFilter.vignetteEffect()
            v.inputImage = out; v.center = CGPoint(x: size.width / 2, y: size.height / 2)
            v.radius = Float(hypot(size.width, size.height) * 0.42); v.intensity = Float(s.vignette); v.falloff = 0.7
            out = (v.outputImage ?? out).cropped(to: canvas)
        }
        if s.shade > 0.01 {   // Verlauf von der Bildkante zum Text, damit er sich abhebt
            let top = s.y < 0.5
            let g = CIFilter.linearGradient()
            g.point0 = CGPoint(x: 0, y: top ? size.height : 0)
            g.point1 = CGPoint(x: 0, y: (1 - s.y + (top ? -0.3 : 0.3)) * size.height)
            g.color0 = CIColor(red: 0, green: 0, blue: 0, alpha: 0.8 * s.shade)
            g.color1 = CIColor(red: 0, green: 0, blue: 0, alpha: 0)
            if let grad = g.outputImage?.cropped(to: canvas) { out = grad.composited(over: out) }
        }

        let (text, ranges) = accents(in: s.text, uppercase: s.uppercase)
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let spec = TextSpec(text: text, style: s.style, fontSize: s.size * min(size.width, size.height), color: s.color,
                                highlight: nil, highlightColor: s.accent, accents: ranges, maxWidth: size.width * 0.9)
            if let t = TextRasterizer.shared.image(spec) {
                var tr = CGAffineTransform(translationX: s.x * size.width, y: (1 - s.y) * size.height)
                if s.tilt { tr = tr.rotated(by: 0.07) }
                tr = tr.translatedBy(x: -t.extent.width / 2, y: -t.extent.height / 2)
                out = t.transformed(by: tr).composited(over: out)
            }
        }
        return out.cropped(to: canvas)
    }
}

/// Holt Standbilder aus dem Original, rendert Vorschaubilder (optional mit KI-Schärfe) und schlägt gute Bilder vor.
final class ThumbnailMaker: @unchecked Sendable {
    let asset: AVAsset
    let frameDuration: CMTime
    private let lock = NSLock()
    private var stills: [Int: CIImage] = [:]
    private var enhanced: [String: CIImage] = [:]
    private var upscaler: AIUpscaler?
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    init(asset: AVAsset, frameDuration: CMTime) {
        self.asset = asset
        self.frameDuration = frameDuration
    }

    func still(_ frame: Int, maxSize: CGSize = .zero) async throws -> CIImage {
        let full = maxSize == .zero
        if full, let c = lock.withLock({ stills[frame] }) { return c }
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero; gen.requestedTimeToleranceAfter = .zero
        gen.maximumSize = maxSize
        let img = CIImage(cgImage: try await gen.image(at: Composer.time(frame: frame, frameDuration)).image)
        if full { lock.withLock { if stills.count > 30 { stills.removeAll() }; stills[frame] = img } }
        return img
    }

    func render(clip: Clip, sourceFrame: Int, settings: ThumbnailSettings) async throws -> CGImage {
        let still = try await still(sourceFrame)
        var enhance: ((CIImage, CGRect) -> CIImage?)?
        if settings.ai, AIUpscaler.isAvailable {
            if lock.withLock({ upscaler }) == nil {
                let u = try await AIUpscaler.load()
                lock.withLock { upscaler = u }
            }
            if let up = lock.withLock({ upscaler }) {
                enhance = { [self] img, rect in
                    let key = "\(sourceFrame)|\(rect)"
                    if let c = lock.withLock({ enhanced[key] }) { return c }
                    guard let e = up.enhance(img) else { return nil }
                    lock.withLock { if enhanced.count > 6 { enhanced.removeAll() }; enhanced[key] = e }
                    return e
                }
            }
        }
        let ctx = context, cs = srgb
        return try await Task.detached {
            let img = ThumbnailComposer.compose(still: still, clip: clip, sourceFrame: sourceFrame, settings: settings, enhance: enhance)
            guard let cg = ctx.createCGImage(img, from: CGRect(origin: .zero, size: settings.format.size), format: .RGBA8, colorSpace: cs) else {
                throw CocoaError(.fileWriteUnknown)
            }
            return cg
        }.value
    }

    /// Bewertet Bilder der Zeitleiste: ein gut erkennbares, scharfes Gesicht im Ausschnitt zählt am meisten (Apple Vision).
    func suggest(clips: [(start: Int, clip: Clip)], fps: Double, format: ThumbFormat, count: Int = 6) async -> [Int] {
        let total = clips.last.map { $0.start + $0.clip.frames } ?? 0
        guard total > 0 else { return [] }
        let samples = min(36, total)
        var scored: [(frame: Int, score: Double)] = []
        for i in 0..<samples {
            if Task.isCancelled { return [] }
            let k = min(total - 1, Int((Double(i) + 0.5) / Double(samples) * Double(total)))
            guard let cs = clips.last(where: { $0.start <= k }) else { continue }
            let src = cs.clip.start + (k - cs.start)
            guard let img = try? await still(src, maxSize: CGSize(width: 640, height: 640)) else { continue }
            let req = VNDetectFaceCaptureQualityRequest()
            try? VNImageRequestHandler(ciImage: img, options: [:]).perform([req])
            let crop = format == .short && cs.clip.framing.mode != .fit
                ? Renderer.cropRect(sourceSize: img.extent.size, center: cs.clip.center(atSourceFrame: src), zoom: cs.clip.framing.zoom)
                : img.extent
            var best = 0.0
            for f in req.results ?? [] {
                let c = CGPoint(x: f.boundingBox.midX * img.extent.width, y: f.boundingBox.midY * img.extent.height)
                guard crop.contains(c) else { continue }
                let area = Double(f.boundingBox.width * f.boundingBox.height)
                best = max(best, Double(f.faceCaptureQuality ?? 0) * (0.6 + min(0.4, area * 6)))
            }
            scored.append((k, best))
        }
        // Ohne Gesichter: gleichmäßig verteilt vorschlagen
        if (scored.map(\.score).max() ?? 0) < 0.01 {
            let step = max(1, scored.count / count)
            return stride(from: step / 2, to: scored.count, by: step).prefix(count).map { scored[$0].frame }
        }
        var picked: [Int] = []
        let gap = max(1, Int(fps * 1.5))
        for s in scored.sorted(by: { $0.score > $1.score }) where s.score > 0.01 && picked.allSatisfy({ abs($0 - s.frame) >= gap }) {
            picked.append(s.frame)
            if picked.count == count { break }
        }
        return picked.sorted()
    }

    static func write(_ cg: CGImage, to url: URL) throws {
        let jpeg = ["jpg", "jpeg"].contains(url.pathExtension.lowercased())
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, (jpeg ? UTType.jpeg : UTType.png).identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(dest, cg, (jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.9] : [:]) as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }
}
