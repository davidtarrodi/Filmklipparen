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
        let md = AVURLAsset(url: URL(fileURLWithPath: args[1])).duration.seconds
        p.music.append(SoundItem(path: args[1], sourceDuration: md, start: 0, duration: md, volume: 0.5))
        p.music.append(SoundItem(path: args[1], sourceDuration: md, inPoint: 0.5, start: 3.0, duration: md - 0.5, volume: 0.5))
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
            // Slowmotion på det vända klippet, snabbt på det andra.
            p.clips[0].speed = 0.5
            if p.clips.count > 1 { p.clips[1].speed = 2 }
            // Pipig röst (+800 cent) på det vända klippet: 440 Hz ska bli cirka 698 Hz.
            let vsrc = Voice.sourceAudioURL(for: p.clips[0])!
            let t1 = Date()
            let vf = try Voice.render(source: vsrc, cents: 800)
            p.clips[0].pitch = 800
            p.clips[0].voicePath = vf.path
            p.clips[0].voiceSource = vsrc.path
            let before = frequency(try Voice.readPCM(AVURLAsset(url: vsrc)))
            let after = frequency(try Voice.readPCM(AVURLAsset(url: vf)))
            let lenA = AVURLAsset(url: vsrc).duration.seconds, lenB = AVURLAsset(url: vf).duration.seconds
            print("röst: \(Int(before)) Hz blev \(Int(after)) Hz (väntat ~698), längd \(String(format: "%.2f", lenA)) → \(String(format: "%.2f", lenB)) s, tog \(String(format: "%.1f", Date().timeIntervalSince(t1))) s")
            if after < 640 || after > 760 { print("FEL: rösten blev inte pipig"); exit(1) }
            // Byte direkt till en annan röst: den gamla filen får inte användas.
            var other = p.clips[0]
            other.pitch = -800
            print("byte av röst: gammal fil används \(Voice.activeFile(for: other) != nil ? "JA (fel)" : "inte (rätt)")")
            if Voice.activeFile(for: other) != nil { exit(1) }
            // Svart först (1 s) och en paus (1 s) mellan klippen.
            p.clips[0].timelineStart = 1.0
            if p.clips.count > 1 { p.clips[1].timelineStart = p.clips[0].t1 + 1.0 }
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
            s.audioTimePitchAlgorithm = .spectral
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
            for (name, t) in [("svart1", 0.5), ("film", 2.0), ("film2", 5.8), ("film3", 6.5), ("svart2", 7.5)] {
                let img = try gen.copyCGImage(at: cm(t), actualTime: nil)
                let u = out.deletingLastPathComponent().appendingPathComponent(name + ".png")
                let dest = CGImageDestinationCreateWithURL(u as CFURL, "public.png" as CFString, 1, nil)!
                CGImageDestinationAddImage(dest, img, nil)
                CGImageDestinationFinalize(dest)
                print("bild \(name) vid \(t) s: ljusstyrka \(Int(brightness(img)))")
                if name.hasPrefix("svart") && brightness(img) > 25 { print("FEL: \(name) är inte svart"); exit(1) }
            }
        } catch {
            print("FEL: \(error)")
            exit(1)
        }
        previewCheck(p, name: "med pauser")
        // Som en gammal film: klippen direkt efter varandra, utan positioner.
        var q = p
        for i in q.clips.indices { q.clips[i].timelineStart = nil }
        q.stills = []; q.texts = []
        previewCheck(q, name: "utan pauser")
        var r = q
        r.ensurePositions()
        previewCheck(r, name: "utan pauser, sparad")
        // Som riktiga mobilfilmer: filen sägs vara lite längre än bilden (ljudet är längre).
        var m = r
        for i in m.clips.indices { m.clips[i].sourceDuration += 0.04; m.clips[i].end += 0.04 }
        m.ensurePositions(); for i in m.clips.indices { m.clips[i].timelineStart = nil }; m.ensurePositions()
        previewCheck(m, name: "ljud längre än bild")
        if previewFailed { exit(1) }
    }

    static var previewFailed = false

    final class Logger: NSObject, AVVideoCompositionValidationHandling {
        var problems: [String] = []
        func videoComposition(_ vc: AVVideoComposition, shouldContinueValidatingAfterFindingInvalidValueForKey key: String) -> Bool { problems.append("ogiltigt värde \(key)"); return true }
        func videoComposition(_ vc: AVVideoComposition, shouldContinueValidatingAfterFindingEmptyTimeRange r: CMTimeRange) -> Bool { problems.append("tomt tidsintervall \(r.start.seconds)–\(r.end.seconds)"); return true }
        func videoComposition(_ vc: AVVideoComposition, shouldContinueValidatingAfterFindingInvalidTimeRangeIn i: AVVideoCompositionInstructionProtocol) -> Bool { problems.append("ogiltig instruktion \(i.timeRange.start.seconds)–\(i.timeRange.end.seconds)"); return true }
        func videoComposition(_ vc: AVVideoComposition, shouldContinueValidatingAfterFindingInvalidTrackIDIn i: AVVideoCompositionInstructionProtocol, layerInstruction l: AVVideoCompositionLayerInstruction, asset: AVAsset) -> Bool { problems.append("ogiltigt spår"); return true }
    }

    /// Förhandsvisningen (som i appen): giltig, och bild där klippen ligger.
    static func previewCheck(_ p: Project, name: String) {
        do {
            guard let b = try MovieBuilder.build(p, forExport: false) else { print("FEL: förhandsvisning \(name) byggdes inte"); previewFailed = true; return }
            let log = Logger()
            let ok = b.videoComposition.isValid(for: b.composition, timeRange: CMTimeRange(start: .zero, duration: b.composition.duration), validationDelegate: log)
            let ins = b.videoComposition.instructions.map { "\($0.timeRange.start.seconds)–\($0.timeRange.end.seconds)" }
            print("förhandsvisning \(name): längd \(b.composition.duration.seconds), instruktioner \(ins), giltig \(ok) \(log.problems)")
            for t in b.composition.tracks { print("  spår \(t.mediaType.rawValue): " + t.segments.map { "\($0.isEmpty ? "tom" : "bit") \(String(format: "%.3f", $0.timeMapping.target.start.seconds))+\(String(format: "%.3f", $0.timeMapping.target.duration.seconds))" }.joined(separator: ", ")) }
            if !ok { previewFailed = true }
            let gen = AVAssetImageGenerator(asset: b.composition)
            gen.videoComposition = b.videoComposition
            gen.requestedTimeToleranceBefore = .zero
            gen.requestedTimeToleranceAfter = .zero
            var q = p; q.tidyClips()
            for c in q.clips {
                let t = c.t0 + c.length / 2
                let img = try gen.copyCGImage(at: cm(t), actualTime: nil)
                let br = brightness(img)
                print("  klipp vid \(String(format: "%.2f", t)) s: ljusstyrka \(Int(br))")
                if br < 25 { print("FEL: svart bild i klippet (\(name))"); previewFailed = true }
            }
        } catch {
            print("FEL: förhandsvisning \(name): \(error)")
            previewFailed = true
        }
    }

    /// Ungefärlig frekvens (Hz) från nollgenomgångar i vänster kanal, mitt i ljudet.
    static func frequency(_ pcm: [Int16]) -> Double {
        let frames = pcm.count / 2
        let a = frames / 4, b = frames * 3 / 4
        guard b > a + 100 else { return 0 }
        var crossings = 0
        var prev = pcm[2 * a]
        for i in (a + 1)..<b {
            let v = pcm[2 * i]
            if (prev < 0 && v >= 0) || (prev >= 0 && v < 0) { crossings += 1 }
            prev = v
        }
        return Double(crossings) / 2 / (Double(b - a) / 44100)
    }

    /// Medelljusstyrka 0–255.
    static func brightness(_ img: CGImage) -> Double {
        let w = 64, h = 36
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        var sum = 0
        for i in stride(from: 0, to: px.count, by: 4) { sum += Int(px[i]) + Int(px[i + 1]) + Int(px[i + 2]) }
        return Double(sum) / Double(w * h * 3)
    }
}
