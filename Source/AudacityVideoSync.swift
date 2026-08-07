// Audacity Video Sync — native video synchronisation companion for Audacity.
// Copyright © 2026 Audacity Video Sync contributors.
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Carbon
import Combine
import Darwin
import SwiftUI
import UniformTypeIdentifiers

private let supportedVideoExtensions: Set<String> = ["mp4", "mov", "m4v", "avi", "mkv", "webm"]

@main
struct AudacityVideoSyncApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 780, minHeight: 620)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 940, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(after: .newItem) {
                Button("Open Video…") { model.chooseVideo() }
                    .keyboardShortcut("o")
            }
        }
        Settings {
            SettingsView()
        }
        .windowResizability(.contentSize)
    }
}

private enum SettingsKey {
    static let filePickerStartLocation = "filePickerStartLocation"
    static let customVideoFolderPath = "customVideoFolderPath"
    static let lastUsedVideoFolderPath = "lastUsedVideoFolderPath"
}

private enum FilePickerStartLocation: String {
    case desktop
    case documents
    case lastUsed
    case custom

    var label: String {
        switch self {
        case .desktop: return "Desktop"
        case .documents: return "Documents"
        case .lastUsed: return "Last Used Folder"
        case .custom: return "Custom Folder"
        }
    }
}

private enum AppSettings {
    static var filePickerStartLocation: FilePickerStartLocation {
        let rawValue = UserDefaults.standard.string(forKey: SettingsKey.filePickerStartLocation)
            ?? FilePickerStartLocation.desktop.rawValue
        return FilePickerStartLocation(rawValue: rawValue) ?? .desktop
    }

    static var filePickerDirectoryURL: URL {
        switch filePickerStartLocation {
        case .desktop:
            return standardFolder(.desktopDirectory, fallbackName: "Desktop")
        case .documents:
            return standardFolder(.documentDirectory, fallbackName: "Documents")
        case .lastUsed:
            return storedFolder(forKey: SettingsKey.lastUsedVideoFolderPath)
                ?? standardFolder(.desktopDirectory, fallbackName: "Desktop")
        case .custom:
            return storedFolder(forKey: SettingsKey.customVideoFolderPath)
                ?? standardFolder(.desktopDirectory, fallbackName: "Desktop")
        }
    }

    static func rememberLastUsedFolder(from url: URL) {
        UserDefaults.standard.set(url.deletingLastPathComponent().path, forKey: SettingsKey.lastUsedVideoFolderPath)
    }

    private static func storedFolder(forKey key: String) -> URL? {
        guard let path = UserDefaults.standard.string(forKey: key), !path.isEmpty else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private static func standardFolder(_ directory: FileManager.SearchPathDirectory, fallbackName: String) -> URL {
        FileManager.default.urls(for: directory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(fallbackName, isDirectory: true)
    }
}

private struct SettingsView: View {
    @AppStorage(SettingsKey.filePickerStartLocation)
    private var startLocation = FilePickerStartLocation.desktop.rawValue
    @AppStorage(SettingsKey.customVideoFolderPath)
    private var customFolderPath = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text("Open Video Starts In")
                Menu {
                    Button("Desktop") { startLocation = FilePickerStartLocation.desktop.rawValue }
                    Button("Documents") { startLocation = FilePickerStartLocation.documents.rawValue }
                    Button("Last Used Folder") { startLocation = FilePickerStartLocation.lastUsed.rawValue }
                    Divider()
                    Button(customFolderPath.isEmpty ? "Choose Custom Folder…" : "Choose Another Folder…") {
                        chooseCustomFolder()
                    }
                } label: {
                    HStack {
                        Text(selectedLocationLabel)
                        Spacer()
                    }
                    .frame(width: 230, alignment: .leading)
                }
            }

            Spacer().frame(height: 38)

            Text("This setting is remembered for future launches.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(28)
        .frame(width: 560, height: 150, alignment: .topLeading)
        .onAppear {
            if startLocation == FilePickerStartLocation.custom.rawValue,
               customFolderPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                startLocation = FilePickerStartLocation.desktop.rawValue
            }
        }
    }

    private var selectedLocationLabel: String {
        guard let location = FilePickerStartLocation(rawValue: startLocation) else { return "Desktop" }
        if location == .custom {
            guard !customFolderPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "Desktop" }
            let folderName = URL(fileURLWithPath: customFolderPath, isDirectory: true).lastPathComponent
            return folderName.isEmpty || folderName == "/" ? "Desktop" : folderName
        }
        return location.label
    }

    private func chooseCustomFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Folder"
        if !customFolderPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: customFolderPath, isDirectory: true)
        } else {
            panel.directoryURL = AppSettings.filePickerDirectoryURL
        }
        if panel.runModal() == .OK, let url = panel.url {
            customFolderPath = url.path
            startLocation = FilePickerStartLocation.custom.rawValue
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A manually owned AppKit window avoids macOS restoring a previously
        // closed SwiftUI WindowGroup as an intentionally windowless process.
        if NSApp.windows.isEmpty {
            let rootView = ContentView()
                .environmentObject(AppModel.shared)
                .frame(minWidth: 780, minHeight: 620)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 940, height: 760),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Audacity Video Sync"
            window.center()
            window.contentView = NSHostingView(rootView: rootView)
            window.isReleasedWhenClosed = false
            window.makeKeyAndOrderFront(nil)
            mainWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.shutdown()
    }
}

private struct NativePlayerView: NSViewRepresentable {
    @EnvironmentObject var model: AppModel

    func makeNSView(context: Context) -> MPVPlayerView {
        let view = MPVPlayerView(frame: .zero)
        model.attachPlayer(view)
        view.isHidden = !model.videoLoaded
        return view
    }

    func updateNSView(_ nsView: MPVPlayerView, context: Context) {
        // NSOpenGLView owns an opaque rendering surface that can otherwise sit
        // above SwiftUI overlays. Keep it hidden until there is video to show.
        nsView.isHidden = !model.videoLoaded
    }
}

private struct VideoDropDelegate: DropDelegate {
    @ObservedObject var model: AppModel
    @Binding var isTargeted: Bool

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [UTType.fileURL])
    }

    func dropEntered(info: DropInfo) {
        isTargeted = true
    }

    func dropExited(info: DropInfo) {
        isTargeted = false
    }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        guard let provider = info.itemProviders(for: [UTType.fileURL]).first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
            guard error == nil else { return }
            let url: URL?
            if let directURL = item as? URL {
                url = directURL
            } else if let data = item as? Data {
                url = URL(dataRepresentation: data, relativeTo: nil)
            } else if let nsURL = item as? NSURL {
                url = nsURL as URL
            } else {
                url = nil
            }
            if let url {
                DispatchQueue.main.async { model.loadVideo(url) }
            }
        }
        return true
    }
}

private struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var isDropTarget = false

    var body: some View {
        VStack(spacing: 14) {
            videoArea
            playerControls
            Divider()
            syncControls
            statusBar
        }
        .padding(18)
        .background(Color(nsColor: .windowBackgroundColor))
        .alert("Audacity Video Sync", isPresented: $model.showingError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(model.errorMessage)
        }
    }

    private var videoArea: some View {
        ZStack {
            Color(nsColor: model.videoLoaded ? .black : .controlBackgroundColor)

            NativePlayerView()
                .environmentObject(model)

            if !model.videoLoaded {
                VStack(spacing: 12) {
                    Image(systemName: "film.stack")
                        .font(.system(size: 42, weight: .light))
                        .foregroundStyle(isDropTarget ? Color.accentColor : .secondary)
                    Text("Drop a video file here")
                        .font(.title2.weight(.semibold))
                    Text("(Video files load paused)")
                        .foregroundStyle(.secondary)
                }
                .allowsHitTesting(false)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(
                    isDropTarget ? Color.accentColor : Color.secondary.opacity(model.videoLoaded ? 0.3 : 0.65),
                    style: StrokeStyle(lineWidth: isDropTarget ? 3 : 2, dash: model.videoLoaded ? [] : [8, 6])
                )
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.chooseVideo() }
        .onDrop(of: [UTType.fileURL], delegate: VideoDropDelegate(model: model, isTargeted: $isDropTarget))
        .frame(minHeight: 430)
    }

    private var playerControls: some View {
        VStack(spacing: 9) {
            HStack(spacing: 10) {
                Text(model.formatTime(model.scrubPosition))
                    .monospacedDigit()
                    .frame(width: 62, alignment: .leading)

                Slider(
                    value: $model.scrubPosition,
                    in: 0...max(model.duration, 1),
                    onEditingChanged: model.seekEditingChanged
                )
                .disabled(!model.videoLoaded)

                Text(model.formatTime(model.duration))
                    .monospacedDigit()
                    .frame(width: 62, alignment: .trailing)
            }

            HStack(spacing: 10) {
                Button("Open Video…") { model.chooseVideo() }

                Button { model.seekRelative(-5) } label: {
                    Label("Back 5 seconds", systemImage: "gobackward.5")
                        .labelStyle(.iconOnly)
                }
                .help("Back 5 seconds")
                .disabled(!model.videoLoaded)

                Button { model.togglePlayback() } label: {
                    Label(
                        model.playing ? "Pause" : "Play",
                        systemImage: model.playing ? "pause.fill" : "play.fill"
                    )
                    .frame(minWidth: 64)
                }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(!model.videoLoaded)

                Button { model.seekRelative(5) } label: {
                    Label("Forward 5 seconds", systemImage: "goforward.5")
                        .labelStyle(.iconOnly)
                }
                .help("Forward 5 seconds")
                .disabled(!model.videoLoaded)

                Toggle("Mute video audio", isOn: $model.videoMuted)
                    .toggleStyle(.checkbox)
                    .onChange(of: model.videoMuted) { _, muted in model.setMuted(muted) }

                Spacer()

                Text(model.videoName ?? "No video loaded")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                    .help(model.videoPath ?? "")
            }
        }
    }

    private var syncControls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Button {
                    model.syncToAudacity()
                } label: {
                    Label("Sync Video to Audacity Cursor", systemImage: "link")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.videoLoaded || model.busy)

                Button {
                    model.toggleSyncedPlayback()
                } label: {
                    VStack(spacing: 2) {
                        Text(model.syncedPlaying ? "Stop Audacity + Video" : "Play Audacity + Video")
                        Text("Ctrl + Option + Space")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 2)
                }
                .disabled(!model.audacitySynced || model.busy)
            }

            HStack(spacing: 12) {
                Text("Startup compensation")
                TextField("0", value: $model.startupCompensationMS, format: .number.precision(.fractionLength(0)))
                    .frame(width: 68)
                    .multilineTextAlignment(.trailing)
                Text("ms")
                    .foregroundStyle(.secondary)

                Toggle("Only use shortcut when Audacity is frontmost", isOn: $model.frontmostOnly)
                    .toggleStyle(.checkbox)

                Spacer()

                Button("Disconnect Sync") { model.disconnectSync() }
                    .disabled(!model.audacitySynced)
            }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.audacitySynced ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: 8, height: 8)
            Text(model.statusText)
                .foregroundStyle(.secondary)
            Spacer()
            if model.audacitySynced {
                Text(String(format: "Audacity %.3fs", model.lastAudacityCursor))
                Text("•")
                Text(String(format: "drift %.0f ms", model.lastDriftMS))
            }
        }
        .font(.caption.monospacedDigit())
    }
}

final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var videoLoaded = false
    @Published var videoName: String?
    @Published var videoPath: String?
    @Published var playing = false
    @Published var duration = 0.0
    @Published var scrubPosition = 0.0
    @Published var videoMuted = true
    @Published var audacitySynced = false
    @Published var syncedPlaying = false
    @Published var busy = false
    @Published var statusText = "Drop or open a video whenever you’re ready."
    @Published var lastAudacityCursor = 0.0
    @Published var lastDriftMS = 0.0
    @Published var showingError = false
    @Published var errorMessage = ""

    @Published var startupCompensationMS: Double {
        didSet { UserDefaults.standard.set(startupCompensationMS, forKey: "startupCompensationMS") }
    }
    @Published var frontmostOnly: Bool {
        didSet { UserDefaults.standard.set(frontmostOnly, forKey: "frontmostOnly") }
    }

    private weak var playerView: MPVPlayerView?
    private let controlQueue = DispatchQueue(label: "com.gothicstorm.audacityvideosync.control", qos: .userInteractive)
    private let audacity = AudacityPipe()
    private let hotKey = GlobalHotKey()
    private var pollTimer: Timer?
    private var syncTimer: Timer?
    private var pollInFlight = false
    private var syncCheckInFlight = false
    private var userSeeking = false
    private var shuttingDown = false

    // Accessed only on controlQueue.
    private var internalSyncActive = false
    private var internalSyncPlaying = false
    private var syncStartCursor = 0.0
    private var syncStartClock = 0.0

    private init() {
        startupCompensationMS = UserDefaults.standard.object(forKey: "startupCompensationMS") as? Double ?? 0
        frontmostOnly = UserDefaults.standard.object(forKey: "frontmostOnly") as? Bool ?? true
        hotKey.handler = { [weak self] in self?.handleGlobalHotKey() }
        hotKey.register()
    }

    func attachPlayer(_ player: MPVPlayerView) {
        guard playerView == nil else { return }
        playerView = player
        do {
            try player.startPlayer()
            startTimers()
            if let path = CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("--") }) {
                let candidate = URL(fileURLWithPath: path)
                if FileManager.default.fileExists(atPath: candidate.path) {
                    DispatchQueue.main.async { self.loadVideo(candidate) }
                }
            }
        } catch {
            showError(error.localizedDescription)
        }
    }

    func chooseVideo() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.movie, .video]
        panel.prompt = "Open Video"
        panel.directoryURL = AppSettings.filePickerDirectoryURL
        if panel.runModal() == .OK, let url = panel.url {
            AppSettings.rememberLastUsedFolder(from: url)
            loadVideo(url)
        }
    }

    func loadVideo(_ url: URL) {
        guard supportedVideoExtensions.contains(url.pathExtension.lowercased()) else {
            showError("That file is not a supported video. Choose MP4, MOV, M4V, AVI, MKV or WebM.")
            return
        }
        guard let player = playerView else {
            showError("The video player is not ready yet.")
            return
        }

        disconnectSync(pauseAudacity: true)
        videoLoaded = true
        videoName = url.lastPathComponent
        videoPath = url.path
        playing = false
        duration = 0
        scrubPosition = 0
        busy = true
        statusText = "Loading \(url.lastPathComponent)…"
        let muted = videoMuted

        controlQueue.async { [weak self, weak player] in
            guard let self, let player else { return }
            do {
                try player.loadFile(atPath: url.path)
                var attempts = 0
                while player.duration() <= 0, attempts < 250 {
                    Thread.sleep(forTimeInterval: 0.02)
                    attempts += 1
                }
                guard player.duration() > 0 else {
                    throw NSError(
                        domain: "com.gothicstorm.audacityvideosync",
                        code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "mpv could not finish loading this video."]
                    )
                }
                try player.setPaused(true)
                try player.setMuted(muted)
                DispatchQueue.main.async {
                    self.busy = false
                    self.statusText = "Video loaded and paused. Play it freely or sync it to Audacity."
                    self.runAutomatedPlaybackTestIfRequested()
                }
            } catch {
                DispatchQueue.main.async {
                    self.videoLoaded = false
                    self.busy = false
                    self.showError(error.localizedDescription)
                }
            }
        }
    }

    func togglePlayback() {
        guard videoLoaded, let player = playerView else { return }
        if audacitySynced {
            toggleSyncedPlayback()
            return
        }
        let shouldPlay = !playing
        playing = shouldPlay
        statusText = shouldPlay ? "Playing video independently." : "Video paused."
        controlQueue.async {
            try? player.setPaused(!shouldPlay)
            try? player.setPlaybackRate(1.0)
        }
    }

    func seekRelative(_ seconds: Double) {
        guard videoLoaded else { return }
        disconnectSync(pauseAudacity: true)
        seek(to: max(0, min(duration, scrubPosition + seconds)))
    }

    func seekEditingChanged(_ editing: Bool) {
        userSeeking = editing
        if editing {
            disconnectSync(pauseAudacity: true)
        } else {
            seek(to: scrubPosition)
        }
    }

    private func seek(to seconds: Double) {
        guard let player = playerView else { return }
        controlQueue.async { try? player.setTimePosition(seconds) }
    }

    func setMuted(_ muted: Bool) {
        guard let player = playerView else { return }
        controlQueue.async { try? player.setMuted(muted) }
    }

    func syncToAudacity() {
        guard videoLoaded, let player = playerView else { return }
        busy = true
        statusText = "Connecting to Audacity…"
        let compensation = startupCompensationMS / 1000.0

        controlQueue.async { [weak self, weak player] in
            guard let self, let player else { return }
            do {
                let cursor = try self.audacity.cursorTime()
                try player.setPaused(true)
                try player.setPlaybackRate(1.0)
                try player.setTimePosition(max(0, cursor + compensation))
                self.internalSyncActive = true
                self.internalSyncPlaying = false
                DispatchQueue.main.async {
                    self.busy = false
                    self.playing = false
                    self.audacitySynced = true
                    self.syncedPlaying = false
                    self.lastAudacityCursor = cursor
                    self.lastDriftMS = 0
                    self.statusText = "Synced and ready. Move Audacity’s playhead, then press Ctrl + Option + Space."
                }
            } catch {
                self.internalSyncActive = false
                self.internalSyncPlaying = false
                DispatchQueue.main.async {
                    self.busy = false
                    self.audacitySynced = false
                    self.syncedPlaying = false
                    self.showError(error.localizedDescription)
                }
            }
        }
    }

    func toggleSyncedPlayback() {
        guard videoLoaded, audacitySynced, !busy, let player = playerView else { return }
        let shouldPlay = !syncedPlaying
        busy = true
        let compensation = startupCompensationMS / 1000.0

        controlQueue.async { [weak self, weak player] in
            guard let self, let player else { return }
            do {
                if shouldPlay {
                    let cursor = try self.audacity.cursorTime()
                    try player.setPaused(true)
                    try player.setTimePosition(max(0, cursor + compensation))
                    try player.setPlaybackRate(1.0)
                    try self.audacity.play()
                    self.syncStartCursor = cursor
                    self.syncStartClock = ProcessInfo.processInfo.systemUptime
                    self.internalSyncActive = true
                    self.internalSyncPlaying = true
                    try player.setPaused(false)
                    DispatchQueue.main.async {
                        self.busy = false
                        self.playing = true
                        self.syncedPlaying = true
                        self.lastAudacityCursor = cursor
                        self.statusText = "Audacity and video are playing in sync."
                    }
                } else {
                    let restartCursor = self.syncStartCursor
                    try self.audacity.stop()
                    try player.setPaused(true)
                    try player.setPlaybackRate(1.0)
                    try player.setTimePosition(max(0, restartCursor + compensation))
                    self.internalSyncPlaying = false
                    DispatchQueue.main.async {
                        self.busy = false
                        self.playing = false
                        self.syncedPlaying = false
                        self.lastAudacityCursor = restartCursor
                        self.lastDriftMS = 0
                        self.statusText = "Stopped at the starting point. Move Audacity’s playhead, then press the shortcut to resync and play."
                    }
                }
            } catch {
                self.internalSyncActive = false
                self.internalSyncPlaying = false
                try? player.setPaused(true)
                try? player.setPlaybackRate(1.0)
                DispatchQueue.main.async {
                    self.busy = false
                    self.playing = false
                    self.audacitySynced = false
                    self.syncedPlaying = false
                    self.showError(error.localizedDescription)
                }
            }
        }
    }

    func disconnectSync() {
        disconnectSync(pauseAudacity: true)
    }

    private func disconnectSync(pauseAudacity: Bool) {
        guard audacitySynced || syncedPlaying else { return }
        audacitySynced = false
        syncedPlaying = false
        playing = false
        statusText = videoLoaded ? "Sync disconnected. Video controls are independent." : "Sync disconnected."
        let player = playerView
        controlQueue.async { [weak self] in
            guard let self else { return }
            if pauseAudacity && self.internalSyncPlaying {
                try? self.audacity.stop()
            }
            self.internalSyncActive = false
            self.internalSyncPlaying = false
            try? player?.setPaused(true)
            try? player?.setPlaybackRate(1.0)
        }
    }

    private func handleGlobalHotKey() {
        guard audacitySynced else { return }
        if frontmostOnly {
            let name = NSWorkspace.shared.frontmostApplication?.localizedName?.lowercased() ?? ""
            guard name.contains("audacity") else { return }
        }
        toggleSyncedPlayback()
    }

    private func startTimers() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.pollPlayer()
        }
        syncTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            self?.correctSyncDrift()
        }
    }

    private func pollPlayer() {
        guard videoLoaded, !pollInFlight, let player = playerView else { return }
        pollInFlight = true
        controlQueue.async { [weak self, weak player] in
            guard let self, let player else { return }
            let position = player.timePosition()
            let duration = player.duration()
            let paused = player.isPaused()
            DispatchQueue.main.async {
                self.pollInFlight = false
                self.duration = max(0, duration)
                if !self.userSeeking { self.scrubPosition = max(0, position) }
                self.playing = !paused
            }
        }
    }

    private func correctSyncDrift() {
        guard audacitySynced, !syncCheckInFlight, let player = playerView else { return }
        syncCheckInFlight = true
        let compensation = startupCompensationMS / 1000.0
        controlQueue.async { [weak self, weak player] in
            guard let self, let player else { return }
            defer { DispatchQueue.main.async { self.syncCheckInFlight = false } }
            guard self.internalSyncActive else { return }

            // Do not query Audacity while stopped. Repeated script-pipe traffic can
            // make Audacity's waveform UI sluggish and interfere with positioning
            // its playhead. The play shortcut performs a fresh cursor read instead.
            guard self.internalSyncPlaying else { return }

            let elapsed = ProcessInfo.processInfo.systemUptime - self.syncStartClock
            let expected = self.syncStartCursor + elapsed + compensation
            let actual = player.timePosition()
            let drift = actual - expected

            if abs(drift) > 0.120 {
                try? player.setTimePosition(expected)
                try? player.setPlaybackRate(1.0)
            } else if abs(drift) > 0.025 {
                let correction = max(0.970, min(1.030, 1.0 - drift * 0.25))
                try? player.setPlaybackRate(correction)
            } else {
                try? player.setPlaybackRate(1.0)
            }

            DispatchQueue.main.async {
                self.lastAudacityCursor = self.syncStartCursor + elapsed
                self.lastDriftMS = drift * 1000
            }
        }
    }

    func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        let total = Int(seconds.rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let remaining = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, remaining)
            : String(format: "%02d:%02d", minutes, remaining)
    }

    private func runAutomatedPlaybackTestIfRequested() {
        guard CommandLine.arguments.contains("--automated-playback-test") else { return }
        let resultURL = URL(fileURLWithPath: "/private/tmp/audacity-video-sync-automated-test.txt")
        try? "AUTOMATED_PLAYBACK_TEST=STARTED\n".write(to: resultURL, atomically: true, encoding: .utf8)
        togglePlayback()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self else { return }
            let passed = self.playing && self.scrubPosition > 1.0 && self.duration > 3.0
            let result = passed
                ? "AUTOMATED_PLAYBACK_TEST=PASS position=\(self.scrubPosition) duration=\(self.duration)\n"
                : "AUTOMATED_PLAYBACK_TEST=FAIL position=\(self.scrubPosition) duration=\(self.duration)\n"
            try? result.write(to: resultURL, atomically: true, encoding: .utf8)
            FileHandle.standardOutput.write(Data(result.utf8))
            NSApp.terminate(nil)
        }
    }

    private func showError(_ message: String) {
        errorMessage = message
        showingError = true
        statusText = "Action could not be completed."
    }

    func shutdown() {
        guard !shuttingDown else { return }
        shuttingDown = true
        pollTimer?.invalidate()
        syncTimer?.invalidate()
        hotKey.unregister()

        let player = playerView
        controlQueue.sync {
            if internalSyncPlaying { try? audacity.stop() }
            internalSyncPlaying = false
            internalSyncActive = false
            try? player?.setPaused(true)
            try? player?.setPlaybackRate(1.0)
        }
        player?.shutdownPlayer()
        playerView = nil
    }
}

private struct AudacityPipe {
    enum PipeError: LocalizedError {
        case unavailable
        case communication(String)
        case invalidCursor

        var errorDescription: String? {
            switch self {
            case .unavailable:
                return "Audacity’s scripting connection is not ready. Make sure Audacity is open, mod-script-pipe is enabled, and Audacity has been restarted after enabling it. Then press Sync again. The video player can still be used independently."
            case .communication(let detail):
                return "Could not communicate with Audacity. \(detail)"
            case .invalidCursor:
                return "Audacity responded, but its cursor position could not be read."
            }
        }
    }

    private var paths: (to: String, from: String) {
        let uid = getuid()
        return ("/tmp/audacity_script_pipe.to.\(uid)", "/tmp/audacity_script_pipe.from.\(uid)")
    }

    func cursorTime(connectionWait: TimeInterval = 3.0) throws -> Double {
        let pattern = #"\"start\"\s*:\s*([-+]?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?)"#
        let regex = try NSRegularExpression(pattern: pattern, options: .caseInsensitive)

        // A command acknowledgement can very occasionally remain ahead of the
        // selection result in the shared pipe. Retry a malformed response rather
        // than dropping an otherwise healthy synchronization session.
        for attempt in 0..<3 {
            let response = try send(
                "GetInfo: Type=Selection Format=JSON",
                connectionWait: attempt == 0 ? connectionWait : 0.5
            )
            let range = NSRange(response.startIndex..., in: response)
            if let match = regex.firstMatch(in: response, range: range),
               let valueRange = Range(match.range(at: 1), in: response),
               let value = Double(response[valueRange]) {
                return value
            }
            if attempt < 2 { Darwin.usleep(75_000) }
        }
        throw PipeError.invalidCursor
    }

    func play() throws {
        _ = try send("Play:")
    }

    func stop() throws {
        _ = try send("Stop:")
    }

    private func send(_ rawCommand: String, connectionWait: TimeInterval = 3.0) throws -> String {
        let pipePaths = paths
        let connectionDeadline = ProcessInfo.processInfo.systemUptime + max(0, connectionWait)
        var writeFD: Int32 = -1

        // Audacity creates the FIFO paths just before its scripting thread is
        // ready to accept a writer. Retry that short startup window so the
        // first press of Sync does not report that an enabled module is absent.
        while true {
            if FileManager.default.fileExists(atPath: pipePaths.to),
               FileManager.default.fileExists(atPath: pipePaths.from) {
                writeFD = Darwin.open(pipePaths.to, O_WRONLY | O_NONBLOCK)
                if writeFD >= 0 { break }
            }
            if ProcessInfo.processInfo.systemUptime >= connectionDeadline { break }
            Darwin.usleep(100_000)
        }

        guard writeFD >= 0 else {
            throw PipeError.unavailable
        }
        defer { Darwin.close(writeFD) }

        let readFD = Darwin.open(pipePaths.from, O_RDONLY | O_NONBLOCK)
        guard readFD >= 0 else {
            throw PipeError.communication(String(cString: strerror(errno)))
        }
        defer { Darwin.close(readFD) }

        let command = rawCommand.hasSuffix("\n") ? rawCommand : rawCommand + "\n"
        let bytes = Array(command.utf8)
        let wroteAll = bytes.withUnsafeBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return false }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(writeFD, base.advanced(by: offset), buffer.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                offset += count
            }
            return true
        }
        guard wroteAll else {
            throw PipeError.communication(String(cString: strerror(errno)))
        }

        var result = Data()
        var pollDescriptor = pollfd(fd: readFD, events: Int16(POLLIN), revents: 0)
        let deadline = ProcessInfo.processInfo.systemUptime + 3.0
        var buffer = [UInt8](repeating: 0, count: 4096)

        while ProcessInfo.processInfo.systemUptime < deadline {
            let pollResult = Darwin.poll(&pollDescriptor, 1, 120)
            if pollResult < 0 {
                if errno == EINTR { continue }
                throw PipeError.communication(String(cString: strerror(errno)))
            }
            if pollResult == 0 { continue }

            let count = Darwin.read(readFD, &buffer, buffer.count)
            if count > 0 {
                result.append(buffer, count: count)
                if let text = String(data: result, encoding: .utf8), text.contains("BatchCommand finished") {
                    return text
                }
            } else if count < 0 && errno != EAGAIN && errno != EWOULDBLOCK {
                throw PipeError.communication(String(cString: strerror(errno)))
            }
        }

        if let text = String(data: result, encoding: .utf8), !text.isEmpty {
            return text
        }
        throw PipeError.communication("Audacity did not respond within three seconds.")
    }
}

private let globalHotKeyHandler: EventHandlerUPP = { _, event, userData in
    guard let event, let userData else { return noErr }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr, hotKeyID.signature == 0x41565359, hotKeyID.id == 1 else { return status }
    let owner = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
    DispatchQueue.main.async { owner.handler?() }
    return noErr
}

private final class GlobalHotKey {
    var handler: (() -> Void)?
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    func register() {
        guard hotKeyRef == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            globalHotKeyHandler,
            1,
            &eventType,
            context,
            &eventHandlerRef
        )
        let hotKeyID = EventHotKeyID(signature: 0x41565359, id: 1)
        RegisterEventHotKey(
            UInt32(kVK_Space),
            UInt32(controlKey | optionKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
    }

    deinit {
        unregister()
    }
}
