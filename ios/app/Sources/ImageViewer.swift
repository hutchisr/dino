import SwiftUI
import UIKit
import AVKit
import Combine

enum MediaViewerItem: Codable, Hashable {
    case image(String)
    case video(String)

    static let windowGroupID = "media-viewer-v2"
}

#if targetEnvironment(macCatalyst)
private struct FocusedMediaViewerItemKey: FocusedValueKey {
    typealias Value = MediaViewerItem
}

extension FocusedValues {
    var mediaViewerItem: MediaViewerItem? {
        get { self[FocusedMediaViewerItemKey.self] }
        set { self[FocusedMediaViewerItemKey.self] = newValue }
    }
}

struct MediaViewerCommands: Commands {
    @Environment(\.dismissWindow) private var dismissWindow
    @FocusedValue(\.mediaViewerItem) private var item

    var body: some Commands {
        CommandGroup(after: .printItem) {
            Button("Close Media Preview") {
                dismissWindow(id: MediaViewerItem.windowGroupID)
            }
            .keyboardShortcut(.cancelAction)
            .disabled(item == nil)
        }
    }
}
#endif

/// Both viewers wear the same chrome, so it lives here once. On macCatalyst the
/// window's own title bar already provides a close affordance, so only the share
/// button is added — styled as a floating glass circle over the black backdrop.
private struct MediaViewerToolbar: ToolbarContent {
    let url: URL
    let onClose: () -> Void

    var body: some ToolbarContent {
#if targetEnvironment(macCatalyst)
        ToolbarItem(placement: .primaryAction) {
            ShareLink(item: url) {
                Image(systemName: "square.and.arrow.up")
                    .frame(width: 36, height: 36)
                    .contentShape(Circle())
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
        }
        .sharedBackgroundVisibility(.hidden)
#else
        ToolbarItem(placement: .cancellationAction) {
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
            }
            .accessibilityLabel("Close")
        }
        ToolbarItem(placement: .primaryAction) {
            ShareLink(item: url) {
                Image(systemName: "square.and.arrow.up")
            }
        }
#endif
    }
}

struct ImageViewer: View {
    let path: String
    var onDismiss: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var image: UIImage?
    @State private var failed = false

    private func maxPixel(for size: CGSize) -> Int {
        let longestSide = max(size.width, size.height)
        return max(1200, min(4096, Int((longestSide * displayScale * 2).rounded())))
    }

    private func closeViewer() {
        if let onDismiss {
            onDismiss()
        } else {
            dismiss()
        }
    }

    var body: some View {
        GeometryReader { geo in
            let pixelBudget = maxPixel(for: geo.size)
            NavigationStack {
                Group {
                    if let image {
                        ZoomableImageView(
                            image: image,
                            reduceMotion: accessibilityReduceMotion,
                            onSwipeDismiss: closeViewer)
                            .ignoresSafeArea()
                            .background(Color.black)
                    } else if failed {
                        Text("Could not load image").foregroundStyle(.white)
                    } else {
                        ProgressView()
                            .tint(.white)
                    }
                }
                .background(Color.black)
                .navigationTitle("")
                .toolbar {
                    MediaViewerToolbar(url: URL(fileURLWithPath: path), onClose: closeViewer)
                }
                .toolbarBackground(.hidden, for: .navigationBar)
                .toolbarColorScheme(.dark, for: .navigationBar)
            }
            .task(id: "\(path)@\(pixelBudget)") {
                await loadImage(maxPixel: pixelBudget)
            }
        }
        .background(Color.black)
        .preferredColorScheme(.dark)
    }

    private func loadImage(maxPixel: Int) async {
        image = ThumbnailLoader.cachedThumbnail(path: path, maxPixel: maxPixel)
        failed = false

        let p = path
        let decoded = await ThumbnailLoader.loadViewerImageAsync(path: p, maxPixel: maxPixel)
        guard !Task.isCancelled else { return }
        if let decoded {
            image = decoded
        } else {
            failed = image == nil
        }
    }
}

struct VideoViewer: View {
    let path: String
    var onDismiss: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?

    private var url: URL {
        URL(fileURLWithPath: path)
    }

    private func closeViewer() {
        if let onDismiss {
            onDismiss()
        } else {
            dismiss()
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                VideoPlayer(player: player)
                    .ignoresSafeArea()
            }
            .navigationTitle("")
            .toolbar {
                MediaViewerToolbar(url: url, onClose: closeViewer)
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .background(Color.black)
        .preferredColorScheme(.dark)
        .onAppear {
            let p = AVPlayer(url: url)
            player = p
            p.play()
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }
}

/// Owns only a visible attachment's player. No decoding or time observers exist
/// until Play is pressed; replacing the active attachment pauses the old one.
@MainActor
final class AudioAttachmentPlayback: ObservableObject {
    private static weak var active: AudioAttachmentPlayback?
    @Published private(set) var isPlaying = false
    @Published private(set) var isLoading = false
    @Published private(set) var duration: Double = 0
    @Published private(set) var position: Double = 0
    @Published private(set) var error: String?

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var observations: [NSKeyValueObservation] = []
    private var notifications: Set<AnyCancellable> = []

    func toggle(url: URL) {
        if isPlaying {
            pause()
            return
        }
        Self.active?.pause()
        Self.active = self
        error = nil
        do {
#if !targetEnvironment(macCatalyst)
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
#endif
            if player == nil { prepare(url: url) }
            if duration > 0, position >= duration {
                seek(to: 0)
            }
            player?.play()
            isPlaying = true
        } catch {
            fail()
        }
    }

    func pause() {
        player?.pause()
        isPlaying = false
        if Self.active === self {
            Self.active = nil
#if !targetEnvironment(macCatalyst)
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
#endif
        }
    }

    func seek(to seconds: Double) {
        guard seconds.isFinite, duration > 0 else { return }
        position = min(max(0, seconds), duration)
        player?.seek(to: CMTime(seconds: position, preferredTimescale: 600),
                     toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func stop() {
        pause()
        observations.removeAll()
        notifications.removeAll()
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        player = nil
        isLoading = false
        duration = 0
        position = 0
    }

    private func fail() {
        stop()
        error = "Could not play audio. The file may be unavailable, damaged, or unsupported by this system."
    }

    private func prepare(url: URL) {
        let item = AVPlayerItem(url: url)
        let p = AVPlayer(playerItem: item)
        player = p
        isLoading = true
        observations = [
            item.observe(\.status, options: [.initial, .new]) { [weak self, weak p] item, _ in
                Task { @MainActor in
                    guard let self, let p, self.player === p else { return }
                    switch item.status {
                    case .readyToPlay:
                        let seconds = item.duration.seconds
                        self.duration = seconds.isFinite && seconds > 0 ? seconds : 0
                        self.isLoading = false
                    case .failed:
                        self.fail()
                    default: break
                    }
                }
            },
            p.observe(\.timeControlStatus, options: [.new]) { [weak self] p, _ in
                Task { @MainActor in
                    guard let self, self.player === p else { return }
                    self.isPlaying = p.timeControlStatus != .paused
                }
            },
        ]
        timeObserver = p.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main
        ) { [weak self, weak p] time in
            Task { @MainActor in
                guard let self, let p, self.player === p, time.seconds.isFinite else { return }
                self.position = max(0, time.seconds)
            }
        }
        NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification, object: item)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.pause()
                self.position = self.duration
            }
            .store(in: &notifications)
        NotificationCenter.default.publisher(for: AVPlayerItem.failedToPlayToEndTimeNotification, object: item)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.fail() }
            .store(in: &notifications)
#if !targetEnvironment(macCatalyst)
        NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
            .merge(with: NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
                .filter {
                    ($0.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
                        == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue
                })
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.pause() }
            .store(in: &notifications)
#endif
    }

    deinit {
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        player?.pause()
    }
}

private struct AttachmentShareButton: View {
    let url: URL
    let label: String
    @State private var request = 0

    var body: some View {
        Button { request += 1 } label: {
            Image(systemName: "square.and.arrow.up")
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .background {
            AttachmentShareAnchor(url: url, request: request)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

/// UIKit supplies only the popover anchor; SwiftUI owns the visible control.
private struct AttachmentShareAnchor: UIViewControllerRepresentable {
    let url: URL
    let request: Int

    func makeUIViewController(context _: Context) -> ShareButtonController {
        ShareButtonController(url: url, request: request)
    }

    func updateUIViewController(_ controller: ShareButtonController, context _: Context) {
        if controller.url != url { controller.dismissShare() }
        controller.url = url
        if controller.request != request {
            controller.request = request
            controller.share()
        }
    }

    static func dismantleUIViewController(_ controller: ShareButtonController, coordinator _: ()) {
        controller.dismissShare()
    }

    final class ShareButtonController: UIViewController {
        var url: URL
        var request: Int
        private weak var activity: UIActivityViewController?

        init(url: URL, request: Int) {
            self.url = url
            self.request = request
            super.init(nibName: nil, bundle: nil)
        }

        required init?(coder: NSCoder) { nil }

        override func loadView() {
            view = UIView()
            view.backgroundColor = .clear
        }

        func share() {
            guard activity == nil, view.window != nil else { return }
            let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            if traitCollection.userInterfaceIdiom != .phone { controller.modalPresentationStyle = .popover }
            controller.popoverPresentationController?.sourceView = view
            controller.popoverPresentationController?.sourceRect = view.bounds
            controller.completionWithItemsHandler = { [weak self] _, _, _, _ in
                self?.activity = nil
            }
            activity = controller
            present(controller, animated: true)
        }

        func dismissShare() {
            activity?.dismiss(animated: false)
            activity = nil
        }
    }
}

struct AudioAttachmentView: View {
    let path: String
    let fileName: String
    var onSave: (() -> Void)? = nil
    @StateObject private var playback = AudioAttachmentPlayback()
    @Environment(\.scenePhase) private var scenePhase
    @State private var scrubPosition: Double?

    private var name: String { fileName.isEmpty ? "Audio" : fileName }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    playback.toggle(url: URL(fileURLWithPath: path))
                } label: {
                    Image(systemName: playback.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.title)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(playback.isPlaying ? "Pause" : "Play") \(name)")
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).lineLimit(1)
                    if playback.isLoading {
                        ProgressView().controlSize(.mini)
                    } else {
                        Text("\(timestamp(scrubPosition ?? playback.position)) / \(timestamp(playback.duration))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                HStack(spacing: 0) {
                    if let onSave {
                        Button(action: onSave) {
                            Image(systemName: "square.and.arrow.down")
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Save \(name)")
                    }
                    AttachmentShareButton(url: URL(fileURLWithPath: path), label: "Share \(name)")
                }
            }
            Slider(
                value: Binding(
                    get: { scrubPosition ?? min(playback.position, playback.duration) },
                    set: { scrubPosition = $0 }
                ),
                in: 0...max(playback.duration, 1),
                onEditingChanged: { editing in
                    if !editing, let seconds = scrubPosition {
                        playback.seek(to: seconds)
                        scrubPosition = nil
                    }
                }
            )
            .disabled(playback.duration <= 0)
            .accessibilityLabel("Playback position")
            if let error = playback.error {
                Text(error).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("audio.playbackError")
            }
        }
        .frame(idealWidth: 260, maxWidth: 300)
        .accessibilityElement(children: .contain)
        .onDisappear { playback.stop() }
#if !targetEnvironment(macCatalyst)
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { playback.pause() }
        }
#endif
    }

    private func timestamp(_ seconds: Double) -> String {
        Duration.seconds(seconds).formatted(.time(pattern: .minuteSecond))
    }
}

/// UIScrollView-backed image view: pinch to zoom, drag to pan, double-tap to
/// toggle zoom. Layout and centering are handled in layoutSubviews so the
/// view works regardless of when SwiftUI sizes it.
struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage
    let reduceMotion: Bool
    var onSwipeDismiss: (() -> Void)? = nil

    func makeUIView(context _: Context) -> ImageScrollView {
        ImageScrollView(
            image: image,
            reduceMotion: reduceMotion,
            onSwipeDismiss: onSwipeDismiss)
    }

    func updateUIView(_ uiView: ImageScrollView, context _: Context) {
        uiView.setReduceMotion(reduceMotion)
        uiView.setImage(image)
    }
}

final class ImageScrollView: UIScrollView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    private let imageView: UIImageView
    private var displayedImage: UIImage?
    private var lastLaidOutSize: CGSize = .zero
    private let onSwipeDismiss: (() -> Void)?
    private var reduceMotion: Bool

    init(image: UIImage, reduceMotion: Bool, onSwipeDismiss: (() -> Void)? = nil) {
        imageView = UIImageView()
        self.reduceMotion = reduceMotion
        self.onSwipeDismiss = onSwipeDismiss
        super.init(frame: .zero)
        delegate = self
        maximumZoomScale = 6
        minimumZoomScale = 1
        bouncesZoom = true
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        backgroundColor = .black
        contentInsetAdjustmentBehavior = .never

        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        addSubview(imageView)
        setImage(image)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        imageView.addGestureRecognizer(doubleTap)

        let swipeDown = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipeDismiss(_:)))
        swipeDown.direction = .down
        swipeDown.delegate = self
        addGestureRecognizer(swipeDown)
    }

    func setImage(_ image: UIImage) {
        if let displayedImage, displayedImage === image { return }
        displayedImage = image
        configureDisplayedImage()
        setNeedsLayout()
    }

    func setReduceMotion(_ reduceMotion: Bool) {
        guard self.reduceMotion != reduceMotion else { return }
        self.reduceMotion = reduceMotion
        configureDisplayedImage()
    }

    private func configureDisplayedImage() {
        guard let displayedImage else { return }

        imageView.stopAnimating()
        imageView.animationImages = nil
        imageView.animationDuration = 0
        imageView.animationRepeatCount = 0

        if let frames = displayedImage.images, frames.count > 1 {
            imageView.image = frames.first
            if !reduceMotion {
                imageView.animationImages = frames
                imageView.animationDuration = displayedImage.duration
                if window != nil {
                    imageView.startAnimating()
                }
            }
        } else {
            imageView.image = displayedImage
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil || reduceMotion {
            imageView.stopAnimating()
        } else if imageView.animationImages?.isEmpty == false {
            imageView.startAnimating()
        }
    }

    @objc private func handleSwipeDismiss(_: UISwipeGestureRecognizer) {
        if zoomScale <= 1.01 {
            onSwipeDismiss?()
        }
    }

    func gestureRecognizer(_: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith _: UIGestureRecognizer) -> Bool {
        true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != lastLaidOutSize {
            lastLaidOutSize = bounds.size
            zoomScale = 1
            imageView.frame = bounds
            contentSize = bounds.size
        }
        centerImage()
    }

    private func centerImage() {
        let dx = max(0, (bounds.width - contentSize.width) / 2)
        let dy = max(0, (bounds.height - contentSize.height) / 2)
        contentInset = UIEdgeInsets(top: dy, left: dx, bottom: dy, right: dx)
    }

    func viewForZooming(in _: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_: UIScrollView) {
        centerImage()
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        if zoomScale > 1 {
            setZoomScale(1, animated: true)
        } else {
            let point = gesture.location(in: imageView)
            let size = CGSize(width: bounds.width / 3, height: bounds.height / 3)
            zoom(to: CGRect(origin: CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2), size: size), animated: true)
        }
    }
}
