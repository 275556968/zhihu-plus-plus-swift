import AppIntents
import Foundation

enum SystemNavigationRequest: Equatable, Sendable {
    case search(query: String?)
    case hot
    case collections
}

struct SystemNavigationRequestEnvelope: Equatable, Sendable {
    let id: UUID
    let request: SystemNavigationRequest

    init(id: UUID = UUID(), request: SystemNavigationRequest) {
        self.id = id
        self.request = request
    }
}

@MainActor
final class SystemNavigationRequestCenter {
    static let shared = SystemNavigationRequestCenter()

    private var pending: SystemNavigationRequestEnvelope?
    private var handler: ((SystemNavigationRequestEnvelope) -> Void)?

    private init() {}

    func submit(_ request: SystemNavigationRequest) {
        let envelope = SystemNavigationRequestEnvelope(request: request)
        if let handler {
            handler(envelope)
        } else {
            pending = envelope
        }
    }

    func installHandler(_ handler: @escaping (SystemNavigationRequestEnvelope) -> Void) {
        self.handler = handler
        if let pending {
            self.pending = nil
            handler(pending)
        }
    }

    func removeHandler() {
        handler = nil
    }

    var pendingRequestForTesting: SystemNavigationRequestEnvelope? { pending }

    func resetForTesting() {
        handler = nil
        pending = nil
    }
}

@available(iOS 16.0, *)
struct OpenZhihuSearchIntent: AppIntent {
    static let title: LocalizedStringResource = "搜索知乎"
    static let description = IntentDescription("打开知乎++并搜索内容")
    static var openAppWhenRun: Bool { true }

    @Parameter(title: "搜索内容")
    var query: String?

    static var parameterSummary: some ParameterSummary {
        Summary("搜索 \(\.$query)")
    }

    func perform() async throws -> some IntentResult {
        let value = query?.trimmingCharacters(in: .whitespacesAndNewlines)
        await MainActor.run {
            SystemNavigationRequestCenter.shared.submit(.search(query: value?.isEmpty == false ? value : nil))
        }
        return .result()
    }
}

@available(iOS 16.0, *)
struct OpenZhihuHotIntent: AppIntent {
    static let title: LocalizedStringResource = "打开热榜"
    static let description = IntentDescription("打开知乎++热榜")
    static var openAppWhenRun: Bool { true }

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            SystemNavigationRequestCenter.shared.submit(.hot)
        }
        return .result()
    }
}

@available(iOS 16.0, *)
struct OpenZhihuCollectionsIntent: AppIntent {
    static let title: LocalizedStringResource = "打开收藏夹"
    static let description = IntentDescription("打开知乎++收藏夹")
    static var openAppWhenRun: Bool { true }

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            SystemNavigationRequestCenter.shared.submit(.collections)
        }
        return .result()
    }
}

@available(iOS 16.0, *)
struct ZhihuPlusAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenZhihuSearchIntent(),
            phrases: ["用 \(.applicationName) 搜索知乎"],
            shortTitle: "搜索知乎",
            systemImageName: "magnifyingglass"
        )
        AppShortcut(
            intent: OpenZhihuHotIntent(),
            phrases: ["用 \(.applicationName) 打开热榜"],
            shortTitle: "打开热榜",
            systemImageName: "flame"
        )
        AppShortcut(
            intent: OpenZhihuCollectionsIntent(),
            phrases: ["用 \(.applicationName) 打开收藏夹"],
            shortTitle: "打开收藏夹",
            systemImageName: "bookmark"
        )
    }
}
