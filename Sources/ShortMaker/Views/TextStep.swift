import SwiftUI
import UniformTypeIdentifiers

/// Schritt 3: Whisper-Untertitel und eigene Titel.
struct TextStep: View {
    @EnvironmentObject var project: Project
    @ObservedObject var head: Playhead
    @LocalState private var tab = 0
    @LocalState private var dragOrigin = CGPoint.zero

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                VStack(spacing: 12) {
                    ShortPreview(onDragStart: startDrag, onDrag: drag).frame(maxWidth: .infinity, maxHeight: .infinity)
                    Transport(head: head, total: project.shortFrames).frame(maxWidth: 520)
                }
                .padding(16)
                Divider()
                VStack(spacing: 0) {
                    Picker("", selection: $tab) { Text("Untertitel").tag(0); Text("Titel").tag(1) }
                        .pickerStyle(.segmented).labelsHidden().padding(14)
                    ScrollView {
                        Group { if tab == 0 { SubtitlePanel() } else { TitlePanel(head: head) } }.padding([.horizontal, .bottom], 14)
                    }
                }
                .frame(width: 380)
            }
            Divider()
            ClipTimeline(head: head).padding(12)
        }
    }

    private var titleIndex: Int? { project.titles.firstIndex { $0.id == project.selectedTitle } }

    private func startDrag() {
        if tab == 1, let i = titleIndex { dragOrigin = CGPoint(x: project.titles[i].x, y: project.titles[i].y) }
        else { dragOrigin = CGPoint(x: 0.5, y: project.subStyle.y) }
    }

    /// Ziehen in der Vorschau verschiebt den gewählten Titel bzw. die Untertitel-Höhe.
    private func drag(_ d: CGSize) {
        if tab == 1, let i = titleIndex {
            project.titles[i].x = min(0.95, max(0.05, dragOrigin.x + d.width))
            project.titles[i].y = min(0.97, max(0.03, dragOrigin.y + d.height))
        } else if tab == 0 {
            project.subStyle.y = min(0.95, max(0.05, dragOrigin.y + d.height))
        }
    }
}

struct StylePicker: View {
    @Binding var style: TextStyle
    var body: some View {
        Picker("Stil", selection: $style) { ForEach(TextStyle.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented).labelsHidden()
    }
}

struct SubtitlePanel: View {
    @EnvironmentObject var project: Project
    private let languages = [("de", "Deutsch"), ("en", "Englisch"), ("fr", "Französisch"), ("es", "Spanisch"), ("it", "Italienisch"), ("auto", "Automatisch erkennen")]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionBox(title: "Spracherkennung") {
                if !project.whisperAvailable {
                    Text("Für Untertitel wird einmalig das Whisper-Modell (large-v3 turbo, ca. 630 MB) geladen. Danach läuft die Erkennung ohne Internet auf diesem Mac.").hint()
                    Button("Whisper-Modell laden") { project.downloadWhisper() }.disabled(project.whisperProgress != nil)
                } else {
                    Picker("Sprache", selection: $project.language) { ForEach(languages, id: \.0) { Text($0.1).tag($0.0) } }
                    Button { project.generateSubtitles() } label: {
                        Label(project.cues.isEmpty ? "Untertitel erzeugen" : "Neu erzeugen", systemImage: "waveform.badge.mic")
                    }
                    .buttonStyle(.borderedProminent).disabled(project.whisperProgress != nil)
                }
                if let p = project.whisperProgress { ProgressView(value: p) { Text(project.whisperStatus).font(.callout) } }
                else if !project.whisperStatus.isEmpty { Text(project.whisperStatus).hint() }
                if project.subtitlesStale {
                    Label("Die Clips haben sich geändert – bitte Untertitel neu erzeugen.", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.orange)
                }
            }

            SectionBox(title: "Aussehen") {
                Toggle("Untertitel einblenden", isOn: $project.subStyle.enabled)
                StylePicker(style: $project.subStyle.style)
                HStack {
                    ColorPicker("Farbe", selection: $project.subStyle.color.color, supportsOpacity: false)
                    Spacer()
                    Toggle("Wort hervorheben", isOn: $project.subStyle.highlight)
                    ColorPicker("", selection: $project.subStyle.highlightColor.color, supportsOpacity: false).labelsHidden().disabled(!project.subStyle.highlight)
                }
                LabeledSlider(title: "Größe", value: $project.subStyle.size, range: 0.04...0.14) { String(format: "%.0f px", $0 * ShortFormat.width) }
                LabeledSlider(title: "Höhe im Bild", value: $project.subStyle.y, range: 0.05...0.95)
                Stepper("Wörter je Einblendung: \(project.subStyle.wordsPerCue)", value: $project.subStyle.wordsPerCue, in: 1...7)
                HStack { Toggle("Großbuchstaben", isOn: $project.subStyle.uppercase); Spacer(); Toggle("Aufploppen", isOn: $project.subStyle.pop) }
                Text("Tipp: Zieh in der Vorschau nach oben oder unten, um die Untertitel zu verschieben. Eine andere Wortzahl teilt den Text neu auf – eigene Korrekturen gehen dabei verloren.").hint()
            }

            if !project.cues.isEmpty {
                SectionBox(title: "Text korrigieren") {
                    ForEach($project.cues) { $cue in
                        HStack(spacing: 8) {
                            Button(Timecode.short(seconds: cue.start)) { project.shortPlayer.pause(); project.seek(Int((cue.start * project.fps).rounded(.up))) }
                                .buttonStyle(.borderless).font(.system(.caption, design: .monospaced)).frame(width: 52, alignment: .leading)
                            TextField("", text: $cue.text).textFieldStyle(.roundedBorder)
                        }
                    }
                    Button("Als SRT sichern …") { saveSRT() }
                }
            }
        }
    }

    private func saveSRT() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "srt") ?? .plainText]
        panel.nameFieldStringValue = (project.url?.deletingPathExtension().lastPathComponent ?? "Short") + ".srt"
        if panel.runModal() == .OK, let url = panel.url { try? Subtitles.srt(project.cues).write(to: url, atomically: true, encoding: .utf8) }
    }
}

struct TitlePanel: View {
    @EnvironmentObject var project: Project
    @ObservedObject var head: Playhead

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button { project.addTitle() } label: { Label("Titel hinzufügen", systemImage: "plus") }.buttonStyle(.borderedProminent)
            if project.titles.isEmpty {
                Text("Titel sind frei platzierbare Texte im Social-Media-Stil – etwa eine Überschrift, die das ganze Short über stehen bleibt.").hint()
            }
            ForEach($project.titles) { $title in
                let selected = title.id == project.selectedTitle
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        TextField("Text", text: $title.text, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(1...4)
                            .onTapGesture { project.selectedTitle = title.id }
                        Button(role: .destructive) { project.titles.removeAll { $0.id == title.id } } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                    }
                    if selected {
                        StylePicker(style: $title.style)
                        HStack {
                            ColorPicker("Farbe", selection: $title.color.color, supportsOpacity: false)
                            Spacer()
                            Toggle("Großbuchstaben", isOn: $title.uppercase)
                        }
                        LabeledSlider(title: "Größe", value: $title.size, range: 0.04...0.2) { String(format: "%.0f px", $0 * ShortFormat.width) }
                        Toggle("Über das ganze Short zeigen", isOn: $title.wholeVideo)
                        if !title.wholeVideo {
                            let total = max(0.1, Double(project.shortFrames) / project.fps)
                            LabeledSlider(title: "Ab", value: $title.start, range: 0...total) { Timecode.short(seconds: $0) }
                            LabeledSlider(title: "Bis", value: $title.end, range: 0...total) { Timecode.short(seconds: $0) }
                            HStack {
                                Button("Ab hier") { title.start = Double(head.frame) / project.fps; title.end = max(title.end, title.start + 0.5) }
                                Button("Bis hier") { title.end = Double(head.frame + 1) / project.fps; title.start = min(title.start, title.end - 0.1) }
                            }
                            .controlSize(.small)
                        }
                        Text("Zieh den Titel in der Vorschau an seinen Platz.").hint()
                    }
                }
                .padding(12)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2))
                .contentShape(Rectangle())
                .onTapGesture { project.selectedTitle = title.id }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
