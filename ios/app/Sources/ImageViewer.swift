import SwiftUI
import UIKit

struct ImageViewerItem: Identifiable {
    let id: String
    var path: String { id }
}

struct ImageViewer: View {
    let path: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?
    @State private var failed = false

    private func maxPixel(for size: CGSize) -> Int {
        let longestSide = max(size.width, size.height)
        return max(1200, min(4096, Int((longestSide * displayScale * 2).rounded())))
    }

    var body: some View {
        GeometryReader { geo in
            let pixelBudget = maxPixel(for: geo.size)
            NavigationStack {
                Group {
                    if let image {
                        ZoomableImageView(image: image, onSwipeDismiss: { dismiss() })
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
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark")
                        }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        ShareLink(item: URL(fileURLWithPath: path)) {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                }
                .toolbarBackground(.black.opacity(0.6), for: .navigationBar)
                .toolbarColorScheme(.dark, for: .navigationBar)
            }
            .task(id: "\(path)@\(pixelBudget)") {
                await loadImage(maxPixel: pixelBudget)
            }
        }
        .background(Color.black)
    }

    private func loadImage(maxPixel: Int) async {
        if let cached = ThumbnailLoader.cachedThumbnail(path: path, maxPixel: maxPixel) {
            image = cached
            failed = false
            return
        }

        image = nil
        failed = false
        let p = path
        let decoded = await Task.detached(priority: .userInitiated) {
            ThumbnailLoader.loadThumbnail(path: p, maxPixel: maxPixel)
        }.value
        if !Task.isCancelled {
            image = decoded
            failed = decoded == nil
        }
    }
}

/// UIScrollView-backed image view: pinch to zoom, drag to pan, double-tap to
/// toggle zoom. Layout and centering are handled in layoutSubviews so the
/// view works regardless of when SwiftUI sizes it.
struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage
    var onSwipeDismiss: (() -> Void)? = nil

    func makeUIView(context: Context) -> ImageScrollView {
        ImageScrollView(image: image, onSwipeDismiss: onSwipeDismiss)
    }

    func updateUIView(_ view: ImageScrollView, context: Context) {}
}

final class ImageScrollView: UIScrollView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    private let imageView: UIImageView
    private var lastLaidOutSize: CGSize = .zero
    private let onSwipeDismiss: (() -> Void)?

    init(image: UIImage, onSwipeDismiss: (() -> Void)? = nil) {
        imageView = UIImageView(image: image)
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

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        imageView.addGestureRecognizer(doubleTap)

        let swipeDown = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipeDismiss(_:)))
        swipeDown.direction = .down
        swipeDown.delegate = self
        addGestureRecognizer(swipeDown)
    }

    @objc private func handleSwipeDismiss(_ gesture: UISwipeGestureRecognizer) {
        if zoomScale <= 1.01 {
            onSwipeDismiss?()
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
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

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
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
