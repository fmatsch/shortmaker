import Foundation
import AppKit

/// Übergabe an YT Producer: legt das Projekt so an, wie YT Producer selbst ein eigenes Video
/// als Short anlegt – Ordner unter „ON Downloads/<Sendung>/<Titel>“, Clip in „Segmente“,
/// Vorschaubild in „Vorschaubilder“, Transkript in „Transkripte“, dazu project.json mit ohneBumper.
enum ProducerHandoff {
    static let bundleID = "at.fmatsch.ytproducer"

    static var appURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) }

    /// Ausgabeordner von YT Producer (dort sucht die App unter „02 Projekte“).
    static var root: URL {
        if let r = ProcessInfo.processInfo.environment["SHORTMAKER_PRODUCER_ROOT"] { return URL(fileURLWithPath: r, isDirectory: true) }
        return (FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Movies"))
            .appendingPathComponent("ON Downloads", isDirectory: true)
    }

    /// Sendungsordner, die es schon gibt – „Eigene Videos“ immer zuerst.
    static func shows() -> [String] {
        let subs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        let names = subs.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }.map(\.lastPathComponent)
        return ["Eigene Videos"] + names.filter { $0 != "Eigene Videos" }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Wie in YT Producer: Titel als Ordnername.
    static func folderName(_ title: String) -> String {
        let clean = title.components(separatedBy: CharacterSet(charactersIn: "/\\:?*\"<>|\n\r")).joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? "Eigenes Video" : String(clean.prefix(80))
    }

    /// Wie die Segmentdateien in YT Producer: „01_Titel_mit_Unterstrichen“.
    static func fileStem(_ title: String) -> String {
        let folded = title.folding(options: [.diacriticInsensitive], locale: Locale(identifier: "de_AT"))
            .replacingOccurrences(of: "ß", with: "ss")
        var out = "", lastUnderscore = false
        for ch in folded {
            if ch.isASCII && (ch.isLetter || ch.isNumber || ch == "-") { out.append(ch); lastUnderscore = false }
            else if !lastUnderscore { out.append("_"); lastUnderscore = true }
        }
        let stem = out.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return "01_" + (stem.isEmpty ? "Short" : String(stem.prefix(70)))
    }

    struct Plan {
        var show: String, title: String
        var folder: URL
        var clip: URL, source: URL, thumbnail: URL, transcriptJSON: URL, transcriptSRT: URL
    }

    /// Zielpfade; gibt es den Ordner schon, wird „(2)“, „(3)“ … angehängt.
    static func plan(show: String, title: String) -> Plan {
        let showName = folderName(show.isEmpty ? "Eigene Videos" : show)
        var name = folderName(title), n = 2
        while FileManager.default.fileExists(atPath: root.appendingPathComponent(showName).appendingPathComponent(name).path) {
            name = folderName(title) + " (\(n))"; n += 1
        }
        let folder = root.appendingPathComponent(showName, isDirectory: true).appendingPathComponent(name, isDirectory: true)
        let stem = fileStem(title)
        return Plan(show: showName, title: title, folder: folder,
                    clip: folder.appendingPathComponent("Segmente/\(stem).mp4"),
                    source: folder.appendingPathComponent("\(name).mp4"),
                    thumbnail: folder.appendingPathComponent("Vorschaubilder/01.jpg"),
                    transcriptJSON: folder.appendingPathComponent("Transkripte/\(stem).json"),
                    transcriptSRT: folder.appendingPathComponent("Transkripte/\(stem).de.srt"))
    }

    // Spiegel der Datentypen von YT Producer (Project / ProjectItem / Transcript), nur die nötigen Felder.
    private struct PItem: Encodable {
        var index = 1, segmentType = "beitrag"
        var start = 0.0, end: Double
        var clipPath: String, title: String, text: String
        var thumbnailPath: String?, transcriptPath: String?
    }
    private struct PProject: Encodable {
        var id = UUID()
        var showLabel: String, onShowID = "shortmaker"
        var episodeTitle: String, airedAt: Date
        var folder: String, sourceVideo: String
        var items: [PItem]
        var orfItems: [String] = []
        var ohneBumper = true
        var updatedAt = Date()
    }
    private struct PSegment: Encodable { var start: Double, end: Double, text: String }
    private struct PTranscript: Encodable {
        var video: String, language: String, model = "whisper-large-v3-turbo (ShortMaker)"
        var segments: [PSegment], text: String
    }

    static func writeProject(_ p: Plan, text: String, duration: Double, hasThumbnail: Bool, cues: [SubtitleCue], language: String) throws {
        var transcriptPath: String?
        if !cues.isEmpty {
            try FileManager.default.createDirectory(at: p.transcriptJSON.deletingLastPathComponent(), withIntermediateDirectories: true)
            let segs = cues.map { PSegment(start: $0.start, end: $0.end, text: $0.text) }
            let t = PTranscript(video: p.clip.path, language: language == "auto" ? "de" : language, segments: segs,
                                text: segs.map(\.text).joined(separator: " "))
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
            try enc.encode(t).write(to: p.transcriptJSON, options: .atomic)
            try Subtitles.srt(cues).write(to: p.transcriptSRT, atomically: true, encoding: .utf8)
            transcriptPath = p.transcriptJSON.path
        }
        let item = PItem(end: duration, clipPath: p.clip.path, title: p.title, text: text,
                         thumbnailPath: hasThumbnail ? p.thumbnail.path : nil, transcriptPath: transcriptPath)
        let project = PProject(showLabel: p.show, episodeTitle: p.title, airedAt: Calendar.current.startOfDay(for: Date()),
                               folder: p.folder.path, sourceVideo: p.source.path, items: [item])
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(project).write(to: p.folder.appendingPathComponent("project.json"), options: .atomic)
    }

    static func openProducer() {
        guard let url = appURL else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}
