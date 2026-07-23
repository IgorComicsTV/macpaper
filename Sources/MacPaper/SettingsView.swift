import AppKit
import MacPaperCore
import SwiftUI

@MainActor
private final class WallpaperLibraryModel: ObservableObject {
    @Published private(set) var videos: [URL] = []
    private var monitors: [DirectoryMonitor] = []

    func load(folders: [String]) {
        videos = folders.flatMap { MediaCatalog.videos(in: URL(fileURLWithPath: $0, isDirectory: true)) }
            .reduce(into: [String: URL]()) { $0[$1.standardizedFileURL.path] = $1 }
            .values
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        monitors = folders.map { path in
            DirectoryMonitor(url: URL(fileURLWithPath: path)) { [weak self] in self?.load(folders: folders) }
        }
    }
}

struct SettingsView: View {
    @ObservedObject var manager: WallpaperManager
    @ObservedObject var store: SettingsStore
    @StateObject private var library = WallpaperLibraryModel()
    @State private var search = ""
    @State private var selectedDisplays: Set<String> = []
    @State private var layout: WallpaperLayoutMode = .mirrored
    @State private var contentMode: VideoContentMode = .fill

    private var filteredVideos: [URL] {
        guard !search.isEmpty else { return library.videos }
        return library.videos.filter { $0.deletingPathExtension().lastPathComponent.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            targetBar
            Divider()
            if library.videos.isEmpty { emptyLibrary }
            else if filteredVideos.isEmpty {
                ContentUnavailableView.search(text: search)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 310), spacing: 14)], spacing: 14) {
                        ForEach(filteredVideos, id: \.self) { url in
                            WallpaperCard(
                                url: url,
                                isActive: store.configuration.groups.contains { $0.currentFile == url.path },
                                action: { apply(url) }
                            )
                        }
                    }
                    .padding(18)
                }
            }
            Divider()
            groupControls
        }
        .frame(minWidth: 880, minHeight: 620)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            if selectedDisplays.isEmpty { selectedDisplays = Set(manager.displays.map(\.id)) }
            library.load(folders: store.configuration.libraryFolders)
        }
        .onChange(of: store.configuration.libraryFolders) { _, folders in library.load(folders: folders) }
        .onChange(of: manager.displays.map(\.id)) { _, ids in
            selectedDisplays.formIntersection(ids)
            if selectedDisplays.isEmpty { selectedDisplays = Set(ids) }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 14) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.title2)
                .foregroundStyle(.tint)
            Text("MacPaper").font(.title2.bold())
            TextField("Buscar wallpapers", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 330)
            Spacer()
            Label(
                manager.powerMonitor.isOnBattery ? "Modo econômico" : "Na tomada",
                systemImage: manager.powerMonitor.isOnBattery ? "battery.50percent" : "bolt.fill"
            ).foregroundStyle(.secondary)
            Button("Adicionar pasta…", systemImage: "plus", action: chooseFolder)
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 18)
        .frame(height: 58)
    }

    private var targetBar: some View {
        HStack(spacing: 16) {
            Text("Aplicar em").font(.headline)
            ForEach(manager.displays) { display in
                Toggle(isOn: Binding(
                    get: { selectedDisplays.contains(display.id) },
                    set: { selected in
                        if selected { selectedDisplays.insert(display.id) }
                        else if selectedDisplays.count > 1 { selectedDisplays.remove(display.id) }
                    }
                )) {
                    Label(display.name, systemImage: "display")
                }
                .toggleStyle(.button)
            }
            Divider().frame(height: 24)
            Picker("Layout", selection: $layout) {
                ForEach(WallpaperLayoutMode.allCases, id: \.self) { Text($0.title).tag($0) }
            }.labelsHidden().frame(width: 140)
            Picker("Enquadramento", selection: $contentMode) {
                ForEach(VideoContentMode.allCases, id: \.self) { Text($0.title).tag($0) }
            }.labelsHidden().frame(width: 130)
        }
        .padding(.horizontal, 18)
        .frame(height: 54)
    }

    private var emptyLibrary: some View {
        ContentUnavailableView {
            Label("Sua biblioteca está vazia", systemImage: "film.stack")
        } description: {
            Text("Adicione uma pasta com vídeos MP4, MOV ou M4V.")
        } actions: {
            Button("Adicionar pasta…", action: chooseFolder)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var groupControls: some View {
        HStack(spacing: 14) {
            Picker("Ordem", selection: Binding(
                get: { selectedGroup?.order ?? .random },
                set: { value in updateSelectedGroups { $0.order = value } }
            )) {
                ForEach(PlaylistOrder.allCases, id: \.self) { Text($0.title).tag($0) }
            }.frame(width: 170)
            Picker("Troca", selection: Binding(
                get: { selectedGroup?.interval ?? 3_600 },
                set: { value in updateSelectedGroups { $0.interval = value } }
            )) {
                ForEach(TimerPreset.values, id: \.self) { Text(TimerPreset.label(for: $0)).tag($0) }
            }.frame(width: 160)
            Picker("Apps em primeiro plano", selection: Binding(
                get: { store.configuration.foregroundBehavior },
                set: { store.setForegroundBehavior($0) }
            )) {
                ForEach(ForegroundBehavior.allCases, id: \.self) { Text($0.title).tag($0) }
            }.frame(width: 320)
            Spacer()
            if !manager.foregroundPausedDisplays.isEmpty {
                let names = manager.displays.filter { manager.foregroundPausedDisplays.contains($0.id) }.map(\.name)
                Label("Pausado: \(names.joined(separator: ", "))", systemImage: "pause.circle.fill")
                    .foregroundStyle(.orange)
            }
            Button(store.configuration.globallyPaused ? "Retomar tudo" : "Pausar tudo") {
                manager.toggleGlobalPause()
            }
            Button("Próximo") { manager.nextAll() }
        }
        .padding(.horizontal, 18)
        .frame(height: 58)
    }

    private func apply(_ url: URL) {
        let targets = selectedDisplays.isEmpty ? manager.displays.map(\.id) : Array(selectedDisplays)
        manager.applyWallpaper(url, to: targets, layout: layout, contentMode: contentMode)
    }

    private var selectedGroup: WallpaperGroupConfiguration? {
        store.configuration.groups.first { !Set($0.displayIDs).isDisjoint(with: selectedDisplays) }
    }

    private func updateSelectedGroups(_ mutate: (inout WallpaperGroupConfiguration) -> Void) {
        let ids = store.configuration.groups.filter {
            !Set($0.displayIDs).isDisjoint(with: selectedDisplays)
        }.map(\.id)
        ids.forEach { store.updateGroup($0, mutate) }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Adicionar pasta à biblioteca"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.addLibraryFolder(url)
        library.load(folders: store.configuration.libraryFolders)
    }
}

private struct WallpaperCard: View {
    let url: URL
    let isActive: Bool
    let action: () -> Void
    @State private var thumbnail: CGImage?

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomLeading) {
                Group {
                    if let thumbnail { Image(decorative: thumbnail, scale: 1).resizable().scaledToFill() }
                    else {
                        Rectangle().fill(.quaternary)
                            .overlay { ProgressView().controlSize(.small) }
                    }
                }
                .frame(height: 142)
                .clipped()

                LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .center, endPoint: .bottom)
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(url.deletingPathExtension().lastPathComponent)
                            .font(.headline).foregroundStyle(.white).lineLimit(1)
                        Text(url.pathExtension.uppercased())
                            .font(.caption2).foregroundStyle(.white.opacity(0.7))
                    }
                    Spacer()
                    if isActive { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                }.padding(10)
            }
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(isActive ? Color.accentColor : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .task(id: url) { thumbnail = await ThumbnailGenerator.shared.image(for: url) }
        .help("Aplicar \(url.lastPathComponent)")
    }
}

@MainActor
final class SettingsWindowController: NSWindowController {
    init(manager: WallpaperManager, store: SettingsStore) {
        let root = SettingsView(manager: manager, store: store)
        let window = NSWindow(contentViewController: NSHostingController(rootView: root))
        window.title = "MacPaper — Biblioteca"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 1_020, height: 700))
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    required init?(coder: NSCoder) { nil }
    func present() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
