import AVFoundation
import AppKit
import ImageIO

func cm(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 600) }

/// En färdig film att spela upp eller spara.
struct BuiltMovie {
    let composition: AVMutableComposition
    let videoComposition: AVMutableVideoComposition
    let audioMix: AVMutableAudioMix
    let duration: Double
}

struct CancelledError: Error {}

enum BuildError: LocalizedError {
    case failed
    case step(String, Error)
    var errorDescription: String? {
        switch self {
        case .failed: return "Filmen kunde inte byggas ihop."
        case .step(let what, let e): return "\(what): \(e.localizedDescription)"
        }
    }
}

/// Säger vilket steg som gick fel, så att felmeddelandet blir begripligt.
func attempt<T>(_ what: @autoclosure () -> String, _ f: () throws -> T) throws -> T {
    do { return try f() } catch let e as BuildError { throw e } catch { throw BuildError.step(what(), error) }
}

// MARK: - Var bilder och texter hamnar (samma i förhandsvisning och sparad film)

enum Overlay {
    /// Bildens ruta i en bild som är `frame` stor. Origo uppe till vänster.
    static func stillRect(_ s: StillItem, frame: CGSize) -> CGRect {
        let a = CGFloat(max(0.05, s.aspect))
        var w = frame.width
        var h = w / a
        if h > frame.height {
            h = frame.height
            w = h * a
        }
        w *= CGFloat(s.scale)
        h *= CGFloat(s.scale)
        return CGRect(x: CGFloat(s.x) * frame.width - w / 2, y: CGFloat(s.y) * frame.height - h / 2,
                      width: w, height: h)
    }

    /// Hur mycket en bild ska förstoras för att täcka hela rutan.
    static func coverScale(aspect: Double) -> Double {
        let f = 16.0 / 9.0
        return max(aspect / f, f / aspect)
    }

    static func font(_ t: TextItem, size: CGFloat) -> NSFont {
        let traits: NSFontTraitMask = t.bold ? .boldFontMask : []
        if let f = NSFontManager.shared.font(withFamily: t.font, traits: traits, weight: t.bold ? 9 : 5, size: size) {
            return f
        }
        return t.bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
    }

    /// Ritar en text till en bild för en film som är `frameHeight` hög.
    /// Bilden ska placeras med mitten i (x, y). Texten bryts så att den får plats i bilden.
    static func textImage(_ t: TextItem, frameHeight: CGFloat) -> CGImage? {
        let text = t.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return nil }
        let k = frameHeight / 1080
        let fontSize = max(6, CGFloat(t.size) * frameHeight)
        let maxWidth = frameHeight * 16 / 9 * 0.92
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        let color = NSColor(cgColor: TextStyle.cgColor(t.color)) ?? .white
        let attr = NSAttributedString(string: text, attributes: [
            .font: font(t, size: fontSize), .foregroundColor: color, .paragraphStyle: para,
        ])
        let b = attr.boundingRect(with: CGSize(width: maxWidth, height: 10000),
                                  options: [.usesLineFragmentOrigin, .usesFontLeading])
        let pad = ceil(16 * k + fontSize * 0.08)
        let w = Int(ceil(b.width) + 2 * pad), h = Int(ceil(b.height) + 2 * pad)
        guard w > 0, h > 0, w < 9000, h < 9000,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let dark = t.color == TextStyle.colors.count - 1
        ctx.setShadow(offset: CGSize(width: 0, height: -2 * k), blur: max(2, 7 * k),
                      color: dark ? CGColor(gray: 1, alpha: 0.85) : CGColor(gray: 0, alpha: 0.9))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        attr.draw(in: CGRect(x: pad, y: pad, width: ceil(b.width) + 1, height: ceil(b.height) + 1))
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    /// Läser en bild (även iPhone-bilder i HEIC), vriden rätt och förminskad.
    static func loadImage(_ url: URL, maxPixels: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }
}

// MARK: - Svart bild där det inte finns någon film

enum BlackFiller {
    private static let lock = NSLock()

    /// En kort svart film som används för att fylla ut. Skapas en gång.
    static func url() -> URL? {
        lock.lock()
        defer { lock.unlock() }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Filmklipparen", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("svart-v2.mov")
        if FileManager.default.fileExists(atPath: url.path),
           !AVURLAsset(url: url).tracks(withMediaType: .video).isEmpty {
            return url
        }
        try? FileManager.default.removeItem(at: url)
        return write(to: url) ? url : nil
    }

    private static func write(to url: URL) -> Bool {
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return false }
        let w = 320, h = 180
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
        ])
        guard writer.canAdd(input) else { return false }
        writer.add(input)
        guard writer.startWriting() else { return false }
        writer.startSession(atSourceTime: .zero)
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, nil, &pb)
        guard let buffer = pb else { return false }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            memset(base, 0, CVPixelBufferGetBytesPerRow(buffer) * h)
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        // 2 sekunder, 10 bilder per sekund.
        for i in 0..<20 {
            var tries = 0
            while !input.isReadyForMoreMediaData && tries < 300 {
                Thread.sleep(forTimeInterval: 0.01)
                tries += 1
            }
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i * 60), timescale: 600))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: 1200, timescale: 600))
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        return writer.status == .completed
    }
}

// MARK: - Bygga ihop filmen

/// Bygger ihop alla spår till en film med Apples AVFoundation. Fungerar på macOS 11.
enum MovieBuilder {
    /// Bilden när filmen sparas (1080p).
    static let exportSize = CGSize(width: 1920, height: 1080)
    /// Bilden i förhandsvisningen (lättare för en äldre dator).
    static let previewSize = CGSize(width: 1280, height: 720)

    /// Körs på en bakgrundskö. Bilder och texter bränns bara in när filmen sparas;
    /// i förhandsvisningen ritas de ovanpå i fönstret.
    static func build(_ project: Project, forExport: Bool,
                      isCancelled: () -> Bool = { false }) throws -> BuiltMovie? {
        let total = project.duration
        if total < 0.05 { return nil }
        let size = forExport ? exportSize : previewSize
        let totalTime = cm(total)

        let comp = AVMutableComposition()
        guard let vTrack = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let aTrack = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw BuildError.failed }

        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: vTrack)
        let clipAudio = AVMutableAudioMixInputParameters(track: aTrack)
        var cursor = CMTime.zero
        // Ett AVAssetTrack håller bara svagt i sin fil (AVAsset). Utan att filerna hålls kvar
        // försvinner de innan spåren hunnit läggas in, och då misslyckas det (fel -12780).
        var keep: [AVAsset] = []
        defer { withExtendedLifetime(keep) {} }

        // Spår 1: filmklippen efter varandra.
        for clip in project.clips where clip.length > 0.05 {
            if isCancelled() { throw CancelledError() }
            let asset = AVURLAsset(url: clip.url)
            keep.append(asset)
            guard let sv = asset.tracks(withMediaType: .video).first else { continue }
            let wanted = CMTimeRange(start: cm(clip.start), end: cm(clip.end))
            let vRange = wanted.intersection(sv.timeRange)
            if vRange.isEmpty || vRange.duration.seconds < 0.03 { continue }

            try attempt("Filmklippet \(clip.name)") { try vTrack.insertTimeRange(vRange, of: sv, at: cursor) }
            layer.setTransform(fitTransform(natural: sv.naturalSize, preferred: sv.preferredTransform, into: size),
                               at: cursor)
            try attempt("Ljudet i \(clip.name)") {
                try place(asset.tracks(withMediaType: .audio).first, range: vRange, into: aTrack, at: cursor)
            }
            clipAudio.setVolume(clip.volume, at: cursor)
            cursor = cursor + vRange.duration
        }

        // Svart efter filmklippen om bilder, texter eller ljud fortsätter längre.
        if totalTime - cursor > cm(0.02) {
            var filled = false
            let fillAsset = BlackFiller.url().map { AVURLAsset(url: $0) }
            if let fa = fillAsset { keep.append(fa) }
            if let fill = fillAsset?.tracks(withMediaType: .video).first {
                // Använd bara en bit mitt i den svarta filmen, så att den säkert finns.
                let chunk = CMTimeMinimum(cm(1.5), fill.timeRange.duration - cm(0.2))
                if chunk > cm(0.1) {
                    layer.setTransform(fitTransform(natural: fill.naturalSize, preferred: fill.preferredTransform,
                                                    into: size), at: cursor)
                    do {
                        while totalTime - cursor > cm(0.001) {
                            let len = CMTimeMinimum(chunk, totalTime - cursor)
                            try vTrack.insertTimeRange(CMTimeRange(start: fill.timeRange.start, duration: len),
                                                       of: fill, at: cursor)
                            cursor = cursor + len
                        }
                        filled = true
                    } catch {
                        NSLog("Filmklipparen: svart utfyllnad gick inte: \(error)")
                    }
                }
            }
            if !filled && totalTime > cursor {
                // Reserv: tom bit, blir svart i bilden.
                vTrack.insertEmptyTimeRange(CMTimeRange(start: cursor, end: totalTime))
                cursor = totalTime
            }
        }

        var params: [AVMutableAudioMixInputParameters] = []
        if aTrack.segments.contains(where: { !$0.isEmpty }) {
            params.append(clipAudio)
        } else {
            comp.removeTrack(aTrack)
        }

        // Spår 2: musik, upprepas om låten är kortare än filmen, tonas ut på slutet.
        let musicAsset = project.musicPath.map { AVURLAsset(url: URL(fileURLWithPath: $0)) }
        if let ma = musicAsset { keep.append(ma) }
        if let ms = musicAsset?.tracks(withMediaType: .audio).first,
           ms.timeRange.duration.seconds > 0.5,
           let mTrack = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            let mRange = ms.timeRange
            var at = CMTime.zero
            while at < totalTime {
                let len = CMTimeMinimum(mRange.duration, totalTime - at)
                try attempt("Musiken") {
                    try mTrack.insertTimeRange(CMTimeRange(start: mRange.start, duration: len), of: ms, at: at)
                }
                at = at + len
            }
            let mp = AVMutableAudioMixInputParameters(track: mTrack)
            let v = project.musicVolume
            let fade = cm(min(2.0, total / 4))
            mp.setVolume(v, at: .zero)
            mp.setVolumeRamp(fromStartVolume: v, toEndVolume: 0,
                             timeRange: CMTimeRange(start: totalTime - fade, duration: fade))
            params.append(mp)
        }

        // Spår 3: ljudeffekter.
        let sounds = project.sounds.sorted { $0.start < $1.start }
        if !sounds.isEmpty,
           let sTrack = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            let sp = AVMutableAudioMixInputParameters(track: sTrack)
            var end = CMTime.zero
            var any = false
            for s in sounds {
                if isCancelled() { throw CancelledError() }
                let sa = AVURLAsset(url: s.url)
                keep.append(sa)
                guard let src = sa.tracks(withMediaType: .audio).first else { continue }
                let wanted = CMTimeRange(start: cm(s.inPoint), duration: cm(s.duration))
                let r = wanted.intersection(src.timeRange)
                if r.isEmpty || r.duration.seconds < 0.02 { continue }
                let at = CMTimeMaximum(cm(s.start), end)
                if at > end { sTrack.insertEmptyTimeRange(CMTimeRange(start: end, end: at)) }
                try attempt("Ljudeffekten \(s.name)") { try sTrack.insertTimeRange(r, of: src, at: at) }
                sp.setVolume(s.volume, at: at)
                end = at + r.duration
                any = true
            }
            if any { params.append(sp) } else { comp.removeTrack(sTrack) }
        }

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: cursor)
        instruction.layerInstructions = [layer]

        let vc = AVMutableVideoComposition()
        vc.instructions = [instruction]
        vc.renderSize = size
        vc.frameDuration = CMTime(value: 1, timescale: 30)
        if forExport {
            vc.animationTool = overlayTool(project, size: size)
        }

        let mix = AVMutableAudioMix()
        mix.inputParameters = params

        return BuiltMovie(composition: comp, videoComposition: vc, audioMix: mix, duration: cursor.seconds)
    }

    /// Lägger in ljudet för ett klipp och fyller ut med tystnad så att ljud och bild håller ihop.
    private static func place(_ source: AVAssetTrack?, range: CMTimeRange,
                              into track: AVMutableCompositionTrack, at cursor: CMTime) throws {
        guard let source = source else {
            track.insertEmptyTimeRange(CMTimeRange(start: cursor, duration: range.duration))
            return
        }
        let r = range.intersection(source.timeRange)
        if r.isEmpty || r.duration.seconds < 0.01 {
            track.insertEmptyTimeRange(CMTimeRange(start: cursor, duration: range.duration))
            return
        }
        let lead = r.start - range.start
        if lead > .zero {
            track.insertEmptyTimeRange(CMTimeRange(start: cursor, duration: lead))
        }
        try track.insertTimeRange(r, of: source, at: cursor + lead)
        let tail = range.end - r.end
        if tail > .zero {
            track.insertEmptyTimeRange(CMTimeRange(start: cursor + lead + r.duration, duration: tail))
        }
    }

    /// Vrider (mobilfilm) och skalar en bild så att den får plats, centrerad, med svart runt.
    static func fitTransform(natural: CGSize, preferred: CGAffineTransform, into size: CGSize) -> CGAffineTransform {
        let rect = CGRect(origin: .zero, size: natural).applying(preferred)
        guard rect.width > 0, rect.height > 0 else { return preferred }
        let s = min(size.width / rect.width, size.height / rect.height)
        var t = preferred.concatenating(CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
        t = t.concatenating(CGAffineTransform(scaleX: s, y: s))
        t = t.concatenating(CGAffineTransform(translationX: (size.width - rect.width * s) / 2,
                                              y: (size.height - rect.height * s) / 2))
        return t
    }

    // MARK: Bild- och textspåren i den sparade filmen

    private static func overlayTool(_ p: Project, size: CGSize) -> AVVideoCompositionCoreAnimationTool? {
        if p.stills.isEmpty && p.texts.isEmpty { return nil }
        // Lagren skapas utanför huvudtråden; utan en egen transaktion syns de aldrig i filmen.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let frame = CGRect(origin: .zero, size: size)
        let parent = CALayer()
        parent.frame = frame
        parent.masksToBounds = true
        let video = CALayer()
        video.frame = frame
        parent.addSublayer(video)

        // Bildspåret under textspåret.
        for s in p.stills {
            guard let img = Overlay.loadImage(s.url, maxPixels: 2400) else { continue }
            let r = Overlay.stillRect(s, frame: size)
            parent.addSublayer(timedLayer(img, rect: r, size: size, start: s.start, duration: s.duration))
        }
        for t in p.texts {
            guard let img = Overlay.textImage(t, frameHeight: size.height) else { continue }
            let w = CGFloat(img.width), h = CGFloat(img.height)
            let r = CGRect(x: CGFloat(t.x) * size.width - w / 2, y: CGFloat(t.y) * size.height - h / 2,
                           width: w, height: h)
            parent.addSublayer(timedLayer(img, rect: r, size: size, start: t.start, duration: t.duration))
        }
        return AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: video, in: parent)
    }

    /// Ett lager som bara syns mellan start och start + duration. `rect` har origo uppe till vänster.
    private static func timedLayer(_ img: CGImage, rect: CGRect, size: CGSize, start: Double, duration: Double) -> CALayer {
        let l = CALayer()
        // I filmens lager är y = 0 nere i bilden.
        l.frame = CGRect(x: rect.minX, y: size.height - rect.maxY, width: rect.width, height: rect.height)
        l.contents = img
        l.contentsGravity = .resize
        l.opacity = 0
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = 1
        a.toValue = 1
        a.beginTime = AVCoreAnimationBeginTimeAtZero + max(0, start)
        a.duration = max(0.02, duration)
        a.isRemovedOnCompletion = false
        l.add(a, forKey: "show")
        return l
    }
}
