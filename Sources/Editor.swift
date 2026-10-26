import SwiftUI
import AVFoundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Var det gula strecket står. Egen klass så att bara det som visar tiden ritas om 30 gånger i sekunden.
final class PlayClock: ObservableObject {
    @Published var time: Double = 0
}

enum Edge { case left, right }

/// Håller filmen, uppspelningen, ångra och sparandet.
final class Editor: ObservableObject, @unchecked Sendable {
    @Published private(set) var project = Project()
    @Published var selection: Selection?
    @Published var isPlaying = false
    @Published var exportProgress: Double?
    @Published var toast: String?
    @Published var thumbs: [String: NSImage] = [:]
    @Published var stillPreviews: [String: NSImage] = [:]
    @Published var pixelsPerSecond: Double = 40
    /// Klipp som håller på att vändas baklänges, och hur långt det kommit (0–1).
    @Published var reversing: [UUID: Double] = [:]
    /// Filmen som är öppen just nu. Ingen öppen film: startskärmen med "Mina filmer" visas.
    @Published private(set) var currentFile: URL?
    @Published private(set) var library: [FilmInfo] = []
    @Published var libraryThumbs: [URL: NSImage] = [:]
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    let player = AVPlayer()
    let clock = PlayClock()

    var time: Double {
        get { clock.time }
        set { clock.time = newValue }
    }

    private var undoStack: [Project] = []
    private var redoStack: [Project] = []
    private var liveStart: Project?
    private var lastCoalesce: (key: String, at: Date)?
    private var builtKey: MediaKey?
    private var buildGeneration = 0
    private let generationLock = NSLock()
    private var generationShared = 0
    private let buildQueue = DispatchQueue(label: "filmklipparen.build", qos: .userInitiated)
    private var exportURLInProgress: URL?
    private var saveWork: DispatchWorkItem?
    private var toastWork: DispatchWorkItem?
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var keyMonitor: Any?
    private var quitObserver: NSObjectProtocol?
    private var exportSession: AVAssetExportSession?
    private var exportTimer: Timer?
    private var thumbLoading: Set<String> = []
    private var stillLoading: Set<String> = []
    private var textCache: [String: NSImage] = [:]
    private var scrubbing = false
    private var wasPlayingBeforeScrub = false

    init() {
        FilmLibrary.migrateOldProject()

        player.actionAtItemEnd = .pause
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30),
                                                      queue: .main) { [weak self] t in
            guard let self = self, self.player.rate != 0, !self.scrubbing else { return }
            let s = t.seconds
            if s.isFinite { self.time = s }
        }
        statusObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] p, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                let playing = p.timeControlStatus != .paused
                if self.isPlaying && !playing && !self.scrubbing {
                    let s = p.currentTime().seconds
                    if s.isFinite { self.time = min(s, self.project.duration) }
                }
                if self.isPlaying != playing { self.isPlaying = playing }
            }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            return self.handleKey(event) ? nil : event
        }
        quitObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                                              object: nil, queue: .main) { [weak self] _ in
            self?.saveNow()
        }

        refreshLibrary()
        // Används av provbygget: öppna senaste filmen direkt.
        if UserDefaults.standard.bool(forKey: "OpenLatest"), let first = library.first {
            open(first.url)
        }
    }

    // MARK: - Mina filmer

    func refreshLibrary() {
        library = FilmLibrary.list()
        for info in library {
            DispatchQueue.global(qos: .utility).async {
                let img = FilmLibrary.thumbnail(info)
                DispatchQueue.main.async { [weak self] in
                    if let img = img { self?.libraryThumbs[info.url] = img } else { self?.libraryThumbs[info.url] = nil }
                }
            }
        }
    }

    /// Ny film med ett namn. Den sparas direkt och öppnas.
    func createFilm(named name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var p = Project()
        p.name = clean.isEmpty ? "Min film" : clean
        let url = FilmLibrary.newURL()
        do {
            try FilmLibrary.save(p, to: url)
        } catch {
            show("Det gick inte att skapa filmen: \(error.localizedDescription)")
            return
        }
        open(url)
    }

    func open(_ url: URL) {
        guard let loaded = FilmLibrary.load(url) else {
            show("Det gick inte att öppna filmen")
            refreshLibrary()
            return
        }
        var cleaned = loaded.removingMissingFiles()
        let beforeMigration = cleaned.project
        cleaned.project.migrateOldTitles()
        let changed = cleaned.project != beforeMigration || cleaned.missing > 0
        player.pause()
        player.replaceCurrentItem(with: nil)
        builtKey = nil
        undoStack.removeAll()
        redoStack.removeAll()
        liveStart = nil
        lastCoalesce = nil
        updateUndoFlags()
        selection = nil
        project = cleaned.project
        currentFile = url
        time = 0
        pixelsPerSecond = 40
        scheduleRebuild()
        if cleaned.missing > 0 {
            show("\(cleaned.missing) fil(er) hittades inte längre och togs bort ur filmen")
        }
        if changed { scheduleSave() }
    }

    /// Tillbaka till "Mina filmer". Filmen sparas först.
    func closeFilm() {
        saveNow()
        player.pause()
        player.replaceCurrentItem(with: nil)
        selection = nil
        currentFile = nil
        undoStack.removeAll()
        redoStack.removeAll()
        updateUndoFlags()
        refreshLibrary()
    }

    func renameFilm(_ info: FilmInfo, to name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        FilmLibrary.rename(info, to: clean)
        refreshLibrary()
    }

    func duplicateFilm(_ info: FilmInfo) {
        FilmLibrary.duplicate(info)
        refreshLibrary()
    }

    func deleteFilm(_ info: FilmInfo) {
        FilmLibrary.delete(info)
        libraryThumbs[info.url] = nil
        refreshLibrary()
        show("\(info.name) ligger i papperskorgen om du ångrar dig")
    }

    // MARK: - Det som syns

    var selectedClip: Clip? {
        guard case .clip(let id)? = selection else { return nil }
        return project.clips.first { $0.id == id }
    }

    var selectedStill: StillItem? {
        guard case .still(let id)? = selection else { return nil }
        return project.stills.first { $0.id == id }
    }

    var selectedText: TextItem? {
        guard case .text(let id)? = selection else { return nil }
        return project.texts.first { $0.id == id }
    }

    var selectedSound: SoundItem? {
        guard case .sound(let id)? = selection else { return nil }
        return project.sounds.first { $0.id == id }
    }

    func show(_ text: String) {
        toast = text
        toastWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.toast = nil }
        toastWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5, execute: w)
    }

    // MARK: - Tangenter

    private func handleKey(_ e: NSEvent) -> Bool {
        if exportProgress != nil || currentFile == nil { return false }
        if e.window?.firstResponder is NSText { return false } // någon skriver i en textruta
        if !e.modifierFlags.intersection([.command, .control, .option]).isEmpty { return false }
        let big = e.modifierFlags.contains(.shift)
        switch e.keyCode {
        case 49: togglePlay()                        // mellanslag
        case 123: step(big ? -30 : -1)               // ←
        case 124: step(big ? 30 : 1)                 // →
        case 40: splitAtPlayhead()                   // K
        case 51, 117: deleteSelected()               // backsteg / delete
        case 53: selection = nil                     // esc
        default: return false
        }
        return true
    }

    /// Tar bort markören ur textrutor, så att mellanslag och K styr filmen igen.
    func defocus() {
        if let w = NSApp.keyWindow, w.firstResponder is NSText {
            w.makeFirstResponder(nil)
        }
    }

    // MARK: - Uppspelning

    func togglePlay() {
        defocus()
        guard player.currentItem != nil else { return }
        if player.rate != 0 {
            player.pause()
        } else {
            if time >= project.duration - 0.05 { seek(0) }
            player.play()
        }
    }

    func seek(_ t: Double, exact: Bool = true) {
        let c = max(0, min(t, project.duration))
        time = c
        let tol = exact ? CMTime.zero : cm(0.1)
        player.seek(to: cm(c), toleranceBefore: tol, toleranceAfter: tol)
    }

    func step(_ frames: Int) {
        player.pause()
        seek(time + Double(frames) / 30)
    }

    func scrub(to t: Double) {
        if !scrubbing {
            defocus()
            scrubbing = true
            wasPlayingBeforeScrub = player.rate != 0
            player.pause()
        }
        seek(t, exact: false)
    }

    func endScrub(at t: Double) {
        seek(t)
        scrubbing = false
        if wasPlayingBeforeScrub { player.play() }
    }

    /// Klick på något i tidslinjen: välj det och flytta strecket dit man klickade.
    func click(_ sel: Selection?, atTimelineX x: Double) {
        defocus()
        selection = sel
        seek(x / pixelsPerSecond)
    }

    func fitTimeline(width: Double) {
        let d = project.duration
        guard d > 0 else { return }
        pixelsPerSecond = min(200, max(2, (width - 60) / d))
    }

    // MARK: - Ångra

    /// `coalesce`: ändringar med samma nyckel inom två sekunder blir ett enda ångra-steg (t.ex. skrivande).
    private func commit(coalesce key: String? = nil, _ change: (inout Project) -> Void) {
        let before = project
        var p = project
        change(&p)
        guard p != before else { return }
        project = p
        if let k = key, let last = lastCoalesce, last.key == k, Date().timeIntervalSince(last.at) < 2 {
            // samma steg som förra gången
        } else {
            pushUndo(before)
        }
        lastCoalesce = key.map { ($0, Date()) }
        projectChanged()
    }

    private func live(coalesce key: String? = nil, _ change: (inout Project) -> Void) {
        if liveStart == nil {
            commit(coalesce: key, change)
            return
        }
        var p = project
        change(&p)
        guard p != project else { return }
        project = p
        projectChanged()
    }

    /// Reglage och dragningar: en hel dragning blir ett enda ångra-steg.
    func liveEditing(_ began: Bool) {
        if began {
            if liveStart == nil { liveStart = project }
        } else {
            if let b = liveStart, b != project { pushUndo(b) }
            liveStart = nil
        }
    }

    private func pushUndo(_ p: Project) {
        undoStack.append(p)
        if undoStack.count > 300 { undoStack.removeFirst(undoStack.count - 300) }
        redoStack.removeAll()
        updateUndoFlags()
    }

    private func updateUndoFlags() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    func undo() {
        liveStart = nil
        lastCoalesce = nil
        guard let p = undoStack.popLast() else { return }
        redoStack.append(project)
        project = p
        updateUndoFlags()
        projectChanged()
    }

    func redo() {
        liveStart = nil
        lastCoalesce = nil
        guard let p = redoStack.popLast() else { return }
        undoStack.append(project)
        project = p
        updateUndoFlags()
        projectChanged()
    }

    private func projectChanged() {
        if let sel = selection {
            let exists: Bool
            switch sel {
            case .clip(let id): exists = project.clips.contains { $0.id == id }
            case .still(let id): exists = project.stills.contains { $0.id == id }
            case .text(let id): exists = project.texts.contains { $0.id == id }
            case .sound(let id): exists = project.sounds.contains { $0.id == id }
            case .music: exists = project.musicPath != nil
            }
            if !exists { selection = nil }
        }
        if time > project.duration { seek(project.duration) }
        scheduleRebuild()
        scheduleSave()
    }

    // MARK: - Fästa mot strecket och kanter

    /// Drar man nära strecket, början eller en kant på något annat fastnar det där.
    func snap(_ t: Double, except id: UUID?) -> Double {
        let tolerance = 8 / pixelsPerSecond
        var targets: [Double] = [0, time]
        var s = 0.0
        for c in project.clips {
            s += c.length
            targets.append(s)
        }
        for x in project.stills where x.id != id { targets += [x.start, x.end] }
        for x in project.texts where x.id != id { targets += [x.start, x.end] }
        for x in project.sounds where x.id != id { targets += [x.start, x.end] }
        guard let best = targets.min(by: { abs($0 - t) < abs($1 - t) }), abs(best - t) <= tolerance else { return t }
        return best
    }

    private func others<T: TimedItem>(_ items: [T], except id: UUID) -> [(start: Double, end: Double)] {
        items.filter { $0.id != id }.map { (start: $0.start, end: $0.end) }
    }

    // MARK: - Filmspåret

    func splitAtPlayhead() {
        let t = time
        switch selection {
        case .still(let id)?: if splitItem(\.stills, id, at: t) { return }
        case .text(let id)?: if splitItem(\.texts, id, at: t) { return }
        case .sound(let id)?:
            if let i = project.sounds.firstIndex(where: { $0.id == id }), splitSound(i, at: t) { return }
        default: break
        }
        guard let i = project.clipIndex(at: t) else {
            show("Flytta det gula strecket in i ett klipp för att klippa där")
            return
        }
        let clip = project.clips[i]
        let local = t - project.startTime(of: i)
        guard local > 0.1, local < clip.length - 0.1 else {
            show("Flytta det gula strecket in i ett klipp för att klippa där")
            return
        }
        player.pause()
        var first = clip
        var second = clip
        second.id = UUID()
        if clip.isReversed {
            // Baklänges spelas slutet först.
            first.start = clip.end - local
            second.end = clip.end - local
        } else {
            first.end = clip.start + local
            second.start = clip.start + local
        }
        commit { p in
            p.clips[i] = first
            p.clips.insert(second, at: i + 1)
        }
        selection = .clip(second.id)
    }

    private func splitItem<T: TimedItem>(_ kp: WritableKeyPath<Project, [T]>, _ id: UUID, at t: Double) -> Bool
        where T: Equatable {
        guard let i = project[keyPath: kp].firstIndex(where: { $0.id == id }) else { return false }
        let item = project[keyPath: kp][i]
        guard t > item.start + 0.1, t < item.end - 0.1 else { return false }
        var first = item
        first.duration = t - item.start
        guard var second = copyWithNewID(item) else { return false }
        second.start = t
        second.duration = item.end - t
        commit { p in
            p[keyPath: kp][i] = first
            p[keyPath: kp].insert(second, at: i + 1)
        }
        selection = selectionFor(second)
        return true
    }

    private func splitSound(_ i: Int, at t: Double) -> Bool {
        let s = project.sounds[i]
        guard t > s.start + 0.1, t < s.end - 0.1 else { return false }
        var first = s
        first.duration = t - s.start
        var second = s
        second.id = UUID()
        second.start = t
        second.inPoint = s.inPoint + (t - s.start)
        second.duration = s.end - t
        commit { p in
            p.sounds[i] = first
            p.sounds.insert(second, at: i + 1)
        }
        selection = .sound(second.id)
        return true
    }

    private func copyWithNewID<T: TimedItem>(_ item: T) -> T? {
        if var s = item as? StillItem { s.id = UUID(); return s as? T }
        if var s = item as? TextItem { s.id = UUID(); return s as? T }
        if var s = item as? SoundItem { s.id = UUID(); return s as? T }
        return nil
    }

    private func selectionFor<T: TimedItem>(_ item: T) -> Selection? {
        if item is StillItem { return .still(item.id) }
        if item is TextItem { return .text(item.id) }
        if item is SoundItem { return .sound(item.id) }
        return nil
    }

    func deleteSelected() {
        switch selection {
        case .clip(let id)?: commit { $0.clips.removeAll { $0.id == id } }
        case .still(let id)?: commit { $0.stills.removeAll { $0.id == id } }
        case .text(let id)?: commit { $0.texts.removeAll { $0.id == id } }
        case .sound(let id)?: commit { $0.sounds.removeAll { $0.id == id } }
        case .music?: commit { $0.musicPath = nil }
        case nil: return
        }
        selection = nil
    }

    func moveSelectedClip(_ direction: Int) {
        guard let id = selectedClip?.id, let i = project.index(of: id) else { return }
        let j = i + direction
        guard j >= 0, j < project.clips.count else { return }
        commit { $0.clips.swapAt(i, j) }
        seek(project.startTime(ofID: id))
    }

    /// Ett filmklipp som dragits hamnar där mitten av de andra klippen säger.
    func moveClip(_ id: UUID, toTimelineX x: Double) {
        guard let from = project.index(of: id) else { return }
        var target = 0
        var s = 0.0
        for (i, c) in project.clips.enumerated() {
            if i != from && (s + c.length / 2) * pixelsPerSecond < x { target += 1 }
            s += c.length
        }
        selection = .clip(id)
        guard target != from else { return }
        commit { p in
            let c = p.clips.remove(at: from)
            p.clips.insert(c, at: target)
        }
        seek(project.startTime(ofID: id))
    }

    func setClipStart(_ id: UUID, _ v: Double) {
        live { p in
            guard let j = p.index(of: id) else { return }
            p.clips[j].start = max(0, min(v, p.clips[j].end - 0.2))
        }
        if let j = project.index(of: id) {
            player.pause()
            seek(project.startTime(of: j))
        }
    }

    func setClipEnd(_ id: UUID, _ v: Double) {
        live { p in
            guard let j = p.index(of: id) else { return }
            let c = p.clips[j]
            p.clips[j].end = max(min(v, c.sourceDuration), c.start + 0.2)
        }
        if let j = project.index(of: id) {
            player.pause()
            seek(project.startTime(of: j) + project.clips[j].length - 1.0 / 30)
        }
    }

    // MARK: - Baklänges

    /// Vänd ett filmklipp baklänges, eller tillbaka framlänges.
    func toggleReverse(_ id: UUID) {
        guard reversing[id] == nil, let clip = project.clips.first(where: { $0.id == id }) else { return }
        if clip.isReversed {
            commit { p in
                if let i = p.index(of: id) { p.clips[i].reversedPath = nil }
            }
            return
        }
        player.pause()
        let source = clip.url
        let cached = ReverseRenderer.cacheURL(for: source)
        if ReverseRenderer.isReady(cached) {
            setReversed(id, path: cached.path, source: clip.path)
            return
        }
        reversing[id] = 0
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var result: URL?
            var problem: Error?
            do {
                result = try ReverseRenderer.render(source, progress: { f in
                    DispatchQueue.main.async { [weak self] in
                        if self?.reversing[id] != nil { self?.reversing[id] = f }
                    }
                })
            } catch {
                problem = error
            }
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.reversing[id] = nil
                if let r = result {
                    self.setReversed(id, path: r.path, source: clip.path)
                    self.show("Klippet spelas nu baklänges")
                } else {
                    self.show("Det gick inte att vända klippet: \(problem?.localizedDescription ?? "okänt fel")")
                }
            }
        }
    }

    /// Klippet spelas från baklänges-kopian.
    private func setReversed(_ id: UUID, path: String, source: String) {
        commit { p in
            if let i = p.index(of: id) { p.clips[i].reversedPath = path }
        }
    }

    func setClipVolume(_ id: UUID, _ v: Float) {
        live { p in
            guard let j = p.index(of: id) else { return }
            p.clips[j].volume = max(0, min(1, v))
        }
    }

    // MARK: - Fria spår: flytta och dra i kanterna

    func moveItem<T: TimedItem>(_ kp: WritableKeyPath<Project, [T]>, _ id: UUID, to desired: Double) where T: Equatable {
        let items = project[keyPath: kp]
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        let len = items[i].duration
        var s = snap(desired, except: id)
        if s == desired { s = snap(desired + len, except: id) - len }
        let start = Lane.freeStart(desired: s, length: len, others: others(items, except: id))
        live { p in p[keyPath: kp][i].start = start }
    }

    func resizeItem<T: TimedItem>(_ kp: WritableKeyPath<Project, [T]>, _ id: UUID, edge: Edge, to t: Double)
        where T: Equatable {
        let items = project[keyPath: kp]
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        var item = items[i]
        let b = Lane.bounds(of: item.start, end: item.end, others: others(items, except: id))
        let v = snap(t, except: id)
        let minLen = 0.3
        switch edge {
        case .left:
            let ns = min(max(v, b.min), item.end - minLen)
            item.duration = item.end - ns
            item.start = ns
        case .right:
            let ne = max(min(v, b.max, item.start + 600), item.start + minLen)
            item.duration = ne - item.start
        }
        live { p in p[keyPath: kp][i] = item }
    }

    func resizeSound(_ id: UUID, edge: Edge, to t: Double) {
        guard let i = project.sounds.firstIndex(where: { $0.id == id }) else { return }
        var s = project.sounds[i]
        let b = Lane.bounds(of: s.start, end: s.end, others: others(project.sounds, except: id))
        let v = snap(t, except: id)
        switch edge {
        case .left:
            let lowest = max(b.min, s.start - s.inPoint)
            let ns = min(max(v, lowest), s.end - 0.1)
            s.inPoint += ns - s.start
            s.duration = s.end - ns
            s.start = ns
        case .right:
            let ne = max(min(v, b.max, s.start + (s.sourceDuration - s.inPoint)), s.start + 0.1)
            s.duration = ne - s.start
        }
        live { p in p.sounds[i] = s }
    }

    // MARK: - Bilder och texter i rutan

    func updateStill(_ id: UUID, _ f: (inout StillItem) -> Void) {
        live { p in
            guard let i = p.stills.firstIndex(where: { $0.id == id }) else { return }
            f(&p.stills[i])
        }
    }

    func updateText(_ id: UUID, typing: Bool = false, _ f: (inout TextItem) -> Void) {
        live(coalesce: typing ? "text-\(id)" : nil) { p in
            guard let i = p.texts.firstIndex(where: { $0.id == id }) else { return }
            f(&p.texts[i])
        }
    }

    func updateSound(_ id: UUID, _ f: (inout SoundItem) -> Void) {
        live { p in
            guard let i = p.sounds.firstIndex(where: { $0.id == id }) else { return }
            f(&p.sounds[i])
        }
    }

    /// Flytta en bild eller text i rutan. Nära mitten fastnar den i mitten.
    func moveOverlay(_ sel: Selection, x: Double, y: Double) {
        func snapped(_ v: Double) -> Double { abs(v - 0.5) < 0.015 ? 0.5 : min(1.2, max(-0.2, v)) }
        let nx = snapped(x), ny = snapped(y)
        switch sel {
        case .still(let id): updateStill(id) { $0.x = nx; $0.y = ny }
        case .text(let id): updateText(id) { $0.x = nx; $0.y = ny }
        default: break
        }
    }

    // MARK: - Övrigt

    func setMusicVolume(_ v: Float) {
        live { $0.musicVolume = max(0, min(1, v)) }
    }

    func removeMusic() {
        commit { $0.musicPath = nil }
        if selection == .music { selection = nil }
    }

    func rename(_ name: String) {
        live(coalesce: "name") { $0.name = name }
    }

    // MARK: - Lägga till

    private func openPanel(_ title: String, types: [UTType], multiple: Bool) -> [URL] {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = "Lägg till"
        panel.allowsMultipleSelection = multiple
        panel.canChooseDirectories = false
        panel.allowedContentTypes = types
        return panel.runModal() == .OK ? panel.urls : []
    }

    func chooseFilms() {
        let urls = openPanel("Välj filmklipp", types: [.movie], multiple: true)
        if !urls.isEmpty { addFilms(urls) }
    }

    func chooseImages() {
        let urls = openPanel("Välj bilder", types: [.image], multiple: true)
        if !urls.isEmpty { addImages(urls) }
    }

    func chooseMusic() {
        if let u = openPanel("Välj en låt", types: [.audio], multiple: false).first { addMusic(u) }
    }

    func chooseSoundEffects() {
        let urls = openPanel("Välj ljudeffekter", types: [.audio], multiple: true)
        if !urls.isEmpty { addSounds(urls, longBecomesMusic: false) }
    }

    func addFilms(_ urls: [URL]) {
        let sorted = Editor.sortedByName(urls)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var added: [Clip] = []
            var bad = 0
            for u in sorted {
                let asset = AVURLAsset(url: u)
                let d = asset.duration.seconds
                if asset.tracks(withMediaType: .video).isEmpty || !d.isFinite || d <= 0.1 {
                    bad += 1
                    continue
                }
                added.append(Clip(path: u.path, sourceDuration: d, start: 0, end: d))
            }
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if !added.isEmpty {
                    let wasEmpty = self.project.isEmpty
                    self.commit { $0.clips.append(contentsOf: added) }
                    self.selection = .clip(added[0].id)
                    if wasEmpty { self.pixelsPerSecond = 40 }
                }
                if bad > 0 { self.show("\(bad) fil(er) gick inte att öppna som film") }
            }
        }
    }

    func addImages(_ urls: [URL]) {
        let sorted = Editor.sortedByName(urls)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var found: [(url: URL, aspect: Double)] = []
            var bad = 0
            for u in sorted {
                if let img = Overlay.loadImage(u, maxPixels: 256), img.height > 0 {
                    found.append((u, Double(img.width) / Double(img.height)))
                } else {
                    bad += 1
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if !found.isEmpty {
                    var cursor = self.time
                    var newIDs: [UUID] = []
                    self.commit { p in
                        for f in found {
                            let len = 4.0
                            let start = Lane.freeStart(desired: cursor, length: len,
                                                       others: p.stills.map { (start: $0.start, end: $0.end) })
                            let s = StillItem(path: f.url.path, aspect: f.aspect, start: start, duration: len)
                            p.stills.append(s)
                            newIDs.append(s.id)
                            cursor = start + len
                        }
                    }
                    if let first = newIDs.first, let s = self.project.stills.first(where: { $0.id == first }) {
                        self.selection = .still(first)
                        self.seek(s.start + 0.01)
                    }
                    self.show("Dra bilden i rutan för att flytta den, i hörnet för att ändra storlek")
                }
                if bad > 0 { self.show("\(bad) fil(er) gick inte att öppna som bild") }
            }
        }
    }

    func addText() {
        let len = 3.0
        let start = Lane.freeStart(desired: time, length: len,
                                   others: project.texts.map { (start: $0.start, end: $0.end) })
        let t = TextItem(text: "Min text", start: start, duration: len)
        commit { $0.texts.append(t) }
        selection = .text(t.id)
        seek(start + 0.01)
    }

    func addMusic(_ url: URL) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let ok = !AVURLAsset(url: url).tracks(withMediaType: .audio).isEmpty
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if !ok {
                    self.show("Det där gick inte att spela som musik")
                    return
                }
                self.commit { $0.musicPath = url.path }
                self.selection = .music
                self.show("Musiken ligger under hela filmen och tonas ut på slutet")
            }
        }
    }

    /// Ljudfiler. Från dra-och-släpp blir en lång låt (över 30 s) musik om det inte redan finns musik.
    func addSounds(_ urls: [URL], longBecomesMusic: Bool) {
        let sorted = Editor.sortedByName(urls)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var found: [(url: URL, duration: Double)] = []
            var bad = 0
            for u in sorted {
                let a = AVURLAsset(url: u)
                let d = a.duration.seconds
                if a.tracks(withMediaType: .audio).isEmpty || !d.isFinite || d < 0.05 {
                    bad += 1
                } else {
                    found.append((u, d))
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                var effects = found
                if longBecomesMusic, self.project.musicPath == nil,
                   let i = effects.firstIndex(where: { $0.duration > 30 }) {
                    self.addMusic(effects.remove(at: i).url)
                }
                if !effects.isEmpty {
                    var cursor = self.time
                    var firstID: UUID?
                    self.commit { p in
                        for f in effects {
                            let len = min(f.duration, 600)
                            let start = Lane.freeStart(desired: cursor, length: len,
                                                       others: p.sounds.map { (start: $0.start, end: $0.end) })
                            let s = SoundItem(path: f.url.path, sourceDuration: f.duration, start: start, duration: len)
                            p.sounds.append(s)
                            if firstID == nil { firstID = s.id }
                            cursor = start + len
                        }
                    }
                    if let id = firstID { self.selection = .sound(id) }
                }
                if bad > 0 { self.show("\(bad) fil(er) gick inte att spela som ljud") }
            }
        }
    }

    func handleDrop(_ providers: [NSItemProvider]) {
        final class Box { var urls: [URL?] = [] }
        let box = Box()
        box.urls = Array(repeating: nil, count: providers.count)
        let lock = NSLock()
        let group = DispatchGroup()
        for (i, p) in providers.enumerated() {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                lock.lock()
                box.urls[i] = url
                lock.unlock()
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in
            var films: [URL] = [], images: [URL] = [], sounds: [URL] = []
            for u in box.urls.compactMap({ $0 }) {
                let t = UTType(filenameExtension: u.pathExtension.lowercased())
                if let t = t, t.conforms(to: .image) {
                    images.append(u)
                } else if let t = t, t.conforms(to: .audio), !t.conforms(to: .movie) {
                    sounds.append(u)
                } else {
                    films.append(u)
                }
            }
            if !films.isEmpty { self?.addFilms(films) }
            if !images.isEmpty { self?.addImages(images) }
            if !sounds.isEmpty { self?.addSounds(sounds, longBecomesMusic: true) }
        }
    }

    private static func sortedByName(_ urls: [URL]) -> [URL] {
        urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    // MARK: - Bygga om förhandsvisningen

    private func scheduleRebuild() {
        let key = project.mediaKey
        guard key != builtKey else { return }
        builtKey = key
        buildGeneration += 1
        let gen = buildGeneration
        generationLock.lock(); generationShared = gen; generationLock.unlock()
        let p = project
        // Vänta lite så att en hel dragning inte bygger om filmen hela tiden.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self = self, gen == self.buildGeneration else { return }
            self.buildQueue.async { [weak self] in
                let stale = { [weak self] in self.map { $0.generationSnapshot != gen } ?? true }
                var built: BuiltMovie?
                var failed = false
                do {
                    built = try MovieBuilder.build(p, forExport: false, isCancelled: stale)
                } catch {
                    failed = !(error is CancelledError)
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, gen == self.buildGeneration else { return }
                    if failed { self.show("Något klipp gick inte att läsa") }
                    self.install(built)
                }
            }
        }
    }

    /// Läses från byggkön, därför bakom ett lås.
    fileprivate var generationSnapshot: Int {
        generationLock.lock(); defer { generationLock.unlock() }
        return generationShared
    }

    private func install(_ built: BuiltMovie?) {
        let wasPlaying = player.rate != 0
        guard let b = built else {
            player.replaceCurrentItem(with: nil)
            return
        }
        let item = AVPlayerItem(asset: b.composition)
        item.videoComposition = b.videoComposition
        item.audioMix = b.audioMix
        player.replaceCurrentItem(with: item)
        player.seek(to: cm(min(time, b.duration)), toleranceBefore: .zero, toleranceAfter: .zero)
        if wasPlaying { player.play() }
    }

    // MARK: - Små bilder

    /// En liten bild från början av ett filmklipp, i rätt format (även stående).
    func thumbnail(for clip: Clip) -> NSImage? {
        let key = "\(clip.path)#\(Int(clip.start * 4))#\(Int(clip.end * 4))#\(clip.isReversed)"
        if let img = thumbs[key] { return img }
        if thumbLoading.contains(key) { return nil }
        thumbLoading.insert(key)
        let url = clip.url
        // Baklänges syns slutet av klippet först.
        let t = clip.isReversed ? max(clip.start, clip.end - 0.2) : clip.start + min(0.2, clip.length / 2)
        DispatchQueue.global(qos: .userInitiated).async {
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 200, height: 112)
            gen.requestedTimeToleranceBefore = cm(0.5)
            gen.requestedTimeToleranceAfter = cm(0.5)
            let cg = try? gen.copyCGImage(at: cm(t), actualTime: nil)
            DispatchQueue.main.async { [weak self] in
                if let cg = cg {
                    self?.thumbs[key] = NSImage(cgImage: cg, size: CGSize(width: cg.width, height: cg.height))
                }
            }
        }
        return nil
    }

    /// En stillbild i lagom storlek för förhandsvisningen.
    func stillPreview(_ path: String) -> NSImage? {
        if let img = stillPreviews[path] { return img }
        if stillLoading.contains(path) { return nil }
        stillLoading.insert(path)
        DispatchQueue.global(qos: .userInitiated).async {
            let cg = Overlay.loadImage(URL(fileURLWithPath: path), maxPixels: 1280)
            DispatchQueue.main.async { [weak self] in
                if let cg = cg {
                    self?.stillPreviews[path] = NSImage(cgImage: cg, size: CGSize(width: cg.width, height: cg.height))
                }
            }
        }
        return nil
    }

    /// Texten som bild, ritad för en 720 hög bild. Samma ritning som i den sparade filmen.
    static let textPreviewHeight: CGFloat = 720

    func textPreview(_ t: TextItem) -> NSImage? {
        let key = "\(t.text)|\(t.font)|\(t.bold)|\(t.size)|\(t.color)"
        if let img = textCache[key] { return img }
        guard let cg = Overlay.textImage(t, frameHeight: Editor.textPreviewHeight) else { return nil }
        if textCache.count > 300 { textCache.removeAll() }
        let img = NSImage(cgImage: cg, size: CGSize(width: cg.width, height: cg.height))
        textCache[key] = img
        return img
    }

    // MARK: - Spara filmen som MP4

    func exportMovie() {
        guard !project.isEmpty else {
            show("Lägg till lite film först!")
            return
        }
        player.pause()
        selection = nil
        let p = project
        let url = Editor.exportURL(name: p.name)
        exportProgress = 0
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var built: BuiltMovie?
            var problem: Error?
            do { built = try MovieBuilder.build(p, forExport: true) } catch { problem = error }
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                guard let b = built,
                      let s = AVAssetExportSession(asset: b.composition, presetName: AVAssetExportPreset1920x1080)
                else {
                    self.exportProgress = nil
                    self.show("Det gick inte att göra filmen: \((problem ?? BuildError.failed).localizedDescription)")
                    return
                }
                s.outputURL = url
                s.outputFileType = .mp4
                s.videoComposition = b.videoComposition
                s.audioMix = b.audioMix
                s.shouldOptimizeForNetworkUse = true
                self.exportSession = s
                self.exportURLInProgress = url
                self.exportTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                    self?.tickExport()
                }
                s.exportAsynchronously { [weak self] in
                    DispatchQueue.main.async { [weak self] in self?.exportFinished() }
                }
            }
        }
    }

    private func tickExport() {
        if let s = exportSession { exportProgress = Double(s.progress) }
    }

    func cancelExport() {
        exportSession?.cancelExport()
    }

    private func exportFinished() {
        guard let s = exportSession, let url = exportURLInProgress else { return }
        exportTimer?.invalidate()
        exportTimer = nil
        exportSession = nil
        exportProgress = nil
        switch s.status {
        case .completed:
            show("Klart! Filmen ligger i mappen Filmer")
            NSWorkspace.shared.activateFileViewerSelecting([url])
        case .cancelled:
            try? FileManager.default.removeItem(at: url)
            show("Sparandet avbröts")
        default:
            try? FileManager.default.removeItem(at: url)
            show("Det gick inte att spara filmen: \(s.error?.localizedDescription ?? "okänt fel")")
        }
    }

    static func exportURL(name: String) -> URL {
        let dir = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
        var base = name.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { base = "Min film" }
        var url = dir.appendingPathComponent(base + ".mp4")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(base) \(n).mp4")
            n += 1
        }
        return url
    }

    // MARK: - Spara arbetet automatiskt

    private func scheduleSave() {
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: w)
    }

    func saveNow() {
        saveWork?.cancel()
        guard let url = currentFile else { return }
        do {
            try FilmLibrary.save(project, to: url)
        } catch {
            NSLog("Filmklipparen: kunde inte spara projektet: \(error)")
        }
    }
}
