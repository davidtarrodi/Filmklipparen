import SwiftUI
import AVKit
import AppKit
import UniformTypeIdentifiers

// MARK: - Hela fönstret

struct ContentView: View {
    @EnvironmentObject var ed: Editor

    var body: some View {
        Group {
            if ed.currentFile == nil {
                StartView()
                    .overlay(ToastView(bottomPadding: 30), alignment: .bottom)
                    .preferredColorScheme(.dark)
                    .navigationTitle("Filmklipparen")
            } else {
                editor
            }
        }
    }

    private var editor: some View {
        VStack(spacing: 0) {
            TopBar()
            Divider()
            HStack(spacing: 0) {
                PreviewArea()
                Divider()
                SidePanel().frame(width: 300)
            }
            Divider()
            TimelinePanel().frame(height: TL.panelHeight)
        }
        .background(Color(NSColor.windowBackgroundColor))
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            ed.handleDrop(providers)
            return true
        }
        .overlay(ToastView(), alignment: .bottom)
        .overlay(exportOverlay)
        .preferredColorScheme(.dark)
        .onAppear {
            // macOS sätter annars markören i namnrutan direkt, och då spelar inte mellanslag.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { ed.defocus() }
        }
        .navigationTitle(ed.project.name.isEmpty ? "Filmklipparen" : ed.project.name)
    }

    @ViewBuilder var exportOverlay: some View {
        if let p = ed.exportProgress {
            ZStack {
                Color.black.opacity(0.6)
                VStack(spacing: 16) {
                    Text("Filmen sparas …").font(.title2.bold())
                    ProgressView(value: min(1, max(0, p))).frame(width: 340)
                    Text("\(Int(p * 100)) %").font(.title3)
                    Button("Avbryt") { ed.cancelExport() }.controlSize(.large)
                }
                .padding(32)
                .background(RoundedRectangle(cornerRadius: 16).fill(Color(NSColor.windowBackgroundColor)))
            }
        }
    }
}

// MARK: - Knapparna högst upp

struct TopBar: View {
    @EnvironmentObject var ed: Editor

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "film").font(.title2).foregroundColor(.yellow)
            TextField("Filmens namn",
                      text: Binding(get: { ed.project.name }, set: { ed.rename($0) }))
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .font(.title3)
                .frame(width: 170)
            Spacer(minLength: 8)
            Button { ed.chooseFilms() } label: { Label("Film", systemImage: "film") }
                .help("Lägg till filmklipp")
            Button { ed.chooseImages() } label: { Label("Bild", systemImage: "photo") }
                .help("Lägg till bilder i bildspåret, ovanpå filmen")
            Button { ed.addText() } label: { Label("Text", systemImage: "textformat") }
                .help("Lägg till en text i textspåret, överst")
            Button { ed.toggleBrowser(.music) } label: { Label("Musik", systemImage: "music.note") }
                .help("En låt under hela filmen")
            Button { ed.toggleBrowser(.sounds) } label: { Label("Ljudeffekt", systemImage: "speaker.wave.2") }
                .help("Lägg till ljudeffekter där det gula strecket står")
            Divider().frame(height: 22)
            Button { ed.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!ed.canUndo)
                .keyboardShortcut("z", modifiers: .command)
                .help("Ångra (⌘Z)")
            Button { ed.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(!ed.canRedo)
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .help("Gör om (⇧⌘Z)")
            Button { ed.closeFilm() } label: { Label("Mina filmer", systemImage: "square.grid.2x2") }
                .help("Tillbaka till alla filmer (den här sparas)")
            Divider().frame(height: 22)
            Button { ed.exportMovie() } label: {
                Label("Spara filmen", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(GreenButtonStyle())
            .disabled(ed.project.isEmpty)
        }
        .controlSize(.large)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

// MARK: - Bilden

struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.player = player
        v.controlsStyle = .none
        v.videoGravity = .resizeAspect
        return v
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {}
}

struct PreviewArea: View {
    @EnvironmentObject var ed: Editor

    var body: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 0)
            ZStack {
                Color.black
                if ed.project.isEmpty {
                    VStack(spacing: 14) {
                        Image(systemName: "video.badge.plus").font(.system(size: 54)).foregroundColor(.yellow)
                        Text("Dra hit filmklipp, bilder och ljud").font(.title.bold())
                        Text("… eller använd knapparna uppe till höger")
                            .font(.title3).foregroundColor(.secondary)
                    }
                } else {
                    PlayerView(player: ed.player)
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { ed.togglePlay() }
                    OverlayLayer()
                }
            }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .clipped()
            .cornerRadius(8)
            Transport()
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct Transport: View {
    @EnvironmentObject var ed: Editor
    @EnvironmentObject var clock: PlayClock

    var body: some View {
        HStack(spacing: 14) {
            Button { ed.seek(0) } label: {
                Image(systemName: "backward.end.fill").frame(width: 26, height: 22)
            }
            .help("Till början")
            Button { ed.togglePlay() } label: {
                Image(systemName: ed.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 20))
                    .frame(width: 44, height: 24)
            }
            .help("Spela / pausa (mellanslag)")
            Text("\(formatTime(clock.time)) / \(formatTime(ed.project.duration))")
                .font(.system(.title3, design: .monospaced))
            Spacer()
            Button { ed.splitAtPlayhead() } label: {
                Label("Klipp här  (K)", systemImage: "scissors")
            }
            .help("Delar det valda (eller filmklippet) där det gula strecket står")
        }
        .controlSize(.large)
        .disabled(ed.project.isEmpty)
    }
}

struct ToastView: View {
    @EnvironmentObject var ed: Editor
    var bottomPadding: CGFloat = TL.panelHeight + 20

    var body: some View {
        Group {
            if let t = ed.toast {
                Text(t)
                    .font(.title3)
                    .foregroundColor(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Color.black.opacity(0.85)))
                    .padding(.bottom, bottomPadding)
            }
        }
        .allowsHitTesting(false)
    }
}

/// Grön knapp för »Spara filmen« (macOS 11 saknar färgade standardknappar).
struct GreenButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(red: 0.16, green: 0.62, blue: 0.27)
                        .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.35))
            )
    }
}

// MARK: - Bilder och texter ovanpå filmen, går att flytta och skala

struct OverlayLayer: View {
    @EnvironmentObject var ed: Editor
    @EnvironmentObject var clock: PlayClock

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .topLeading) {
                ForEach(ed.project.stills.filter { $0.visible(at: clock.time) }) { s in
                    StillOverlay(item: s, frame: g.size)
                }
                ForEach(ed.project.texts.filter { $0.visible(at: clock.time) }) { t in
                    TextOverlay(item: t, frame: g.size)
                }
            }
            .frame(width: g.size.width, height: g.size.height, alignment: .topLeading)
            .coordinateSpace(name: "overlay")
        }
    }
}

struct StillOverlay: View {
    @EnvironmentObject var ed: Editor
    let item: StillItem
    let frame: CGSize

    var body: some View {
        let r = Overlay.stillRect(item, frame: frame)
        MovableBox(sel: .still(item.id), rect: r, frame: frame, x: item.x, y: item.y, sizeValue: item.scale,
                   setSize: { v in ed.updateStill(item.id) { $0.scale = min(4, max(0.05, v)) } }) {
            if let img = ed.stillPreview(item.path) {
                Image(nsImage: img).resizable()
            } else {
                Color.gray.opacity(0.4)
            }
        }
    }
}

struct TextOverlay: View {
    @EnvironmentObject var ed: Editor
    let item: TextItem
    let frame: CGSize

    var body: some View {
        if let img = ed.textPreview(item) {
            let k = frame.height / Editor.textPreviewHeight
            let w = img.size.width * k, h = img.size.height * k
            let r = CGRect(x: CGFloat(item.x) * frame.width - w / 2, y: CGFloat(item.y) * frame.height - h / 2,
                           width: w, height: h)
            MovableBox(sel: .text(item.id), rect: r, frame: frame, x: item.x, y: item.y, sizeValue: item.size,
                       setSize: { v in ed.updateText(item.id) { $0.size = min(0.3, max(0.02, v)) } }) {
                Image(nsImage: img).resizable()
            }
        }
    }
}

/// Något i rutan som går att välja, dra och ändra storlek på (i det gula hörnet).
struct MovableBox<Content: View>: View {
    @EnvironmentObject var ed: Editor
    let sel: Selection
    let rect: CGRect
    let frame: CGSize
    let x: Double
    let y: Double
    let sizeValue: Double
    let setSize: (Double) -> Void
    let content: Content

    @State private var dragStart: CGPoint?
    @State private var scaleStart: (value: Double, distance: CGFloat)?

    init(sel: Selection, rect: CGRect, frame: CGSize, x: Double, y: Double, sizeValue: Double,
         setSize: @escaping (Double) -> Void, @ViewBuilder content: () -> Content) {
        self.sel = sel
        self.rect = rect
        self.frame = frame
        self.x = x
        self.y = y
        self.sizeValue = sizeValue
        self.setSize = setSize
        self.content = content()
    }

    var body: some View {
        let selected = ed.selection == sel
        content
            .frame(width: max(1, rect.width), height: max(1, rect.height))
            .overlay(
                Rectangle()
                    .stroke(Color.yellow, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .opacity(selected ? 1 : 0)
            )
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("overlay"))
                    .onChanged { v in
                        if dragStart == nil {
                            dragStart = CGPoint(x: x, y: y)
                            ed.defocus()
                            ed.selection = sel
                            ed.liveEditing(true)
                        }
                        guard let s = dragStart, frame.width > 0, frame.height > 0 else { return }
                        if abs(v.translation.width) + abs(v.translation.height) < 2 { return }
                        ed.moveOverlay(sel, x: Double(s.x) + Double(v.translation.width / frame.width),
                                       y: Double(s.y) + Double(v.translation.height / frame.height))
                    }
                    .onEnded { _ in
                        dragStart = nil
                        ed.liveEditing(false)
                    }
            )
            .overlay(handle.opacity(selected ? 1 : 0).allowsHitTesting(selected), alignment: .bottomTrailing)
            .position(x: rect.midX, y: rect.midY)
    }

    /// Det gula hörnet: dra utåt för större, inåt för mindre.
    private var handle: some View {
        Circle()
            .fill(Color.yellow)
            .overlay(Circle().stroke(Color.black, lineWidth: 1.5))
            .frame(width: 16, height: 16)
            .offset(x: 8, y: 8)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("overlay"))
                    .onChanged { v in
                        let c = CGPoint(x: rect.midX, y: rect.midY)
                        if scaleStart == nil {
                            let d = hypot(v.startLocation.x - c.x, v.startLocation.y - c.y)
                            scaleStart = (sizeValue, max(4, d))
                            ed.liveEditing(true)
                        }
                        guard let s = scaleStart else { return }
                        let d = hypot(v.location.x - c.x, v.location.y - c.y)
                        setSize(s.value * Double(max(2, d) / s.distance))
                    }
                    .onEnded { _ in
                        scaleStart = nil
                        ed.liveEditing(false)
                    }
            )
            .onHover { inside in
                if inside { NSCursor.crosshair.push() } else { NSCursor.pop() }
            }
    }
}
