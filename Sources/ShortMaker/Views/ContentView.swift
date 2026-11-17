import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var project: Project
    @LocalState private var showExport = false
    @LocalState private var keyMonitor: Any?

    var body: some View {
        VStack(spacing: 0) {
            if project.url == nil {
                DropZone()
            } else {
                StepBar(showExport: $showExport)
                Divider()
                switch project.step {
                case .select: SelectStep(head: project.sourceHead)
                case .format: FormatStep(head: project.shortHead)
                case .text: TextStep(head: project.shortHead)
                case .thumbnail: ThumbnailStep(head: project.shortHead)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            _ = providers.first?.loadObject(ofClass: URL.self) { url, _ in
                if let url { Task { @MainActor in project.open(url) } }
            }
            return true
        }
        .sheet(isPresented: $showExport) { ExportSheet() }
        .alert("Hinweis", isPresented: Binding(get: { project.errorMessage != nil }, set: { if !$0 { project.errorMessage = nil } })) {
            Button("OK") { project.errorMessage = nil }
        } message: { Text(project.errorMessage ?? "") }
        .onAppear(perform: installKeys)
    }

    /// Tastatur: Leertaste, Pfeile (bildweise), I/O, Eingabe – außer beim Tippen in Textfeldern.
    private func installKeys() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if NSApp.keyWindow?.firstResponder is NSText || project.url == nil || NSApp.keyWindow?.sheets.isEmpty == false { return event }
            if event.modifierFlags.contains(.command) { return event }
            let shift = event.modifierFlags.contains(.shift)
            switch event.keyCode {
            case 49 where project.step != .thumbnail: project.togglePlay()
            case 123: project.stepFrames(shift ? -10 : -1)
            case 124: project.stepFrames(shift ? 10 : 1)
            case 34 where project.step == .select: project.setIn()
            case 31 where project.step == .select: project.setOut()
            case 36 where project.step == .select && project.canAddClip: project.addClip()
            default: return event
            }
            return nil
        }
    }
}

struct DropZone: View {
    @EnvironmentObject var project: Project
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "rectangle.portrait.on.rectangle.portrait.angled").font(.system(size: 64, weight: .light)).foregroundStyle(.tint)
            Text("Aus langen Videos werden Shorts").font(.largeTitle.weight(.semibold))
            Text("Zieh ein 16:9-Video hierher. Du wählst bildgenau die Stellen aus,\nShortMaker macht daraus ein 9:16-Video mit Untertiteln und Titeln.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            if project.loading { ProgressView().controlSize(.large) }
            else { Button("Video öffnen …") { openVideoPanel(project) }.controlSize(.large).buttonStyle(.borderedProminent) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

struct StepBar: View {
    @EnvironmentObject var project: Project
    @Binding var showExport: Bool

    var body: some View {
        HStack(spacing: 10) {
            Button { openVideoPanel(project) } label: { Label(project.url?.lastPathComponent ?? "", systemImage: "film") }
                .buttonStyle(.plain).foregroundStyle(.secondary).lineLimit(1).help("Anderes Video öffnen")
                .frame(maxWidth: 200, alignment: .leading)
            Spacer()
            ForEach(Step.allCases, id: \.self) { s in
                let enabled = s == .select || !project.clips.isEmpty
                Button { project.step = s } label: {
                    HStack(spacing: 6) {
                        Text("\(s.rawValue + 1)").font(.caption.weight(.bold))
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(project.step == s ? Color.white.opacity(0.25) : Color.secondary.opacity(0.2)))
                        Label(s.title, systemImage: s.symbol)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Capsule().fill(project.step == s ? Color.accentColor : Color.clear))
                    .foregroundStyle(project.step == s ? .white : .primary)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain).disabled(!enabled).opacity(enabled ? 1 : 0.4)
                if s != Step.allCases.last { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) }
            }
            Spacer()
            Text(project.clips.isEmpty ? "" : "Short: \(Timecode.short(seconds: Double(project.shortFrames) / project.fps))")
                .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                .frame(width: 130, alignment: .trailing)
            Button { showExport = true } label: { Label("Exportieren", systemImage: "square.and.arrow.up") }
                .buttonStyle(.borderedProminent).disabled(project.clips.isEmpty || project.step == .select)
                .help(project.step == .select ? "Erst Bereiche wählen und zu „Format“ wechseln" : "Short als MP4 sichern")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
}

struct ExportSheet: View {
    @EnvironmentObject var project: Project
    @Environment(\.dismiss) private var dismiss
    @LocalState private var quality: Exporter.Quality = .fast
    @LocalState private var hevc = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Short exportieren").font(.title2.weight(.semibold))
            Text("1080 × 1920, \(String(format: "%.2f", project.fps)) Bilder/s, \(Timecode.short(seconds: Double(project.shortFrames) / project.fps))")
                .foregroundStyle(.secondary)
            Picker("Hochskalierung", selection: $quality) {
                ForEach(Exporter.Quality.allCases) { q in Text(q.title).tag(q) }
            }
            .pickerStyle(.radioGroup).disabled(project.exportProgress != nil)
            if quality == .ai {
                Text(AIUpscaler.isAvailable ? "Jeder Ausschnitt wird mit Real-ESRGAN vierfach vergrößert und dann auf 1080 × 1920 gebracht. Das dauert pro Bild etwa eine halbe bis ganze Sekunde."
                     : "Das Real-ESRGAN-Modell wurde nicht gefunden.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Toggle("HEVC (H.265) statt H.264 – kleinere Datei", isOn: $hevc).disabled(project.exportProgress != nil)
            if let p = project.exportProgress {
                ProgressView(value: p) { Text("Wird exportiert … \(Int(p * 100)) %").monospacedDigit() }
            } else if let done = project.exportedURL {
                Label("Gesichert: \(done.lastPathComponent)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            }
            HStack {
                if let done = project.exportedURL, project.exportProgress == nil {
                    Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([done]) }
                }
                Spacer()
                if project.exportProgress != nil {
                    Button("Abbrechen") { project.cancelExport() }
                } else {
                    Button("Schließen") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Sichern …") { save() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                        .disabled(quality == .ai && !AIUpscaler.isAvailable)
                }
            }
        }
        .padding(24).frame(width: 460)
    }

    private func save() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = (project.url?.deletingPathExtension().lastPathComponent ?? "Short") + " – Short.mp4"
        if panel.runModal() == .OK, let url = panel.url { project.export(to: url, quality: quality, hevc: hevc) }
    }
}
