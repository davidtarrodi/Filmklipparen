import Foundation
import AVFoundation
import AppKit

/// En film i listan "Mina filmer".
struct FilmInfo: Identifiable, Equatable {
    var id: URL { url }
    let url: URL
    let name: String
    let modified: Date
    let duration: Double
    /// Varifrån den lilla bilden hämtas: ett filmklipp (med tid) eller en stillbild.
    let thumbPath: String?
    let thumbTime: Double
    let thumbIsStill: Bool
}

/// Alla filmer sparas som var sin fil i en egen mapp.
enum FilmLibrary {
    static var root: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Filmklipparen", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var folder: URL {
        let dir = root.appendingPathComponent("Filmer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func newURL() -> URL {
        folder.appendingPathComponent(UUID().uuidString + ".json")
    }

    static func load(_ url: URL) -> Project? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Project.self, from: data)
    }

    static func save(_ p: Project, to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted]
        try enc.encode(p).write(to: url, options: .atomic)
    }

    /// Den gamla appen hade bara en film (projekt.json). Den flyttas in som första film i listan.
    static func migrateOldProject() {
        let old = root.appendingPathComponent("projekt.json")
        guard FileManager.default.fileExists(atPath: old.path) else { return }
        if let p = load(old), !p.isEmpty {
            var q = p
            if q.name.trimmingCharacters(in: .whitespaces).isEmpty { q.name = "Min film" }
            try? save(q, to: newURL())
        }
        let backup = root.appendingPathComponent("projekt-gammal.json")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.moveItem(at: old, to: backup)
    }

    /// Alla filmer, senast ändrade först.
    static func list() -> [FilmInfo] {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey],
                                                options: [.skipsHiddenFiles])) ?? []
        var out: [FilmInfo] = []
        for u in urls where u.pathExtension == "json" {
            guard let p = load(u) else { continue }
            let mod = (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            var thumbPath: String?
            var thumbTime = 0.0
            var still = false
            if let c = p.clips.first {
                thumbPath = c.path
                thumbTime = c.isReversed ? max(c.start, c.end - 0.2) : c.start + min(0.3, c.length / 2)
            } else if let s = p.stills.first {
                thumbPath = s.path
                still = true
            }
            out.append(FilmInfo(url: u, name: p.name.isEmpty ? "Namnlös film" : p.name, modified: mod,
                                duration: p.duration, thumbPath: thumbPath, thumbTime: thumbTime, thumbIsStill: still))
        }
        return out.sorted { $0.modified > $1.modified }
    }

    static func rename(_ info: FilmInfo, to name: String) {
        guard var p = load(info.url) else { return }
        p.name = name
        try? save(p, to: info.url)
    }

    static func duplicate(_ info: FilmInfo) {
        guard var p = load(info.url) else { return }
        p.name = p.name + " (kopia)"
        try? save(p, to: newURL())
    }

    /// Lägger filen i papperskorgen, så att den går att få tillbaka.
    static func delete(_ info: FilmInfo) {
        do {
            try FileManager.default.trashItem(at: info.url, resultingItemURL: nil)
        } catch {
            try? FileManager.default.removeItem(at: info.url)
        }
    }

    /// En liten bild till listan.
    static func thumbnail(_ info: FilmInfo) -> NSImage? {
        guard let path = info.thumbPath, FileManager.default.fileExists(atPath: path) else { return nil }
        let url = URL(fileURLWithPath: path)
        if info.thumbIsStill {
            guard let cg = Overlay.loadImage(url, maxPixels: 480) else { return nil }
            return NSImage(cgImage: cg, size: CGSize(width: cg.width, height: cg.height))
        }
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 480, height: 270)
        gen.requestedTimeToleranceBefore = cm(0.5)
        gen.requestedTimeToleranceAfter = cm(0.5)
        guard let cg = try? gen.copyCGImage(at: cm(info.thumbTime), actualTime: nil) else { return nil }
        return NSImage(cgImage: cg, size: CGSize(width: cg.width, height: cg.height))
    }
}
