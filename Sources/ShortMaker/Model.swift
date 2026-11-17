import Foundation
import CoreGraphics
import SwiftUI

/// Ausgabeformat des Shorts (9:16, Full HD hochkant).
enum ShortFormat {
    static let width = 1080.0, height = 1920.0
    static let size = CGSize(width: width, height: height)
    static let aspect = width / height
}

enum Step: Int, CaseIterable {
    case select, format, text, thumbnail
    var title: String { ["Auswahl", "Format", "Text", "Vorschaubild"][rawValue] }
    var symbol: String { ["scissors", "rectangle.portrait", "captions.bubble", "photo"][rawValue] }
}

enum FramingMode: String, CaseIterable, Identifiable {
    case manual, track, fit
    var id: String { rawValue }
    var title: String {
        switch self {
        case .manual: return "Manuell"
        case .track: return "Verfolgen"
        case .fit: return "Ganzes Bild"
        }
    }
}

/// Welcher Teil des 16:9-Bildes im 9:16-Short landet.
struct Framing: Equatable {
    var mode: FramingMode = .manual
    var centerX = 0.5       // 0…1, von links
    var centerY = 0.5       // 0…1, von oben
    var zoom = 1.0          // 1 = volle Bildhöhe
}

struct Clip: Identifiable, Equatable {
    var id = UUID()
    var start: Int          // erstes Quellbild (inklusive)
    var end: Int            // letztes Quellbild + 1
    var framing = Framing()
    /// Verfolgte Bildmitte je Quellbild ab `trackStart` (x von links, y von oben, 0…1)
    var track: [CGPoint] = []
    var trackStart = 0
    var frames: Int { max(0, end - start) }
    var isTracked: Bool { !track.isEmpty && trackStart <= start && trackStart + track.count >= end }

    func center(atSourceFrame f: Int) -> CGPoint {
        if framing.mode == .track, !track.isEmpty {
            let p = track[min(max(0, f - trackStart), track.count - 1)]
            // Bei Zoom 1 bestimmt nur x den Ausschnitt; y folgt der Person erst, wenn hineingezoomt ist
            return p
        }
        return CGPoint(x: framing.centerX, y: framing.centerY)
    }
}

struct RGBA: Hashable {
    var r = 1.0, g = 1.0, b = 1.0
    static let white = RGBA(), black = RGBA(r: 0, g: 0, b: 0)
    static let yellow = RGBA(r: 1, g: 0.9, b: 0.1), pink = RGBA(r: 1, g: 0.18, b: 0.47)
    var luminance: Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }
    var cg: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: 1) }
    var color: Color {
        get { Color(.sRGB, red: r, green: g, blue: b) }
        set {
            guard let c = NSColor(newValue).usingColorSpace(.sRGB) else { return }
            r = Double(c.redComponent); g = Double(c.greenComponent); b = Double(c.blueComponent)
        }
    }
}

enum TextStyle: String, CaseIterable, Identifiable {
    case outline, box, glow, shadow
    var id: String { rawValue }
    var title: String {
        switch self {
        case .outline: return "Kontur"
        case .box: return "Kasten"
        case .glow: return "Leuchten"
        case .shadow: return "Schatten"
        }
    }
}

struct TitleItem: Identifiable, Equatable {
    var id = UUID()
    var text = "Dein Titel"
    var style: TextStyle = .box
    var color = RGBA.white
    var size = 0.085        // Schrifthöhe als Anteil der Bildbreite
    var x = 0.5, y = 0.16   // Mitte, 0…1 (y von oben)
    var wholeVideo = true
    var start = 0.0, end = 3.0
    var uppercase = false
}

struct Word: Equatable {
    var text: String
    var start: Double
    var end: Double
}

struct SubtitleCue: Identifiable, Equatable {
    var id = UUID()
    var words: [Word]
    var start: Double { words.first?.start ?? 0 }
    var end: Double { words.last?.end ?? 0 }
    var text: String {
        get { words.map(\.text).joined(separator: " ") }
        set {
            let parts = newValue.split(whereSeparator: \.isWhitespace).map(String.init)
            guard !parts.isEmpty else { return }
            if parts.count == words.count {
                for i in parts.indices { words[i].text = parts[i] }
            } else {    // Wortzahl geändert: Zeit gleichmäßig über den Abschnitt verteilen
                let s = start, d = max(0.05, end - start) / Double(parts.count)
                words = parts.enumerated().map { Word(text: $1, start: s + Double($0) * d, end: s + Double($0 + 1) * d) }
            }
        }
    }
}

struct SubtitleStyle: Equatable {
    var enabled = true
    var style: TextStyle = .outline
    var color = RGBA.white
    var highlight = true
    var highlightColor = RGBA.yellow
    var size = 0.075
    var y = 0.72
    var uppercase = true
    var pop = true
    var wordsPerCue = 3
}

enum Subtitles {
    /// Wörter zu kurzen Einblendungen bündeln – Social-Media-typisch wenige Wörter auf einmal.
    static func cues(from words: [Word], perCue: Int) -> [SubtitleCue] {
        var cues: [SubtitleCue] = [], cur: [Word] = []
        func flush() { if !cur.isEmpty { cues.append(SubtitleCue(words: cur)); cur = [] } }
        for w in words {
            if let last = cur.last {
                let chars = cur.reduce(0) { $0 + $1.text.count + 1 } + w.text.count
                let sentenceEnd = last.text.last.map { ".!?…".contains($0) } ?? false
                if cur.count >= perCue || w.start - last.end > 0.6 || sentenceEnd || (chars > 26 && cur.count > 1) { flush() }
            }
            cur.append(w)
        }
        flush()
        // kurze Lücken schließen, damit die Untertitel nicht flackern
        for i in cues.indices.dropLast() where cues[i + 1].start - cues[i].end < 0.35 {
            cues[i].words[cues[i].words.count - 1].end = cues[i + 1].start
        }
        return cues
    }

    static func srt(_ cues: [SubtitleCue]) -> String {
        func ts(_ t: Double) -> String {
            let ms = Int((t * 1000).rounded())
            return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60000 % 60, ms / 1000 % 60, ms % 1000)
        }
        return cues.enumerated().map { "\($0 + 1)\n\(ts($1.start)) --> \(ts($1.end))\n\($1.text)\n" }.joined(separator: "\n")
    }
}

enum Timecode {
    static func string(frame: Int, fps: Double) -> String {
        let base = max(1, Int(fps.rounded()))
        let f = max(0, frame)
        let s = f / base
        return String(format: "%02d:%02d:%02d:%02d", s / 3600, s / 60 % 60, s % 60, f % base)
    }
    static func short(seconds: Double) -> String {
        let s = max(0, seconds)
        return String(format: "%d:%04.1f", Int(s) / 60, s.truncatingRemainder(dividingBy: 60))
    }
}
