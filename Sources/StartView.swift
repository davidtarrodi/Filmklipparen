import SwiftUI
import AppKit

/// Det första man ser: alla filmer man gjort, och knappen för att göra en ny.
struct StartView: View {
    @EnvironmentObject var ed: Editor
    @State private var naming: NameRequest?
    @State private var toDelete: FilmInfo?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "film").font(.system(size: 30)).foregroundColor(.yellow)
                Text("Filmklipparen").font(.system(size: 30, weight: .bold))
                Spacer()
                Button { naming = NameRequest(kind: .new) } label: {
                    Label("Ny film", systemImage: "plus")
                        .font(.title3.weight(.semibold))
                }
                .buttonStyle(GreenButtonStyle())
                .keyboardShortcut("n", modifiers: .command)
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 16)

            if ed.library.isEmpty {
                emptyState
            } else {
                Text("Mina filmer").font(.title2.bold()).padding(.horizontal, 28)
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 230, maximum: 300), spacing: 20)],
                              alignment: .leading, spacing: 22) {
                        ForEach(ed.library) { info in
                            FilmCard(info: info,
                                     rename: { naming = NameRequest(kind: .rename(info)) },
                                     delete: { toDelete = info })
                        }
                    }
                    .padding(28)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(NSColor.windowBackgroundColor))
        .sheet(item: $naming) { req in
            NameSheet(request: req) { name in
                switch req.kind {
                case .new: ed.createFilm(named: name)
                case .rename(let info): ed.renameFilm(info, to: name)
                }
                naming = nil
            } cancel: {
                naming = nil
            }
        }
        .alert(item: $toDelete) { info in
            Alert(title: Text("Ta bort \(info.name)?"),
                  message: Text("Filmen läggs i papperskorgen. Dina filmklipp, bilder och ljud finns kvar."),
                  primaryButton: .destructive(Text("Ta bort")) { ed.deleteFilm(info) },
                  secondaryButton: .cancel(Text("Avbryt")))
        }
        .onAppear { ed.refreshLibrary() }
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "video.badge.plus").font(.system(size: 64)).foregroundColor(.yellow)
            Text("Gör din första film!").font(.largeTitle.bold())
            Text("Tryck på »Ny film« och ge den ett namn. Allt sparas av sig självt.")
                .font(.title3).foregroundColor(.secondary)
            Button { naming = NameRequest(kind: .new) } label: {
                Label("Ny film", systemImage: "plus").font(.title2.weight(.semibold))
            }
            .buttonStyle(GreenButtonStyle())
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

/// Vad namnrutan ska användas till.
struct NameRequest: Identifiable {
    enum Kind {
        case new
        case rename(FilmInfo)
    }
    let id = UUID()
    let kind: Kind

    var title: String {
        switch kind {
        case .new: return "Vad ska filmen heta?"
        case .rename: return "Nytt namn på filmen"
        }
    }

    var initial: String {
        switch kind {
        case .new: return ""
        case .rename(let info): return info.name
        }
    }

    var button: String {
        switch kind {
        case .new: return "Skapa filmen"
        case .rename: return "Byt namn"
        }
    }
}

struct NameSheet: View {
    let request: NameRequest
    let done: (String) -> Void
    let cancel: () -> Void
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(request.title).font(.title2.bold())
            TextField("T.ex. Sommarlovet", text: $name, onCommit: commit)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .font(.title3)
                .frame(width: 360)
            HStack {
                Spacer()
                Button("Avbryt", action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button(request.button, action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty)
            }
            .controlSize(.large)
        }
        .padding(26)
        .onAppear { name = request.initial }
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func commit() {
        if !trimmed.isEmpty { done(trimmed) }
    }
}

struct FilmCard: View {
    @EnvironmentObject var ed: Editor
    let info: FilmInfo
    let rename: () -> Void
    let delete: () -> Void
    @State private var hover = false

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "sv_SE")
        f.unitsStyle = .full
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                Color.black
                if let img = ed.libraryThumbs[info.url] {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: "film").font(.system(size: 34)).foregroundColor(.gray)
                }
            }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .cornerRadius(8)
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(hover ? Color.yellow : Color.white.opacity(0.15), lineWidth: hover ? 3 : 1))
            .contentShape(Rectangle())
            .onTapGesture { ed.open(info.url) }

            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(info.name).font(.headline).lineLimit(2)
                    Text("\(formatShort(info.duration)) · ändrad \(FilmCard.relative.localizedString(for: info.modified, relativeTo: Date()))")
                        .font(.caption).foregroundColor(.secondary)
                }
                Spacer(minLength: 4)
                Menu {
                    Button("Öppna") { ed.open(info.url) }
                    Button("Byt namn …", action: rename)
                    Button("Gör en kopia") { ed.duplicateFilm(info) }
                    Divider()
                    Button("Ta bort …", action: delete)
                } label: {
                    Image(systemName: "ellipsis.circle").font(.title3)
                }
                .menuStyle(BorderlessButtonMenuStyle())
                .frame(width: 30)
            }
        }
        .onHover { hover = $0 }
        .contextMenu {
            Button("Öppna") { ed.open(info.url) }
            Button("Byt namn …", action: rename)
            Button("Gör en kopia") { ed.duplicateFilm(info) }
            Divider()
            Button("Ta bort …", action: delete)
        }
        .help("Klicka för att öppna \(info.name)")
    }
}
