import Foundation
import AVFoundation
import CoreImage
import AppKit

/// Prüft die Bildkette ohne Oberfläche:  ShortMaker --selftest <video> <ausgabeordner> [ai] [whisper]
enum SelfTest {
    static func run(_ args: [String]) async -> Int32 {
        guard args.count >= 2 else { print("Aufruf: --selftest <video> <ausgabeordner> [ai] [whisper]"); return 2 }
        let out = URL(fileURLWithPath: args[1])
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        do {
            let asset = AVURLAsset(url: URL(fileURLWithPath: args[0]), options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            guard let vt = try await asset.loadTracks(withMediaType: .video).first else { print("keine Videospur"); return 1 }
            let fd = Composer.frameDuration(fps: try await vt.load(.nominalFrameRate))
            let fps = 1 / fd.seconds
            let total = Int(try await asset.load(.duration).seconds * fps)
            print("Quelle: \(total) Bilder, \(fps) fps")
            let third = total / 3
            var a = Clip(start: third / 4, end: third / 4 + min(third, Int(fps * 3)))
            var b = Clip(start: 2 * third, end: 2 * third + min(third - 1, Int(fps * 3)))
            var c = Clip(start: third, end: third + min(third, Int(fps * 2)))
            a.framing.mode = .track
            a.track = try await Tracker.track(asset: asset, start: a.start, frames: a.frames, frameDuration: fd) { _ in }
            a.trackStart = a.start
            print("Verfolgung: \(a.track.count) Punkte, x von \(a.track.map(\.x).min() ?? 0) bis \(a.track.map(\.x).max() ?? 0)")
            b.framing = Framing(mode: .manual, centerX: 0.8, centerY: 0.3, zoom: 1.5)
            c.framing.mode = .fit
            let clips = [a, b, c]
            let comp = try await Composer.composition(asset: asset, clips: clips, frameDuration: fd)
            print("Zeitleiste: \(try await comp.load(.duration).seconds) s, erwartet \(Double(clips.reduce(0) { $0 + $1.frames }) / fps) s")

            var snap = RenderSnapshot(fps: fps)
            var at = 0
            for cl in clips { snap.clips.append(.init(tlStart: at, clip: cl)); at += cl.frames }
            let dur = Double(at) / fps
            snap.titles = [TitleItem(text: "So geht\nShortMaker", style: .box, color: .white, y: 0.14),
                           TitleItem(text: "Leuchten", style: .glow, color: .pink, size: 0.1, y: 0.3),
                           TitleItem(text: "Schatten", style: .shadow, color: .yellow, size: 0.1, y: 0.42)]
            if args.contains("whisper") {
                let samples = try await Transcriber.samples(from: comp)
                print("Ton: \(samples.count) Abtastwerte")
                let words = try await Transcriber().transcribe(samples: samples, language: "de") { _ in }
                print("Whisper: " + words.map { "\($0.text)[\(String(format: "%.2f", $0.start))]" }.joined(separator: " "))
                snap.cues = Subtitles.cues(from: words, perCue: 3)
                try Subtitles.srt(snap.cues).write(to: out.appendingPathComponent("test.srt"), atomically: true, encoding: .utf8)
            } else {
                let demo = ["Das", "ist", "ein", "Test", "für", "die", "Untertitel", "im", "Short."]
                let d = dur / Double(demo.count)
                snap.cues = Subtitles.cues(from: demo.enumerated().map { Word(text: $1, start: Double($0) * d, end: Double($0 + 1) * d) }, perCue: 3)
            }

            // Vorschau-Pfad: Einzelbilder über dieselbe Videokomposition wie im Player
            let state = RenderState(); state.snapshot = snap
            let gen = AVAssetImageGenerator(asset: comp)
            gen.videoComposition = Composer.videoComposition(for: comp, frameDuration: fd, state: state)
            gen.requestedTimeToleranceBefore = .zero; gen.requestedTimeToleranceAfter = .zero
            for (i, t) in [0.5, Double(a.frames) / fps + 0.5, dur - 0.5].enumerated() {
                let cg = try await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image
                let rep = NSBitmapImageRep(cgImage: cg)
                try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("preview\(i).png"))
                print("Vorschaubild \(i): \(cg.width)×\(cg.height)")
            }
            let t0 = Date()
            try await Exporter.export(composition: comp, frameDuration: fd, snapshot: snap, quality: args.contains("ai") ? .ai : .fast, hevc: false,
                                      to: out.appendingPathComponent("short.mp4")) { _ in }
            print("Export fertig in \(String(format: "%.1f", Date().timeIntervalSince(t0))) s")
            return 0
        } catch { print("FEHLER: \(error)"); return 1 }
    }
}
