// Audacity Video Sync — native video synchronisation companion for Audacity.
// Copyright © 2026 Audacity Video Sync contributors.
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Carbon
import Combine
import CoreAudio
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
        .defaultSize(width: 1080, height: 1050)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(after: .newItem) {
                Button("Open Video…") { model.chooseVideo() }
                    .keyboardShortcut("o")

                Button("Pause or Resume Synced Playback") {
                    model.togglePauseShortcut()
                }
                .keyboardShortcut("p", modifiers: [])
                .disabled(!model.audacitySynced || !model.syncedPlaying || model.busy)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--transport-state-test") {
            NSApp.setActivationPolicy(.prohibited)
            runAudacityTransportStateTest()
            return
        }
        // A manually owned AppKit window avoids macOS restoring a previously
        // closed SwiftUI WindowGroup as an intentionally windowless process.
        if NSApp.windows.isEmpty {
            let rootView = ContentView()
                .environmentObject(AppModel.shared)
                .frame(minWidth: 780, minHeight: 620)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1080, height: 1050),
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

private struct VideoScrubber: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let selection: ClosedRange<Double>?
    let enabled: Bool
    let onEditingChanged: (Bool) -> Void

    @State private var dragging = false

    var body: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(nsColor: .separatorColor).opacity(0.55))
                    .frame(height: 5)

                if let selection, selection.upperBound > selection.lowerBound {
                    let lowerX = xPosition(for: selection.lowerBound, width: width)
                    let upperX = xPosition(for: selection.upperBound, width: width)
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.accentColor.opacity(0.25))
                        .frame(width: max(2, upperX - lowerX), height: 11)
                        .offset(x: lowerX)
                }

                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: xPosition(for: value, width: width), height: 5)

                Rectangle()
                    .fill(Color.black.opacity(0.82))
                    .frame(width: 2, height: 17)
                    .offset(x: min(max(0, xPosition(for: value, width: width) - 1), width - 2))
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        guard enabled else { return }
                        if !dragging {
                            dragging = true
                            onEditingChanged(true)
                        }
                        setValue(from: gesture.location.x, width: width)
                    }
                    .onEnded { gesture in
                        guard enabled else { return }
                        setValue(from: gesture.location.x, width: width)
                        dragging = false
                        onEditingChanged(false)
                    }
            )
        }
        .frame(height: 22)
        .opacity(enabled ? 1 : 0.45)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Video position")
        .accessibilityValue(String(format: "%.3f seconds", value))
    }

    private func xPosition(for position: Double, width: Double) -> Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        let fraction = (position - range.lowerBound) / span
        return min(width, max(0, fraction * width))
    }

    private func setValue(from x: Double, width: Double) {
        let fraction = min(1, max(0, x / max(1, width)))
        value = range.lowerBound + fraction * (range.upperBound - range.lowerBound)
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

                VideoScrubber(
                    value: $model.scrubPosition,
                    range: 0...max(model.duration, 1),
                    selection: model.videoSelectionRange,
                    enabled: model.videoLoaded,
                    onEditingChanged: model.seekEditingChanged
                )

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
                .help(model.audacitySynced
                    ? "Play or stop Audacity and the video together (Space)"
                    : "Play or pause the video (Space)")
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
                    Label(
                        model.audacitySynced ? "Synced to Audacity" : "Sync Video to Audacity Cursor",
                        systemImage: model.audacitySynced ? "checkmark.circle.fill" : "link"
                    )
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                }
                .buttonStyle(.borderedProminent)
                .tint(model.audacitySynced ? .green : .accentColor)
                .disabled(!model.videoLoaded || model.busy)

                Button {
                    model.disconnectSync()
                } label: {
                    Label("Disconnect Sync", systemImage: "xmark.circle")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                }
                .disabled(!model.audacitySynced)
            }

            HStack(spacing: 12) {
                Text("Startup compensation")
                TextField("0", value: $model.startupCompensationMS, format: .number.precision(.fractionLength(0)))
                    .frame(width: 68)
                    .multilineTextAlignment(.trailing)
                Text("ms")
                    .foregroundStyle(.secondary)

                Spacer()

                Text("Space plays/stops • P pauses/resumes (in Audacity or AVS)")
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 4) {
                HStack(spacing: 10) {
                    Text("Video offset")

                    Button("−10 ms") { model.nudgeVideoOffset(by: -0.010) }
                        .frame(width: 58)
                        .help("Delay video by 10 milliseconds")

                    Button("−1 ms") { model.nudgeVideoOffset(by: -0.001) }
                        .frame(width: 52)
                        .help("Delay video by 1 millisecond")

                    Slider(
                        value: Binding(
                            get: { model.videoOffsetSeconds },
                            set: { model.setVideoOffset($0) }
                        ),
                        in: -30...30,
                        step: 0.01
                    )
                    .tint(offsetColour)
                    .frame(minWidth: 220)
                    .help("Temporary offset. Positive values advance the video.")

                    Button("+1 ms") { model.nudgeVideoOffset(by: 0.001) }
                        .frame(width: 52)
                        .help("Advance video by 1 millisecond")

                    Button("+10 ms") { model.nudgeVideoOffset(by: 0.010) }
                        .frame(width: 58)
                        .help("Advance video by 10 milliseconds")

                    Text(String(format: "%+.3f s", model.videoOffsetSeconds))
                        .monospacedDigit()
                        .frame(width: 82, alignment: .trailing)

                    Button("Reset") { model.resetVideoOffset() }
                        .disabled(abs(model.videoOffsetSeconds) < 0.0005)
                }
                .disabled(!model.audacitySynced || model.busy)

                Text("Temporary for this video only. Positive values advance the video; Audacity and both files remain unchanged.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            Image(systemName: model.audacitySynced ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(model.audacitySynced ? Color.green : Color.secondary)
            Text(model.statusText)
                .foregroundStyle(.secondary)
            Spacer()
            if model.audacitySynced {
                Text(String(format: "Audacity %.3fs", model.lastAudacityCursor))
                Text("•")
                DriftGauge(driftMS: model.lastDriftMS)
                Text(String(format: "Drift %.0f ms", model.lastDriftMS))
            }
        }
        .font(.caption.monospacedDigit())
    }

    private var offsetColour: Color {
        abs(model.videoOffsetSeconds) < 0.0005 ? .green : .orange
    }
}

private struct DriftGauge: View {
    let driftMS: Double

    private var normalisedDrift: Double {
        max(-1, min(1, driftMS / 120.0))
    }

    private var needleColour: Color {
        let magnitude = abs(driftMS)
        if magnitude <= 25 { return .green }
        if magnitude <= 120 { return .orange }
        return .red
    }

    var body: some View {
        GeometryReader { geometry in
            let centre = geometry.size.width / 2
            let travel = max(0, centre - 3)
            ZStack {
                Capsule()
                    .fill(Color.secondary.opacity(0.18))
                Rectangle()
                    .fill(Color.secondary.opacity(0.55))
                    .frame(width: 1)
                Capsule()
                    .fill(needleColour)
                    .frame(width: 5, height: geometry.size.height)
                    .offset(x: normalisedDrift * travel)
            }
        }
        .frame(width: 82, height: 8)
        .accessibilityLabel("Synchronization drift")
        .accessibilityValue(String(format: "%.0f milliseconds", driftMS))
        .help("Video drift: green within 25 ms, amber within 120 ms, red beyond 120 ms")
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
    @Published var syncedPaused = false
    @Published var busy = false
    @Published var statusText = "Drop or open a video whenever you’re ready."
    @Published var lastAudacityCursor = 0.0
    @Published var lastDriftMS = 0.0
    @Published private(set) var audacitySelectionStart: Double?
    @Published private(set) var audacitySelectionEnd: Double?
    @Published private(set) var videoOffsetSeconds = 0.0
    @Published var showingError = false
    @Published var errorMessage = ""

    @Published var startupCompensationMS: Double {
        didSet { UserDefaults.standard.set(startupCompensationMS, forKey: "startupCompensationMS") }
    }
    private weak var playerView: MPVPlayerView?
    private let controlQueue = DispatchQueue(label: "com.gothicstorm.audacityvideosync.control", qos: .userInteractive)
    private let transportObservationQueue = DispatchQueue(label: "com.gothicstorm.audacityvideosync.transport-observation", qos: .userInteractive)
    private let audacity = AudacityPipe()
    private let keyboardTap = AudacityKeyboardTap()
    private let audacityAudioState = AudacityAudioStateReader()
    private var transportObservationGeneration = 0
    private var pollTimer: Timer?
    private var syncTimer: Timer?
    private var pollInFlight = false
    private var syncCheckInFlight = false
    private var userSeeking = false
    private var shuttingDown = false
    private var pendingOffsetSeek: DispatchWorkItem?
    private var pendingSelectionStop: DispatchWorkItem?
    private var securityScopedVideoURL: URL?
    private var hasSecurityScopedVideoAccess = false

    // Accessed only on controlQueue.
    private var internalSyncActive = false
    private var internalSyncPlaying = false
    private var internalSyncPaused = false
    private var syncStartCursor = 0.0
    private var syncStartClock = 0.0
    private var syncPausedCursor = 0.0
    private var syncReturnCursor = 0.0
    private var syncSelectionEnd: Double?

    private init() {
        startupCompensationMS = UserDefaults.standard.object(forKey: "startupCompensationMS") as? Double ?? 0
        keyboardTap.handler = { [weak self] eventType, keyCode, flags in
            self?.handleAudacityInputEvent(type: eventType, keyCode: keyCode, flags: flags) ?? false
        }
    }

    var videoSelectionRange: ClosedRange<Double>? {
        guard let start = audacitySelectionStart,
              let end = audacitySelectionEnd,
              end > start,
              duration > 0 else { return nil }
        let adjustment = startupCompensationMS / 1000.0 + videoOffsetSeconds
        let lower = max(0, min(duration, start + adjustment))
        let upper = max(0, min(duration, end + adjustment))
        return upper > lower ? lower...upper : nil
    }

    private func publishSelection(_ selection: AudacityPipe.Selection) {
        DispatchQueue.main.async {
            self.audacitySelectionStart = selection.hasRange ? selection.start : nil
            self.audacitySelectionEnd = selection.hasRange ? selection.end : nil
        }
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
        panel.directoryURL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
        if panel.runModal() == .OK, let url = panel.url {
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

        releaseVideoFileAccess()
        securityScopedVideoURL = url
        hasSecurityScopedVideoAccess = url.startAccessingSecurityScopedResource()

        disconnectSync(pauseAudacity: true)
        videoLoaded = true
        videoName = url.lastPathComponent
        videoPath = url.path
        playing = false
        duration = 0
        scrubPosition = 0
        audacitySelectionStart = nil
        audacitySelectionEnd = nil
        pendingOffsetSeek?.cancel()
        videoOffsetSeconds = 0
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
                    if CommandLine.arguments.contains("--automated-sync-transport-test") {
                        self.runAutomatedSyncTransportTest()
                    } else {
                        self.runAutomatedPlaybackTestIfRequested()
                    }
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

    private func releaseVideoFileAccess() {
        if hasSecurityScopedVideoAccess, let securityScopedVideoURL {
            securityScopedVideoURL.stopAccessingSecurityScopedResource()
        }
        securityScopedVideoURL = nil
        hasSecurityScopedVideoAccess = false
    }

    func togglePlayback() {
        guard videoLoaded, let player = playerView else { return }
        if audacitySynced {
            if syncedPaused {
                toggleSyncedPause(controlAudacity: true)
            } else {
                toggleSyncedPlayback()
            }
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

    func togglePauseShortcut() {
        guard audacitySynced, syncedPlaying, !busy else { return }
        toggleSyncedPause(controlAudacity: true)
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

    func setVideoOffset(_ seconds: Double) {
        let offset = max(-30, min(30, (seconds * 1000).rounded() / 1000))
        videoOffsetSeconds = offset
        applyVideoOffsetDuringSync(offset)
    }

    func nudgeVideoOffset(by seconds: Double) {
        setVideoOffset(videoOffsetSeconds + seconds)
    }

    func resetVideoOffset() {
        setVideoOffset(0)
    }

    private func applyVideoOffsetDuringSync(_ offset: Double) {
        pendingOffsetSeek?.cancel()
        guard audacitySynced, let player = playerView else { return }

        let compensation = startupCompensationMS / 1000.0
        let stoppedCursor = lastAudacityCursor
        let work = DispatchWorkItem { [weak self, weak player] in
            guard let self, let player else { return }
            guard self.internalSyncActive else { return }

            let audacityPosition: Double
            if self.internalSyncPaused {
                audacityPosition = self.syncPausedCursor
            } else if self.internalSyncPlaying {
                audacityPosition = self.syncStartCursor
                    + (ProcessInfo.processInfo.systemUptime - self.syncStartClock)
            } else {
                audacityPosition = stoppedCursor
            }
            let target = self.clampedVideoPosition(
                audacityPosition + compensation + offset,
                duration: player.duration()
            )
            try? player.setTimePosition(target)
            try? player.setPlaybackRate(1.0)
        }
        pendingOffsetSeek = work
        controlQueue.asyncAfter(deadline: .now() + 0.015, execute: work)
    }

    private func clampedVideoPosition(_ position: Double, duration: Double) -> Double {
        max(0, min(max(0, duration), position))
    }

    func syncToAudacity() {
        guard videoLoaded, let player = playerView else { return }
        guard ensureAudacityKeyboardMonitoring() else {
            openAccessibilitySettings()
            return
        }
        busy = true
        statusText = "Connecting to Audacity…"
        let compensation = startupCompensationMS / 1000.0
        let offset = videoOffsetSeconds

        controlQueue.async { [weak self, weak player] in
            guard let self, let player else { return }
            do {
                let selection = try self.audacity.selection()
                let cursor = selection.start
                try player.setPaused(true)
                try player.setPlaybackRate(1.0)
                try player.setTimePosition(self.clampedVideoPosition(
                    cursor + compensation + offset,
                    duration: player.duration()
                ))
                self.internalSyncActive = true
                self.internalSyncPlaying = false
                self.publishSelection(selection)
                DispatchQueue.main.async {
                    self.busy = false
                    self.playing = false
                    self.audacitySynced = true
                    self.syncedPlaying = false
                    self.syncedPaused = false
                    self.lastAudacityCursor = cursor
                    self.lastDriftMS = 0
                    self.statusText = "Synced and ready. Use Space and P normally in Audacity."
                }
            } catch {
                self.internalSyncActive = false
                self.internalSyncPlaying = false
                DispatchQueue.main.async {
                    self.busy = false
                    self.audacitySynced = false
                    self.syncedPlaying = false
                    self.syncedPaused = false
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
        let offset = videoOffsetSeconds

        controlQueue.async { [weak self, weak player] in
            guard let self, let player else { return }
            do {
                if shouldPlay {
                    self.pendingSelectionStop?.cancel()
                    let selection = try self.audacity.selection()
                    let cursor = selection.start
                    self.publishSelection(selection)
                    try player.setPaused(true)
                    try player.setTimePosition(self.clampedVideoPosition(
                        cursor + compensation + offset,
                        duration: player.duration()
                    ))
                    try player.setPlaybackRate(1.0)
                    try self.audacity.play()
                    self.syncStartCursor = cursor
                    self.syncStartClock = ProcessInfo.processInfo.systemUptime
                    self.syncReturnCursor = cursor
                    self.syncSelectionEnd = selection.hasRange ? selection.end : nil
                    self.internalSyncActive = true
                    self.internalSyncPlaying = true
                    self.internalSyncPaused = false
                    try player.setPaused(false)
                    self.scheduleSelectionStopIfNeeded(
                        player: player,
                        compensation: compensation,
                        offset: offset
                    )
                    DispatchQueue.main.async {
                        self.busy = false
                        self.playing = true
                        self.syncedPlaying = true
                        self.syncedPaused = false
                        self.lastAudacityCursor = cursor
                        self.statusText = selection.hasRange
                            ? "Playing Audacity’s selection in sync."
                            : "Audacity and video are playing in sync."
                    }
                } else {
                    self.pendingSelectionStop?.cancel()
                    self.pendingSelectionStop = nil
                    let restartCursor = self.syncReturnCursor
                    try self.audacity.stop()
                    try player.setPaused(true)
                    try player.setPlaybackRate(1.0)
                    try player.setTimePosition(self.clampedVideoPosition(
                        restartCursor + compensation + offset,
                        duration: player.duration()
                    ))
                    self.internalSyncPlaying = false
                    self.internalSyncPaused = false
                    self.syncSelectionEnd = nil
                    DispatchQueue.main.async {
                        self.busy = false
                        self.playing = false
                        self.syncedPlaying = false
                        self.syncedPaused = false
                        self.lastAudacityCursor = restartCursor
                        self.lastDriftMS = 0
                        self.statusText = "Stopped at the starting point. Use Space in Audacity to play again."
                    }
                }
            } catch {
                self.internalSyncActive = false
                self.internalSyncPlaying = false
                self.internalSyncPaused = false
                try? player.setPaused(true)
                try? player.setPlaybackRate(1.0)
                DispatchQueue.main.async {
                    self.busy = false
                    self.playing = false
                    self.audacitySynced = false
                    self.syncedPlaying = false
                    self.syncedPaused = false
                    self.showError(error.localizedDescription)
                }
            }
        }
    }

    private func scheduleSelectionStopIfNeeded(
        player: MPVPlayerView,
        compensation: Double,
        offset: Double
    ) {
        pendingSelectionStop?.cancel()
        guard let selectionEnd = syncSelectionEnd, !internalSyncPaused else {
            pendingSelectionStop = nil
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        let currentCursor = syncStartCursor + max(0, now - syncStartClock)
        let remaining = max(0, selectionEnd - currentCursor)
        let restartCursor = syncReturnCursor
        let work = DispatchWorkItem { [weak self, weak player] in
            guard let self, let player, self.internalSyncPlaying else { return }

            try? player.setPaused(true)
            try? player.setPlaybackRate(1.0)
            try? player.setTimePosition(self.clampedVideoPosition(
                restartCursor + compensation + offset,
                duration: player.duration()
            ))
            self.internalSyncPlaying = false
            self.internalSyncPaused = false
            self.syncSelectionEnd = nil
            self.pendingSelectionStop = nil

            // Audacity normally stops itself at the selection boundary. Sending
            // Stop as well makes the outcome deterministic if its playback state
            // changes a fraction later than the video timer.
            try? self.audacity.stop()

            DispatchQueue.main.async {
                self.busy = false
                self.playing = false
                self.syncedPlaying = false
                self.syncedPaused = false
                self.lastAudacityCursor = restartCursor
                self.lastDriftMS = 0
                self.statusText = "Selection finished and returned to its starting point."
            }
        }
        pendingSelectionStop = work
        controlQueue.asyncAfter(deadline: .now() + remaining, execute: work)
    }

    private func startVideoFollowingAudacity(
        eventTimestamp: TimeInterval,
        selection: AudacityPipe.Selection
    ) {
        guard videoLoaded, audacitySynced, !busy, let player = playerView else { return }
        busy = true
        let compensation = startupCompensationMS / 1000.0
        let offset = videoOffsetSeconds

        controlQueue.async { [weak self, weak player] in
            guard let self, let player else { return }
            do {
                self.pendingSelectionStop?.cancel()
                self.pendingSelectionStop = nil
                self.publishSelection(selection)
                let now = ProcessInfo.processInfo.systemUptime
                let elapsed = max(0, now - eventTimestamp)
                let currentCursor = selection.hasRange
                    ? min(selection.end, selection.start + elapsed)
                    : selection.start + elapsed

                try player.setPaused(true)
                try player.setTimePosition(self.clampedVideoPosition(
                    currentCursor + compensation + offset,
                    duration: player.duration()
                ))
                try player.setPlaybackRate(1.0)
                self.syncStartCursor = selection.start
                self.syncStartClock = eventTimestamp
                self.syncReturnCursor = selection.start
                self.syncSelectionEnd = selection.hasRange ? selection.end : nil
                self.internalSyncActive = true
                self.internalSyncPlaying = true
                self.internalSyncPaused = false
                try player.setPaused(false)
                self.scheduleSelectionStopIfNeeded(
                    player: player,
                    compensation: compensation,
                    offset: offset
                )
                DispatchQueue.main.async {
                    self.busy = false
                    self.playing = true
                    self.syncedPlaying = true
                    self.syncedPaused = false
                    self.lastAudacityCursor = selection.start
                    self.statusText = selection.hasRange
                        ? "Following Audacity’s selected playback."
                        : "Following Audacity playback."
                }
            } catch {
                self.internalSyncPlaying = false
                self.internalSyncPaused = false
                try? player.setPaused(true)
                DispatchQueue.main.async {
                    self.busy = false
                    self.showError(error.localizedDescription)
                }
            }
        }
    }

    private func stopVideoFollowingAudacity() {
        guard audacitySynced, !busy, let player = playerView else { return }
        busy = true
        let compensation = startupCompensationMS / 1000.0
        let offset = videoOffsetSeconds
        controlQueue.async { [weak self, weak player] in
            guard let self, let player else { return }
            self.pendingSelectionStop?.cancel()
            self.pendingSelectionStop = nil
            let restartCursor = self.syncReturnCursor
            try? player.setPaused(true)
            try? player.setPlaybackRate(1.0)
            try? player.setTimePosition(self.clampedVideoPosition(
                restartCursor + compensation + offset,
                duration: player.duration()
            ))
            self.internalSyncPlaying = false
            self.internalSyncPaused = false
            self.syncSelectionEnd = nil
            DispatchQueue.main.async {
                self.busy = false
                self.playing = false
                self.syncedPlaying = false
                self.syncedPaused = false
                self.lastAudacityCursor = restartCursor
                self.lastDriftMS = 0
                self.statusText = "Stopped with Audacity and returned to the starting point."
            }
        }
    }

    private func toggleVideoPauseFollowingAudacity() {
        toggleSyncedPause(controlAudacity: false)
    }

    private func toggleSyncedPause(controlAudacity: Bool) {
        guard syncedPlaying, !busy, let player = playerView else { return }
        busy = true
        let compensation = startupCompensationMS / 1000.0
        let offset = videoOffsetSeconds

        controlQueue.async { [weak self, weak player] in
            guard let self, let player else { return }
            if controlAudacity { try? self.audacity.pause() }

            if self.internalSyncPaused {
                let cursor = self.syncPausedCursor
                self.syncStartCursor = cursor
                self.syncStartClock = ProcessInfo.processInfo.systemUptime
                self.internalSyncPaused = false
                try? player.setTimePosition(self.clampedVideoPosition(
                    cursor + compensation + offset,
                    duration: player.duration()
                ))
                try? player.setPlaybackRate(1.0)
                try? player.setPaused(false)
                self.scheduleSelectionStopIfNeeded(
                    player: player,
                    compensation: compensation,
                    offset: offset
                )
                DispatchQueue.main.async {
                    self.busy = false
                    self.playing = true
                    self.syncedPaused = false
                    self.statusText = "Audacity and video resumed in sync."
                }
            } else {
                let elapsed = ProcessInfo.processInfo.systemUptime - self.syncStartClock
                self.syncPausedCursor = self.syncStartCursor + max(0, elapsed)
                if let selectionEnd = self.syncSelectionEnd {
                    self.syncPausedCursor = min(selectionEnd, self.syncPausedCursor)
                }
                self.internalSyncPaused = true
                self.pendingSelectionStop?.cancel()
                self.pendingSelectionStop = nil
                try? player.setPaused(true)
                try? player.setPlaybackRate(1.0)
                DispatchQueue.main.async {
                    self.busy = false
                    self.playing = false
                    self.syncedPaused = true
                    self.lastAudacityCursor = self.syncPausedCursor
                    self.lastDriftMS = 0
                    self.statusText = "Audacity and video are paused. Press P to resume."
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
        syncedPaused = false
        playing = false
        audacitySelectionStart = nil
        audacitySelectionEnd = nil
        statusText = videoLoaded ? "Sync disconnected. Video controls are independent." : "Sync disconnected."
        let player = playerView
        controlQueue.async { [weak self] in
            guard let self else { return }
            self.pendingSelectionStop?.cancel()
            self.pendingSelectionStop = nil
            if pauseAudacity && self.internalSyncPlaying {
                try? self.audacity.stop()
            }
            self.internalSyncActive = false
            self.internalSyncPlaying = false
            self.internalSyncPaused = false
            self.syncSelectionEnd = nil
            try? player?.setPaused(true)
            try? player?.setPlaybackRate(1.0)
        }
    }

    private var isAudacityFrontmost: Bool {
        let name = NSWorkspace.shared.frontmostApplication?.localizedName?.lowercased() ?? ""
        return name.contains("audacity")
    }

    private func ensureAudacityKeyboardMonitoring() -> Bool {
        keyboardTap.start()
    }

    private func openAccessibilitySettings() {
        statusText = "Enable Audacity Video Sync in Accessibility, then return and press Sync again."
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            NSRunningApplication.runningApplications(
                withBundleIdentifier: "com.apple.systempreferences"
            ).first?.activate(options: [.activateAllWindows])
        }
    }

    private func handleAudacityInputEvent(
        type: CGEventType,
        keyCode: Int,
        flags: CGEventFlags
    ) -> Bool {
        guard audacitySynced, type == .keyDown, isAudacityFrontmost else { return false }
        let transportModifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
        guard flags.intersection(transportModifiers).isEmpty else { return false }
        if keyCode == kVK_ANSI_P {
            // Audacity keeps its Core Audio output stream alive while paused,
            // so P cannot use the output-state detector. Label editing only
            // occurs while transport is stopped; in that state P passes
            // through as text. During synced playback AVS owns P and sends the
            // same Pause command to Audacity and the video.
            guard syncedPlaying else { return false }
            if busy { return true }
            toggleSyncedPause(controlAudacity: true)
            return true
        }
        guard keyCode == kVK_Space else { return false }

        // Audacity receives the original key immediately and retains complete
        // ownership of label editing. Core Audio then tells us whether
        // Audacity actually started or stopped producing audio. Label typing
        // causes no audio transition, including when Space is the first
        // character, so AVS does nothing in that case.
        guard let outputBeforeKey = audacityAudioState.isOutputRunning() else { return false }
        // Capture the cursor while Audacity is still idle. GetInfo must not be
        // sent after playback starts because that can disturb the transport.
        let selectionBeforeKey = outputBeforeKey
            ? nil
            : try? audacity.selection(connectionWait: 0.25)
        let eventTimestamp = ProcessInfo.processInfo.systemUptime
        transportObservationGeneration += 1
        let generation = transportObservationGeneration
        controlQueue.async { [weak self] in
            guard let self else { return }
            self.pendingSelectionStop?.cancel()
            self.pendingSelectionStop = nil
        }
        observeAudacityAudioAfterKey(
            eventTimestamp: eventTimestamp,
            outputBeforeKey: outputBeforeKey,
            selectionBeforeKey: selectionBeforeKey,
            generation: generation,
            attempt: 0
        )
        return false
    }

    private func observeAudacityAudioAfterKey(
        eventTimestamp: TimeInterval,
        outputBeforeKey: Bool,
        selectionBeforeKey: AudacityPipe.Selection?,
        generation: Int,
        attempt: Int
    ) {
        let delays: [TimeInterval] = [0.015, 0.025, 0.040, 0.065, 0.100, 0.160, 0.240]
        guard attempt < delays.count else { return }
        transportObservationQueue.asyncAfter(deadline: .now() + delays[attempt]) { [weak self] in
            guard let self else { return }
            let outputAfterKey = self.audacityAudioState.isOutputRunning()
            DispatchQueue.main.async {
                guard generation == self.transportObservationGeneration,
                      self.audacitySynced else { return }

                guard let outputAfterKey,
                      outputAfterKey != outputBeforeKey,
                      !self.busy else {
                    self.observeAudacityAudioAfterKey(
                        eventTimestamp: eventTimestamp,
                        outputBeforeKey: outputBeforeKey,
                        selectionBeforeKey: selectionBeforeKey,
                        generation: generation,
                        attempt: attempt + 1
                    )
                    return
                }

                // Reconcile to Audacity's confirmed result, never toggle from
                // AVS's potentially stale state left by an earlier key.
                if outputAfterKey {
                    guard let selectionBeforeKey else { return }
                    self.startVideoFollowingAudacity(
                        eventTimestamp: eventTimestamp,
                        selection: selectionBeforeKey
                    )
                } else {
                    self.stopVideoFollowingAudacity()
                }
            }
        }
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
        let offset = videoOffsetSeconds
        controlQueue.async { [weak self, weak player] in
            guard let self, let player else { return }
            defer { DispatchQueue.main.async { self.syncCheckInFlight = false } }
            guard self.internalSyncActive else { return }

            // Do not query Audacity while stopped. Repeated script-pipe traffic can
            // make Audacity's waveform UI sluggish and interfere with positioning
            // its playhead. The play shortcut performs a fresh cursor read instead.
            guard self.internalSyncPlaying, !self.internalSyncPaused else { return }

            let elapsed = ProcessInfo.processInfo.systemUptime - self.syncStartClock
            let expected = self.clampedVideoPosition(
                self.syncStartCursor + elapsed + compensation + offset,
                duration: player.duration()
            )
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

    private func runAutomatedSyncTransportTest() {
        let resultURL = URL(fileURLWithPath: "/private/tmp/avs-full-sync-test.txt")
        syncToAudacity()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            func mainValue<T>(_ value: @escaping () -> T) -> T {
                DispatchQueue.main.sync(execute: value)
            }
            func waitUntil(_ timeout: TimeInterval = 2.0, _ condition: @escaping () -> Bool) -> Bool {
                let deadline = ProcessInfo.processInfo.systemUptime + timeout
                repeat {
                    if mainValue(condition) { return true }
                    Darwin.usleep(20_000)
                } while ProcessInfo.processInfo.systemUptime < deadline
                return false
            }
            func waitForAudio(_ expected: Bool, timeout: TimeInterval = 2.0) -> Bool {
                let deadline = ProcessInfo.processInfo.systemUptime + timeout
                repeat {
                    if self.audacityAudioState.isOutputRunning() == expected { return true }
                    Darwin.usleep(20_000)
                } while ProcessInfo.processInfo.systemUptime < deadline
                return false
            }
            func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags = []) {
                let source = CGEventSource(stateID: .hidSystemState)
                let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
                let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
                down?.flags = flags
                up?.flags = flags
                down?.post(tap: .cghidEventTap)
                up?.post(tap: .cghidEventTap)
            }
            var lines: [String] = []
            do {
                guard waitUntil(4.0, { self.audacitySynced && !self.busy }) else {
                    throw NSError(domain: "AVSTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "Sync did not become ready"])
                }
                let original = try self.audacity.selection()
                let originalLabels = try self.audacity.labelsFingerprint()
                guard let audacityApp = NSRunningApplication.runningApplications(
                    withBundleIdentifier: "org.audacityteam.audacity"
                ).first else { throw AudacityPipe.PipeError.unavailable }
                defer {
                    try? self.audacity.stop()
                    try? self.audacity.select(start: original.start, end: original.end)
                }

                for cycle in 1...5 {
                    let start = Double(cycle) * 0.5
                    try self.audacity.select(start: start, end: start + 3.0)
                    audacityApp.activate(options: [.activateAllWindows])
                    Darwin.usleep(120_000)
                    postKey(CGKeyCode(kVK_Space))
                    let videoStarted = waitUntil { self.syncedPlaying && self.playing }
                    let audioStarted = waitForAudio(true)
                    Darwin.usleep(350_000)
                    let videoAdvanced = self.controlQueue.sync {
                        guard let player = self.playerView else { return false }
                        return !player.isPaused() && player.timePosition() > start + 0.15
                    }

                    var pausePassed = true
                    if cycle == 1 {
                        postKey(CGKeyCode(kVK_ANSI_P))
                        let paused = waitUntil { self.syncedPaused && !self.playing }
                        postKey(CGKeyCode(kVK_ANSI_P))
                        let resumed = waitUntil { !self.syncedPaused && self.playing }
                        pausePassed = paused && resumed
                    }

                    postKey(CGKeyCode(kVK_Space))
                    let videoStopped = waitUntil { !self.syncedPlaying && !self.playing }
                    let audioStopped = waitForAudio(false)
                    let passed = videoStarted && audioStarted && videoAdvanced
                        && pausePassed && videoStopped && audioStopped
                    lines.append("cycle=\(cycle) audioStarted=\(audioStarted) videoStarted=\(videoStarted) advanced=\(videoAdvanced) pause=\(pausePassed) audioStopped=\(audioStopped) videoStopped=\(videoStopped) result=\(passed ? "PASS" : "FAIL")")
                }

                try self.audacity.select(start: original.start, end: original.start)
                audacityApp.activate(options: [.activateAllWindows])
                Darwin.usleep(120_000)
                postKey(CGKeyCode(kVK_ANSI_B), flags: .maskCommand)
                Darwin.usleep(180_000)
                postKey(CGKeyCode(kVK_Space))
                Darwin.usleep(300_000)
                let labelChanged = (try self.audacity.labelsFingerprint()) != originalLabels
                let labelDidNotStartVideo = mainValue { !self.syncedPlaying && !self.playing }
                postKey(CGKeyCode(kVK_Return))
                Darwin.usleep(100_000)
                var restored = false
                for _ in 0..<4 {
                    postKey(CGKeyCode(kVK_ANSI_Z), flags: .maskCommand)
                    Darwin.usleep(140_000)
                    if (try self.audacity.labelsFingerprint()) == originalLabels {
                        restored = true
                        break
                    }
                }
                let labelPassed = labelChanged && labelDidNotStartVideo && restored
                lines.append("leadingLabelSpace changed=\(labelChanged) videoStayedStopped=\(labelDidNotStartVideo) restored=\(restored) result=\(labelPassed ? "PASS" : "FAIL")")
            } catch {
                lines.append("ERROR \(error.localizedDescription)")
            }
            let output = lines.joined(separator: "\n") + "\n"
            try? output.write(to: resultURL, atomically: true, encoding: .utf8)
            FileHandle.standardOutput.write(Data(output.utf8))
            DispatchQueue.main.async { NSApp.terminate(nil) }
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
        keyboardTap.stop()

        let player = playerView
        controlQueue.sync {
            pendingSelectionStop?.cancel()
            pendingSelectionStop = nil
            if internalSyncPlaying { try? audacity.stop() }
            internalSyncPlaying = false
            internalSyncPaused = false
            internalSyncActive = false
            try? player?.setPaused(true)
            try? player?.setPlaybackRate(1.0)
        }
        player?.shutdownPlayer()
        playerView = nil
        releaseVideoFileAccess()
    }
}

private final class AudacityAudioStateReader {
    func isOutputRunning() -> Bool? {
        guard let audacityPID = NSRunningApplication.runningApplications(
            withBundleIdentifier: "org.audacityteam.audacity"
        ).first?.processIdentifier else { return nil }

        var listAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &listAddress,
            0,
            nil,
            &dataSize
        ) == noErr else { return nil }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var processObjects = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &listAddress,
            0,
            nil,
            &dataSize,
            &processObjects
        ) == noErr else { return nil }

        for object in processObjects {
            var pidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyPID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var pid: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            guard AudioObjectGetPropertyData(
                object, &pidAddress, 0, nil, &pidSize, &pid
            ) == noErr, pid == audacityPID else { continue }

            var runningAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyIsRunningOutput,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var running: UInt32 = 0
            var runningSize = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(
                object, &runningAddress, 0, nil, &runningSize, &running
            ) == noErr else { return nil }
            return running != 0
        }
        return false
    }
}

private struct AudacityTransportSnapshot {
    let playing: Bool
    let paused: Bool
}

private final class AudacityTransportStateReader {
    private var stopButton: AXUIElement?
    private var playButton: AXUIElement?
    private var pauseButton: AXUIElement?

    func reset() {
        stopButton = nil
        playButton = nil
        pauseButton = nil
    }

    func snapshot() -> AudacityTransportSnapshot? {
        if stopButton == nil || playButton == nil || pauseButton == nil {
            discoverControls()
        }
        guard let stopButton, let pauseButton,
              let stopEnabled = boolAttribute(kAXEnabledAttribute, from: stopButton) else {
            reset()
            return nil
        }

        let playName = playButton.map(searchableText(for:))?.lowercased() ?? ""
        let playPressed: Bool?
        if playName.contains("not pressed") {
            playPressed = false
        } else if playName.contains("pressed") {
            playPressed = true
        } else {
            playPressed = nil
        }
        let pauseName = searchableText(for: pauseButton).lowercased()
        let paused = pauseName.contains("pressed") && !pauseName.contains("not pressed")
        return AudacityTransportSnapshot(playing: playPressed ?? stopEnabled, paused: paused)
    }

    private func discoverControls() {
        reset()
        guard let app = NSRunningApplication.runningApplications(
            withBundleIdentifier: "org.audacityteam.audacity"
        ).first else { return }

        let root = AXUIElementCreateApplication(app.processIdentifier)
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var index = 0
        var visited = 0

        while index < queue.count && visited < 2500
                && (stopButton == nil || playButton == nil || pauseButton == nil) {
            let (element, depth) = queue[index]
            index += 1
            visited += 1

            let role = stringAttribute(kAXRoleAttribute, from: element) ?? ""
            let text = searchableText(for: element).lowercased()
            if stopButton == nil, role == (kAXButtonRole as String), text.contains("stop") {
                stopButton = element
            }
            if playButton == nil,
               role == (kAXButtonRole as String),
               text.contains("play"), text.contains("button"),
               !text.contains("loop") {
                playButton = element
            }
            if pauseButton == nil,
               (role == (kAXStaticTextRole as String) || role == (kAXButtonRole as String)),
               text.contains("pause"), text.contains("button") {
                pauseButton = element
            }

            guard depth < 14 else { continue }
            for child in elementArrayAttribute(kAXChildrenAttribute, from: element) {
                queue.append((child, depth + 1))
            }
        }
    }

    private func searchableText(for element: AXUIElement) -> String {
        [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute, kAXValueAttribute]
            .compactMap { stringAttribute($0, from: element) }
            .joined(separator: " ")
    }

    private func stringAttribute(_ name: String, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private func boolAttribute(_ name: String, from element: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value as? Bool
    }

    private func elementArrayAttribute(_ name: String, from element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let values = value as? [Any] else { return [] }
        return values.compactMap { item in
            let object = item as CFTypeRef
            guard CFGetTypeID(object) == AXUIElementGetTypeID() else { return nil }
            return (item as! AXUIElement)
        }
    }
}

private let audacityKeyboardTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let owner = Unmanaged<AudacityKeyboardTap>.fromOpaque(userInfo).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let eventTap = owner.eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: true)
        }
        return Unmanaged.passUnretained(event)
    }

    guard type == .keyDown,
          event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else {
        return Unmanaged.passUnretained(event)
    }

    let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
    if owner.handler?(type, keyCode, event.flags) == true {
        return nil
    }
    return Unmanaged.passUnretained(event)
}

private final class AudacityKeyboardTap {
    var handler: ((CGEventType, Int, CGEventFlags) -> Bool)?
    fileprivate var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    func start() -> Bool {
        if eventTap != nil { return true }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else { return false }

        let eventMask = CGEventMask(1) << CGEventType.keyDown.rawValue
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: audacityKeyboardTapCallback,
            userInfo: userInfo
        ) else { return false }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        eventTap = tap
        runLoopSource = source
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        runLoopSource = nil
        eventTap = nil
    }

    deinit {
        stop()
    }
}

private struct AudacityPipe {
    struct Selection {
        let start: Double
        let end: Double

        var duration: Double { max(0, end - start) }
        var hasRange: Bool { duration > 0.0005 }
    }

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
        try selection(connectionWait: connectionWait).start
    }

    func selection(connectionWait: TimeInterval = 3.0) throws -> Selection {
        let number = #"([-+]?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?)"#
        let startRegex = try NSRegularExpression(
            pattern: #"\"start\"\s*:\s*"# + number,
            options: .caseInsensitive
        )
        let endRegex = try NSRegularExpression(
            pattern: #"\"end\"\s*:\s*"# + number,
            options: .caseInsensitive
        )

        // A command acknowledgement can very occasionally remain ahead of the
        // selection result in the shared pipe. Retry a malformed response rather
        // than dropping an otherwise healthy synchronization session.
        for attempt in 0..<3 {
            let response = try send(
                "GetInfo: Type=Selection Format=JSON",
                connectionWait: attempt == 0 ? connectionWait : 0.5
            )
            let range = NSRange(response.startIndex..., in: response)
            if let startMatch = startRegex.firstMatch(in: response, range: range),
               let startRange = Range(startMatch.range(at: 1), in: response),
               let start = Double(response[startRange]),
               let endMatch = endRegex.firstMatch(in: response, range: range),
               let endRange = Range(endMatch.range(at: 1), in: response),
               let end = Double(response[endRange]) {
                return Selection(start: start, end: max(start, end))
            }
            if attempt < 2 { Darwin.usleep(75_000) }
        }
        throw PipeError.invalidCursor
    }

    func play() throws {
        // Audacity's script-only Play command waits for a finite selection to
        // finish before replying. The normal Play/Stop transport command starts
        // the same selection immediately, allowing the video to start with it.
        _ = try send("DefaultPlayStop:")
    }

    func stop() throws {
        _ = try send("Stop:")
    }

    func pause() throws {
        _ = try send("Pause:")
    }

    func labelsFingerprint() throws -> String {
        try send("GetInfo: Type=Labels Format=JSON")
    }

    func select(start: Double, end: Double) throws {
        _ = try send("SelectTime: Start=\(start) End=\(end) RelativeTo=ProjectStart")
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

private func runAudacityTransportStateTest() {
    DispatchQueue.global(qos: .userInitiated).async {
        let resultURL = URL(fileURLWithPath: "/private/tmp/avs-transport-state-test.txt")
        let pipe = AudacityPipe()
        let audioState = AudacityAudioStateReader()
        var lines: [String] = []
        func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags = []) {
            let source = CGEventSource(stateID: .hidSystemState)
            let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
            let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
            down?.flags = flags
            up?.flags = flags
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
        }
        func waitForOutput(_ expected: Bool, timeout: TimeInterval = 1.0) -> Bool {
            let deadline = ProcessInfo.processInfo.systemUptime + timeout
            repeat {
                if audioState.isOutputRunning() == expected { return true }
                Darwin.usleep(20_000)
            } while ProcessInfo.processInfo.systemUptime < deadline
            return false
        }
        do {
            let original = try pipe.selection()
            let originalLabels = try pipe.labelsFingerprint()
            guard let audacityApp = NSRunningApplication.runningApplications(
                withBundleIdentifier: "org.audacityteam.audacity"
            ).first else { throw AudacityPipe.PipeError.unavailable }
            defer {
                try? pipe.stop()
                try? pipe.select(start: original.start, end: original.end)
            }
            try? pipe.stop()
            _ = waitForOutput(false)
            for cycle in 1...3 {
                let start = original.start + (Double(cycle) * 0.125)
                try pipe.select(start: start, end: start + 3.0)
                Darwin.usleep(120_000)
                let selected = try pipe.selection()
                audacityApp.activate(options: [.activateAllWindows])
                Darwin.usleep(120_000)
                postKey(CGKeyCode(kVK_Space))
                let realAudioStarted = waitForOutput(true)
                postKey(CGKeyCode(kVK_Space))
                let realAudioStopped = waitForOutput(false)
                let cursorMoved = abs(selected.start - start) < 0.002
                let passed = cursorMoved && realAudioStarted && realAudioStopped
                let resultText = passed ? "PASS" : "FAIL"
                lines.append("cycle=\(cycle) cursorMoved=\(cursorMoved) audioStarted=\(realAudioStarted) audioStopped=\(realAudioStopped) result=\(resultText)")
            }

            try pipe.select(start: original.start, end: original.start + 3.0)
            audacityApp.activate(options: [.activateAllWindows])
            Darwin.usleep(120_000)
            postKey(CGKeyCode(kVK_Space))
            let pauseStarted = waitForOutput(true)
            postKey(CGKeyCode(kVK_ANSI_P))
            let pauseStoppedOutput = waitForOutput(false)
            postKey(CGKeyCode(kVK_ANSI_P))
            let pauseResumedOutput = waitForOutput(true)
            postKey(CGKeyCode(kVK_Space))
            _ = waitForOutput(false)
            lines.append("audacityPauseProbe start=\(pauseStarted) outputStopsOnPause=\(pauseStoppedOutput) outputOnResume=\(pauseResumedOutput)")

            try pipe.select(start: original.start, end: original.start)
            audacityApp.activate(options: [.activateAllWindows])
            Darwin.usleep(120_000)
            postKey(CGKeyCode(kVK_ANSI_B), flags: .maskCommand)
            Darwin.usleep(180_000)
            postKey(CGKeyCode(kVK_Space))
            Darwin.usleep(180_000)
            let labelDidNotPlay = audioState.isOutputRunning() == false
            let labelChanged = (try pipe.labelsFingerprint()) != originalLabels
            postKey(CGKeyCode(kVK_Return))
            Darwin.usleep(100_000)
            var labelRestored = false
            for _ in 0..<4 {
                postKey(CGKeyCode(kVK_ANSI_Z), flags: .maskCommand)
                Darwin.usleep(140_000)
                if (try pipe.labelsFingerprint()) == originalLabels {
                    labelRestored = true
                    break
                }
            }
            let labelPassed = labelDidNotPlay && labelChanged && labelRestored
            lines.append("leadingLabelSpace noAudio=\(labelDidNotPlay) labelChanged=\(labelChanged) restored=\(labelRestored) result=\(labelPassed ? "PASS" : "FAIL")")
        } catch {
            lines.append("ERROR \(error.localizedDescription)")
        }
        let output = lines.joined(separator: "\n") + "\n"
        try? output.write(to: resultURL, atomically: true, encoding: .utf8)
        FileHandle.standardOutput.write(Data(output.utf8))
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }
}
