import Foundation
import CoreGraphics

// MARK: - Spåren
//
// Video (överst ligger ovanpå):  Text  ·  Bild  ·  Film
// Ljud:                          Filmljud  ·  Musik  ·  Ljudeffekter

/// Äldre projekt hade text direkt på filmklippen. Används bara när ett gammalt projekt läses in.
enum TitlePlace: String, Codable {
    case top, middle, bottom
}

/// Ett filmklipp i filmspåret. Klippen ligger direkt efter varandra.
struct Clip: Identifiable, Codable, Equatable {
    var id = UUID()
    var path: String
    var sourceDuration: Double
    var start: Double
    var end: Double
    var volume: Float = 1
    // Gammalt: flyttas till textspåret när projektet öppnas.
    var title: String? = nil
    var titlePlace: TitlePlace? = nil

    var length: Double { max(0, end - start) }
    var url: URL { URL(fileURLWithPath: path) }
    var name: String { url.deletingPathExtension().lastPathComponent }
}

/// Något som ligger fritt i tiden i ett spår (bild, text eller ljudeffekt).
protocol TimedItem: Identifiable {
    var id: UUID { get }
    var start: Double { get set }
    var duration: Double { get set }
}

extension TimedItem {
    var end: Double { start + duration }
    func visible(at t: Double) -> Bool { t >= start - 0.0005 && t < end }
}

/// En stillbild i bildspåret.
struct StillItem: TimedItem, Codable, Equatable {
    var id = UUID()
    var path: String
    var aspect: Double          // bredd / höjd
    var start: Double
    var duration: Double
    var x: Double = 0.5         // mitten av bilden, 0 = vänster kant, 1 = höger kant
    var y: Double = 0.5         // 0 = överkant, 1 = nederkant
    var scale: Double = 1       // 1 = hela bilden får precis plats i rutan

    var url: URL { URL(fileURLWithPath: path) }
    var name: String { url.deletingPathExtension().lastPathComponent }
}

/// En text i textspåret.
struct TextItem: TimedItem, Codable, Equatable {
    var id = UUID()
    var text: String
    var font: String = TextStyle.fonts[0]
    var bold = true
    var size: Double = 0.08     // bokstavshöjd som del av bildens höjd
    var color: Int = 0
    var x: Double = 0.5
    var y: Double = 0.82
    var start: Double
    var duration: Double
}

/// En ljudeffekt i ljudeffektspåret.
struct SoundItem: TimedItem, Codable, Equatable {
    var id = UUID()
    var path: String
    var sourceDuration: Double
    var inPoint: Double = 0     // var i ljudfilen effekten börjar
    var start: Double
    var duration: Double
    var volume: Float = 1

    var url: URL { URL(fileURLWithPath: path) }
    var name: String { url.deletingPathExtension().lastPathComponent }
}

enum TextStyle {
    /// Typsnitt som finns i alla Mac-datorer från macOS 11.
    static let fonts = [
        "Helvetica Neue", "Avenir Next", "Futura", "Gill Sans", "Georgia", "Baskerville",
        "American Typewriter", "Courier New", "Chalkboard SE", "Marker Felt", "Noteworthy",
        "Comic Sans MS", "Impact", "Snell Roundhand", "Papyrus",
    ]

    static let colors: [(name: String, r: Double, g: Double, b: Double)] = [
        ("Vit", 1, 1, 1), ("Gul", 1, 0.84, 0.1), ("Orange", 1, 0.55, 0.1), ("Röd", 0.93, 0.2, 0.2),
        ("Rosa", 1, 0.45, 0.75), ("Lila", 0.6, 0.4, 1), ("Blå", 0.25, 0.6, 1), ("Grön", 0.3, 0.85, 0.35),
        ("Svart", 0, 0, 0),
    ]

    static func cgColor(_ i: Int) -> CGColor {
        let c = colors[max(0, min(colors.count - 1, i))]
        return CGColor(red: CGFloat(c.r), green: CGFloat(c.g), blue: CGFloat(c.b), alpha: 1)
    }
}

/// Vad som är valt just nu.
enum Selection: Equatable {
    case clip(UUID)
    case still(UUID)
    case text(UUID)
    case sound(UUID)
    case music

    var id: UUID? {
        switch self {
        case .clip(let i), .still(let i), .text(let i), .sound(let i): return i
        case .music: return nil
        }
    }
}

/// Hela filmen.
struct Project: Codable, Equatable {
    var name: String = "Min film"
    var clips: [Clip] = []
    var stills: [StillItem] = []
    var texts: [TextItem] = []
    var sounds: [SoundItem] = []
    var musicPath: String? = nil
    var musicVolume: Float = 0.5

    init() {}

    // Läser även projekt sparade av äldre versioner (utan bilder, texter och ljudeffekter).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Min film"
        clips = try c.decodeIfPresent([Clip].self, forKey: .clips) ?? []
        stills = try c.decodeIfPresent([StillItem].self, forKey: .stills) ?? []
        texts = try c.decodeIfPresent([TextItem].self, forKey: .texts) ?? []
        sounds = try c.decodeIfPresent([SoundItem].self, forKey: .sounds) ?? []
        musicPath = try c.decodeIfPresent(String.self, forKey: .musicPath)
        musicVolume = try c.decodeIfPresent(Float.self, forKey: .musicVolume) ?? 0.5
    }

    /// Filmspårets längd.
    var filmDuration: Double { clips.reduce(0) { $0 + $1.length } }

    /// Hela filmens längd. Bilder, texter och ljud efter sista filmklippet förlänger filmen (med svart).
    var duration: Double {
        var d = filmDuration
        for s in stills { d = max(d, s.end) }
        for t in texts { d = max(d, t.end) }
        for s in sounds { d = max(d, s.end) }
        return d
    }

    var isEmpty: Bool { clips.isEmpty && stills.isEmpty && texts.isEmpty && sounds.isEmpty }

    func index(of id: UUID) -> Int? { clips.firstIndex { $0.id == id } }

    func startTime(of index: Int) -> Double {
        clips.prefix(index).reduce(0) { $0 + $1.length }
    }

    func startTime(ofID id: UUID) -> Double {
        guard let i = index(of: id) else { return 0 }
        return startTime(of: i)
    }

    /// Filmklippet som ligger under en tidpunkt.
    func clipIndex(at t: Double) -> Int? {
        var s = 0.0
        for (i, c) in clips.enumerated() {
            if t >= s && t < s + c.length { return i }
            s += c.length
        }
        return nil
    }

    /// Flyttar texter från gamla filmklipp till textspåret.
    mutating func migrateOldTitles() {
        var s = 0.0
        for i in clips.indices {
            let c = clips[i]
            if let title = c.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
                var t = TextItem(text: title, start: s, duration: c.length)
                switch c.titlePlace ?? .bottom {
                case .top: t.y = 0.14
                case .middle: t.y = 0.5
                case .bottom: t.y = 0.84
                }
                texts.append(t)
            }
            clips[i].title = nil
            clips[i].titlePlace = nil
            s += c.length
        }
    }

    /// Tar bort det vars filer inte finns längre.
    func removingMissingFiles() -> (project: Project, missing: Int) {
        var p = self
        let fm = FileManager.default
        p.clips = clips.filter { fm.fileExists(atPath: $0.path) }
        p.stills = stills.filter { fm.fileExists(atPath: $0.path) }
        p.sounds = sounds.filter { fm.fileExists(atPath: $0.path) }
        var missing = (clips.count - p.clips.count) + (stills.count - p.stills.count) + (sounds.count - p.sounds.count)
        if let m = musicPath, !fm.fileExists(atPath: m) {
            p.musicPath = nil
            missing += 1
        }
        return (p, missing)
    }

    /// Det som kräver att förhandsvisningen byggs om (bilder och texter ritas ovanpå direkt).
    var mediaKey: MediaKey {
        MediaKey(clips: clips.map { ClipKey(path: $0.path, start: $0.start, end: $0.end, volume: $0.volume) },
                 sounds: sounds.map { SoundKey(path: $0.path, inPoint: $0.inPoint, start: $0.start,
                                               duration: $0.duration, volume: $0.volume) },
                 music: musicPath, musicVolume: musicVolume,
                 duration: (duration * 30).rounded() / 30)
    }
}

struct ClipKey: Equatable {
    var path: String
    var start: Double
    var end: Double
    var volume: Float
}

struct SoundKey: Equatable {
    var path: String
    var inPoint: Double
    var start: Double
    var duration: Double
    var volume: Float
}

struct MediaKey: Equatable {
    var clips: [ClipKey]
    var sounds: [SoundKey]
    var music: String?
    var musicVolume: Float
    var duration: Double
}

// MARK: - Fria spår: ingenting får ligga omlott

enum Lane {
    /// Närmaste starttid till `desired` där något som är `length` långt får plats utan att krocka.
    static func freeStart(desired: Double, length: Double, others: [(start: Double, end: Double)]) -> Double {
        let want = max(0, desired)
        func fits(_ s: Double) -> Bool {
            s >= -0.0001 && !others.contains { s < $0.end - 0.0001 && s + length > $0.start + 0.0001 }
        }
        if fits(want) { return want }
        var candidates: [Double] = []
        for o in others {
            candidates.append(o.end)
            candidates.append(o.start - length)
        }
        let ok = candidates.filter { $0 >= 0 && fits($0) }
        return ok.min { abs($0 - want) < abs($1 - want) } ?? (others.map { $0.end }.max() ?? want)
    }

    /// Hur långt till vänster och höger något får växa utan att krocka.
    static func bounds(of start: Double, end: Double, others: [(start: Double, end: Double)]) -> (min: Double, max: Double) {
        let before = others.filter { $0.end <= start + 0.0001 }.map { $0.end }.max() ?? 0
        let after = others.filter { $0.start >= end - 0.0001 }.map { $0.start }.min() ?? .infinity
        return (before, after)
    }
}

// MARK: - Tid som text

func formatTime(_ t: Double) -> String {
    let t = max(0, t.isFinite ? t : 0)
    let m = Int(t) / 60
    let s = t - Double(m * 60)
    return String(format: "%d:%04.1f", m, s)
}

func formatShort(_ t: Double) -> String {
    let t = Int(max(0, t.rounded()))
    return String(format: "%d:%02d", t / 60, t % 60)
}
