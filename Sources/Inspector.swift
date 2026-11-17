import SwiftUI
import AppKit

// MARK: - Inställningar till höger, för det som är valt

struct Field<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.bold()).foregroundColor(.secondary)
            content
        }
    }
}

struct VolumeSlider: View {
    @EnvironmentObject var ed: Editor
    let value: Float
    let set: (Float) -> Void

    var body: some View {
        HStack {
            Image(systemName: "speaker.fill").foregroundColor(.secondary)
            Slider(value: Binding(get: { Double(value) }, set: { set(Float($0)) }), in: 0...1,
                   onEditingChanged: { ed.liveEditing($0) })
            Image(systemName: "speaker.wave.3.fill").foregroundColor(.secondary)
        }
    }
}

struct PanelHeader: View {
    @EnvironmentObject var ed: Editor
    let kind: String
    let color: Color
    var title: String = ""
    var detail: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Circle().fill(color).frame(width: 10, height: 10)
                Text(kind).font(.caption.bold()).foregroundColor(.secondary)
                Spacer()
                Button("Klar") { ed.selection = nil }
            }
            if !title.isEmpty {
                Text(title).font(.title3.bold()).lineLimit(2)
            }
            if !detail.isEmpty {
                Text(detail).foregroundColor(.secondary)
            }
        }
    }
}

/// En knapp som är på eller av (gul när den är på).
struct Chip: View {
    let title: String
    var icon: String? = nil
    let on: Bool
    var minWidth: CGFloat = 52
    let action: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            if let i = icon { Image(systemName: i) }
            Text(title)
        }
        .font(.callout.weight(.semibold))
        .frame(minWidth: minWidth)
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 6).fill(on ? Color.yellow : Color.white.opacity(0.1)))
        .foregroundColor(on ? .black : .primary)
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
    }
}

/// Förlopp när något görs om (baklänges, svartvitt, röst).
struct Busy: View {
    let text: String
    let value: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ProgressView(value: value)
            Text("\(text) \(Int(value * 100)) %").font(.caption).foregroundColor(.secondary)
        }
    }
}

struct DeleteButton: View {
    @EnvironmentObject var ed: Editor
    let title: String

    var body: some View {
        Button { ed.deleteSelected() } label: { Label(title, systemImage: "trash") }
    }
}

struct SidePanel: View {
    @EnvironmentObject var ed: Editor

    var body: some View {
        if let kind = ed.browser {
            MediaBrowserView(lib: kind == .sounds ? ed.soundLibrary : ed.musicLibrary)
                .id(kind == .sounds ? "sounds" : "music")
        } else {
            settings
        }
    }

    private var settings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let c = ed.selectedClip {
                    ClipSettings(clip: c)
                } else if let s = ed.selectedStill {
                    StillSettings(item: s)
                } else if let t = ed.selectedText {
                    TextSettings(item: t)
                } else if let s = ed.selectedSound {
                    SoundSettings(item: s)
                } else if let m = ed.selectedMusic {
                    MusicSettings(item: m)
                } else {
                    MovieSettings()
                }
            }
            .padding(16)
            .frame(maxWidth: 380, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Hur länge något visas, som ett reglage.
struct DurationSlider: View {
    @EnvironmentObject var ed: Editor
    let duration: Double
    let set: (Double) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Slider(value: Binding(get: { min(30, duration) }, set: { set($0) }), in: 0.5...30,
                   onEditingChanged: { ed.liveEditing($0) })
            Text("\(String(format: "%.1f", duration)) sekunder").foregroundColor(.secondary)
        }
    }
}

struct ClipSettings: View {
    @EnvironmentObject var ed: Editor
    let clip: Clip

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PanelHeader(kind: "FILMKLIPP", color: Palette.filmColor(for: clip.id),
                        title: clip.name, detail: formatTime(clip.length))

            Field("Effekter") {
                HStack(spacing: 6) {
                    Chip(title: "Baklänges", icon: "backward.fill", on: clip.isReversed) {
                        ed.toggleReverse(clip.id)
                    }
                    Chip(title: "Svartvitt", icon: "circle.lefthalf.fill", on: clip.blackWhite == true) {
                        ed.setBlackWhite(clip.id, clip.blackWhite != true)
                    }
                }
                if let f = ed.reversing[clip.id] { Busy(text: "Vänder klippet …", value: f) }
                if let f = ed.blackWhiting[clip.id] { Busy(text: "Gör svartvitt …", value: f) }
            }
            Field("Hastighet") {
                SpeedButtons(rate: clip.rate) { ed.setClipSpeed(clip.id, $0) }
            }
            Field("Röst") {
                if let f = ed.voicing[clip.id] {
                    Busy(text: "Gör om rösten …", value: f)
                } else {
                    VoiceButtons(cents: clip.pitch ?? 0) { ed.setClipVoice(clip.id, $0) }
                }
            }
            Field("Ljud") {
                VolumeSlider(value: clip.volume) { ed.setClipVolume(clip.id, $0) }
            }
            Field("Början och slut") {
                trimSliders
            }
            HStack {
                Button { ed.moveSelectedClip(-1) } label: { Image(systemName: "arrow.left") }
                    .help("Byt plats med klippet före")
                Button { ed.moveSelectedClip(1) } label: { Image(systemName: "arrow.right") }
                    .help("Byt plats med klippet efter")
                Spacer()
                DeleteButton(title: "Ta bort")
            }
        }
        .controlSize(.large)
    }

    @ViewBuilder private var trimSliders: some View {
        if clip.isReversed {
            // Baklänges: början är slutet i originalfilmen.
            let d = clip.sourceDuration
            Slider(value: Binding(get: { d - clip.end }, set: { ed.setClipEnd(clip.id, d - $0) }),
                   in: 0...max(0.3, d), onEditingChanged: { ed.liveEditing($0) })
            Slider(value: Binding(get: { d - clip.start }, set: { ed.setClipStart(clip.id, d - $0) }),
                   in: 0...max(0.3, d), onEditingChanged: { ed.liveEditing($0) })
        } else {
            Slider(value: Binding(get: { clip.start }, set: { ed.setClipStart(clip.id, $0) }),
                   in: 0...max(0.3, clip.sourceDuration), onEditingChanged: { ed.liveEditing($0) })
            Slider(value: Binding(get: { clip.end }, set: { ed.setClipEnd(clip.id, $0) }),
                   in: 0...max(0.3, clip.sourceDuration), onEditingChanged: { ed.liveEditing($0) })
        }
    }
}

struct StillSettings: View {
    @EnvironmentObject var ed: Editor
    let item: StillItem

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PanelHeader(kind: "BILD", color: Palette.still, title: item.name)
            if let img = ed.stillPreview(item.path) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 120, maxHeight: 80)
                    .cornerRadius(4)
            }
            Field("Storlek") {
                Slider(value: Binding(get: { item.scale }, set: { v in ed.updateStill(item.id) { $0.scale = v } }),
                       in: 0.05...3, onEditingChanged: { ed.liveEditing($0) })
                HStack {
                    Button("Hela bilden") {
                        ed.updateStill(item.id) { $0.scale = 1; $0.x = 0.5; $0.y = 0.5 }
                    }
                    Button("Fyll rutan") {
                        let f = ed.project.aspect
                        ed.updateStill(item.id) {
                            $0.scale = Overlay.coverScale(aspect: $0.aspect, frameAspect: f); $0.x = 0.5; $0.y = 0.5
                        }
                    }
                    Button("Mitten") { ed.updateStill(item.id) { $0.x = 0.5; $0.y = 0.5 } }
                }
            }
            Field("Visas i") {
                DurationSlider(duration: item.duration) { ed.resizeItem(\.stills, item.id, edge: .right, to: item.start + $0) }
            }
            DeleteButton(title: "Ta bort bilden")
        }
        .controlSize(.large)
    }
}

struct TextSettings: View {
    @EnvironmentObject var ed: Editor
    let item: TextItem

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PanelHeader(kind: "TEXT", color: Palette.text)
            TextEditor(text: Binding(get: { item.text },
                                     set: { v in ed.updateText(item.id, typing: true) { $0.text = v } }))
                .font(.title3)
                .frame(height: 70)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.5)))
            HStack {
                Picker("", selection: Binding(get: { item.font },
                                              set: { v in ed.updateText(item.id) { $0.font = v } })) {
                    ForEach(TextStyle.fonts, id: \.self) { f in
                        Text(f).tag(f)
                    }
                }
                .pickerStyle(MenuPickerStyle())
                .labelsHidden()
                Toggle("Fet", isOn: Binding(get: { item.bold },
                                            set: { v in ed.updateText(item.id) { $0.bold = v } }))
            }
            Field("Storlek") {
                Slider(value: Binding(get: { item.size }, set: { v in ed.updateText(item.id) { $0.size = v } }),
                       in: 0.02...0.3, onEditingChanged: { ed.liveEditing($0) })
            }
            Field("Färg") {
                ColorRow(selected: item.color) { c in ed.updateText(item.id) { $0.color = c } }
            }
            Field("Placering") {
                HStack {
                    Button("Uppe") { ed.updateText(item.id) { $0.x = 0.5; $0.y = 0.14 } }
                    Button("Mitten") { ed.updateText(item.id) { $0.x = 0.5; $0.y = 0.5 } }
                    Button("Nere") { ed.updateText(item.id) { $0.x = 0.5; $0.y = 0.84 } }
                }
            }
            Field("Visas i") {
                DurationSlider(duration: item.duration) { ed.resizeItem(\.texts, item.id, edge: .right, to: item.start + $0) }
            }
            DeleteButton(title: "Ta bort texten")
        }
        .controlSize(.large)
    }
}

struct ColorRow: View {
    let selected: Int
    let set: (Int) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<TextStyle.colors.count, id: \.self) { i in
                let c = TextStyle.colors[i]
                Circle()
                    .fill(Color(red: c.r, green: c.g, blue: c.b))
                    .frame(width: 22, height: 22)
                    .overlay(Circle().stroke(i == selected ? Color.yellow : Color.gray.opacity(0.6),
                                             lineWidth: i == selected ? 3 : 1))
                    .onTapGesture { set(i) }
                    .help(c.name)
            }
        }
    }
}

struct SoundSettings: View {
    @EnvironmentObject var ed: Editor
    let item: SoundItem

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PanelHeader(kind: "LJUDEFFEKT", color: Palette.sound, title: item.name, detail: formatTime(item.duration))
            Field("Ljudnivå") {
                VolumeSlider(value: item.volume) { v in ed.updateAudio(\.sounds, item.id) { $0.volume = max(0, min(1, v)) } }
            }
            DeleteButton(title: "Ta bort ljudeffekten")
        }
        .controlSize(.large)
    }
}

struct MusicSettings: View {
    @EnvironmentObject var ed: Editor
    let item: SoundItem

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PanelHeader(kind: "MUSIK", color: Palette.music, title: item.name,
                        detail: "\(formatTime(item.duration)) av \(formatTime(item.sourceDuration))")
            Field("Ljudnivå") {
                VolumeSlider(value: item.volume) { v in ed.updateAudio(\.music, item.id) { $0.volume = max(0, min(1, v)) } }
            }
            HStack {
                Button { ed.replaceMusic(item.id) } label: { Label("Byt låt", systemImage: "arrow.triangle.2.circlepath") }
                DeleteButton(title: "Ta bort")
            }
        }
        .controlSize(.large)
    }
}

struct MovieSettings: View {
    @EnvironmentObject var ed: Editor

    var body: some View {
        let p = ed.project
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("HELA FILMEN").font(.caption.bold()).foregroundColor(.secondary)
                Text(formatTime(p.duration)).font(.title2.bold())
            }
            Field("Format") {
                HStack(spacing: 6) {
                    Chip(title: "Liggande", icon: "rectangle", on: !p.isPortrait, minWidth: 90) { ed.setPortrait(false) }
                    Chip(title: "Stående", icon: "rectangle.portrait", on: p.isPortrait, minWidth: 90) { ed.setPortrait(true) }
                }
            }
            if p.hasGaps {
                Button { ed.closeGaps() } label: { Label("Ta bort svarta pauser", systemImage: "rectangle.compress.vertical") }
            }
            Spacer(minLength: 8)
            VStack(alignment: .leading, spacing: 6) {
                key("Mellanslag", "spela / pausa")
                key("K", "klipp vid strecket")
                key("← →", "en bild i taget")
                key("⌫", "ta bort det valda")
                key("⌘Z", "ångra")
            }
            .font(.callout)
            .foregroundColor(.secondary)
        }
        .controlSize(.large)
    }

    private func key(_ k: String, _ text: String) -> some View {
        HStack(spacing: 8) {
            Text(k).font(.callout.bold()).frame(width: 90, alignment: .leading)
            Text(text)
        }
    }
}

/// Knappar för hastigheten: 50 % (slowmotion) till 400 % (fyra gånger så fort).
struct SpeedButtons: View {
    let rate: Double
    let set: (Double) -> Void
    static let steps: [Double] = [0.5, 0.75, 1, 1.5, 2, 3, 4]

    static func label(_ r: Double) -> String { "\(Int((r * 100).rounded())) %" }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ForEach(SpeedButtons.steps.prefix(3), id: \.self) { r in button(r) }
            }
            HStack(spacing: 6) {
                ForEach(SpeedButtons.steps.suffix(4), id: \.self) { r in button(r) }
            }
        }
    }

    private func button(_ r: Double) -> some View {
        Chip(title: SpeedButtons.label(r), on: abs(rate - r) < 0.001, minWidth: 40) { set(r) }
    }
}

/// Röstknappar: Monster, Mörk, Vanlig, Pipig, Ekorre.
struct VoiceButtons: View {
    let cents: Int
    let set: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ForEach(Voice.presets.prefix(3), id: \.cents) { p in button(p.name, p.cents) }
            }
            HStack(spacing: 6) {
                ForEach(Voice.presets.suffix(2), id: \.cents) { p in button(p.name, p.cents) }
            }
        }
    }

    private func button(_ name: String, _ c: Int) -> some View {
        Chip(title: name, on: c == cents, minWidth: 64) { set(c) }
    }
}
