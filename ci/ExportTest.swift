import AVFoundation
import Foundation

// Provkör MovieBuilder utan fönster: bygger en film av filerna och sparar den.
// Används bara av GitHub-bygget. Kompileras ihop med Model.swift och MovieBuilder.swift.

@main
struct ExportTest {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count >= 6 else {
            print("användning: ExportTest ut.mp4 musik.m4a bild.png effekt.wav film1 film2 …")
            exit(2)
        }
        let out = URL(fileURLWithPath: args[0])
        try? FileManager.default.removeItem(at: out)
        var p = Project()
        p.musicPath = args[1]
        for path in args.dropFirst(4) {
            let d = AVURLAsset(url: URL(fileURLWithPath: path)).duration.seconds
            var c = Clip(path: path, sourceDuration: d, start: 0.5, end: d - 0.5)
            c.volume = 0.8
            p.clips.append(c)
        }
        // Första klippet baklänges.
        let t0 = Date()
        do {
            let src = URL(fileURLWithPath: p.clips[0].path)
            let rev = try ReverseRenderer.render(src, progress: { _ in })
            let a = AVURLAsset(url: rev)
            let v = a.tracks(withMediaType: .video).first
            print("baklänges: \(String(format: "%.2f", a.duration.seconds)) s (original \(String(format: "%.2f", AVURLAsset(url: src).duration.seconds)) s), ljudfil \(FileManager.default.fileExists(atPath: ReverseRenderer.audioURL(forReversed: rev).path)), storlek \(v.map { "\(Int($0.naturalSize.width))x\(Int($0.naturalSize.height))" } ?? "-"), tog \(String(format: "%.1f", Date().timeIntervalSince(t0))) s")
            p.clips[0].reversedPath = rev.path
            try? rev.path.write(to: out.deletingLastPathComponent().appendingPathComponent("baklanges.txt"),
                                atomically: true, encoding: .utf8)
        } catch {
            print("FEL: baklänges \(error)")
            exit(1)
        }
        // Bild som börjar på filmen och fortsätter efter den (svart utfyllnad).
        let img = Overlay.loadImage(URL(fileURLWithPath: args[2]), maxPixels: 256)!
        p.stills.append(StillItem(path: args[2], aspect: Double(img.width) / Double(img.height),
                                  start: 3.5, duration: 3.5, x: 0.7, y: 0.45, scale: 0.6))
        p.texts.append(TextItem(text: "Hej från Filmklipparen! Åäö", start: 0.2, duration: 2.5))
        var t2 = TextItem(text: "Stor gul text\növer bilden", start: 4.5, duration: 2.4)
        t2.font = "Marker Felt"; t2.color = 1; t2.size = 0.12; t2.x = 0.3; t2.y = 0.3
        p.texts.append(t2)
        let sd = AVURLAsset(url: URL(fileURLWithPath: args[3])).duration.seconds
        p.sounds.append(SoundItem(path: args[3], sourceDuration: sd, start: 1.0, duration: min(sd, 1.0)))
        p.sounds.append(SoundItem(path: args[3], sourceDuration: sd, inPoint: 0.2, start: 5.0, duration: 0.5))
        print("väntad längd \(p.duration) s (film \(p.filmDuration) s)")

        do {
            guard let b = try MovieBuilder.build(p, forExport: true),
                  let s = AVAssetExportSession(asset: b.composition, presetName: AVAssetExportPreset1920x1080)
            else { print("FEL: kunde inte bygga"); exit(1) }
            s.outputURL = out
            s.outputFileType = .mp4
            s.videoComposition = b.videoComposition
            s.audioMix = b.audioMix
            let done = DispatchSemaphore(value: 0)
            s.exportAsynchronously { done.signal() }
            done.wait()
            guard s.status == .completed else {
                print("FEL: export \(s.status.rawValue) \(String(describing: s.error))")
                exit(1)
            }
            let check = AVURLAsset(url: out)
            let dur = check.duration.seconds
            let v = check.tracks(withMediaType: .video)
            let a = check.tracks(withMediaType: .audio)
            let size = v.first?.naturalSize ?? .zero
            print("OK: \(String(format: "%.2f", dur)) s väntat \(String(format: "%.2f", b.duration)) s, video \(v.count) \(Int(size.width))x\(Int(size.height)), ljud \(a.count)")
            if abs(dur - b.duration) > 0.2 || v.count != 1 || a.isEmpty || size.width != 1920 {
                print("FEL: oväntat resultat")
                exit(1)
            }
            // Spara en bild från klippet med text som kontroll.
            let gen = AVAssetImageGenerator(asset: check)
            gen.requestedTimeToleranceBefore = .zero
            gen.requestedTimeToleranceAfter = .zero
            for (name, t) in [("film", 1.0), ("film2", 4.8), ("film3", 6.5)] {
                let img = try gen.copyCGImage(at: cm(t), actualTime: nil)
                let u = out.deletingLastPathComponent().appendingPathComponent(name + ".png")
                let dest = CGImageDestinationCreateWithURL(u as CFURL, "public.png" as CFString, 1, nil)!
                CGImageDestinationAddImage(dest, img, nil)
                CGImageDestinationFinalize(dest)
            }
        } catch {
            print("FEL: \(error)")
            exit(1)
        }
    }
}
