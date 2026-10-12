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
            Text(title).font(.headline)
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

    var body: some View {
        HStack {
            Circle().fill(color).frame(width: 10, height: 10)
            Text(kind).font(.caption.bold()).foregroundColor(.secondary)
            Spacer()
            Button("Klar") { ed.selection = nil }
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
                } else if ed.selection == .music, ed.project.musicPath != nil {
                    MusicSettings()
                } else {
                    MovieSettings()
                }
            }
            .padding(16)
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
        VStack(alignment: .leading, spacing: 16) {
            PanelHeader(kind: "FILMKLIPP", color: Palette.filmColor(0))
            Text(clip.name).font(.title3.bold()).lineLimit(2)
            Text("Längd \(formatTime(clip.length))").foregroundColor(.secondary)

            Field("Börjar") {
                Slider(value: Binding(get: { clip.start }, set: { ed.setClipStart(clip.id, $0) }),
                       in: 0...max(0.3, clip.sourceDuration),
                       onEditingChanged: { ed.liveEditing($0) })
            }
            Field("Slutar") {
                Slider(value: Binding(get: { clip.end }, set: { ed.setClipEnd(clip.id, $0) }),
                       in: 0...max(0.3, clip.sourceDuration),
                       onEditingChanged: { ed.liveEditing($0) })
            }
            Text("Du kan också dra i klippets kanter i tidslinjen.")
                .font(.caption).foregroundColor(.secondary)
            Field("Ljud i klippet") {
                VolumeSlider(value: clip.volume) { ed.setClipVolume(clip.id, $0) }
            }
            Field("Flytta") {
                HStack {
                    Button { ed.moveSelectedClip(-1) } label: { Label("Tidigare", systemImage: "arrow.left") }
                    Button { ed.moveSelectedClip(1) } label: { Label("Senare", systemImage: "arrow.right") }
                }
            }
            DeleteButton(title: "Ta bort klippet")
        }
        .controlSize(.large)
    }
}

struct StillSettings: View {
    @EnvironmentObject var ed: Editor
    let item: StillItem

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PanelHeader(kind: "BILD", color: Palette.still)
            HStack(spacing: 10) {
                if let img = ed.stillPreview(item.path) {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 80, maxHeight: 60)
                        .cornerRadius(4)
                }
                Text(item.name).font(.title3.bold()).lineLimit(2)
            }
            Text("Dra bilden i rutan för att flytta den. Dra i det gula hörnet för att ändra storlek.")
                .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)

            Field("Storlek") {
                Slider(value: Binding(get: { item.scale }, set: { v in ed.updateStill(item.id) { $0.scale = v } }),
                       in: 0.05...3, onEditingChanged: { ed.liveEditing($0) })
                HStack {
                    Button("Hela bilden") {
                        ed.updateStill(item.id) { $0.scale = 1; $0.x = 0.5; $0.y = 0.5 }
                    }
                    .help("Hela bilden syns, i mitten")
                    Button("Fyll rutan") {
                        ed.updateStill(item.id) {
                            $0.scale = Overlay.coverScale(aspect: $0.aspect); $0.x = 0.5; $0.y = 0.5
                        }
                    }
                    .help("Bilden täcker hela rutan (kanterna kan skäras bort)")
                }
                Button("Lägg i mitten") { ed.updateStill(item.id) { $0.x = 0.5; $0.y = 0.5 } }
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
        VStack(alignment: .leading, spacing: 16) {
            PanelHeader(kind: "TEXT", color: Palette.text)
            Field("Text") {
                TextEditor(text: Binding(get: { item.text },
                                         set: { v in ed.updateText(item.id, typing: true) { $0.text = v } }))
                    .font(.title3)
                    .frame(height: 70)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.5)))
            }
            Field("Typsnitt") {
                Picker("", selection: Binding(get: { item.font },
                                              set: { v in ed.updateText(item.id) { $0.font = v } })) {
                    ForEach(TextStyle.fonts, id: \.self) { f in
                        Text(f).tag(f)
                    }
                }
                .pickerStyle(MenuPickerStyle())
                .labelsHidden()
                Toggle("Fet stil", isOn: Binding(get: { item.bold },
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
                Text("Dra texten i rutan dit du vill ha den.")
                    .font(.caption).foregroundColor(.secondary)
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
        VStack(alignment: .leading, spacing: 16) {
            PanelHeader(kind: "LJUDEFFEKT", color: Palette.sound)
            Text(item.name).font(.title3.bold()).lineLimit(2)
            Text("Längd \(formatTime(item.duration))").foregroundColor(.secondary)
            Text("Dra effekten i tidslinjen dit den ska höras. Dra i kanterna för att korta den.")
                .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            Field("Ljudnivå") {
                VolumeSlider(value: item.volume) { v in ed.updateSound(item.id) { $0.volume = max(0, min(1, v)) } }
            }
            DeleteButton(title: "Ta bort ljudeffekten")
        }
        .controlSize(.large)
    }
}

struct MusicSettings: View {
    @EnvironmentObject var ed: Editor

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PanelHeader(kind: "MUSIK", color: Palette.music)
            if let m = ed.project.musicPath {
                Text(URL(fileURLWithPath: m).deletingPathExtension().lastPathComponent)
                    .font(.title3.bold()).lineLimit(2)
            }
            Text("Musiken ligger under hela filmen, börjar om om den är för kort och tonas ut på slutet.")
                .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            Field("Ljudnivå") {
                VolumeSlider(value: ed.project.musicVolume) { ed.setMusicVolume($0) }
            }
            HStack {
                Button { ed.chooseMusic() } label: { Label("Byt låt", systemImage: "music.note") }
                Button { ed.removeMusic() } label: { Label("Ta bort", systemImage: "trash") }
            }
        }
        .controlSize(.large)
    }
}

struct MovieSettings: View {
    @EnvironmentObject var ed: Editor

    var body: some View {
        let p = ed.project
        VStack(alignment: .leading, spacing: 16) {
            Text("HELA FILMEN").font(.caption.bold()).foregroundColor(.secondary)
            Text(formatTime(p.duration)).font(.title2.bold())
            VStack(alignment: .leading, spacing: 4) {
                Text("\(p.clips.count) filmklipp · \(p.stills.count) bilder · \(p.texts.count) texter")
                Text("\(p.sounds.count) ljudeffekter · \(p.musicPath == nil ? "ingen musik" : "musik")")
            }
            .foregroundColor(.secondary)

            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("Så här gör du").font(.headline)
                tip("square.stack.3d.up", "Text ligger överst, sedan bild, sedan film")
                tip("hand.tap", "Klicka på något för att ändra det")
                tip("hand.draw", "Dra i tidslinjen för att flytta, dra i kanterna för att korta")
                tip("arrow.up.left.and.arrow.down.right", "Dra bilder och texter direkt i rutan")
                tip("scissors", "K klipper där det gula strecket står")
                tip("playpause", "Mellanslag spelar och pausar")
                tip("arrow.left.and.right", "← → går en bild i taget")
                tip("delete.left", "Backsteg tar bort det du valt")
                tip("arrow.uturn.backward", "⌘Z ångrar, allt sparas av sig självt")
            }
            .foregroundColor(.secondary)
        }
        .controlSize(.large)
    }

    private func tip(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).frame(width: 20)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}
