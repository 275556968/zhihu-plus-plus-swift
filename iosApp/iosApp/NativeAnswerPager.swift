import SwiftUI
import UIKit

struct QAReadingPreferences: Equatable {
    let pinAnswerDate: Bool

    init(defaults: UserDefaults = .standard) {
        pinAnswerDate = defaults.bool(forKey: "pinAnswerDate")
    }
}

struct NativeAnswerPager: View {
    @ObservedObject var store: AnswerPagerStore
    let preferences: QAReadingPreferences
    let onNavigate: (QANavigationIntent) -> Void
    @Environment(\.nativeHapticFeedback) private var hapticFeedback

    var body: some View {
        QAAnswerPagerSurface(
            pager: store,
            answer: store.current,
            preferences: preferences,
            hapticFeedback: hapticFeedback,
            onNavigate: onNavigate
        )
        .task { await store.prepare() }
    }
}

private struct QAAnswerPagerSurface: View {
    @ObservedObject var pager: AnswerPagerStore
    @ObservedObject var answer: AnswerStore
    let preferences: QAReadingPreferences
    let hapticFeedback: NativeHapticFeedbackAction
    let onNavigate: (QANavigationIntent) -> Void
    @State private var posterDocument: NativeContentPosterDocument?

    var body: some View {
        ZStack(alignment: .top) {
            QAAnswerPageController(
                pager: pager,
                pinAnswerDate: preferences.pinAnswerDate,
                hapticFeedback: hapticFeedback,
                onNavigate: onNavigate
            )
            if let error = pager.switchError {
                Button {
                    Task { await pager.retrySwitch() }
                } label: {
                    Label("下一个回答加载失败，点此重试", systemImage: "arrow.clockwise")
                        .font(.caption)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.thinMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityHint(error)
                .padding(.top, 8)
            } else if let notice = pager.boundaryNotice {
                Text(notice)
                    .font(.caption)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.thinMaterial, in: Capsule())
                    .accessibilityAddTraits(.isStaticText)
                    .padding(.top, 8)
            }
        }
        .navigationTitle(answer.initialRoute.kind == .answer ? "回答" : "文章")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if let content = answer.content {
                    Menu {
                        Button {
                            UIPasteboard.general.url = content.sourceURL
                        } label: {
                            Label("复制链接", systemImage: "doc.on.doc")
                        }
                        Button {
                            posterDocument = NativeContentPosterDocument(answer: content)
                        } label: {
                            Label("分享内容海报", systemImage: "photo.on.rectangle.angled")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .accessibilityLabel("更多操作")
                }
            }
        }
        .sheet(item: $posterDocument) { document in
            NativeContentPosterShareView(document: document)
        }
        .background(NativeAnswerInteractivePopBridge())
    }
}

struct QAMarkdownTemporaryFile: Equatable {
    let fileURL: URL
    let directoryURL: URL

    func cleanup(fileManager: FileManager = .default) {
        try? fileManager.removeItem(at: directoryURL)
    }
}

enum QAMarkdownTemporaryFileStore {
    static func write(
        contents: String,
        suggestedFileName: String,
        baseDirectory: URL = FileManager.default.temporaryDirectory,
        fileManager: FileManager = .default
    ) throws -> QAMarkdownTemporaryFile {
        let directory = baseDirectory.appendingPathComponent(
            "zhihu-plus-plus-markdown-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        do {
            let rawName = URL(fileURLWithPath: suggestedFileName).lastPathComponent
            let fileName = rawName.lowercased().hasSuffix(".md") ? rawName : "\(rawName).md"
            let fileURL = directory.appendingPathComponent(fileName, isDirectory: false)
            try Data(contents.utf8).write(to: fileURL, options: .atomic)
            return QAMarkdownTemporaryFile(fileURL: fileURL, directoryURL: directory)
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }
    }
}

private struct QAMarkdownSharePresentation: Identifiable {
    let id = UUID()
    let activityItem: Any
    let temporaryFile: QAMarkdownTemporaryFile?

    init(document: QAMarkdownDocument) throws {
        switch QAMarkdownSharePayloadBuilder.payload(for: document) {
        case let .text(markdown):
            activityItem = markdown
            temporaryFile = nil
        case let .file(contents, suggestedFileName):
            let file = try QAMarkdownTemporaryFileStore.write(
                contents: contents,
                suggestedFileName: suggestedFileName
            )
            activityItem = file.fileURL
            temporaryFile = file
        }
    }

    func cleanup() {
        temporaryFile?.cleanup()
    }
}

private struct QAMarkdownActivityView: UIViewControllerRepresentable {
    let presentation: QAMarkdownSharePresentation

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(
            activityItems: [presentation.activityItem],
            applicationActivities: nil
        )
        controller.completionWithItemsHandler = { _, _, _, _ in
            presentation.cleanup()
        }
        return controller
    }

    func updateUIViewController(
        _ uiViewController: UIActivityViewController,
        context: Context
    ) {}
}

private struct NativeAnswerInteractivePopBridge: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> NativeAnswerInteractivePopObserverController {
        NativeAnswerInteractivePopObserverController()
    }

    func updateUIViewController(
        _ uiViewController: NativeAnswerInteractivePopObserverController,
        context: Context
    ) {}
}

final class NativeAnswerInteractivePopObserverController: UIViewController,
    UIGestureRecognizerDelegate
{
    private weak var observedGesture: UIGestureRecognizer?
    private weak var previousDelegate: UIGestureRecognizerDelegate?

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard let navigationController,
              navigationController.viewControllers.count > 1,
              let gesture = navigationController.interactivePopGestureRecognizer
        else { return }
        observeInteractivePopGesture(gesture)
    }

    func observeInteractivePopGesture(_ gesture: UIGestureRecognizer) {
        guard observedGesture == nil,
              gesture.delegate !== self
        else { return }
        observedGesture = gesture
        previousDelegate = gesture.delegate
        gesture.delegate = self
        gesture.isEnabled = true
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        stopObservingInteractivePopGesture()
    }

    func stopObservingInteractivePopGesture() {
        if observedGesture?.delegate === self {
            observedGesture?.delegate = previousDelegate
        }
        observedGesture = nil
        previousDelegate = nil
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard navigationController?.viewControllers.count ?? 0 > 1 else { return false }
        guard let previousDelegate,
              previousDelegate !== self
        else { return true }
        return previousDelegate.gestureRecognizerShouldBegin?(gestureRecognizer) ?? true
    }
}

enum AnswerPagerLayoutDirection: Equatable {
    case leftToRight
    case rightToLeft
}

enum AnswerPagerHorizontalGestureOwner: Equatable {
    case pager
    case systemBack
    case undecided
}

struct AnswerPagerGestureArbitrationPolicy {
    static let horizontalIntentRatio: CGFloat = 1.15
    static let systemLeadingEdgeWidth: CGFloat = 44

    static func isLeadingToTrailing(
        horizontalMovement: CGFloat,
        layoutDirection: AnswerPagerLayoutDirection
    ) -> Bool {
        switch layoutDirection {
        case .leftToRight: horizontalMovement > 0
        case .rightToLeft: horizontalMovement < 0
        }
    }

    static func owner(
        translation: CGPoint,
        velocity: CGPoint,
        startLocationX: CGFloat,
        containerWidth: CGFloat,
        hasPreviousAnswer: Bool,
        canNavigateBack: Bool,
        layoutDirection: AnswerPagerLayoutDirection
    ) -> AnswerPagerHorizontalGestureOwner {
        let movement = abs(velocity.x) > 0.5 || abs(velocity.y) > 0.5
            ? velocity
            : translation
        guard abs(movement.x) > abs(movement.y) * horizontalIntentRatio else {
            return .undecided
        }
        let isLeadingToTrailing = isLeadingToTrailing(
            horizontalMovement: movement.x,
            layoutDirection: layoutDirection
        )
        guard isLeadingToTrailing else { return .pager }
        if canNavigateBack,
           startsInSystemLeadingEdge(
               locationX: startLocationX,
               containerWidth: containerWidth,
               layoutDirection: layoutDirection
           ) {
            return .systemBack
        }
        guard hasPreviousAnswer else {
            return canNavigateBack ? .systemBack : .pager
        }
        return .pager
    }

    static func startsInSystemLeadingEdge(
        locationX: CGFloat,
        containerWidth: CGFloat,
        layoutDirection: AnswerPagerLayoutDirection
    ) -> Bool {
        guard containerWidth > 0 else { return false }
        let clampedLocation = min(max(locationX, 0), containerWidth)
        switch layoutDirection {
        case .leftToRight:
            return clampedLocation <= systemLeadingEdgeWidth
        case .rightToLeft:
            return clampedLocation >= containerWidth - systemLeadingEdgeWidth
        }
    }
}

@MainActor
struct NativeAnswerPagerFeedback {
    let action: NativeHapticFeedbackAction

    func pageDidCommit(_ committed: Bool) {
        guard committed else { return }
        action(.selection)
    }

    func forwardBoundaryDidPublish(_ published: Bool) {
        guard published else { return }
        action(.navigationBoundary)
    }
}

private struct QAAnswerPageController: UIViewControllerRepresentable {
    @ObservedObject var pager: AnswerPagerStore
    let pinAnswerDate: Bool
    let hapticFeedback: NativeHapticFeedbackAction
    let onNavigate: (QANavigationIntent) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            pager: pager,
            pinAnswerDate: pinAnswerDate,
            hapticFeedback: hapticFeedback,
            onNavigate: onNavigate
        )
    }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let controller = UIPageViewController(
            transitionStyle: .scroll,
            navigationOrientation: .horizontal
        )
        controller.dataSource = context.coordinator
        controller.delegate = context.coordinator
        controller.view.backgroundColor = .systemBackground
        controller.setViewControllers(
            [context.coordinator.controller(for: pager.current)],
            direction: .forward,
            animated: false
        )
        context.coordinator.recordPagingAvailability()
        DispatchQueue.main.async {
            context.coordinator.establishSystemEdgePrecedence(in: controller)
        }
        return controller
    }

    func updateUIViewController(_ controller: UIPageViewController, context: Context) {
        context.coordinator.pager = pager
        context.coordinator.onNavigate = onNavigate
        context.coordinator.updatePinAnswerDate(pinAnswerDate)
        context.coordinator.feedback = NativeAnswerPagerFeedback(action: hapticFeedback)
        context.coordinator.establishSystemEdgePrecedence(in: controller)
        guard let visible = controller.viewControllers?.first as? QAHostedAnswerController else { return }
        if visible.answerID != pager.current.id, !context.coordinator.isTransitioning {
            controller.setViewControllers(
                [context.coordinator.controller(for: pager.current)],
                direction: .forward,
                animated: false
            )
            context.coordinator.recordPagingAvailability()
        } else {
            context.coordinator.refreshPagingAvailabilityIfNeeded(in: controller, visible: visible)
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate,
        UIGestureRecognizerDelegate
    {
        var pager: AnswerPagerStore
        var pinAnswerDate: Bool
        var feedback: NativeAnswerPagerFeedback
        var onNavigate: (QANavigationIntent) -> Void
        var isTransitioning = false
        private var controllers: [Int64: QAHostedAnswerController] = [:]
        private weak var relatedNavigationController: UINavigationController?
        private weak var relatedPagingPan: UIPanGestureRecognizer?
        private weak var pagingPanGesture: UIPanGestureRecognizer?
        private weak var pageController: UIPageViewController?
        private weak var pagingScrollView: UIScrollView?
        private var contentPopGate: UIPanGestureRecognizer?
        private var recordedCurrentID: Int64?
        private var recordedPreviousID: Int64?
        private var recordedNextID: Int64?

        init(
            pager: AnswerPagerStore,
            pinAnswerDate: Bool,
            hapticFeedback: NativeHapticFeedbackAction,
            onNavigate: @escaping (QANavigationIntent) -> Void
        ) {
            self.pager = pager
            self.pinAnswerDate = pinAnswerDate
            feedback = NativeAnswerPagerFeedback(action: hapticFeedback)
            self.onNavigate = onNavigate
        }

        func controller(for store: AnswerStore) -> QAHostedAnswerController {
            if let cached = controllers[store.id] { return cached }
            let root = hostedRoot(for: store)
            let created = QAHostedAnswerController(answerID: store.id, rootView: root)
            created.view.backgroundColor = .systemBackground
            controllers[store.id] = created
            return created
        }

        func refreshHostedRoots() {
            for controller in controllers.values {
                controller.rootView = hostedRoot(for: controller.rootView.store)
            }
        }

        func updatePinAnswerDate(_ value: Bool) {
            guard pinAnswerDate != value else { return }
            pinAnswerDate = value
            refreshHostedRoots()
        }

        func recordPagingAvailability() {
            recordedCurrentID = pager.current.id
            recordedPreviousID = pager.previous?.id
            recordedNextID = pager.next?.id
        }

        func refreshPagingAvailabilityIfNeeded(
            in pageController: UIPageViewController,
            visible: QAHostedAnswerController
        ) {
            let availabilityChanged = recordedCurrentID != pager.current.id ||
                recordedPreviousID != pager.previous?.id ||
                recordedNextID != pager.next?.id
            guard !isTransitioning,
                  visible.answerID == pager.current.id,
                  availabilityChanged,
                  pagingPanGesture?.state != .began,
                  pagingPanGesture?.state != .changed
            else { return }
            pageController.setViewControllers(
                [visible],
                direction: .forward,
                animated: false
            )
            recordPagingAvailability()
        }

        private func hostedRoot(for store: AnswerStore) -> AnswerNativeView {
            AnswerNativeView(
                store: store,
                pinAnswerDate: pinAnswerDate,
                onNavigate: { [weak self] intent in self?.onNavigate(intent) }
            )
        }

        func establishSystemEdgePrecedence(in pageController: UIPageViewController) {
            self.pageController = pageController
            guard let pagingScrollView = pageController.view.subviews
                .compactMap({ $0 as? UIScrollView })
                .first
            else { return }
            self.pagingScrollView = pagingScrollView
            pagingScrollView.isScrollEnabled = true
            let pagePan = pagingScrollView.panGestureRecognizer

            if pagingPanGesture !== pagePan {
                pagingPanGesture?.removeTarget(self, action: #selector(handlePagePan(_:)))
                pagePan.addTarget(self, action: #selector(handlePagePan(_:)))
                pagingPanGesture = pagePan
            }

            guard let navigationController = pageController.navigationController,
                  let interactivePop = navigationController.interactivePopGestureRecognizer
            else { return }
            guard relatedNavigationController !== navigationController || relatedPagingPan !== pagePan else { return }
            if navigationController.viewControllers.count > 1 {
                interactivePop.isEnabled = true
            }
            pagePan.require(toFail: interactivePop)
            relatedNavigationController = navigationController
            relatedPagingPan = pagePan
        }

        private func makeContentPopGate(in scrollView: UIScrollView) -> UIPanGestureRecognizer {
            let gate = UIPanGestureRecognizer(target: nil, action: nil)
            gate.delegate = self
            gate.cancelsTouchesInView = false
            gate.delaysTouchesBegan = false
            gate.delaysTouchesEnded = false
            gate.name = "zhpp.answer-pager-content-pop-gate"
            scrollView.addGestureRecognizer(gate)
            contentPopGate = gate
            return gate
        }

        func tearDownGestureCoordination() {
            pagingPanGesture?.removeTarget(self, action: #selector(handlePagePan(_:)))
            if let gate = contentPopGate {
                gate.view?.removeGestureRecognizer(gate)
            }
            contentPopGate = nil
            pagingPanGesture = nil
            relatedPagingPan = nil
            relatedNavigationController = nil
        }

        @objc private func handlePagePan(_ gesture: UIPanGestureRecognizer) {
            guard gesture.state == .ended || gesture.state == .cancelled else { return }
            defer {
                if let pageController,
                   let visible = pageController.viewControllers?.first as? QAHostedAnswerController
                {
                    refreshPagingAvailabilityIfNeeded(in: pageController, visible: visible)
                }
            }
            guard gesture.state == .ended else { return }
            let translation = gesture.translation(in: gesture.view)
            guard abs(translation.x) > 72, abs(translation.x) > abs(translation.y),
                  pager.current.initialRoute.kind == .answer
            else { return }
            let layoutDirection: AnswerPagerLayoutDirection =
                gesture.view?.effectiveUserInterfaceLayoutDirection == .rightToLeft
                ? .rightToLeft
                : .leftToRight
            let isForward = !AnswerPagerGestureArbitrationPolicy.isLeadingToTrailing(
                horizontalMovement: translation.x,
                layoutDirection: layoutDirection
            )
            if isForward, case .end = pager.forwardAvailability {
                feedback.forwardBoundaryDidPublish(pager.reportForwardBoundaryReached())
            }
        }

        func pageViewController(
            _ pageViewController: UIPageViewController,
            viewControllerBefore viewController: UIViewController
        ) -> UIViewController? {
            guard let visible = viewController as? QAHostedAnswerController,
                  visible.answerID == pager.current.id
            else { return nil }
            if let previous = pager.previous {
                return controller(for: previous)
            }
            return nil
        }

        func pageViewController(
            _ pageViewController: UIPageViewController,
            viewControllerAfter viewController: UIViewController
        ) -> UIViewController? {
            guard let visible = viewController as? QAHostedAnswerController,
                  visible.answerID == pager.current.id,
                  let next = pager.next
            else { return nil }
            return controller(for: next)
        }

        func pageViewController(
            _ pageViewController: UIPageViewController,
            willTransitionTo pendingViewControllers: [UIViewController]
        ) {
            isTransitioning = true
        }

        func pageViewController(
            _ pageViewController: UIPageViewController,
            didFinishAnimating finished: Bool,
            previousViewControllers: [UIViewController],
            transitionCompleted completed: Bool
        ) {
            isTransitioning = false
            guard completed, let visible = pageViewController.viewControllers?.first else { return }
            guard let visible = visible as? QAHostedAnswerController else { return }
            let committed = pager.commitDisplayedAnswer(answerID: visible.answerID)
            feedback.pageDidCommit(committed)
            guard committed else { return }
            recordPagingAvailability()
            Task { await pager.prepareDisplayedAnswer() }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard gestureRecognizer === contentPopGate,
                  let pan = gestureRecognizer as? UIPanGestureRecognizer,
                  let view = pan.view
            else { return true }
            return gestureOwner(for: pan, in: view) == .pager
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            guard gestureRecognizer === contentPopGate || otherGestureRecognizer === contentPopGate else {
                return false
            }
            let peer = gestureRecognizer === contentPopGate ? otherGestureRecognizer : gestureRecognizer
            guard peer === pagingPanGesture,
                  let gate = contentPopGate,
                  let view = gate.view
            else { return false }
            return gestureOwner(for: gate, in: view) == .pager
        }

        private func gestureOwner(
            for gesture: UIPanGestureRecognizer,
            in view: UIView
        ) -> AnswerPagerHorizontalGestureOwner {
            let referenceView = pageController?.navigationController?.view ?? view
            let direction: AnswerPagerLayoutDirection =
                referenceView.effectiveUserInterfaceLayoutDirection == .rightToLeft
                ? .rightToLeft
                : .leftToRight
            let translation = gesture.translation(in: referenceView)
            let currentLocation = gesture.location(in: referenceView)
            return AnswerPagerGestureArbitrationPolicy.owner(
                translation: translation,
                velocity: gesture.velocity(in: referenceView),
                startLocationX: currentLocation.x - translation.x,
                containerWidth: referenceView.bounds.width,
                hasPreviousAnswer: pager.previous != nil,
                canNavigateBack: (pageController?.navigationController?.viewControllers.count ?? 0) > 1,
                layoutDirection: direction
            )
        }
    }

    static func dismantleUIViewController(
        _ uiViewController: UIPageViewController,
        coordinator: Coordinator
    ) {
        coordinator.tearDownGestureCoordination()
    }
}

private final class QAHostedAnswerController: UIHostingController<AnswerNativeView> {
    let answerID: Int64

    init(answerID: Int64, rootView: AnswerNativeView) {
        self.answerID = answerID
        super.init(rootView: rootView)
    }

    @MainActor required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
