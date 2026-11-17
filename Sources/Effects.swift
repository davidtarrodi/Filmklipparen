import AVFoundation
import CoreImage

/// Svartvitt: en svartvit kopia av filmklippets bild görs en gång och sparas i appens mapp.
/// (Baklänges-kopian får en egen svartvit kopia.) Ljudet tas fortfarande från originalet.
enum BlackWhite {
    static var folder: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Filmklipparen/Svartvitt", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func cacheURL(source: URL) -> URL {
        let attrs = try? FileManager.default.attributesOfItem(atPath: source.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in "\(source.path)|\(size)|\(Int(mtime))|bw1".utf8 {
            h ^= UInt64(b)
            h = h &* 0x0000_0100_0000_01b3
        }
        return folder.appendingPathComponent(String(format: "%016llx.mov", h))
    }

    /// Den svartvita bilden om klippet ska vara svartvitt och kopian är klar.
    static func activeFile(for clip: Clip) -> URL? {
        guard clip.blackWhite == true else { return nil }
        let u = cacheURL(source: clip.mediaURL)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    /// Körs på en bakgrundskö. Gör den svartvita kopian (samma längd och storlek som originalet).
    static func render(source: URL, progress: @escaping (Double) -> Void = { _ in }) throws -> URL {
        let out = cacheURL(source: source)
        if FileManager.default.fileExists(atPath: out.path) { return out }
        let tmp = out.deletingPathExtension().appendingPathExtension("tmp.mov")
        try? FileManager.default.removeItem(at: tmp)
        let asset = AVURLAsset(url: source)
        guard !asset.tracks(withMediaType: .video).isEmpty else { throw BuildError.failed }
        let vc = AVMutableVideoComposition(asset: asset) { req in
            let img = req.sourceImage.clampedToExtent()
            let f = CIFilter(name: "CIPhotoEffectMono")
            f?.setValue(img, forKey: kCIInputImageKey)
            let result = (f?.outputImage ?? img).cropped(to: req.sourceImage.extent)
            req.finish(with: result, context: nil)
        }
        guard let s = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality)
        else { throw BuildError.failed }
        s.outputURL = tmp
        s.outputFileType = .mov
        s.videoComposition = vc
        let done = DispatchSemaphore(value: 0)
        s.exportAsynchronously { done.signal() }
        while done.wait(timeout: .now() + 0.2) == .timedOut {
            progress(Double(s.progress))
        }
        guard s.status == .completed else {
            try? FileManager.default.removeItem(at: tmp)
            throw s.error ?? BuildError.failed
        }
        try FileManager.default.moveItem(at: tmp, to: out)
        progress(1)
        return out
    }
}
