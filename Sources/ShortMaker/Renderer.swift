import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreText
import AppKit

/// Unveränderliches Abbild des Projekts für den Render-Thread.
struct RenderSnapshot {
    struct ClipSnap {
        var tlStart: Int        // erstes Bild auf der Short-Zeitleiste
        var clip: Clip
    }
    var fps = 30.0
    var clips: [ClipSnap] = []
    var titles: [TitleItem] = []
    var cues: [SubtitleCue] = []
    var subStyle = SubtitleStyle()
    var duration: Double { Double(clips.last.map { $0.tlStart + $0.clip.frames } ?? 0) / fps }

    func clip(atTimelineFrame k: Int) -> ClipSnap? {
        clips.last { $0.tlStart <= k } ?? clips.first
    }
}

/// Vom Hauptthread geschrieben, vom Render-Thread gelesen.
final class RenderState: @unchecked Sendable {
    private let lock = NSLock()
    private var snap = RenderSnapshot()
    var snapshot: RenderSnapshot {
        get { lock.lock(); defer { lock.unlock() }; return snap }
        set { lock.lock(); snap = newValue; lock.unlock() }
    }
}

enum Renderer {
    /// Ausschnitt im Quellbild (Core-Image-Koordinaten, Ursprung unten links).
    static func cropRect(sourceSize: CGSize, center: CGPoint, zoom: Double, aspect: Double = ShortFormat.aspect) -> CGRect {
        let W = Double(sourceSize.width), H = Double(sourceSize.height)
        var ch = H / max(1, zoom), cw = ch * aspect
        if cw > W { cw = W; ch = cw / aspect }
        let cx = Double(center.x) * W, cy = (1 - Double(center.y)) * H
        let x0 = min(max(0, cx - cw / 2), W - cw), y0 = min(max(0, cy - ch / 2), H - ch)
        return CGRect(x: x0, y: y0, width: cw, height: ch)
    }

    /// Erzeugt ein fertiges 1080×1920-Bild. `enhance` (optional) skaliert den Ausschnitt per KI hoch.
    static func frame(source: CIImage, time t: Double, snap: RenderSnapshot, enhance: ((CIImage) -> CIImage?)? = nil) -> CIImage {
        let canvas = CGRect(origin: .zero, size: ShortFormat.size)
        let src = source.transformed(by: CGAffineTransform(translationX: -source.extent.minX, y: -source.extent.minY))
        let k = Int((t * snap.fps + 0.5).rounded(.down))
        var out = CIImage(color: .black).cropped(to: canvas)
        if let cs = snap.clip(atTimelineFrame: k) {
            let clip = cs.clip
            let center = clip.center(atSourceFrame: clip.start + (k - cs.tlStart))
            if clip.framing.mode == .fit {
                out = fit(src, center: center, zoom: clip.framing.zoom).composited(over: out)
            } else {
                var rect = cropRect(sourceSize: src.extent.size, center: center, zoom: clip.framing.zoom)
                var img: CIImage
                if let enhance, rect.height < ShortFormat.height - 1 {
                    rect = rect.integral.intersection(src.extent)
                    let cropped = src.cropped(to: rect).transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
                    img = enhance(cropped) ?? cropped
                    img = scaled(img, to: ShortFormat.height / img.extent.height)
                } else {
                    img = src.cropped(to: rect).transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
                    let s = ShortFormat.height / rect.height
                    img = scaled(img, to: s)
                    if s > 1.05 {   // Hochskaliertes Material leicht nachschärfen
                        let f = CIFilter.sharpenLuminance()
                        f.inputImage = img; f.sharpness = Float(min(0.6, 0.25 + 0.2 * (s - 1))); f.radius = 1.6
                        img = f.outputImage ?? img
                    }
                }
                out = img.composited(over: out)
            }
        }
        // Untertitel
        let st = snap.subStyle
        if st.enabled, let cue = snap.cues.first(where: { t >= $0.start && t < $0.end }) {
            let words = cue.words.map { st.uppercase ? $0.text.uppercased() : $0.text }
            var range: NSRange?
            if st.highlight, let wi = cue.words.lastIndex(where: { t >= $0.start }) {
                let loc = words[..<wi].reduce(0) { $0 + ($1 as NSString).length + 1 }
                range = NSRange(location: loc, length: (words[wi] as NSString).length)
            }
            let spec = TextSpec(text: words.joined(separator: " "), style: st.style, fontSize: st.size * ShortFormat.width, color: st.color,
                                highlight: range, highlightColor: st.highlightColor)
            if let img = TextRasterizer.shared.image(spec) {
                var scale = 1.0
                if st.pop { let p = min(1, (t - cue.start) / 0.12); scale = 0.82 + 0.18 * (1 - (1 - p) * (1 - p)) }
                out = place(img, x: 0.5, y: st.y, scale: scale).composited(over: out)
            }
        }
        // Titel
        for title in snap.titles where title.wholeVideo || (t >= title.start && t < title.end) {
            let text = title.uppercase ? title.text.uppercased() : title.text
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let spec = TextSpec(text: text, style: title.style, fontSize: title.size * ShortFormat.width, color: title.color, highlight: nil, highlightColor: .yellow)
            if let img = TextRasterizer.shared.image(spec) { out = place(img, x: title.x, y: title.y, scale: 1).composited(over: out) }
        }
        return out.cropped(to: canvas)
    }

    static func scaled(_ img: CIImage, to s: Double) -> CIImage {
        guard abs(s - 1) > 0.001 else { return img }
        let f = CIFilter.lanczosScaleTransform()
        f.inputImage = img.clampedToExtent(); f.scale = Float(s); f.aspectRatio = 1
        let target = CGRect(x: 0, y: 0, width: img.extent.width * s, height: img.extent.height * s)
        return (f.outputImage ?? img).cropped(to: target)
    }

    /// Ganzes Bild mittig, dahinter dasselbe Bild unscharf und abgedunkelt als Füllung.
    static func fit(_ src: CIImage, center: CGPoint, zoom: Double) -> CIImage {
        let canvas = CGRect(origin: .zero, size: ShortFormat.size)
        let W = src.extent.width, H = src.extent.height
        let fill = ShortFormat.height / H
        var bg = src.transformed(by: CGAffineTransform(scaleX: fill, y: fill))
        bg = bg.transformed(by: CGAffineTransform(translationX: (ShortFormat.width - W * fill) / 2, y: 0))
        bg = bg.cropped(to: canvas).clampedToExtent().applyingGaussianBlur(sigma: 36).cropped(to: canvas)
        let dim = CIFilter.colorControls(); dim.inputImage = bg; dim.brightness = -0.12; dim.saturation = 1.1
        bg = dim.outputImage ?? bg
        let s = min(fill, ShortFormat.width / W * max(1, zoom))
        var fg = scaled(src, to: s)
        let w = W * s, h = H * s
        let x = w <= ShortFormat.width ? (ShortFormat.width - w) / 2 : min(0, max(ShortFormat.width - w, ShortFormat.width / 2 - center.x * w))
        fg = fg.transformed(by: CGAffineTransform(translationX: x, y: (ShortFormat.height - h) / 2))
        return fg.composited(over: bg).cropped(to: canvas)
    }

    private static func place(_ img: CIImage, x: Double, y: Double, scale: Double) -> CIImage {
        let w = img.extent.width, h = img.extent.height
        var t = CGAffineTransform(translationX: x * ShortFormat.width, y: (1 - y) * ShortFormat.height)
        t = t.scaledBy(x: scale, y: scale).translatedBy(x: -w / 2, y: -h / 2)
        return img.transformed(by: t)
    }
}

struct TextSpec: Hashable {
    var text: String
    var style: TextStyle
    var fontSize: Double
    var color: RGBA
    var highlight: NSRange?
    var highlightColor: RGBA
    var accents: [NSRange] = []          // weitere Bereiche in der Hervorhebungsfarbe
    var maxWidth = ShortFormat.width * 0.88
}

/// Zeichnet Titel/Untertitel im Social-Media-Stil mit Core Text und hält die Bilder im Zwischenspeicher.
final class TextRasterizer: @unchecked Sendable {
    static let shared = TextRasterizer()
    private var cache: [TextSpec: CIImage] = [:]
    private let lock = NSLock()

    func image(_ spec: TextSpec) -> CIImage? {
        lock.lock(); defer { lock.unlock() }
        if let c = cache[spec] { return c }
        guard let cg = Self.draw(spec) else { return nil }
        if cache.count > 300 { cache.removeAll() }
        let img = CIImage(cgImage: cg)
        cache[spec] = img
        return img
    }

    static func draw(_ spec: TextSpec) -> CGImage? {
        let size = CGFloat(spec.fontSize)
        let base = NSFont.systemFont(ofSize: size, weight: spec.style == .box ? .bold : .black)
        let font: CTFont = (base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? base) as CTFont
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineSpacing = spec.style == .box ? size * 0.42 : size * 0.05
        let textColor: RGBA = spec.style == .box ? (spec.color.luminance > 0.55 ? .black : .white) : spec.color
        var attrs: [NSAttributedString.Key: Any] = [
            .init(kCTFontAttributeName as String): font,
            .init(kCTParagraphStyleAttributeName as String): para,
            .init(kCTForegroundColorAttributeName as String): textColor.cg,
        ]
        let fill = NSMutableAttributedString(string: spec.text, attributes: attrs)
        if let r = spec.highlight, r.location + r.length <= fill.length {
            fill.addAttribute(.init(kCTForegroundColorAttributeName as String), value: spec.highlightColor.cg, range: r)
        }
        for r in spec.accents where r.location + r.length <= fill.length {
            fill.addAttribute(.init(kCTForegroundColorAttributeName as String), value: spec.highlightColor.cg, range: r)
        }
        let strokeW = size * 0.16
        attrs[.init(kCTStrokeWidthAttributeName as String)] = strokeW / size * 100
        attrs[.init(kCTStrokeColorAttributeName as String)] = CGColor(gray: 0, alpha: 1)
        let stroke = NSAttributedString(string: spec.text, attributes: attrs)

        let maxW = CGFloat(spec.maxWidth)
        let setter = CTFramesetterCreateWithAttributedString(fill)
        let fitSize = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(), nil, CGSize(width: maxW, height: 4000), nil)
        let pad = ceil(size * 0.7)
        let w = Int(ceil(maxW + 2 * pad)), h = Int(ceil(fitSize.height + 2 * pad))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let box = CGRect(x: pad, y: pad, width: maxW, height: ceil(fitSize.height))
        let path = CGPath(rect: box, transform: nil)
        let fillFrame = CTFramesetterCreateFrame(setter, CFRange(), path, nil)
        ctx.setLineJoin(.round)
        ctx.setAllowsAntialiasing(true)

        switch spec.style {
        case .box:
            let lines = CTFrameGetLines(fillFrame) as! [CTLine]
            var origins = [CGPoint](repeating: .zero, count: lines.count)
            CTFrameGetLineOrigins(fillFrame, CFRange(), &origins)
            ctx.setFillColor(spec.color.cg)
            for (line, o) in zip(lines, origins) {
                var asc: CGFloat = 0, desc: CGFloat = 0, lead: CGFloat = 0
                let lw = CGFloat(CTLineGetTypographicBounds(line, &asc, &desc, &lead)) - CGFloat(CTLineGetTrailingWhitespaceWidth(line))
                guard lw > 0 else { continue }
                let r = CGRect(x: box.minX + o.x - size * 0.32, y: box.minY + o.y - desc - size * 0.16, width: lw + size * 0.64, height: asc + desc + size * 0.32)
                ctx.addPath(CGPath(roundedRect: r, cornerWidth: size * 0.26, cornerHeight: size * 0.26, transform: nil))
                ctx.fillPath()
            }
        case .outline:
            ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.06), blur: size * 0.12, color: CGColor(gray: 0, alpha: 0.55))
            CTFrameDraw(CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(stroke), CFRange(), path, nil), ctx)
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
        case .glow:
            for blur in [0.5, 0.28, 0.12] {
                ctx.setShadow(offset: .zero, blur: size * blur, color: spec.color.cg)
                CTFrameDraw(fillFrame, ctx)
            }
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            let core = NSMutableAttributedString(attributedString: fill)
            core.addAttribute(.init(kCTForegroundColorAttributeName as String), value: CGColor(gray: 1, alpha: 0.82), range: NSRange(location: 0, length: core.length))
            CTFrameDraw(CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(core), CFRange(), path, nil), ctx)
            return ctx.makeImage()
        case .shadow:
            ctx.setShadow(offset: CGSize(width: size * 0.07, height: -size * 0.07), blur: 0, color: CGColor(gray: 0, alpha: 1))
        }
        CTFrameDraw(fillFrame, ctx)
        return ctx.makeImage()
    }
}
