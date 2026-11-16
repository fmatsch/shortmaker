import SwiftUI

struct ShortMakerApp: App {
    @StateObject private var project = Project()

    var body: some Scene {
        Window("ShortMaker", id: "main") {
            ContentView()
                .environmentObject(project)
                .frame(minWidth: 1080, minHeight: 700)
                .onOpenURL { project.open($0) }
                .task { await project.runDemoIfRequested() }
        }
        .defaultSize(width: 1320, height: 840)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Video öffnen …") { openVideoPanel(project) }.keyboardShortcut("o")
            }
        }
    }
}

@MainActor func openVideoPanel(_ project: Project) {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
    panel.allowsMultipleSelection = false
    if panel.runModal() == .OK, let url = panel.url { project.open(url) }
}
