import SwiftUI
import AVFoundation

/// Zeigt einen AVPlayer ohne Bedienelemente.
struct PlayerView: NSViewRepresentable {
    let player: AVPlayer
    final class LayerView: NSView {
        override func makeBackingLayer() -> CALayer { AVPlayerLayer() }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
    func makeNSView(context: Context) -> LayerView {
        let v = LayerView()
        v.wantsLayer = true
        v.playerLayer.player = player
        v.playerLayer.videoGravity = .resizeAspect
        v.playerLayer.backgroundColor = NSColor.black.cgColor
        return v
    }
    func updateNSView(_ v: LayerView, context: Context) { if v.playerLayer.player !== player { v.playerLayer.player = player } }
}

/// Wiedergabeknöpfe mit Timecode; arbeitet auf dem Player des aktuellen Schritts.
struct Transport: View {
    @EnvironmentObject var project: Project
    @ObservedObject var head: Playhead
    let total: Int

    var body: some View {
        HStack(spacing: 6) {
            Text(Timecode.string(frame: head.frame, fps: project.fps))
                .font(.system(.title3, design: .monospaced).weight(.medium))
                .help("Stunden:Minuten:Sekunden:Bild")
            Text("/ \(Timecode.string(frame: total, fps: project.fps))").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Group {
                Button { project.stepFrames(-10) } label: { Image(systemName: "backward.fill") }.help("10 Bilder zurück (⇧←)")
                Button { project.stepFrames(-1) } label: { Image(systemName: "backward.frame.fill") }.help("1 Bild zurück (←)")
                Button { project.togglePlay() } label: { Image(systemName: head.playing ? "pause.fill" : "play.fill").frame(width: 22) }
                    .help("Wiedergabe (Leertaste)")
                Button { project.stepFrames(1) } label: { Image(systemName: "forward.frame.fill") }.help("1 Bild vor (→)")
                Button { project.stepFrames(10) } label: { Image(systemName: "forward.fill") }.help("10 Bilder vor (⇧→)")
            }
            .controlSize(.large)
        }
    }
}

struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var format: (Double) -> String = { String(format: "%.0f %%", $0 * 100) }
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack { Text(title); Spacer(); Text(format(value)).foregroundStyle(.secondary).monospacedDigit() }.font(.callout)
            Slider(value: $value, in: range)
        }
    }
}

struct SectionBox<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// 9:16-Vorschau des Shorts; `onDrag` meldet Verschiebungen als Anteil der Vorschaugröße.
struct ShortPreview: View {
    @EnvironmentObject var project: Project
    var onDragStart: () -> Void = {}
    var onDrag: (CGSize) -> Void = { _ in }
    @LocalState private var dragging = false

    var body: some View {
        GeometryReader { geo in
            PlayerView(player: project.shortPlayer)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.12)))
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 2)
                    .onChanged { v in
                        if !dragging { dragging = true; onDragStart() }
                        onDrag(CGSize(width: v.translation.width / geo.size.width, height: v.translation.height / geo.size.height))
                    }
                    .onEnded { _ in dragging = false })
        }
        .aspectRatio(ShortFormat.aspect, contentMode: .fit)
        .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
    }
}

/// Zeitleiste des Shorts: Clips als Blöcke in Reihenfolge, Breite nach Länge.
struct ClipTimeline: View {
    @EnvironmentObject var project: Project
    @ObservedObject var head: Playhead

    var body: some View {
        GeometryReader { geo in
            let total = max(1, project.shortFrames), w = geo.size.width
            let current = project.clipIndex(atShortFrame: head.frame)
            ZStack(alignment: .topLeading) {
                HStack(spacing: 0) {
                    ForEach(Array(project.clips.enumerated()), id: \.element.id) { i, clip in
                        ZStack(alignment: .bottomLeading) {
                            if let img = project.thumbs[clip.id] {
                                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                            } else { Color.gray.opacity(0.3) }
                            LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .center, endPoint: .bottom)
                            HStack(spacing: 4) {
                                Text("\(i + 1)").fontWeight(.bold)
                                Text(Timecode.short(seconds: Double(clip.frames) / project.fps))
                                if clip.framing.mode == .track { Image(systemName: "person.fill.viewfinder") }
                                if clip.framing.mode == .fit { Image(systemName: "rectangle.center.inset.filled") }
                            }
                            .font(.caption2).foregroundStyle(.white).padding(5).lineLimit(1)
                        }
                        .frame(width: max(2, CGFloat(clip.frames) / CGFloat(total) * w - 2), height: geo.size.height)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(i == current ? Color.accentColor : .white.opacity(0.15), lineWidth: i == current ? 2.5 : 1))
                        .padding(.horizontal, 1)
                    }
                }
                Rectangle().fill(.white).frame(width: 2, height: geo.size.height)
                    .shadow(color: .black, radius: 1)
                    .offset(x: CGFloat(head.frame) / CGFloat(total) * w - 1)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                project.shortPlayer.pause()
                project.seek(Int(v.location.x / w * CGFloat(total)))
            })
        }
        .frame(height: 76)
    }
}
/// Ersatz für `@State`: Mit reinen Command Line Tools steht das SwiftUI-Makro-Plugin nicht zur Verfügung,
/// daher wird `State` direkt (ohne Makro) eingewickelt. Verhalten ist identisch.
@propertyWrapper
struct LocalState<Value>: DynamicProperty {
    private let state: State<Value>
    init(wrappedValue: Value) { state = State(initialValue: wrappedValue) }
    var wrappedValue: Value {
        get { state.wrappedValue }
        nonmutating set { state.wrappedValue = newValue }
    }
    var projectedValue: Binding<Value> { state.projectedValue }
}
