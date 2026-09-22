import ImageIO
import Photos
import SwiftUI
import UIKit

struct NativeMediaGallery: View {
    let urls: [URL]
    let initialIndex: Int
    let accessibilityPrefix: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.nativeHapticFeedback) private var hapticFeedback
    @State private var selectedIndex: Int
    @StateObject private var imageStore = NativeMediaImageStore()
    @State private var zoomedIndices: Set<Int> = []
    @State private var pageDragOffset: CGFloat = 0
    @State private var dismissOffset: CGFloat = 0
    @State private var shareItems: NativeMediaActivityItems?
    @State private var message: NativeMediaMessage?
    @State private var isSaving = false

    init(urls: [URL], initialIndex: Int, accessibilityPrefix: String = "media_gallery") {
        self.urls = urls
        self.initialIndex = min(max(0, initialIndex), max(0, urls.count - 1))
        self.accessibilityPrefix = accessibilityPrefix
        _selectedIndex = State(initialValue: min(max(0, initialIndex), max(0, urls.count - 1)))
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black
                    .opacity(backgroundOpacity(viewportHeight: geometry.size.height))
                    .ignoresSafeArea()

                HStack(spacing: 0) {
                    ForEach(urls.indices, id: \.self) { index in
                        NativeZoomableRemoteImage(
                            url: urls[index],
                            store: imageStore,
                            onZoomChanged: { isZoomed in
                                if isZoomed { zoomedIndices.insert(index) } else { zoomedIndices.remove(index) }
                            }
                        )
                        .frame(width: geometry.size.width, height: geometry.size.height)
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .leading)
                .offset(
                    x: -CGFloat(selectedIndex) * geometry.size.width + pageDragOffset,
                    y: dismissOffset
                )
                .contentShape(Rectangle())
                .simultaneousGesture(horizontalPagingGesture(pageWidth: geometry.size.width))
                .simultaneousGesture(verticalDismissGesture(viewportHeight: geometry.size.height))

                if urls.count > 1 {
                    VStack {
                        Spacer()
                        Text("\(selectedIndex + 1) / \(urls.count)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.white)
                            .fixedSize(horizontal: true, vertical: false)
                            .frame(minWidth: 54)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 7)
                            .modifier(NativeMediaIndicatorSurface())
                            .padding(.bottom, 18)
                    }
                    .allowsHitTesting(false)
                }
            }
            .clipped()
        }
        .background(Color.black.ignoresSafeArea())
        .overlay(alignment: .top) { topControls }
        .preferredColorScheme(.dark)
        .sheet(item: $shareItems) { items in
            NativeMediaActivityView(activityItems: items.values)
        }
        .alert(item: $message) { message in
            Alert(
                title: Text("操作结果"),
                message: Text(message.text),
                dismissButton: .default(Text("知道了"))
            )
        }
        .accessibilityIdentifier(accessibilityPrefix)
    }

    @ViewBuilder
    private var topControls: some View {
        controls
    }

    private var controls: some View {
        HStack(spacing: 10) {
            NativeMediaControlButton(
                systemImage: "xmark",
                accessibilityLabel: "关闭图片",
                action: dismiss.callAsFunction
            )
            .accessibilityIdentifier("\(accessibilityPrefix)_close")

            Spacer()

            Menu {
                if let currentImage {
                    Button {
                        shareItems = NativeMediaActivityItems(values: [currentImage])
                    } label: {
                        Label("分享图片文件", systemImage: "square.and.arrow.up")
                    }
                }

                if #available(iOS 16, *), let currentURL {
                    ShareLink(item: currentURL) {
                        Label("分享图片链接", systemImage: "link")
                    }
                }

                Button(action: copyCurrentImage) {
                    Label("复制图片", systemImage: "doc.on.doc")
                }

                Button(action: saveCurrentImage) {
                    Label(isSaving ? "正在保存" : "保存到照片", systemImage: "square.and.arrow.down")
                }
                .disabled(currentImage == nil || isSaving)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
                    .modifier(NativeMediaControlSurface())
            }
            .foregroundStyle(.white)
            .accessibilityLabel("图片操作")
            .accessibilityIdentifier("\(accessibilityPrefix)_actions")
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }

    private var currentURL: URL? {
        urls.indices.contains(selectedIndex) ? urls[selectedIndex] : nil
    }

    private var currentImage: UIImage? {
        currentURL.flatMap { imageStore.image(for: $0) }
    }

    private var isCurrentImageZoomed: Bool { zoomedIndices.contains(selectedIndex) }

    private func backgroundOpacity(viewportHeight: CGFloat) -> Double {
        let fadeDistance = max(viewportHeight * 0.3, 1)
        return 1 - min(abs(dismissOffset) / fadeDistance, 1) * 0.55
    }

    private func horizontalPagingGesture(pageWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .onChanged { value in
                guard !isCurrentImageZoomed,
                      abs(value.translation.width) > abs(value.translation.height),
                      pageWidth > 0
                else { return }
                let pastFirst = selectedIndex == 0 && value.translation.width > 0
                let pastLast = selectedIndex == urls.count - 1 && value.translation.width < 0
                pageDragOffset = value.translation.width * (pastFirst || pastLast ? 0.25 : 1)
            }
            .onEnded { value in
                guard !isCurrentImageZoomed,
                      abs(value.translation.width) > abs(value.translation.height),
                      pageWidth > 0
                else {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) { pageDragOffset = 0 }
                    return
                }
                let target = NativeMediaPagingPolicy.targetIndex(
                    currentIndex: selectedIndex,
                    pageCount: urls.count,
                    translationWidth: value.translation.width,
                    predictedEndTranslationWidth: value.predictedEndTranslation.width,
                    pageWidth: pageWidth
                )
                let previousIndex = selectedIndex
                withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
                    selectedIndex = target
                    pageDragOffset = 0
                }
                NativeMediaGalleryFeedback(action: hapticFeedback).pageDidCommit(
                    from: previousIndex,
                    to: target
                )
            }
    }

    private func verticalDismissGesture(viewportHeight: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .onChanged { value in
                guard !isCurrentImageZoomed,
                      NativeMediaDismissalPolicy.isVertical(value.translation)
                else { return }
                dismissOffset = value.translation.height
            }
            .onEnded { value in
                guard !isCurrentImageZoomed,
                      NativeMediaDismissalPolicy.isVertical(value.translation)
                else {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) { dismissOffset = 0 }
                    return
                }
                if NativeMediaDismissalPolicy.shouldDismiss(
                    translation: value.translation,
                    predictedEndTranslation: value.predictedEndTranslation,
                    viewportHeight: viewportHeight
                ) {
                    NativeMediaGalleryFeedback(action: hapticFeedback)
                        .verticalDismissDidCommit(true)
                    dismiss()
                } else {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) { dismissOffset = 0 }
                }
            }
    }

    private func copyCurrentImage() {
        if let currentImage {
            UIPasteboard.general.image = currentImage
            message = NativeMediaMessage(text: "已复制图片")
        } else if let currentURL {
            UIPasteboard.general.url = currentURL
            message = NativeMediaMessage(text: "图片尚未加载完成，已复制图片链接")
        } else {
            message = NativeMediaMessage(text: "当前图片不可用")
        }
    }

    private func saveCurrentImage() {
        guard let currentImage, !isSaving else { return }
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                try await NativePhotoLibrary.save(currentImage)
                message = NativeMediaMessage(text: "已保存到照片")
            } catch {
                message = NativeMediaMessage(text: "无法保存图片，请检查照片权限后重试")
            }
        }
    }
}

private struct NativeMediaControlButton: View {
    let systemImage: String
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 44, height: 44)
                .contentShape(Circle())
                .modifier(NativeMediaControlSurface())
        }
        .foregroundStyle(.white)
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct NativeMediaControlSurface: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        content.background(.ultraThinMaterial, in: Circle())
    }
}

private struct NativeMediaIndicatorSurface: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        content.background(.ultraThinMaterial, in: Capsule())
    }
}

private struct NativeZoomableRemoteImage: View {
    let url: URL
    @ObservedObject var store: NativeMediaImageStore
    let onZoomChanged: (Bool) -> Void

    @State private var scale: CGFloat = 1
    @State private var settledScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var settledOffset: CGSize = .zero

    var body: some View {
        Group {
            if NativeRemoteMediaPolicy.isAnimatedImage(url) {
                zoomableContent(
                    NativeAnimatedRemoteImage(url: url, contentMode: .fit)
                )
            } else if let image = store.image(for: url) {
                zoomableImage(image)
            } else if store.didFail(url) {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                    Text("图片加载失败")
                    Button("重试") { Task { await store.load(url) } }
                        .buttonStyle(.bordered)
                }
                .foregroundStyle(.white)
            } else {
                ProgressView().tint(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .task(id: url) { await store.load(url) }
        .onDisappear { onZoomChanged(false) }
    }

    private func zoomableImage(_ image: UIImage) -> some View {
        zoomableContent(Image(uiImage: image).resizable().scaledToFit())
    }

    @ViewBuilder
    private func zoomableContent<Content: View>(_ content: Content) -> some View {
        let transformed = content
            .scaleEffect(scale)
            .offset(offset)
            .gesture(magnificationGesture)
            .onTapGesture(count: 2, perform: toggleZoom)

        if scale > 1.001 {
            transformed.simultaneousGesture(panGesture)
        } else {
            transformed
        }
    }

    private var magnificationGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                scale = min(max(settledScale * value, 1), 5)
                onZoomChanged(scale > 1.001)
            }
            .onEnded { _ in
                settledScale = scale
                if scale == 1 {
                    offset = .zero
                    settledOffset = .zero
                }
                onZoomChanged(scale > 1.001)
            }
    }

    private var panGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                guard scale > 1 else { return }
                offset = CGSize(
                    width: settledOffset.width + value.translation.width,
                    height: settledOffset.height + value.translation.height
                )
            }
            .onEnded { _ in settledOffset = offset }
    }

    private func toggleZoom() {
        if scale > 1 {
            scale = 1
            settledScale = 1
            offset = .zero
            settledOffset = .zero
        } else {
            scale = 2
            settledScale = 2
        }
        onZoomChanged(scale > 1.001)
    }
}

enum NativeRemoteMediaPolicy {
    static func isAnimatedImage(_ url: URL) -> Bool {
        ["gif", "webp", "apng"].contains(url.pathExtension.lowercased())
    }
}

struct NativeAnimatedRemoteImage: View {
    let url: URL
    let contentMode: ContentMode

    @StateObject private var loader = NativeAnimatedImageLoader()

    init(url: URL, contentMode: ContentMode = .fit) {
        self.url = url
        self.contentMode = contentMode
    }

    var body: some View {
        Group {
            if let image = loader.image {
                NativeAnimatedUIImageView(image: image, contentMode: contentMode)
                    .aspectRatio(
                        image.size.height > 0 ? image.size.width / image.size.height : 1,
                        contentMode: contentMode
                    )
            } else if loader.didFail {
                ZStack {
                    Color.secondary.opacity(0.12)
                    Image(systemName: "photo.badge.exclamationmark")
                        .foregroundStyle(.secondary)
                }
            } else {
                ZStack {
                    Color.secondary.opacity(0.08)
                    ProgressView()
                }
            }
        }
        .task(id: url) { await loader.load(url) }
        .accessibilityLabel("动图")
    }
}

private struct NativeAnimatedUIImageView: UIViewRepresentable {
    let image: UIImage
    let contentMode: ContentMode

    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView()
        view.clipsToBounds = true
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: UIImageView, context: Context) {
        uiView.contentMode = contentMode == .fill ? .scaleAspectFill : .scaleAspectFit
        guard uiView.image !== image else { return }
        uiView.stopAnimating()
        uiView.image = image
        uiView.startAnimating()
    }
}

@MainActor
private final class NativeAnimatedImageLoader: ObservableObject {
    @Published private(set) var image: UIImage?
    @Published private(set) var didFail = false
    private var loadedURL: URL?

    func load(_ url: URL) async {
        guard loadedURL != url || image == nil else { return }
        loadedURL = url
        image = nil
        didFail = false
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode),
                  data.count <= 40 * 1_024 * 1_024,
                  let decoded = NativeAnimatedImageDecoder.decode(data)
            else { throw URLError(.cannotDecodeContentData) }
            guard loadedURL == url else { return }
            image = decoded
        } catch is CancellationError {
        } catch {
            guard loadedURL == url else { return }
            didFail = true
        }
    }
}

enum NativeAnimatedImageDecoder {
    private static let maximumFrameCount = 60
    private static let maximumTotalPixels = 24_000_000
    private static let maximumPixelSize = 1_600

    static func decode(_ data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let frameCount = CGImageSourceGetCount(source)
        guard frameCount > 1 else { return UIImage(data: data) }

        let stride = max(1, Int(ceil(Double(frameCount) / Double(maximumFrameCount))))
        let decodedFrameCount = Int(ceil(Double(frameCount) / Double(stride)))
        let memoryBoundPixelSize = Int(
            sqrt(Double(maximumTotalPixels) / Double(max(decodedFrameCount, 1)))
        )
        let thumbnailPixelSize = min(maximumPixelSize, max(memoryBoundPixelSize, 320))
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary
        var frames: [UIImage] = []
        frames.reserveCapacity(min(frameCount, maximumFrameCount))
        var duration = 0.0

        for index in 0 ..< frameCount {
            duration += frameDuration(source: source, index: index)
            guard index % stride == 0,
                  let cgImage = CGImageSourceCreateThumbnailAtIndex(source, index, options)
            else { continue }
            frames.append(UIImage(cgImage: cgImage))
        }

        guard !frames.isEmpty else { return nil }
        return UIImage.animatedImage(with: frames, duration: max(duration, 0.1))
    }

    private static func frameDuration(source: CGImageSource, index: Int) -> TimeInterval {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil)
            as? [CFString: Any],
              let gif = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        else { return 0.1 }
        let unclamped = (gif[kCGImagePropertyGIFUnclampedDelayTime] as? NSNumber)?.doubleValue
        let clamped = (gif[kCGImagePropertyGIFDelayTime] as? NSNumber)?.doubleValue
        let value = unclamped ?? clamped ?? 0.1
        return value < 0.02 ? 0.1 : value
    }
}

@MainActor
struct NativeMediaGalleryFeedback {
    let action: NativeHapticFeedbackAction

    func pageDidCommit(from previousIndex: Int, to selectedIndex: Int) {
        guard previousIndex != selectedIndex else { return }
        action(.selection)
    }

    func verticalDismissDidCommit(_ committed: Bool) {
        guard committed else { return }
        action(.dismiss)
    }
}

struct NativeMediaDismissalPolicy {
    static func isVertical(_ translation: CGSize) -> Bool {
        abs(translation.height) > abs(translation.width) * 1.15
    }

    static func shouldDismiss(
        translation: CGSize,
        predictedEndTranslation: CGSize,
        viewportHeight: CGFloat
    ) -> Bool {
        guard isVertical(translation) else { return false }
        let threshold = max(viewportHeight * 0.16, 72)
        return abs(translation.height) >= threshold ||
            abs(predictedEndTranslation.height) >= threshold * 1.35
    }
}

struct NativeMediaPagingPolicy {
    static func targetIndex(
        currentIndex: Int,
        pageCount: Int,
        translationWidth: CGFloat,
        predictedEndTranslationWidth: CGFloat,
        pageWidth: CGFloat
    ) -> Int {
        guard pageCount > 0, pageWidth > 0, pageCount > currentIndex, currentIndex >= 0 else {
            return currentIndex
        }
        let threshold = pageWidth * 0.18
        if (translationWidth <= -threshold || predictedEndTranslationWidth <= -threshold * 1.35),
           currentIndex < pageCount - 1 {
            return currentIndex + 1
        }
        if (translationWidth >= threshold || predictedEndTranslationWidth >= threshold * 1.35),
           currentIndex > 0 {
            return currentIndex - 1
        }
        return currentIndex
    }
}

@MainActor
private final class NativeMediaImageStore: ObservableObject {
    private struct LoadOperation {
        let id = UUID()
        let task: Task<Data, Error>
    }

    @Published private var images: [URL: UIImage] = [:]
    @Published private var failedURLs: Set<URL> = []
    private var operations: [URL: LoadOperation] = [:]

    func image(for url: URL) -> UIImage? { images[url] }
    func didFail(_ url: URL) -> Bool { failedURLs.contains(url) }

    func load(_ url: URL) async {
        guard images[url] == nil else { return }
        let operation: LoadOperation
        if let existing = operations[url] {
            operation = existing
        } else {
            failedURLs.remove(url)
            operation = LoadOperation(task: Task {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard let response = response as? HTTPURLResponse,
                      (200..<300).contains(response.statusCode)
                else { throw URLError(.badServerResponse) }
                return data
            })
            operations[url] = operation
        }
        do {
            let data = try await operation.task.value
            guard let image = UIImage(data: data) else { throw URLError(.cannotDecodeContentData) }
            images[url] = image
            failedURLs.remove(url)
        } catch is CancellationError {
            // A second visible page may still await the shared operation.
        } catch {
            failedURLs.insert(url)
        }
        if operations[url]?.id == operation.id { operations.removeValue(forKey: url) }
    }
}

private enum NativePhotoLibrary {
    static func save(_ image: UIImage) async throws {
        let status = await authorizationStatus()
        guard status == .authorized || status == .limited else {
            throw NativePhotoLibraryError.permissionDenied
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            } completionHandler: { succeeded, error in
                if let error { continuation.resume(throwing: error) }
                else if succeeded { continuation.resume() }
                else { continuation.resume(throwing: NativePhotoLibraryError.saveFailed) }
            }
        }
    }

    private static func authorizationStatus() async -> PHAuthorizationStatus {
        let current = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        guard current == .notDetermined else { return current }
        return await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                continuation.resume(returning: status)
            }
        }
    }
}

private enum NativePhotoLibraryError: Error {
    case permissionDenied
    case saveFailed
}

private struct NativeMediaActivityItems: Identifiable {
    let id = UUID()
    let values: [Any]
}

private struct NativeMediaActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private struct NativeMediaMessage: Identifiable {
    let id = UUID()
    let text: String
}
