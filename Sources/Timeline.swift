import SwiftUI
import AppKit

/// Måtten i tidslinjen.
enum TL {
    static let ruler: CGFloat = 22
    static let text: CGFloat = 30
    static let still: CGFloat = 40
    static let film: CGFloat = 60
    static let filmAudio: CGFloat = 16
    static let music: CGFloat = 26
    static let sound: CGFloat = 30
    static let gap: CGFloat = 4
    static let labelWidth: CGFloat = 92
    static var lanesHeight: CGFloat { ruler + text + still + film + filmAudio + music + sound + 6 * gap }
    static var panelHeight: CGFloat { lanesHeight + 66 }
}

enum Palette {
    static let film: [Color] = [
        Color(red: 0.25, green: 0.45, blue: 0.95),
        Color(red: 0.62, green: 0.35, blue: 0.90),
        Color(red: 0.92, green: 0.35, blue: 0.55),
        Color(red: 0.95, green: 0.55, blue: 0.20),
        Color(red: 0.20, green: 0.70, blue: 0.70),
        Color(red: 0.45, green: 0.70, blue: 0.25),
    ]
    static func filmColor(_ i: Int) -> Color { film[i % film.count] }
    static let text = Color(red: 0.95, green: 0.75, blue: 0.15)
    static let still = Color(red: 0.15, green: 0.65, blue: 0.85)
    static let filmAudio = Color(red: 0.35, green: 0.55, blue: 0.95)
    static let music = Color(red: 0.25, green: 0.70, blue: 0.40)
    static let sound = Color(red: 0.90, green: 0.45, blue: 0.25)
}

private struct ScrollXKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

// MARK: - Panelen

struct TimelinePanel: View {
    @EnvironmentObject var ed: Editor
    @State private var scrollX: CGFloat = 0

    var body: some View {
        GeometryReader { g in
            let contentWidth = max(g.size.width - TL.labelWidth - 12,
                                   CGFloat(ed.project.duration * ed.pixelsPerSecond) + 240)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Text("Tidslinje").font(.headline)
                    Spacer()
                    Button("Visa hela filmen") { ed.fitTimeline(width: Double(g.size.width - TL.labelWidth)) }
                        .disabled(ed.project.isEmpty)
                    Image(systemName: "minus.magnifyingglass").foregroundColor(.secondary)
                    Slider(value: $ed.pixelsPerSecond, in: 2...200).frame(width: 160)
                    Image(systemName: "plus.magnifyingglass").foregroundColor(.secondary)
                }
                .padding(.horizontal, 14)

                HStack(alignment: .top, spacing: 0) {
                    LaneLabels().frame(width: TL.labelWidth)
                    ScrollView(.horizontal, showsIndicators: true) {
                        ZStack(alignment: .topLeading) {
                            VStack(alignment: .leading, spacing: TL.gap) {
                                Ruler(width: contentWidth)
                                TextLane(width: contentWidth)
                                StillLane(width: contentWidth)
                                FilmLane(width: contentWidth, scrollX: scrollX)
                                FilmAudioLane(width: contentWidth)
                                MusicLane(width: contentWidth)
                                SoundLane(width: contentWidth)
                            }
                            Playhead()
                        }
                        .coordinateSpace(name: "tlcontent")
                        .padding(.trailing, 12)
                        .padding(.bottom, 8)
                        .background(GeometryReader { c in
                            Color.clear.preference(key: ScrollXKey.self, value: c.frame(in: .named("tlscroll")).minX)
                        })
                    }
                    .coordinateSpace(name: "tlscroll")
                    .onPreferenceChange(ScrollXKey.self) { scrollX = max(0, -$0) }
                }
            }
            .padding(.top, 8)
        }
    }
}

/// Namnen på spåren till vänster.
struct LaneLabels: View {
    var body: some View {
        VStack(alignment: .leading, spacing: TL.gap) {
            Color.clear.frame(height: TL.ruler)
            label("Text", "textformat", Palette.text, TL.text)
            label("Bild", "photo", Palette.still, TL.still)
            label("Film", "film", Palette.filmColor(0), TL.film)
            label("Filmljud", "waveform", Palette.filmAudio, TL.filmAudio, small: true)
            label("Musik", "music.note", Palette.music, TL.music)
            label("Effekter", "speaker.wave.2", Palette.sound, TL.sound)
        }
        .padding(.leading, 12)
    }

    private func label(_ name: String, _ icon: String, _ color: Color, _ h: CGFloat, small: Bool = false) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundColor(color).frame(width: 16)
            Text(name).font(small ? .caption : .callout).foregroundColor(.secondary)
        }
        .frame(height: h, alignment: .leading)
    }
}

struct Playhead: View {
    @EnvironmentObject var ed: Editor
    @EnvironmentObject var clock: PlayClock

    var body: some View {
        VStack(spacing: 0) {
            Triangle().fill(Color.yellow).frame(width: 12, height: 10)
            Rectangle().fill(Color.yellow).frame(width: 2, height: TL.lanesHeight - 10)
        }
        .frame(width: 12)
        .offset(x: CGFloat(clock.time * ed.pixelsPerSecond) - 6)
        .allowsHitTesting(false)
    }
}

struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

/// Sekunderna överst. Klicka eller dra här för att flytta det gula strecket.
struct Ruler: View {
    @EnvironmentObject var ed: Editor
    let width: CGFloat

    var body: some View {
        let pps = ed.pixelsPerSecond
        let steps: [Double] = [1, 2, 5, 10, 15, 30, 60, 120, 300]
        let step = steps.first { $0 * pps >= 60 } ?? 600
        let count = Int(Double(width) / (step * pps)) + 1
        ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(0..<count, id: \.self) { n in
                let t = Double(n) * step
                ZStack(alignment: .bottomLeading) {
                    Rectangle().fill(Color.secondary).frame(width: 1, height: 7)
                    Text(formatShort(t))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .fixedSize()
                        .offset(x: 3, y: -9)
                }
                .frame(width: 40, height: TL.ruler, alignment: .bottomLeading)
                .offset(x: CGFloat(t * pps))
            }
        }
        .frame(width: width, height: TL.ruler)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in ed.scrub(to: Double(v.location.x) / ed.pixelsPerSecond) }
                .onEnded { v in ed.endScrub(at: Double(v.location.x) / ed.pixelsPerSecond) }
        )
    }
}

/// Bakgrunden i ett spår.
struct LaneBackground: View {
    @EnvironmentObject var ed: Editor
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(Color.white.opacity(0.045))
            .frame(width: width, height: height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        if ed.selection != nil { ed.selection = nil }
                        ed.scrub(to: Double(v.location.x) / ed.pixelsPerSecond)
                    }
                    .onEnded { v in ed.endScrub(at: Double(v.location.x) / ed.pixelsPerSecond) }
            )
    }
}

// MARK: - Kanter att dra i

/// En smal kant till vänster eller höger på ett klipp. Dra för att göra klippet kortare eller längre.
struct EdgeHandle: View {
    @EnvironmentObject var ed: Editor
    let edge: Edge
    let height: CGFloat
    let origin: () -> Double
    let change: (Double) -> Void
    @State private var start: Double?

    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(Color.white.opacity(start == nil ? 0.55 : 0.95))
            .frame(width: 4, height: max(8, height * 0.5))
            .frame(width: 10, height: height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("tlcontent"))
                    .onChanged { v in
                        if start == nil {
                            start = origin()
                            ed.defocus()
                            ed.liveEditing(true)
                        }
                        guard let s = start else { return }
                        change(s + Double(v.translation.width) / ed.pixelsPerSecond)
                    }
                    .onEnded { _ in
                        start = nil
                        ed.liveEditing(false)
                    }
            )
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .help(edge == .left ? "Dra för att ändra början" : "Dra för att ändra slutet")
    }
}

// MARK: - Fria spår (text, bild, ljudeffekter)

/// Ett klipp i ett fritt spår: dra för att flytta i tiden, dra i kanterna för att ändra längden.
struct TimedBlock<Label: View>: View {
    @EnvironmentObject var ed: Editor
    let sel: Selection
    let start: Double
    let duration: Double
    let height: CGFloat
    let color: Color
    let move: (Double) -> Void
    let resize: (Edge, Double) -> Void
    let label: Label

    @State private var moveStart: Double?
    @State private var moved = false

    init(sel: Selection, start: Double, duration: Double, height: CGFloat, color: Color,
         move: @escaping (Double) -> Void, resize: @escaping (Edge, Double) -> Void,
         @ViewBuilder label: () -> Label) {
        self.sel = sel
        self.start = start
        self.duration = duration
        self.height = height
        self.color = color
        self.move = move
        self.resize = resize
        self.label = label()
    }

    var body: some View {
        let w = max(8, CGFloat(duration * ed.pixelsPerSecond))
        let selected = ed.selection == sel
        ZStack(alignment: .leading) {
            color.opacity(0.85)
            label
                .padding(.leading, 9)
                .padding(.trailing, 9)
                .frame(width: w, height: height, alignment: .leading)
                .clipped()
        }
        .frame(width: w, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(selected ? Color.yellow : Color.black.opacity(0.6), lineWidth: selected ? 2.5 : 1)
        )
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named("tlcontent"))
                .onChanged { v in
                    if moveStart == nil {
                        moveStart = start
                        moved = false
                        ed.defocus()
                        ed.liveEditing(true)
                    }
                    if abs(v.translation.width) > 4 { moved = true }
                    guard moved, let s = moveStart else { return }
                    if ed.selection != sel { ed.selection = sel }
                    move(s + Double(v.translation.width) / ed.pixelsPerSecond)
                }
                .onEnded { v in
                    if !moved {
                        // Ett klick: välj och flytta strecket dit man klickade.
                        ed.click(sel, atTimelineX: Double(v.startLocation.x))
                    }
                    moveStart = nil
                    ed.liveEditing(false)
                }
        )
        .overlay(
            HStack(spacing: 0) {
                EdgeHandle(edge: .left, height: height, origin: { start }, change: { resize(.left, $0) })
                Spacer(minLength: 0)
                EdgeHandle(edge: .right, height: height, origin: { start + duration },
                           change: { resize(.right, $0) })
            }
            .opacity(w >= 26 ? 1 : 0)
            .allowsHitTesting(w >= 26)
        )
        .offset(x: CGFloat(start * ed.pixelsPerSecond))
    }
}

struct TextLane: View {
    @EnvironmentObject var ed: Editor
    let width: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            LaneBackground(width: width, height: TL.text)
            ForEach(ed.project.texts) { t in
                TimedBlock(sel: .text(t.id), start: t.start, duration: t.duration, height: TL.text,
                           color: Palette.text,
                           move: { ed.moveItem(\.texts, t.id, to: $0) },
                           resize: { ed.resizeItem(\.texts, t.id, edge: $0, to: $1) }) {
                    HStack(spacing: 4) {
                        Image(systemName: "textformat")
                        Text(t.text.replacingOccurrences(of: "\n", with: " ")).lineLimit(1)
                    }
                    .font(.caption.bold())
                    .foregroundColor(.black)
                }
            }
        }
        .frame(width: width, height: TL.text, alignment: .topLeading)
    }
}

struct StillLane: View {
    @EnvironmentObject var ed: Editor
    let width: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            LaneBackground(width: width, height: TL.still)
            ForEach(ed.project.stills) { s in
                TimedBlock(sel: .still(s.id), start: s.start, duration: s.duration, height: TL.still,
                           color: Palette.still,
                           move: { ed.moveItem(\.stills, s.id, to: $0) },
                           resize: { ed.resizeItem(\.stills, s.id, edge: $0, to: $1) }) {
                    HStack(spacing: 5) {
                        if let img = ed.stillPreview(s.path) {
                            Image(nsImage: img)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxWidth: 52, maxHeight: TL.still - 8)
                                .cornerRadius(2)
                        }
                        Text(s.name).font(.caption.bold()).foregroundColor(.white).lineLimit(1)
                    }
                }
            }
        }
        .frame(width: width, height: TL.still, alignment: .topLeading)
    }
}

struct SoundLane: View {
    @EnvironmentObject var ed: Editor
    let width: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            LaneBackground(width: width, height: TL.sound)
            ForEach(ed.project.sounds) { s in
                TimedBlock(sel: .sound(s.id), start: s.start, duration: s.duration, height: TL.sound,
                           color: Palette.sound,
                           move: { ed.moveItem(\.sounds, s.id, to: $0) },
                           resize: { ed.resizeSound(s.id, edge: $0, to: $1) }) {
                    HStack(spacing: 4) {
                        Image(systemName: s.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        Text(s.name).lineLimit(1)
                    }
                    .font(.caption.bold())
                    .foregroundColor(.white)
                }
            }
        }
        .frame(width: width, height: TL.sound, alignment: .topLeading)
    }
}

// MARK: - Filmspåret

struct FilmLane: View {
    @EnvironmentObject var ed: Editor
    let width: CGFloat
    let scrollX: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            LaneBackground(width: width, height: TL.film)
            if ed.project.clips.isEmpty {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary, style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                    .overlay(Text("Här hamnar filmklippen").foregroundColor(.secondary))
                    .frame(width: 320, height: TL.film)
                    .allowsHitTesting(false)
            }
            HStack(spacing: 0) {
                ForEach(Array(ed.project.clips.enumerated()), id: \.element.id) { i, clip in
                    ClipBlock(clip: clip, index: i, x0: CGFloat(ed.project.startTime(of: i) * ed.pixelsPerSecond),
                              scrollX: scrollX)
                }
            }
            .coordinateSpace(name: "clips")
        }
        .frame(width: width, height: TL.film, alignment: .topLeading)
    }
}

struct ClipBlock: View {
    @EnvironmentObject var ed: Editor
    let clip: Clip
    let index: Int
    let x0: CGFloat
    let scrollX: CGFloat
    @State private var dragX: CGFloat = 0

    var body: some View {
        let w = max(6, CGFloat(clip.length * ed.pixelsPerSecond))
        let selected = ed.selection == .clip(clip.id)
        ZStack(alignment: .topLeading) {
            Palette.filmColor(index).opacity(0.9)
            stickyLabel(w: w)
        }
        .frame(width: w, height: TL.film)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(selected ? Color.yellow : Color.black.opacity(0.7), lineWidth: selected ? 3 : 1.5)
        )
        .shadow(color: Color.black.opacity(dragX == 0 ? 0 : 0.6), radius: 8)
        .offset(x: dragX, y: dragX == 0 ? 0 : -4)
        .zIndex(dragX == 0 ? 0 : 1)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named("clips"))
                .onChanged { v in
                    if abs(v.translation.width) > 5 || dragX != 0 { dragX = v.translation.width }
                }
                .onEnded { v in
                    if dragX == 0 && abs(v.translation.width) <= 5 {
                        ed.click(.clip(clip.id), atTimelineX: Double(v.startLocation.x))
                    } else {
                        ed.moveClip(clip.id, toTimelineX: Double(v.location.x))
                    }
                    dragX = 0
                }
        )
        .overlay(
            HStack(spacing: 0) {
                EdgeHandle(edge: .left, height: TL.film, origin: { clip.start },
                           change: { ed.setClipStart(clip.id, $0) })
                Spacer(minLength: 0)
                EdgeHandle(edge: .right, height: TL.film, origin: { clip.end },
                           change: { ed.setClipEnd(clip.id, $0) })
            }
            .opacity(w >= 30 && dragX == 0 ? 1 : 0)
            .allowsHitTesting(w >= 30 && dragX == 0)
        )
    }

    /// Liten bild och namn längst till vänster. Följer med när man scrollar, så den syns
    /// även om klippets början är utanför tidslinjen.
    private func stickyLabel(w: CGFloat) -> some View {
        let thumbH = TL.film - 12
        let img = ed.thumbnail(for: clip)
        let aspect = img.map { $0.size.height > 0 ? $0.size.width / $0.size.height : 16.0 / 9 } ?? 16.0 / 9
        let thumbW = min(84, thumbH * aspect)
        let labelW = min(w - 12, thumbW + 130)
        let shift = min(max(0, scrollX - x0), max(0, w - labelW - 12))
        return HStack(spacing: 6) {
            ZStack {
                Color.black.opacity(0.35)
                if let img = img {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                }
            }
            .frame(width: thumbW, height: thumbH)
            .cornerRadius(3)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.black.opacity(0.5), lineWidth: 1))
            VStack(alignment: .leading, spacing: 2) {
                Text(clip.name).lineLimit(1)
                Text(formatTime(clip.length)).foregroundColor(.white.opacity(0.75))
            }
            .font(.caption.bold())
            .foregroundColor(.white)
        }
        .padding(6)
        .frame(width: max(0, w), height: TL.film, alignment: .leading)
        .offset(x: shift + 4)
        .clipped()
    }
}

/// Ljudet i filmklippen, under filmspåret.
struct FilmAudioLane: View {
    @EnvironmentObject var ed: Editor
    let width: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            LaneBackground(width: width, height: TL.filmAudio)
            HStack(spacing: 0) {
                ForEach(ed.project.clips) { clip in
                    let w = max(6, CGFloat(clip.length * ed.pixelsPerSecond))
                    let selected = ed.selection == .clip(clip.id)
                    ZStack(alignment: .leading) {
                        Palette.filmAudio.opacity(0.25)
                        Palette.filmAudio.opacity(0.8)
                            .frame(width: w * CGFloat(clip.volume))
                        if clip.volume == 0, w > 20 {
                            Image(systemName: "speaker.slash.fill").font(.caption2).padding(.leading, 4)
                        }
                    }
                    .frame(width: w, height: TL.filmAudio)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .overlay(RoundedRectangle(cornerRadius: 3)
                        .stroke(selected ? Color.yellow : Color.black.opacity(0.6), lineWidth: selected ? 2 : 1))
                    .contentShape(Rectangle())
                    .onTapGesture { ed.selection = .clip(clip.id) }
                    .help("Ljudet i filmklippet. Ändra ljudnivån till höger.")
                }
            }
        }
        .frame(width: width, height: TL.filmAudio, alignment: .topLeading)
    }
}

struct MusicLane: View {
    @EnvironmentObject var ed: Editor
    let width: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            LaneBackground(width: width, height: TL.music)
            if let m = ed.project.musicPath, ed.project.duration > 0 {
                let selected = ed.selection == .music
                HStack(spacing: 6) {
                    Image(systemName: "music.note")
                    Text(URL(fileURLWithPath: m).deletingPathExtension().lastPathComponent).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .font(.caption.bold())
                .foregroundColor(.white)
                .padding(.horizontal, 8)
                .frame(width: max(20, CGFloat(ed.project.duration * ed.pixelsPerSecond)), height: TL.music,
                       alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 5).fill(Palette.music.opacity(0.75)))
                .overlay(RoundedRectangle(cornerRadius: 5)
                    .stroke(selected ? Color.yellow : Color.clear, lineWidth: 2.5))
                .contentShape(Rectangle())
                .onTapGesture { ed.selection = .music }
            }
        }
        .frame(width: width, height: TL.music, alignment: .topLeading)
    }
}
