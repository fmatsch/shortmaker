import SwiftUI

/// Schritt 1: im 16:9-Original bildgenau Bereiche markieren.
struct SelectStep: View {
    @EnvironmentObject var project: Project
    @ObservedObject var head: Playhead

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 12) {
                PlayerView(player: project.sourcePlayer)
                    .aspectRatio(project.sourceSize.width / project.sourceSize.height, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Transport(head: head, total: project.totalFrames)
                JogStrip(head: head)
                Scrubber(head: head)
                HStack(spacing: 10) {
                    Button { project.setIn() } label: { Label(mark("In", project.markIn), systemImage: "arrow.right.to.line") }
                        .help("Anfang auf das aktuelle Bild setzen (I)")
                    Button { project.setOut() } label: { Label(mark("Out", project.markOut.map { $0 - 1 }), systemImage: "arrow.left.to.line") }
                        .help("Ende auf das aktuelle Bild setzen (O) – das Bild gehört noch dazu")
                    if let i = project.markIn, let o = project.markOut, o > i {
                        Text("\(o - i) Bilder · \(Timecode.short(seconds: Double(o - i) / project.fps))").foregroundStyle(.secondary).monospacedDigit()
                    }
                    Spacer()
                    Button { project.addClip() } label: { Label("Bereich übernehmen", systemImage: "plus.circle.fill") }
                        .buttonStyle(.borderedProminent).disabled(!project.canAddClip).help("Markierten Bereich als Clip übernehmen (↩)")
                }
                .controlSize(.large)
            }
            .padding(16)
            Divider()
            ClipList()
                .frame(width: 320)
        }
    }

    private func mark(_ name: String, _ frame: Int?) -> String {
        frame.map { "\(name)  \(Timecode.string(frame: $0, fps: project.fps))" } ?? "\(name) setzen"
    }
}

/// Feinrad: jedes Bild ein Strich; Ziehen bewegt bildweise.
struct JogStrip: View {
    @EnvironmentObject var project: Project
    @ObservedObject var head: Playhead
    @LocalState private var dragStart: Int?
    private let pitch: CGFloat = 9

    var body: some View {
        Canvas { ctx, size in
            let mid = size.width / 2, base = Int(project.fps.rounded())
            let half = Int(mid / pitch) + 2
            for f in (head.frame - half)...(head.frame + half) where f >= 0 && f < project.totalFrames {
                let x = mid + CGFloat(f - head.frame) * pitch
                let inClip = project.clips.contains { f >= $0.start && f < $0.end }
                let inMark = (project.markIn.map { f >= $0 } ?? false) && (project.markOut.map { f < $0 } ?? true) && project.markIn != nil
                if inClip || inMark {
                    ctx.fill(Path(CGRect(x: x - pitch / 2, y: 0, width: pitch, height: size.height)), with: .color(inMark ? .yellow.opacity(0.35) : .accentColor.opacity(0.35)))
                }
                let second = f % base == 0
                let h = second ? size.height * 0.7 : (f % 5 == 0 ? size.height * 0.45 : size.height * 0.28)
                ctx.fill(Path(CGRect(x: x - 0.5, y: size.height - h, width: 1, height: h)), with: .color(.primary.opacity(second ? 0.8 : 0.35)))
            }
            ctx.fill(Path(CGRect(x: mid - 1, y: 0, width: 2, height: size.height)), with: .color(.red))
        }
        .frame(height: 30)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { v in
                if dragStart == nil { dragStart = head.frame; project.sourcePlayer.pause() }
                project.seek((dragStart ?? 0) - Int((v.translation.width / pitch).rounded()))
            }
            .onEnded { _ in dragStart = nil })
        .help("Ziehen, um bildweise zu fahren")
    }
}

/// Übersicht über das ganze Video mit Filmstreifen, übernommenen Clips und Markierung.
struct Scrubber: View {
    @EnvironmentObject var project: Project
    @ObservedObject var head: Playhead

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, total = CGFloat(max(1, project.totalFrames))
            ZStack(alignment: .topLeading) {
                HStack(spacing: 0) {
                    ForEach(Array(project.filmstrip.enumerated()), id: \.offset) { _, img in
                        Image(nsImage: img).resizable().aspectRatio(contentMode: .fill).frame(width: w / 24, height: geo.size.height).clipped()
                    }
                    Spacer(minLength: 0)
                }
                .opacity(0.75)
                ForEach(project.clips) { c in
                    Rectangle().fill(Color.accentColor.opacity(0.45))
                        .overlay(Rectangle().strokeBorder(Color.accentColor, lineWidth: 1.5))
                        .frame(width: max(2, CGFloat(c.frames) / total * w), height: geo.size.height)
                        .offset(x: CGFloat(c.start) / total * w)
                }
                if let i = project.markIn {
                    let o = project.markOut ?? i
                    Rectangle().fill(Color.yellow.opacity(0.4))
                        .overlay(Rectangle().strokeBorder(Color.yellow, lineWidth: 1.5))
                        .frame(width: max(2, CGFloat(max(0, o - i)) / total * w), height: geo.size.height)
                        .offset(x: CGFloat(i) / total * w)
                } else if let o = project.markOut {
                    Rectangle().fill(Color.yellow).frame(width: 2, height: geo.size.height).offset(x: CGFloat(o) / total * w)
                }
                Rectangle().fill(.red).frame(width: 2, height: geo.size.height).offset(x: CGFloat(head.frame) / total * w - 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                project.sourcePlayer.pause()
                project.seek(Int(v.location.x / w * total))
            })
        }
        .frame(height: 46)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }
}

struct ClipList: View {
    @EnvironmentObject var project: Project

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Clips für das Short").font(.headline).padding([.horizontal, .top], 14)
            VStack(alignment: .leading, spacing: 6) {
                Toggle("An Bildschnitten automatisch teilen", isOn: $project.autoSplit)
                    .help("Beim Übernehmen wird der Bereich an jedem Wechsel der Einstellung in einzelne Clips geteilt.")
                if let p = project.cutProgress {
                    ProgressView(value: p) { Text("Bildschnitte werden gesucht …").font(.caption) }
                } else if !project.cutMessage.isEmpty {
                    Text(project.cutMessage).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14).padding(.bottom, 10)
            if project.clips.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Zum Anfang der Stelle fahren, **I** drücken", systemImage: "1.circle")
                    Label("Zum Ende fahren, **O** drücken", systemImage: "2.circle")
                    Label("Mit **↩** übernehmen", systemImage: "3.circle")
                    Text("← und → fahren bildweise, mit ⇧ in Zehnerschritten. Die Leertaste startet und stoppt.")
                        .font(.callout).foregroundStyle(.secondary).padding(.top, 6)
                }
                .padding(.horizontal, 14)
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(Array(project.clips.enumerated()), id: \.element.id) { i, clip in ClipRow(index: i, clip: clip) }
                    }
                    .padding(.horizontal, 10)
                }
            }
            Divider()
            HStack {
                VStack(alignment: .leading) {
                    Text("Gesamtlänge").font(.caption).foregroundStyle(.secondary)
                    Text("\(Timecode.short(seconds: Double(project.shortFrames) / project.fps))").font(.title3.monospacedDigit())
                }
                Spacer()
                Button { project.step = .format } label: { Label("Weiter", systemImage: "arrow.right") }
                    .buttonStyle(.borderedProminent).controlSize(.large).disabled(project.clips.isEmpty)
            }
            .padding(14)
        }
    }
}

struct ClipRow: View {
    @EnvironmentObject var project: Project
    let index: Int
    let clip: Clip

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Group {
                    if let img = project.thumbs[clip.id] { Image(nsImage: img).resizable().aspectRatio(contentMode: .fill) } else { Color.gray.opacity(0.3) }
                }
                .frame(width: 80, height: 45).clipShape(RoundedRectangle(cornerRadius: 5))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Clip \(index + 1)").fontWeight(.semibold)
                    Text("\(clip.frames) Bilder · \(Timecode.short(seconds: Double(clip.frames) / project.fps))").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { move(-1) } label: { Image(systemName: "chevron.up") }.disabled(index == 0).help("Nach vorne")
                Button { move(1) } label: { Image(systemName: "chevron.down") }.disabled(index == project.clips.count - 1).help("Nach hinten")
                Button(role: .destructive) { project.clips.remove(at: index) } label: { Image(systemName: "trash") }.help("Clip entfernen")
            }
            .buttonStyle(.borderless)
            HStack(spacing: 4) {
                edge("In", frame: clip.start, goto: clip.start) { d in
                    project.clips[index].start = min(max(0, clip.start + d), clip.end - 1)
                    project.seek(project.clips[index].start)
                }
                Spacer()
                edge("Out", frame: clip.end - 1, goto: clip.end - 1) { d in
                    project.clips[index].end = min(max(clip.start + 1, clip.end + d), project.totalFrames)
                    project.seek(project.clips[index].end - 1)
                }
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private func move(_ d: Int) { project.clips.swapAt(index, index + d) }

    /// Anfang/Ende bildweise nachstellen; Klick auf den Timecode springt dorthin.
    private func edge(_ name: String, frame: Int, goto: Int, nudge: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 2) {
            Button { nudge(-1) } label: { Image(systemName: "minus") }.help("\(name) ein Bild früher")
            Button { project.sourcePlayer.pause(); project.seek(goto) } label: {
                Text("\(name) \(Timecode.string(frame: frame, fps: project.fps))").font(.system(.caption, design: .monospaced))
            }
            .help("Zum \(name)-Bild springen")
            Button { nudge(1) } label: { Image(systemName: "plus") }.help("\(name) ein Bild später")
        }
        .buttonStyle(.borderless).controlSize(.small)
    }
}
