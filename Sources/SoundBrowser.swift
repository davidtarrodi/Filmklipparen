import SwiftUI
import AVFoundation
import AppKit

/// Vilket bibliotek bläddraren visar.
enum BrowserKind: Equatable {
    case sounds
    case music

    var title: String { self == .sounds ? "Ljudeffekter" : "Musik" }
    var icon: String { self == .sounds ? "speaker.wave.2.fill" : "music.note" }
    var color: Color { self == .sounds ? Palette.sound : Palette.music }
    var defaultsKey: String { self == .sounds ? "soundFolder" : "musicFolder" }
    var addHelp: String {
        self == .sounds ? "Lägg in effekten där det gula strecket står" : "Använd som musik under hela filmen"
    }

    /// Standardmappen: Filmer/Ljudeffekter eller Filmer/Musik.
    var defaultFolder: URL {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
        return movies.appendingPathComponent(self == .sounds ? "Ljudeffekter" : "Musik", isDirectory: true)
    }
}

/// En ljudfil i biblioteket.
struct MediaFile: Identifiable, Hashable {
    var id: URL { url }
    let url: URL
    let name: String
    /// Första undermappen, t.ex. "funny" eller "cartoon".
    let category: String
    /// Det man söker i (namn + mapp), utan stora bokstäver och accenter.
    let searchKey: String
}

/// Läser en mapp med ljud och spelar upp dem för att provlyssna.
final class MediaLibrary: NSObject, ObservableObject, AVAudioPlayerDelegate {
    let kind: BrowserKind
    @Published private(set) var files: [MediaFile] = []
    @Published private(set) var categories: [String] = []
    @Published private(set) var scanning = false
    @Published private(set) var durations: [URL: Double] = [:]
    @Published private(set) var playing: URL?

    private var player: AVAudioPlayer?
    private var durationLoading: Set<URL> = []
    private let durationQueue = DispatchQueue(label: "filmklipparen.durations", qos: .utility)
    private static let types: Set<String> = ["wav", "mp3", "m4a", "aif", "aiff", "aifc", "caf", "aac", "flac"]

    init(kind: BrowserKind) {
        self.kind = kind
        super.init()
    }

    var folder: URL {
        get {
            if let p = UserDefaults.standard.string(forKey: kind.defaultsKey), !p.isEmpty {
                return URL(fileURLWithPath: p, isDirectory: true)
            }
            return kind.defaultFolder
        }
        set {
            UserDefaults.standard.set(newValue.path, forKey: kind.defaultsKey)
            objectWillChange.send()
            scan()
        }
    }

    static func searchable(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "sv_SE"))
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
    }

    /// Läser in alla ljudfiler i mappen (och dess undermappar).
    func scan() {
        let root = folder
        if root.path == kind.defaultFolder.path {
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        scanning = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var found: [MediaFile] = []
            let keys: [URLResourceKey] = [.isRegularFileKey]
            if let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                      options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
                for case let u as URL in e {
                    guard MediaLibrary.types.contains(u.pathExtension.lowercased()) else { continue }
                    let rel = u.path.dropFirst(root.path.count).split(separator: "/")
                    let category = rel.count > 1 ? String(rel[0]) : ""
                    let name = u.deletingPathExtension().lastPathComponent
                    found.append(MediaFile(url: u, name: name, category: category,
                                           searchKey: MediaLibrary.searchable(name + " " + category)))
                    if found.count >= 10_000 { break }
                }
            }
            found.sort { ($0.category, $0.name.lowercased()) < ($1.category, $1.name.lowercased()) }
            let cats = Array(Set(found.map { $0.category }.filter { !$0.isEmpty })).sorted()
            DispatchQueue.main.async { [weak self] in
                self?.files = found
                self?.categories = cats
                self?.scanning = false
            }
        }
    }

    func filtered(search: String, category: String?) -> [MediaFile] {
        let words = MediaLibrary.searchable(search).split(separator: " ").map(String.init)
        return files.filter { f in
            if let c = category, f.category != c { return false }
            return words.allSatisfy { f.searchKey.contains($0) }
        }
    }

    /// Längden läses i bakgrunden första gången raden syns.
    func requestDuration(_ url: URL) {
        if durations[url] != nil || durationLoading.contains(url) { return }
        durationLoading.insert(url)
        durationQueue.async { [weak self] in
            let d = AVURLAsset(url: url).duration.seconds
            DispatchQueue.main.async { [weak self] in
                self?.durations[url] = d.isFinite ? d : 0
            }
        }
    }

    // MARK: Provlyssna

    func toggle(_ url: URL) {
        if playing == url {
            stop()
            return
        }
        stop()
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.delegate = self
            p.volume = 0.9
            p.play()
            player = p
            playing = url
        } catch {
            playing = nil
        }
    }

    func stop() {
        player?.stop()
        player = nil
        if playing != nil { playing = nil }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { [weak self] in
            if self?.player === player {
                self?.player = nil
                self?.playing = nil
            }
        }
    }
}

// MARK: - Bläddraren i sidopanelen

struct MediaBrowserView: View {
    @EnvironmentObject var ed: Editor
    @ObservedObject var lib: MediaLibrary
    @State private var search = ""
    @State private var category: String?

    var body: some View {
        let kind = lib.kind
        let list = lib.filtered(search: search, category: category)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: kind.icon).foregroundColor(kind.color)
                Text(kind.title.uppercased()).font(.caption.bold()).foregroundColor(.secondary)
                Spacer()
                Button("Stäng") { ed.closeBrowser() }
            }

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("Sök, t.ex. boing", text: $search)
                    .textFieldStyle(PlainTextFieldStyle())
                    .font(.title3)
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(PlainButtonStyle())
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.08)))

            if !lib.categories.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        chip("Alla", selected: category == nil) { category = nil }
                        ForEach(lib.categories, id: \.self) { c in
                            chip(c, selected: category == c) { category = (category == c ? nil : c) }
                        }
                    }
                }
            }

            if lib.files.isEmpty {
                emptyState
            } else if list.isEmpty {
                Text("Inget ljud heter så. Prova ett annat ord.")
                    .foregroundColor(.secondary)
                    .padding(.top, 20)
                Spacer()
            } else {
                Text("\(list.count) av \(lib.files.count)").font(.caption).foregroundColor(.secondary)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(list) { f in
                            MediaRow(file: f, lib: lib, add: { add(f) })
                        }
                    }
                }
            }

            Divider()
            HStack {
                Button { NSWorkspace.shared.open(lib.folder) } label: { Label("Öppna mappen", systemImage: "folder") }
                Spacer()
                Menu {
                    Button("Byt mapp …") { chooseFolder() }
                    Button("Använd standardmappen") {
                        UserDefaults.standard.removeObject(forKey: lib.kind.defaultsKey)
                        lib.scan()
                    }
                    Button("Läs in mappen igen") { lib.scan() }
                    Divider()
                    Button("Välj en enstaka fil …") {
                        if kind == .sounds { ed.chooseSoundEffects() } else { ed.chooseMusic() }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(BorderlessButtonMenuStyle())
                .frame(width: 34)
            }
            .controlSize(.regular)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { lib.scan() }
        .onDisappear { lib.stop() }
    }

    private func add(_ f: MediaFile) {
        lib.stop()
        if lib.kind == .sounds {
            ed.addSounds([f.url], longBecomesMusic: false)
        } else {
            ed.addMusic(f.url)
        }
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Text(title)
            .font(.callout.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(selected ? lib.kind.color : Color.white.opacity(0.1)))
            .foregroundColor(selected ? .white : .primary)
            .contentShape(Capsule())
            .onTapGesture(perform: action)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            if lib.scanning {
                ProgressView().padding(.top, 20)
            } else {
                Text("Mappen är tom").font(.title3.bold()).padding(.top, 16)
                Text("Lägg \(lib.kind == .sounds ? "ljudeffekter" : "musik") i mappen, gärna i undermappar som blir kategorier. Sedan dyker de upp här.")
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(lib.folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.system(.caption, design: .monospaced)).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Välj mappen med \(lib.kind == .sounds ? "ljudeffekter" : "musik")"
        panel.prompt = "Välj"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = lib.folder
        if panel.runModal() == .OK, let u = panel.url { lib.folder = u }
    }
}

struct MediaRow: View {
    let file: MediaFile
    @ObservedObject var lib: MediaLibrary
    let add: () -> Void
    @State private var hover = false

    var body: some View {
        let isPlaying = lib.playing == file.url
        HStack(spacing: 8) {
            Image(systemName: isPlaying ? "stop.circle.fill" : "play.circle.fill")
                .font(.system(size: 22))
                .foregroundColor(lib.kind.color)
            VStack(alignment: .leading, spacing: 1) {
                Text(file.name).lineLimit(1)
                HStack(spacing: 6) {
                    if !file.category.isEmpty { Text(file.category) }
                    if let d = lib.durations[file.url] { Text(formatTime(d)) }
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
            Spacer(minLength: 4)
            Button(action: add) {
                Image(systemName: "plus.circle.fill").font(.system(size: 22))
            }
            .buttonStyle(PlainButtonStyle())
            .foregroundColor(hover ? .green : .secondary)
            .help(lib.kind.addHelp)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(isPlaying ? lib.kind.color.opacity(0.25) : (hover ? Color.white.opacity(0.06) : Color.clear)))
        .contentShape(Rectangle())
        .onTapGesture { lib.toggle(file.url) }
        .onHover { hover = $0 }
        .onAppear { lib.requestDuration(file.url) }
        .help("Klicka för att lyssna")
    }
}
