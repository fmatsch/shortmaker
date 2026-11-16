import SwiftUI

/// Schritt 2: Clips als 9:16-Zeitleiste; je Clip den Ausschnitt festlegen oder Personen verfolgen lassen.
struct FormatStep: View {
    @EnvironmentObject var project: Project
    @ObservedObject var head: Playhead
    @LocalState private var dragOrigin = Framing()

    private var index: Int? { project.clipIndex(atShortFrame: head.frame) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                VStack(spacing: 12) {
                    ShortPreview(onDragStart: { if let i = index { dragOrigin = project.clips[i].framing } }, onDrag: pan)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Transport(head: head, total: project.shortFrames).frame(maxWidth: 520)
                }
                .padding(16)
                Divider()
                ScrollView {
                    if let i = index, project.clips.indices.contains(i) {
                        FramingInspector(index: i, sourceFrame: project.clips[i].start + head.frame - project.shortStart(ofClip: i))
                            .padding(14)
                    }
                }
                .frame(width: 340)
            }
            Divider()
            ClipTimeline(head: head).padding(12)
        }
    }

    /// Ziehen in der Vorschau verschiebt das Bild unter dem Ausschnitt.
    private func pan(_ d: CGSize) {
        guard let i = index, project.clips[i].framing.mode != .track else { return }
        let size = project.sourceSize
        let rect = Renderer.cropRect(sourceSize: size, center: CGPoint(x: 0.5, y: 0.5), zoom: project.clips[i].framing.zoom)
        let fit = project.clips[i].framing.mode == .fit
        project.clips[i].framing.centerX = min(1, max(0, dragOrigin.centerX - d.width * (fit ? 1 : rect.width / size.width)))
        project.clips[i].framing.centerY = min(1, max(0, dragOrigin.centerY - d.height * rect.height / size.height))
    }
}

struct FramingInspector: View {
    @EnvironmentObject var project: Project
    let index: Int
    let sourceFrame: Int

    private var clip: Clip { project.clips[index] }
    private var framing: Binding<Framing> { Binding(get: { project.clips[index].framing }, set: { project.clips[index].framing = $0 }) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Clip \(index + 1) von \(project.clips.count)").font(.headline)
                Spacer()
                Button { project.clips.swapAt(index, index - 1) } label: { Image(systemName: "arrow.left") }.disabled(index == 0).help("Clip nach vorne schieben")
                Button { project.clips.swapAt(index, index + 1) } label: { Image(systemName: "arrow.right") }.disabled(index >= project.clips.count - 1).help("Clip nach hinten schieben")
                Button(role: .destructive) { project.clips.remove(at: index) } label: { Image(systemName: "trash") }.help("Clip entfernen")
            }

            SectionBox(title: "Ausschnitt") {
                Picker("", selection: framing.mode) {
                    ForEach(FramingMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()

                switch clip.framing.mode {
                case .manual:
                    Text("Der Ausschnitt steht fest. Zieh das Bild in der Vorschau oder den Rahmen hier an die richtige Stelle.").hint()
                case .track:
                    if let p = project.tracking[clip.id] {
                        ProgressView(value: p) { Text("Personen werden gesucht … \(Int(p * 100)) %").font(.callout) }
                    } else {
                        HStack {
                            Label(clip.isTracked ? "Ausschnitt folgt der Hauptperson" : "Noch nicht verfolgt", systemImage: "person.fill.viewfinder").font(.callout)
                            Spacer()
                            Button("Neu suchen") { project.startTracking(clip) }.controlSize(.small)
                        }
                    }
                    Text("Gesichter und Körper werden lokal erkannt (Apple Vision); die Kamerafahrt wird geglättet.").hint()
                case .fit:
                    Text("Das ganze 16:9-Bild bleibt sichtbar, der Rest wird mit dem unscharfen Bild gefüllt.").hint()
                }

                CropMap(index: index, sourceFrame: sourceFrame)

                if clip.framing.mode == .manual {
                    LabeledSlider(title: "Position waagrecht", value: framing.centerX, range: 0...1)
                    if clip.framing.zoom > 1.01 { LabeledSlider(title: "Position senkrecht", value: framing.centerY, range: 0...1) }
                }
                LabeledSlider(title: "Zoom", value: framing.zoom, range: 1...3) { String(format: "%.2f×", $0) }
                Button("Für alle Clips übernehmen") {
                    let f = clip.framing
                    for i in project.clips.indices { project.clips[i].framing = f }
                }
                .disabled(project.clips.count < 2)
            }

            SectionBox(title: "Hochskalierung") {
                let rect = Renderer.cropRect(sourceSize: project.sourceSize, center: .zero, zoom: clip.framing.zoom)
                if clip.framing.mode == .fit {
                    Text("Im Modus „Ganzes Bild“ wird nicht vergrößert.").hint()
                } else {
                    Text("Ausschnitt \(Int(rect.width)) × \(Int(rect.height)) → 1080 × 1920 (\(String(format: "%.1f", ShortFormat.height / rect.height))-fach)")
                        .font(.callout).monospacedDigit()
                    Text("Die Vorschau vergrößert mit Lanczos und schärft nach. Beim Export kannst du zusätzlich die KI-Hochskalierung (Real-ESRGAN) wählen.").hint()
                }
            }

            Button { project.step = .text } label: { Label("Weiter zu Untertiteln und Titeln", systemImage: "arrow.right") }
                .buttonStyle(.borderedProminent).controlSize(.large).frame(maxWidth: .infinity)
        }
    }
}

/// Das 16:9-Original mit eingezeichnetem 9:16-Ausschnitt; Ziehen setzt die Position.
struct CropMap: View {
    @EnvironmentObject var project: Project
    let index: Int
    let sourceFrame: Int

    var body: some View {
        let clip = project.clips[index], size = project.sourceSize
        GeometryReader { geo in
            let rect = Renderer.cropRect(sourceSize: size, center: clip.center(atSourceFrame: sourceFrame), zoom: clip.framing.zoom)
            let sx = geo.size.width / size.width, sy = geo.size.height / size.height
            // Core-Image-Rechteck (Ursprung unten) → Ansicht (Ursprung oben)
            let view = CGRect(x: rect.minX * sx, y: (size.height - rect.maxY) * sy, width: rect.width * sx, height: rect.height * sy)
            ZStack(alignment: .topLeading) {
                if let img = project.thumbs[clip.id] { Image(nsImage: img).resizable() } else { Color.gray.opacity(0.3) }
                if clip.framing.mode != .fit {
                    Path { p in p.addRect(CGRect(origin: .zero, size: geo.size)); p.addRect(view) }
                        .fill(.black.opacity(0.6), style: FillStyle(eoFill: true))
                    Rectangle().strokeBorder(.white, lineWidth: 2).frame(width: view.width, height: view.height).offset(x: view.minX, y: view.minY)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                guard clip.framing.mode != .fit else { return }
                project.clips[index].framing.mode = .manual
                project.clips[index].framing.centerX = min(1, max(0, v.location.x / geo.size.width))
                project.clips[index].framing.centerY = min(1, max(0, v.location.y / geo.size.height))
            })
        }
        .aspectRatio(size.width / size.height, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

extension Text {
    func hint() -> some View { font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
}
