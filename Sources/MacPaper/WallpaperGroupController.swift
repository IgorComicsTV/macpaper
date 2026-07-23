import AppKit
import AVFoundation
import CoreImage
import MacPaperCore
import Metal
import QuartzCore

private final class MetalWallpaperView: NSView {
    let metalLayer = CAMetalLayer()

    init(frame: NSRect, device: MTLDevice) {
        super.init(frame: frame)
        wantsLayer = true
        layer = metalLayer
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = false
        metalLayer.backgroundColor = NSColor.black.cgColor
        updateDrawableSize()
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        metalLayer.frame = bounds
        updateDrawableSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    private func updateDrawableSize() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: max(bounds.width * scale, 1), height: max(bounds.height * scale, 1))
    }
}

@MainActor
private final class WallpaperSurface {
    let display: DisplayDescriptor
    let window: NSWindow
    let view: MetalWallpaperView

    init(display: DisplayDescriptor, device: MTLDevice) {
        self.display = display
        view = MetalWallpaperView(frame: display.screen.frame, device: device)
        window = NSWindow(
            contentRect: display.screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false,
            screen: display.screen
        )
        window.contentView = view
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.ignoresMouseEvents = true
        window.isOpaque = true
        window.backgroundColor = .black
        window.hasShadow = false
        window.animationBehavior = .none
        window.setFrame(display.screen.frame, display: true)
    }

    func show() { window.orderFrontRegardless() }
    func hide() { window.orderOut(nil) }
    func close() {
        window.orderOut(nil)
        window.close()
    }
}

@MainActor
final class WallpaperGroupController {
    let id: String
    private var configuration: WallpaperGroupConfiguration
    private var displays: [DisplayDescriptor]
    private var surfaces: [String: WallpaperSurface] = [:]
    private let player = AVPlayer()
    private var videoOutput: AVPlayerItemVideoOutput?
    private let device: MTLDevice
    private let context: CIContext
    private let commandQueue: MTLCommandQueue
    private var files: [URL] = []
    private var currentURL: URL?
    private var switchTimer: Timer?
    private var renderTimer: Timer?
    private var directoryMonitor: DirectoryMonitor?
    private var observers: [NSObjectProtocol] = []
    private var globallyPaused = false
    private var systemSuspended = false
    private var onBattery = false
    private var foregroundPausedDisplays: Set<String> = []
    var onCurrentFileChanged: ((String?) -> Void)?

    init?(configuration: WallpaperGroupConfiguration, displays: [DisplayDescriptor]) {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        id = configuration.id
        self.configuration = configuration
        self.displays = displays
        self.device = device
        context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        commandQueue = queue
        player.isMuted = true
        player.volume = 0
        player.preventsDisplaySleepDuringVideoPlayback = false
        updateSurfaces()
        installObservers()
        reloadFolder()
        renderTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.renderFrame() }
        }
        renderTimer?.tolerance = 0.006
        applyPlaybackState()
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    func apply(
        configuration: WallpaperGroupConfiguration,
        displays: [DisplayDescriptor],
        globallyPaused: Bool,
        onBattery: Bool
    ) {
        let folderChanged = self.configuration.folderPath != configuration.folderPath
        let fileChanged = self.configuration.currentFile != configuration.currentFile
        let intervalChanged = self.configuration.interval != configuration.interval
        let displaysChanged = Set(self.displays.map(\.id)) != Set(displays.map(\.id))
        self.configuration = configuration
        self.displays = displays
        self.globallyPaused = globallyPaused
        let powerChanged = self.onBattery != onBattery
        self.onBattery = onBattery
        if displaysChanged { updateSurfaces() }
        if folderChanged { reloadFolder() }
        else if fileChanged, let path = configuration.currentFile { play(URL(fileURLWithPath: path)) }
        if intervalChanged { scheduleSwitchTimer() }
        if powerChanged, let currentURL { play(currentURL, preservingTime: true) }
        applyPlaybackState()
    }

    func setSystemSuspended(_ value: Bool) {
        systemSuspended = value
        applyPlaybackState()
    }

    func setForegroundPausedDisplays(_ ids: Set<String>) {
        foregroundPausedDisplays = ids
        applyPlaybackState()
    }

    func next() {
        guard let next = MediaCatalog.next(in: files, after: currentURL, order: configuration.order) else {
            stopForEmptyPlaylist()
            return
        }
        play(next)
    }

    func close() {
        renderTimer?.invalidate()
        switchTimer?.invalidate()
        player.pause()
        player.replaceCurrentItem(with: nil)
        videoOutput = nil
        directoryMonitor = nil
        surfaces.values.forEach { $0.close() }
    }

    private func updateSurfaces() {
        let activeIDs = Set(displays.map(\.id))
        for (displayID, surface) in surfaces where !activeIDs.contains(displayID) {
            surface.close()
            surfaces[displayID] = nil
        }
        for display in displays where surfaces[display.id] == nil {
            surfaces[display.id] = WallpaperSurface(display: display, device: device)
        }
        if currentURL != nil { surfaces.values.forEach { $0.show() } }
    }

    private func reloadFolder() {
        directoryMonitor = nil
        reloadFilesOnly()
        if let path = configuration.folderPath {
            directoryMonitor = DirectoryMonitor(url: URL(fileURLWithPath: path)) { [weak self] in
                self?.refreshDirectory()
            }
        }
        if let saved = configuration.currentFile.map(URL.init(fileURLWithPath:)), files.contains(saved) {
            play(saved)
        } else {
            next()
        }
    }

    private func refreshDirectory() {
        reloadFilesOnly()
        if files.isEmpty { stopForEmptyPlaylist() }
        else if currentURL == nil || !files.contains(currentURL!) { next() }
    }

    private func reloadFilesOnly() {
        guard let path = configuration.folderPath else { files = []; return }
        files = MediaCatalog.videos(in: URL(fileURLWithPath: path, isDirectory: true))
    }

    private func play(_ source: URL, preservingTime: Bool = false) {
        let oldTime = preservingTime ? player.currentTime() : .zero
        currentURL = source
        configuration.currentFile = source.path
        onCurrentFileChanged?(source.path)
        surfaces.values.forEach { $0.show() }

        Task { [weak self] in
            guard let self else { return }
            let optimized = await MediaOptimizer.shared.cachedURL(for: source)
            await MainActor.run {
                let playbackURL = self.onBattery ? (optimized ?? source) : source
                let item = AVPlayerItem(url: playbackURL)
                item.preferredForwardBufferDuration = 2
                let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
                ])
                item.add(output)
                self.videoOutput = output
                self.player.replaceCurrentItem(with: item)
                item.tracks.filter { $0.assetTrack?.mediaType == .audio }.forEach { $0.isEnabled = false }
                if preservingTime, oldTime.isValid { self.player.seek(to: oldTime) }
                self.applyPlaybackState()
                self.scheduleSwitchTimer()
            }
            await MediaOptimizer.shared.optimizeIfNeeded(source, onBattery: self.onBattery)
        }
    }

    private func renderFrame() {
        guard player.rate != 0, let output = videoOutput, currentURL != nil else { return }
        let itemTime = output.itemTime(forHostTime: CACurrentMediaTime())
        guard output.hasNewPixelBuffer(forItemTime: itemTime),
              let pixelBuffer = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil)
        else { return }
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let union = displays.reduce(CGRect.null) { $0.union($1.screen.frame) }

        for display in displays where !foregroundPausedDisplays.contains(display.id) {
            guard let surface = surfaces[display.id], let drawable = surface.view.metalLayer.nextDrawable(),
                  let commandBuffer = commandQueue.makeCommandBuffer() else { continue }
            let targetSize = surface.view.metalLayer.drawableSize
            let mapped = mappedImage(
                image,
                targetSize: targetSize,
                screenFrame: display.screen.frame,
                unionFrame: union
            )
            let bounds = CGRect(origin: .zero, size: targetSize)
            let background = CIImage(color: .black).cropped(to: bounds)
            context.render(
                mapped.composited(over: background),
                to: drawable.texture,
                commandBuffer: commandBuffer,
                bounds: bounds,
                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!
            )
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }

    private func mappedImage(
        _ source: CIImage,
        targetSize: CGSize,
        screenFrame: CGRect,
        unionFrame: CGRect
    ) -> CIImage {
        let normalized = source.transformed(by: CGAffineTransform(
            translationX: -source.extent.minX,
            y: -source.extent.minY
        ))
        if configuration.layoutMode == .spanned, displays.count > 1 {
            let canvasSize = unionFrame.size
            let canvas = position(normalized, in: canvasSize, mode: configuration.contentMode)
            let local = CGRect(
                x: screenFrame.minX - unionFrame.minX,
                y: screenFrame.minY - unionFrame.minY,
                width: screenFrame.width,
                height: screenFrame.height
            )
            let cropped = canvas.cropped(to: local).transformed(by: CGAffineTransform(
                translationX: -local.minX,
                y: -local.minY
            ))
            return cropped.transformed(by: CGAffineTransform(
                scaleX: targetSize.width / max(local.width, 1),
                y: targetSize.height / max(local.height, 1)
            ))
        }
        return position(normalized, in: targetSize, mode: configuration.contentMode)
    }

    private func position(_ image: CIImage, in size: CGSize, mode: VideoContentMode) -> CIImage {
        let sx = size.width / max(image.extent.width, 1)
        let sy = size.height / max(image.extent.height, 1)
        let transform: CGAffineTransform
        switch mode {
        case .stretch:
            transform = CGAffineTransform(scaleX: sx, y: sy)
        case .fill, .fit:
            let scale = mode == .fill ? max(sx, sy) : min(sx, sy)
            let scaled = CGSize(width: image.extent.width * scale, height: image.extent.height * scale)
            transform = CGAffineTransform(translationX: (size.width - scaled.width) / 2, y: (size.height - scaled.height) / 2)
                .scaledBy(x: scale, y: scale)
        }
        return image.transformed(by: transform).cropped(to: CGRect(origin: .zero, size: size))
    }

    private func installObservers() {
        observers.append(NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor in
                guard let self, note.object as? AVPlayerItem === self.player.currentItem else { return }
                self.player.seek(to: .zero)
                self.applyPlaybackState()
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor in
                guard let self, note.object as? AVPlayerItem === self.player.currentItem else { return }
                self.next()
            }
        })
    }

    private func scheduleSwitchTimer() {
        switchTimer?.invalidate()
        guard !files.isEmpty else { return }
        switchTimer = Timer.scheduledTimer(withTimeInterval: TimerPreset.clamped(configuration.interval), repeats: true) {
            [weak self] _ in Task { @MainActor in
                guard let self, !self.globallyPaused, !self.configuration.isPaused, !self.systemSuspended else { return }
                self.next()
            }
        }
    }

    private func applyPlaybackState() {
        let allDisplaysPaused = !configuration.displayIDs.isEmpty
            && Set(configuration.displayIDs).isSubset(of: foregroundPausedDisplays)
        if globallyPaused || configuration.isPaused || systemSuspended || allDisplaysPaused || currentURL == nil {
            player.pause()
        } else {
            player.play()
        }
    }

    private func stopForEmptyPlaylist() {
        currentURL = nil
        player.replaceCurrentItem(with: nil)
        videoOutput = nil
        switchTimer?.invalidate()
        surfaces.values.forEach { $0.hide() }
        onCurrentFileChanged?(nil)
    }
}
