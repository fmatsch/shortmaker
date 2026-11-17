import SwiftUI

/// Schritt 4: Vorschaubild aus demselben Material und im selben Stil wie das Short.
struct ThumbnailStep: View {
    @EnvironmentObject var project: Project
    @ObservedObject var head: Playhead
    @LocalState private var dragOrigin = CGPoint.zero
    @LocalState private var dragging = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                VStack(spacing: 12) {
                    preview.frame(maxWidth: .infinity, maxHeight: .infinity)
                    frameControls.frame(maxWidth: 560)
                    suggestions
                }
                .padding(16)
                Divider()
                ScrollView { ThumbnailInspector().padding(14) }.frame(width: 380)
            }
            Divider()
            ClipTimeline(head: head).padding(12)
        }
    }

    private var preview: some View {
        let size = project.thumb.format.size
        return GeometryReader { geo in
            ZStack {
                if let img = project.thumbImage { Image(nsImage: img).resizable().interpolation(.high) } else { Color.black }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.12)))
            .overlay(alignment: .topTrailing) {
                if project.thumbBusy { ProgressView().controlSize(.small).padding(10).background(.ultraThinMaterial, in: Circle()).padding(8) }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 2)
                .onChanged { v in
                    if !dragging { dragging = true; dragOrigin = CGPoint(x: project.thumb.x, y: project.thumb.y) }
                    project.thumb.x = min(0.95, max(0.05, dragOrigin.x + v.translation.width / geo.size.width))
                    project.thumb.y = min(0.97, max(0.03, dragOrigin.y + v.translation.height / geo.size.height))
                }
                .onEnded { _ in dragging = false })
            .help("Text an seinen Platz ziehen")
        }
        .aspectRatio(size.width / size.height, contentMode: .fit)
        .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
    }

    private var frameControls: some View {
        HStack(spacing: 6) {
            Text(Timecode.string(frame: head.frame, fps: project.fps)).font(.system(.title3, design: .monospaced).weight(.medium))
            Text("Bild für das Vorschaubild").font(.callout).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Group {
                Button { project.stepFrames(-10) } label: { Image(systemName: "backward.fill") }.help("10 Bilder zurück (⇧←)")
                Button { project.stepFrames(-1) } label: { Image(systemName: "backward.frame.fill") }.help("1 Bild zurück (←)")
                Button { project.stepFrames(1) } label: { Image(systemName: "forward.frame.fill") }.help("1 Bild vor (→)")
                Button { project.stepFrames(10) } label: { Image(systemName: "forward.fill") }.help("10 Bilder vor (⇧→)")
            }
            .controlSize(.large)
        }
    }

    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button { project.suggestThumbnails() } label: { Label("Bilder vorschlagen", systemImage: "sparkles") }
                    .disabled(project.suggesting)
                if project.suggesting { ProgressView().controlSize(.small) }
                Text("Sucht Bilder, auf denen ein Gesicht gut zu sehen ist.").font(.callout).foregroundStyle(.secondary)
                Spacer()
            }
            if !project.thumbSuggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(project.thumbSuggestions) { s in
                            Button { project.shortPlayer.pause(); project.seek(s.frame) } label: {
                                Image(nsImage: s.image).resizable().aspectRatio(contentMode: .fit)
                                    .frame(height: project.thumb.format == .short ? 120 : 80)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                    .overlay(RoundedRectangle(cornerRadius: 6)
                                        .strokeBorder(s.frame == head.frame ? Color.accentColor : .white.opacity(0.15), lineWidth: s.frame == head.frame ? 3 : 1))
                            }
                            .buttonStyle(.plain)
                            .help("Bild \(Timecode.string(frame: s.frame, fps: project.fps)) nehmen")
                        }
                    }
                }
            }
        }
    }
}

struct ThumbnailInspector: View {
    @EnvironmentObject var project: Project

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionBox(title: "Format") {
                Picker("", selection: $project.thumb.format) { ForEach(ThumbFormat.allCases) { Text($0.title).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden()
                Text(project.thumb.format == .short
                     ? "1080 × 1920 – Titelbild für das Short. Der Ausschnitt ist der aus Schritt 2."
                     : "1920 × 1080 – etwa als Vorschaubild für das lange Video.").hint()
            }

            SectionBox(title: "Text") {
                TextEditor(text: $project.thumb.text)
                    .font(.body).frame(height: 62).scrollContentBackground(.hidden).padding(4)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
                Text("Wörter zwischen *Sternchen* erscheinen in der Akzentfarbe.").hint()
                StylePicker(style: $project.thumb.style)
                HStack {
                    ColorPicker("Farbe", selection: $project.thumb.color.color, supportsOpacity: false)
                    Spacer()
                    ColorPicker("Akzent", selection: $project.thumb.accent.color, supportsOpacity: false)
                }
                LabeledSlider(title: "Größe", value: $project.thumb.size, range: 0.06...0.25) { String(format: "%.0f px", $0 * 1080) }
                HStack { Toggle("Großbuchstaben", isOn: $project.thumb.uppercase); Spacer(); Toggle("Schräg", isOn: $project.thumb.tilt) }
                if !project.titles.isEmpty {
                    Button("Stil vom ersten Titel übernehmen") { project.applyTitleStyleToThumb() }
                }
                Text("Zieh den Text in der Vorschau an seinen Platz.").hint()
            }

            SectionBox(title: "Bild") {
                LabeledSlider(title: "Zoom", value: $project.thumb.zoom, range: 1...2.5) { String(format: "%.2f×", $0) }
                LabeledSlider(title: "Kräftige Farben", value: $project.thumb.vivid, range: 0...1)
                LabeledSlider(title: "Vignette", value: $project.thumb.vignette, range: 0...1)
                LabeledSlider(title: "Abdunkeln hinter dem Text", value: $project.thumb.shade, range: 0...1)
                if AIUpscaler.isAvailable {
                    Toggle("KI-Schärfe (Real-ESRGAN)", isOn: $project.thumb.ai)
                    Text("Vergrößert den Ausschnitt mit KI für sichtbar mehr Detail. Nach einer Änderung an Bild oder Zoom dauert das etwa eine Sekunde.").hint()
                }
            }

            Button { project.saveThumbnail() } label: { Label("Vorschaubild sichern …", systemImage: "square.and.arrow.down") }
                .buttonStyle(.borderedProminent).controlSize(.large).frame(maxWidth: .infinity)
                .disabled(project.thumbImage == nil)
            if let saved = project.thumbSaved {
                HStack {
                    Label("Gesichert: \(saved.lastPathComponent)", systemImage: "checkmark.circle.fill").foregroundStyle(.green).lineLimit(1)
                    Spacer()
                    Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([saved]) }.controlSize(.small)
                }
            }
            Text("Als JPEG bleibt das Bild meist unter den 2 MB, die YouTube für Vorschaubilder erlaubt.").hint()
        }
    }
}
