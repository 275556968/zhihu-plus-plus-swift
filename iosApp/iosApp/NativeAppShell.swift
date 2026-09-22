import CoreSpotlight
import SwiftUI
import UIKit

enum NativeShellRoute: Hashable {
    case answer(AnswerRouteDTO)
    case question(QuestionRouteDTO)
    case person(PersonRoutePayload)
    case personConnections(PersonConnectionsRoute)
    case personWeb(PersonWebRoute)
    case pin(PinRouteDTO)
    case video(NativeVideoRouteDTO)
    case comments(CommentThreadRouteDTO)
    case search(SearchRouteDTO)
    case hotList
    case writeAnswer(WriteAnswerRouteDTO)
    case writePin
    case account
    case collections(userToken: String)
    case collectionContent(String)
    case special(String)
    case column(String)
    case history
    case notifications
    case notificationSettings
    case settings
    case systemAndUpdate

    var diagnosticRouteType: String {
        switch self {
        case .answer: return "answer"
        case .question: return "question"
        case .person: return "person"
        case .personConnections: return "person_connections"
        case .personWeb: return "person_web"
        case .pin: return "pin"
        case .video: return "video"
        case .comments: return "comments"
        case .search: return "search"
        case .hotList: return "hot_list"
        case .writeAnswer: return "write_answer"
        case .writePin: return "write_pin"
        case .account: return "account"
        case .collections: return "collections"
        case .collectionContent: return "collection_content"
        case .special: return "special"
        case .column: return "column"
        case .history: return "history"
        case .notifications: return "notifications"
        case .notificationSettings: return "notification_settings"
        case .settings: return "settings"
        case .systemAndUpdate: return "system_and_update"
        }
    }
}

enum NativeHotSystemNavigationTarget: Equatable {
    case homeChannel
    case hotList(tab: NativeAppTab)
}

enum NativeHotSystemNavigationPolicy {
    static func target(
        selectedTabs: [NativeAppTab],
        currentTab: NativeAppTab,
        startTab: NativeAppTab
    ) -> NativeHotSystemNavigationTarget? {
        if selectedTabs.contains(.home) { return .homeChannel }
        if selectedTabs.contains(currentTab) { return .hotList(tab: currentTab) }
        if selectedTabs.contains(startTab) { return .hotList(tab: startTab) }
        return selectedTabs.first.map { .hotList(tab: $0) }
    }
}

struct NativeSearchTabNavigationTarget: Equatable {
    let tab: NativeAppTab
    let route: SearchRouteDTO

    init(query: String?) {
        tab = .search
        route = SearchRouteDTO(query: query ?? "")
    }
}

struct NativeTabTapEvent: Equatable {
    let tab: NativeAppTab
    let timestamp: TimeInterval
}

struct NativeSearchFocusRequest: Equatable {
    let token: UInt
    let isActive: Bool

    static let inactive = Self(token: 0, isActive: false)
}

enum NativeSearchFocusRequestPolicy {
    static func nextToken(after current: UInt) -> UInt {
        let next = current &+ 1
        return next == 0 ? 1 : next
    }

    static func shouldConsume(
        _ request: NativeSearchFocusRequest,
        lastConsumedToken: UInt
    ) -> Bool {
        guard request.isActive, request.token != 0 else { return false }
        if lastConsumedToken == 0 { return true }
        let forwardDistance = request.token &- lastConsumedToken
        return forwardDistance > 0 && forwardDistance <= UInt.max / 2
    }

    static func pushedRouteRequest(_ route: SearchRouteDTO) -> NativeSearchFocusRequest {
        guard route.isMemberRestricted, route.query.isEmpty else {
            return .inactive
        }
        return NativeSearchFocusRequest(token: 1, isActive: true)
    }

    static func shouldRequestForTabSelection(
        previous: NativeAppTab,
        next: NativeAppTab,
        isSearchRoot: Bool
    ) -> Bool {
        previous != .search && next == .search && isSearchRoot
    }

    static func shouldRequestForTabReselection(
        tab: NativeAppTab,
        isSearchRoot: Bool
    ) -> Bool {
        tab == .search && isSearchRoot
    }
}

enum NativeTabReselectPolicy {
    static func isReselect(
        tappedTab: NativeAppTab,
        selectedTabAtTouchBegan: NativeAppTab?
    ) -> Bool {
        tappedTab == selectedTabAtTouchBegan
    }
}

struct NativeHomeTabDoubleTapGate {
    let maximumInterval: TimeInterval
    private var firstTapAt: TimeInterval?

    init(maximumInterval: TimeInterval = 0.45) {
        self.maximumInterval = maximumInterval
    }

    mutating func register(
        _ event: NativeTabTapEvent,
        isHomeSelected: Bool,
        isHomeRoot: Bool,
        isAppUnlocked: Bool
    ) -> Bool {
        guard event.tab == .home,
              isHomeSelected,
              isHomeRoot,
              isAppUnlocked
        else {
            cancel()
            return false
        }

        guard let firstTapAt,
              event.timestamp >= firstTapAt,
              event.timestamp - firstTapAt <= maximumInterval
        else {
            firstTapAt = event.timestamp
            return false
        }

        self.firstTapAt = nil
        return true
    }

    mutating func cancel() {
        firstTapAt = nil
    }
}

extension PersonNavigationIntent {
    var nativeShellRoute: NativeShellRoute {
        switch self {
        case let .article(route):
            return .answer(.init(contentID: route.id, kind: route.kind == .answer ? .answer : .article))
        case let .question(id): return .question(.init(questionID: id))
        case let .pin(id): return .pin(.init(pinID: id))
        case let .collection(id): return .collectionContent(id)
        case let .person(payload): return .person(payload)
        case let .connections(route): return .personConnections(route)
        case let .search(route): return .search(route)
        case let .web(route): return .personWeb(route)
        }
    }
}

@MainActor
final class NativeTabNavigationState: ObservableObject {
    @Published private var paths: [NativeAppTab: [NativeShellRoute]] = [:]
    private let diagnostics: PerformanceDiagnosticsClient

    init(diagnostics: PerformanceDiagnosticsClient = .disabled) {
        self.diagnostics = diagnostics
    }

    func binding(for tab: NativeAppTab) -> Binding<[NativeShellRoute]> {
        Binding(
            get: { self.paths[tab] ?? [] },
            set: { newPath in
                let oldPath = self.paths[tab] ?? []
                if newPath.count < oldPath.count {
                    for route in oldPath.dropFirst(newPath.count).reversed() {
                        self.record(route, operation: "pop")
                    }
                }
                self.paths[tab] = newPath
            }
        )
    }

    func navigate(to route: NativeShellRoute, in tab: NativeAppTab) {
        var path = paths[tab] ?? []
        if path.last != route {
            path.append(route)
            record(route, operation: "push")
        }
        paths[tab] = path
    }

    func replaceTop(with route: NativeShellRoute, in tab: NativeAppTab) {
        var path = paths[tab] ?? []
        if !path.isEmpty { path.removeLast() }
        path.append(route)
        paths[tab] = path
        record(route, operation: "replace")
    }

    func isAtRoot(in tab: NativeAppTab) -> Bool {
        paths[tab, default: []].isEmpty
    }

    func reset(in tab: NativeAppTab) { paths[tab] = [] }

    func resetAll() { paths.removeAll() }

    private func record(_ route: NativeShellRoute, operation: String) {
        diagnostics.record(.init(
            category: "navigation",
            operation: operation,
            result: .success,
            routeType: route.diagnosticRouteType
        ))
    }
}

private struct NativeMediaPresentation: Identifiable, Hashable {
    let id = UUID()
    let urls: [URL]
    let initialIndex: Int
}

@available(iOS 16.0, *)
struct NativeAppShell: View {
    let hostModel: HostModel
    let isAppUnlocked: Bool
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var preferences: NativeShellPreferences
    @ObservedObject private var account: NativeAccountStore
    @ObservedObject private var notifications: NativeNotificationStore
    @ObservedObject private var notificationPreferences: NativeNotificationPreferences

    @StateObject private var navigation: NativeTabNavigationState
    @StateObject private var recommendationStore: HomeFeedNativeStore
    @StateObject private var followingStore: FollowNativeStore
    @StateObject private var hotStore: HotFeedStore
    @StateObject private var dailyStore: DailyNativeStore
    @StateObject private var clipboardLinkMonitor = NativeClipboardZhihuLinkMonitor()
    @State private var selectedTab: NativeAppTab
    @State private var selectedHomeChannelID: HomeChannel.ID
    @State private var mediaPresentation: NativeMediaPresentation?
    @State private var shareURL: URL?
    @State private var pendingShareChoiceURL: URL?
    @State private var showsCopiedLinkConfirmation = false
    @State private var homeTabDoubleTapGate = NativeHomeTabDoubleTapGate()
    @State private var homeDoubleTapRefreshRequest: UInt = 0
    @State private var searchRootRoute = SearchRouteDTO()
    @State private var searchFocusRequestToken: UInt = 0
    @State private var clipboardInspectionArmed = false

    init(hostModel: HostModel, isAppUnlocked: Bool) {
        self.hostModel = hostModel
        self.isAppUnlocked = isAppUnlocked
        _preferences = ObservedObject(wrappedValue: hostModel.preferences)
        _account = ObservedObject(wrappedValue: hostModel.account)
        _notifications = ObservedObject(wrappedValue: hostModel.notifications)
        _notificationPreferences = ObservedObject(wrappedValue: hostModel.notificationPreferences)
        _navigation = StateObject(wrappedValue: NativeTabNavigationState(
            diagnostics: hostModel.performanceDiagnostics.client
        ))
        _recommendationStore = StateObject(wrappedValue: HomeFeedNativeStore(
            repository: hostModel.homeRepository,
            configuration: {
                hostModel.preferences.homeRecommendationRefreshConfiguration
            },
            cachePersistence: hostModel.homeRecommendationCachePersistence,
            cacheAccountID: {
                hostModel.account.identity?.id
            },
            diagnostics: hostModel.performanceDiagnostics.client
        ))
        _followingStore = StateObject(wrappedValue: FollowNativeStore(repository: hostModel.followRepository))
        _hotStore = StateObject(wrappedValue: HotFeedStore(repository: hostModel.hotRepository))
        _dailyStore = StateObject(wrappedValue: DailyNativeStore(repository: hostModel.dailyRepository))
        _selectedTab = State(initialValue: hostModel.preferences.startTab)
        _selectedHomeChannelID = State(initialValue: HomeChannel.recommendation.id)
    }

    var body: some View {
        tabBarBehavior(
            appTabView
        )
        .background(
            NativeTabTapObserver(
                isEnabled: true,
                tabs: NativeAppTab.fixedBottomBarTabs,
                selectedTab: selectedTab,
                onTap: handleTabTap
            )
            .frame(width: 0, height: 0)
        )
        .preferredColorScheme(preferences.themeMode.colorScheme)
        .sheet(item: Binding(
            get: { shareURL.map(NativeSharePresentation.init) },
            set: { if $0 == nil { shareURL = nil } }
        )) { presentation in
            NativeShareSheet(items: [presentation.url])
        }
        .confirmationDialog(
            "分享链接",
            isPresented: Binding(
                get: { pendingShareChoiceURL != nil },
                set: { if !$0 { pendingShareChoiceURL = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("系统分享") {
                shareURL = pendingShareChoiceURL
                pendingShareChoiceURL = nil
            }
            Button("复制链接") {
                guard let url = pendingShareChoiceURL else { return }
                pendingShareChoiceURL = nil
                copyShareURL(url)
            }
            Button("取消", role: .cancel) { pendingShareChoiceURL = nil }
        }
        .alert("链接已复制", isPresented: $showsCopiedLinkConfirmation) {
            Button("好", role: .cancel) {}
        }
        .alert(item: $clipboardLinkMonitor.candidate) { candidate in
            Alert(
                title: Text("发现知乎链接"),
                message: Text("是否在知乎++中打开？"),
                primaryButton: .default(Text("打开")) {
                    clipboardLinkMonitor.candidate = nil
                    openContent(candidate.destination)
                },
                secondaryButton: .cancel(Text("取消")) {
                    clipboardLinkMonitor.candidate = nil
                }
            )
        }
        .fullScreenCover(item: $mediaPresentation) { presentation in
            NativeMediaGallery(urls: presentation.urls, initialIndex: presentation.initialIndex)
        }
        .onChange(of: selectedTab) { _ in
            homeTabDoubleTapGate.cancel()
        }
        .onChange(of: navigation.isAtRoot(in: .home)) { isAtHomeRoot in
            if !isAtHomeRoot { homeTabDoubleTapGate.cancel() }
        }
        .onChange(of: isAppUnlocked) { isUnlocked in
            if !isUnlocked { homeTabDoubleTapGate.cancel() }
            if isUnlocked, scenePhase == .active {
                inspectClipboardAfterActivationIfNeeded()
            }
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active:
                inspectClipboardAfterActivationIfNeeded()
            case .inactive, .background:
                clipboardInspectionArmed = true
            @unknown default:
                clipboardInspectionArmed = true
            }
        }
        .onChange(of: account.identity.map { "\($0.id)|\($0.urlToken ?? "")" }) { _ in
            navigation.resetAll()
            recommendationStore.accountDidChange()
            followingStore.accountDidChange()
            hotStore.accountDidChange()
            dailyStore.accountDidChange()
            notifications.accountDidChange()
            Task {
                switch HomeChannel(rawValue: selectedHomeChannelID) ?? .recommendation {
                case .recommendation:
                    await recommendationStore.loadInitialIfNeeded()
                case .following:
                    await followingStore.loadInitialIfNeeded()
                case .hot:
                    await hotStore.loadInitialIfNeeded()
                case .daily:
                    await dailyStore.loadInitialIfNeeded()
                }
                if account.isSignedIn {
                    await notifications.refresh()
                }
            }
        }
        .onChange(of: preferences.homeRecommendationSource) { _ in
            Task { await recommendationStore.recommendationSourceDidChange() }
        }
        .task {
            if case .loading = account.state { account.reloadFromKeychain() }
            if account.isSignedIn { await notifications.refreshUnreadCounts() }
            SystemNavigationRequestCenter.shared.installHandler(handleSystemNavigation)
            clipboardInspectionArmed = true
            inspectClipboardAfterActivationIfNeeded()
        }
        .onDisappear { SystemNavigationRequestCenter.shared.removeHandler() }
        .onContinueUserActivity(CSSearchableItemActionType) { activity in
            guard let identifier = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
                  let route = SpotlightRouteCodec.route(fromSearchableItemIdentifier: identifier)
            else { return }
            openContent(route.nativeDestination)
        }
        .environment(\.nativeContentPresentation, preferences.contentPresentation)
        .environment(\.nativeSearchPresentation, preferences.searchPresentation)
        .environment(
            \.nativeHapticFeedback,
            .live(configuration: preferences.hapticFeedbackConfiguration)
        )
        .environmentObject(hostModel.questionAuthorBlocklist)
    }

    @ViewBuilder
    private var appTabView: some View {
        TabView(selection: tabSelection) {
            ForEach(NativeAppTab.fixedBottomBarTabs) { tab in
                tabNavigationStack(for: tab)
                    .tabItem { Label(tab.title, systemImage: tab.systemImage) }
                    .tag(tab)
            }
        }
    }

    private var tabSelection: Binding<NativeAppTab> {
        Binding(
            get: { selectedTab },
            set: { nextTab in
                let previousTab = selectedTab
                selectedTab = nextTab
                if NativeSearchFocusRequestPolicy.shouldRequestForTabSelection(
                    previous: previousTab,
                    next: nextTab,
                    isSearchRoot: navigation.isAtRoot(in: .search)
                ) {
                    requestSearchFocus()
                }
            }
        )
    }

    private func tabNavigationStack(for tab: NativeAppTab) -> some View {
        NavigationStack(path: navigation.binding(for: tab)) {
            rootContent(for: tab)
                .toolbar(navigation.isAtRoot(in: tab) ? .visible : .hidden, for: .tabBar)
                .navigationDestination(for: NativeShellRoute.self) { destination($0, in: tab) }
        }
    }

    @ViewBuilder
    private func rootContent(for tab: NativeAppTab) -> some View {
        switch tab {
        case .home:
            HomeChannelsNativeView(
                selectedChannelID: $selectedHomeChannelID,
                recommendationStore: recommendationStore,
                followingStore: followingStore,
                hotStore: hotStore,
                dailyStore: dailyStore,
                doubleTapRefreshRequest: homeDoubleTapRefreshRequest,
                isOperationallyVisible: isAppUnlocked
                    && selectedTab == .home
                    && navigation.isAtRoot(in: .home),
                notificationUnreadCount: notifications.unreadCount,
                onOpenFeed: openFeed,
                onOpenPerson: { navigate(.person($0)) },
                onOpenDaily: { handleDailyDestination($0, in: .home) },
                onOpenCreation: { navigate(.writePin) },
                onOpenNotifications: { navigate(.notifications) }
            )
        case .follow, .hot, .daily:
            EmptyView()
        case .history:
            if account.isSignedIn {
                NativeHistoryView(repository: hostModel.libraryRepository, onOpenContent: openContent)
            } else {
                NativeSignedOutLibraryView(title: "登录后查看浏览历史", openLogin: hostModel.openLogin)
            }
        case .collections:
            if let token = account.identity?.collectionToken {
                NativeCollectionsView(
                    userToken: token,
                    repository: hostModel.libraryRepository,
                    onOpenContent: openContent
                )
            } else {
                NativeSignedOutLibraryView(title: "登录后查看收藏夹", openLogin: hostModel.openLogin)
            }
        case .account:
            NativeAccountView(store: account, actions: accountActions)
        case .search:
            SearchNativeView(
                route: searchRootRoute,
                repository: hostModel.searchRepository,
                focusRequest: NativeSearchFocusRequest(
                    token: searchFocusRequestToken,
                    isActive: isAppUnlocked
                        && selectedTab == .search
                        && navigation.isAtRoot(in: .search)
                ),
                onOpen: openFeed
            )
            .id(searchRootRoute)
        }
    }

    @ViewBuilder
    private func destination(_ route: NativeShellRoute, in tab: NativeAppTab) -> some View {
        Group {
            switch route {
            case let .answer(route):
                ArticleHostView(
                    route: route,
                    repository: hostModel.questionAnswerRepository,
                    openedHistory: hostModel.answerOpenedHistory,
                    diagnostics: hostModel.performanceDiagnostics.client,
                    onNavigate: { handleQAIntent($0, in: tab) }
                )
        case let .question(route):
            NativeQuestionRouteView(
                route: route,
                repository: hostModel.questionAnswerRepository,
                onNavigate: { handleQAIntent($0, in: tab) }
            )
        case let .person(payload):
            NativePersonRouteView(
                payload: payload,
                accountStore: hostModel.accountStore,
                diagnostics: hostModel.performanceDiagnostics.client,
                onNavigate: { handlePersonIntent($0, in: tab) }
            )
        case let .personConnections(route):
            NativePersonConnectionsRouteView(
                route: route,
                accountStore: hostModel.accountStore,
                diagnostics: hostModel.performanceDiagnostics.client,
                onNavigate: { handlePersonIntent($0, in: tab) }
            )
        case let .personWeb(route):
            PersonWebDestinationView(
                route: route,
                accountStore: hostModel.accountStore,
                openExternal: hostModel.openExternal
            )
        case let .pin(route):
            PinNativeView(
                route: route,
                repository: hostModel.pinRepository,
                onOpenPerson: { navigate(.person($0), in: tab) },
                onOpenLink: handlePinLink,
                onOpenComments: {
                    navigate(.comments(.init(subject: .pin($0))), in: tab)
                }
            )
        case let .video(route):
            NativeVideoPlayerScreen(
                route: route,
                repository: hostModel.videoRepository,
                openExternal: hostModel.openExternal
            )
        case let .comments(route):
            NativeCommentNavigationRouteView(
                route: route,
                accountStore: hostModel.accountStore,
                onPersonNavigate: { handlePersonIntent($0, in: tab) }
            )
        case let .search(route):
            SearchNativeView(
                route: route,
                repository: hostModel.searchRepository,
                focusRequest: NativeSearchFocusRequestPolicy.pushedRouteRequest(route),
                onOpen: openFeed
            )
        case .hotList:
            HotListNativeView(store: hotStore, onOpen: openFeed)
        case let .writeAnswer(route):
            WriteAnswerNativeView(
                route: route,
                repository: hostModel.creationRepository,
                onSystemIntent: handleCreationIntent,
                onPublished: { navigation.replaceTop(with: .answer(.init(
                    contentID: $0,
                    kind: .answer,
                    questionID: route.questionID,
                    provisionalTitle: route.questionTitle
                )), in: tab) }
            )
        case .writePin:
            WritePinNativeView(
                repository: hostModel.creationRepository,
                onSystemIntent: handleCreationIntent,
                onPublished: { navigation.replaceTop(with: .pin(.init(pinID: $0)), in: tab) }
            )
        case .account:
            NativeAccountView(store: account, actions: accountActions)
        case let .collections(token):
            NativeCollectionsView(userToken: token, repository: hostModel.libraryRepository, onOpenContent: openContent)
        case let .collectionContent(id):
            NativeCollectionContentView(collectionID: id, repository: hostModel.libraryRepository, onOpenContent: openContent)
        case let .special(id):
            NativeSpecialView(
                specialID: id,
                repository: hostModel.specialRepository,
                onOpenContent: { openFeed($0, in: tab) }
            )
        case let .column(id):
            NativeColumnView(
                columnID: id,
                repository: hostModel.columnRepository,
                onOpenContent: openContent
            )
        case .history:
            NativeHistoryView(repository: hostModel.libraryRepository, onOpenContent: openContent)
        case .notifications:
            NativeNotificationsView(store: notifications, preferences: notificationPreferences, onOpenContent: openContent)
        case .notificationSettings:
            NativeNotificationSettingsView(preferences: notificationPreferences)
        case .settings:
            NativeSettingsView(
                preferences: preferences,
                notificationPreferences: notificationPreferences,
                systemSettings: hostModel.systemSettings,
                appLock: hostModel.appLock,
                performanceDiagnostics: hostModel.performanceDiagnostics,
                setAppLock: hostModel.setAppLock
            )
            case .systemAndUpdate:
                SystemAndUpdateView(openExternalLink: hostModel.openSystemExternalLink)
            }
        }
        .toolbar(.hidden, for: .tabBar)
    }

    private var accountActions: NativeAccountActions {
        NativeAccountActions(
            openLogin: hostModel.openLogin,
            openQrAuthorization: hostModel.openQrAuthorization,
            openProfile: { identity in
                guard let payload = PersonRoutePayload(
                    memberID: identity.id,
                    urlToken: identity.urlToken,
                    displayName: identity.name,
                    initialTab: .activities
                ) else { return }
                navigate(.person(payload))
            }
        )
    }

    private func navigate(_ route: NativeShellRoute, in tab: NativeAppTab? = nil) {
        navigation.navigate(to: route, in: tab ?? selectedTab)
    }

    private func handleTabTap(_ event: NativeTabTapEvent) {
        if NativeSearchFocusRequestPolicy.shouldRequestForTabReselection(
            tab: event.tab,
            isSearchRoot: navigation.isAtRoot(in: .search)
        ) {
            requestSearchFocus()
        }

        guard preferences.topLevelReselectEnabled else {
            homeTabDoubleTapGate.cancel()
            return
        }
        let shouldRefreshHome = homeTabDoubleTapGate.register(
            event,
            isHomeSelected: selectedTab == .home,
            isHomeRoot: navigation.isAtRoot(in: .home),
            isAppUnlocked: isAppUnlocked
        )
        guard shouldRefreshHome else { return }
        homeDoubleTapRefreshRequest &+= 1
    }

    private func requestSearchFocus() {
        searchFocusRequestToken = NativeSearchFocusRequestPolicy.nextToken(
            after: searchFocusRequestToken
        )
    }

    private func inspectClipboardAfterActivationIfNeeded() {
        guard clipboardInspectionArmed, isAppUnlocked else { return }
        clipboardInspectionArmed = false
        Task { await clipboardLinkMonitor.inspectIfNeeded() }
    }

    private func openFeed(_ route: FeedItemRoute) {
        openFeed(route, in: selectedTab)
    }

    private func openFeed(_ route: FeedItemRoute, in tab: NativeAppTab) {
        switch route {
        case let .answer(id, questionID, title):
            navigate(.answer(.init(contentID: id, kind: .answer, questionID: questionID, provisionalTitle: title)), in: tab)
        case let .article(id, title):
            navigate(.answer(.init(contentID: id, kind: .article, provisionalTitle: title)), in: tab)
        case let .question(id, title):
            navigate(.question(.init(questionID: id, provisionalTitle: title)), in: tab)
        case let .pin(id):
            navigate(.pin(.init(pinID: id)), in: tab)
        case let .video(route):
            navigate(.video(route), in: tab)
        }
    }

    private func openContent(_ destination: NativeContentDestination) {
        switch destination {
        case let .article(id, kind):
            navigate(.answer(.init(contentID: id, kind: kind == .answer ? .answer : .article)))
        case let .question(id): navigate(.question(.init(questionID: id)))
        case let .person(id, token, name):
            if let payload = PersonRoutePayload(memberID: id, urlToken: token, displayName: name) {
                navigate(.person(payload))
            }
        case let .pin(id): navigate(.pin(.init(pinID: id)))
        case let .special(id): navigate(.special(id))
        case let .column(id): navigate(.column(id))
        case let .search(query): navigate(.search(.init(query: query)))
        case let .external(url): hostModel.openExternal(url)
        }
    }

    private func handleDailyDestination(_ destination: DailyStoryDestination, in tab: NativeAppTab) {
        switch destination {
        case let .feed(route): openFeed(route, in: tab)
        case let .external(url): hostModel.openExternal(url)
        }
    }

    private func handlePinLink(_ destination: PinLinkDestination) {
        switch destination {
        case let .feed(route): openFeed(route)
        case let .external(url): hostModel.openExternal(url)
        }
    }

    private func handleQAIntent(_ intent: QANavigationIntent, in tab: NativeAppTab) {
        switch intent {
        case let .person(payload): navigate(.person(payload), in: tab)
        case let .question(route): navigate(.question(route), in: tab)
        case let .answer(route): navigate(.answer(route), in: tab)
        case let .writeAnswer(route): navigate(.writeAnswer(route), in: tab)
        case let .comments(route), let .segmentComments(route):
            navigate(.comments(route), in: tab)
        case let .images(urls, index):
            guard !urls.isEmpty else { return }
            mediaPresentation = .init(urls: urls, initialIndex: index)
        case let .link(link): handleQALink(link, in: tab)
        case let .endorsement(url):
            if let destination = NativeContentDestinationResolver.resolve(url.absoluteString) {
                openContent(destination)
            } else {
                hostModel.openExternal(url)
            }
        case let .video(route): navigate(.video(route), in: tab)
        case let .share(url): handleShare(url)
        }
    }

    private func handleShare(_ url: URL) {
        switch preferences.defaultShareAction {
        case .ask:
            pendingShareChoiceURL = url
        case .systemShare:
            shareURL = url
        case .copyLink:
            copyShareURL(url)
        }
    }

    private func copyShareURL(_ url: URL) {
        UIPasteboard.general.url = url
        clipboardLinkMonitor.recordAsHandled(url)
        showsCopiedLinkConfirmation = true
    }

    private func handleQALink(_ link: QALinkDestination, in tab: NativeAppTab) {
        switch link {
        case let .answer(id): navigate(.answer(.init(contentID: id, kind: .answer)), in: tab)
        case let .article(id): navigate(.answer(.init(contentID: id, kind: .article)), in: tab)
        case let .question(id): navigate(.question(.init(questionID: id)), in: tab)
        case let .pin(id): navigate(.pin(.init(pinID: id)), in: tab)
        case let .person(token):
            if let payload = PersonRoutePayload(memberID: nil, urlToken: token, displayName: "") {
                navigate(.person(payload), in: tab)
            }
        case let .external(url): hostModel.openExternal(url)
        }
    }

    private func handlePersonIntent(_ intent: PersonNavigationIntent, in tab: NativeAppTab) {
        navigate(intent.nativeShellRoute, in: tab)
    }

    private func handleCreationIntent(_ intent: CreationSystemIntent, retry: @escaping () async -> Void) {
        switch intent {
        case .loginRequired: hostModel.openLogin()
        case let .riskControlRequired(url): hostModel.openRiskControl(url: url, retry: retry)
        }
    }

    private func handleSystemNavigation(_ envelope: SystemNavigationRequestEnvelope) {
        switch envelope.request {
        case let .search(query):
            let target = NativeSearchTabNavigationTarget(query: query)
            navigation.reset(in: target.tab)
            searchRootRoute = target.route
            selectedTab = target.tab
            requestSearchFocus()
        case .hot:
            switch NativeHotSystemNavigationPolicy.target(
                selectedTabs: NativeAppTab.fixedBottomBarTabs,
                currentTab: selectedTab,
                startTab: preferences.startTab
            ) {
            case .homeChannel:
                navigation.reset(in: .home)
                selectedHomeChannelID = HomeChannel.hot.id
                selectedTab = .home
            case let .hotList(tab):
                selectedTab = tab
                navigate(.hotList, in: tab)
            case nil:
                break
            }
        case .collections:
            guard let token = account.identity?.collectionToken else {
                hostModel.openLogin()
                return
            }
            navigate(.collections(userToken: token))
        }
    }

    @ViewBuilder
    private func tabBarBehavior<Content: View>(_ content: Content) -> some View {
        content
    }
}

private struct NativeTabTapObserver: UIViewRepresentable {
    let isEnabled: Bool
    let tabs: [NativeAppTab]
    let selectedTab: NativeAppTab
    let onTap: (NativeTabTapEvent) -> Void

    func makeUIView(context: Context) -> InstallerView {
        InstallerView(
            isEnabled: isEnabled,
            tabs: tabs,
            selectedTab: selectedTab,
            onTap: onTap
        )
    }

    func updateUIView(_ view: InstallerView, context: Context) {
        view.update(
            isEnabled: isEnabled,
            tabs: tabs,
            selectedTab: selectedTab,
            onTap: onTap
        )
    }

    static func dismantleUIView(_ view: InstallerView, coordinator: ()) {
        view.uninstall()
    }

    final class InstallerView: UIView, UIGestureRecognizerDelegate {
        private var tabs: [NativeAppTab]
        private var selectedTab: NativeAppTab
        private var onTap: (NativeTabTapEvent) -> Void
        private let tabTap = NativeTabTapGestureRecognizer()
        private var selectedTabAtTouchBegan: NativeAppTab?
        private weak var installedWindow: UIWindow?
        private weak var installedTabBar: UITabBar?

        init(
            isEnabled: Bool,
            tabs: [NativeAppTab],
            selectedTab: NativeAppTab,
            onTap: @escaping (NativeTabTapEvent) -> Void
        ) {
            self.tabs = tabs
            self.selectedTab = selectedTab
            self.onTap = onTap
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            tabTap.onTouchesBegan = { [weak self] in
                self?.selectedTabAtTouchBegan = self?.selectedTab
            }
            tabTap.addTarget(self, action: #selector(didTapTabBar(_:)))
            tabTap.cancelsTouchesInView = false
            tabTap.delegate = self
            tabTap.isEnabled = isEnabled
        }

        required init?(coder: NSCoder) { nil }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil {
                uninstall()
            } else {
                installIfNeeded()
            }
        }

        func update(
            isEnabled: Bool,
            tabs: [NativeAppTab],
            selectedTab: NativeAppTab,
            onTap: @escaping (NativeTabTapEvent) -> Void
        ) {
            self.tabs = tabs
            self.selectedTab = selectedTab
            self.onTap = onTap
            tabTap.isEnabled = isEnabled
            installIfNeeded()
            installTabTapIfNeeded()
        }

        func uninstall() {
            installedTabBar?.removeGestureRecognizer(tabTap)
            installedTabBar = nil
            installedWindow = nil
        }

        private func installIfNeeded() {
            guard let window, installedWindow !== window else { return }
            uninstall()
            installedWindow = window
            installTabTapIfNeeded()
        }

        private func installTabTapIfNeeded() {
            guard let tabBar = findTabBarController(from: installedWindow?.rootViewController)?.tabBar,
                  installedTabBar !== tabBar
            else { return }
            installedTabBar?.removeGestureRecognizer(tabTap)
            tabBar.addGestureRecognizer(tabTap)
            installedTabBar = tabBar
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }

        @objc private func didTapTabBar(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended,
                  let tabBar = installedTabBar,
                  let tappedIndex = tappedTabIndex(at: recognizer.location(in: tabBar), in: tabBar),
                  tabs.indices.contains(tappedIndex),
                  NativeTabReselectPolicy.isReselect(
                      tappedTab: tabs[tappedIndex],
                      selectedTabAtTouchBegan: selectedTabAtTouchBegan
                  )
            else { return }
            onTap(.init(tab: tabs[tappedIndex], timestamp: Date().timeIntervalSinceReferenceDate))
        }

        private func tappedTabIndex(at location: CGPoint, in tabBar: UITabBar) -> Int? {
            let buttons = tabBarButtonViews(in: tabBar).sorted {
                $0.convert($0.bounds, to: tabBar).minX < $1.convert($1.bounds, to: tabBar).minX
            }
            if let index = buttons.firstIndex(where: {
                $0.convert($0.bounds, to: tabBar).contains(location)
            }) {
                return index
            }
            guard !tabs.isEmpty, tabBar.bounds.width > 0 else { return nil }
            return min(max(Int(location.x / (tabBar.bounds.width / CGFloat(tabs.count))), 0), tabs.count - 1)
        }

        private func tabBarButtonViews(in view: UIView) -> [UIView] {
            var result: [UIView] = []
            for subview in view.subviews {
                if String(describing: type(of: subview)).contains("UITabBarButton") {
                    result.append(subview)
                } else {
                    result.append(contentsOf: tabBarButtonViews(in: subview))
                }
            }
            return result
        }

        private func findTabBarController(from controller: UIViewController?) -> UITabBarController? {
            guard let controller else { return nil }
            if let tabController = controller as? UITabBarController { return tabController }
            if let presented = controller.presentedViewController,
               let result = findTabBarController(from: presented) {
                return result
            }
            for child in controller.children {
                if let result = findTabBarController(from: child) { return result }
            }
            return nil
        }
    }
}

private final class NativeTabTapGestureRecognizer: UITapGestureRecognizer {
    var onTouchesBegan: (() -> Void)?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        onTouchesBegan?()
        super.touchesBegan(touches, with: event)
    }
}

private struct NativeQuestionRouteView: View {
    @StateObject private var store: QuestionStore
    let onNavigate: (QANavigationIntent) -> Void

    init(route: QuestionRouteDTO, repository: QuestionAnswerRepository, onNavigate: @escaping (QANavigationIntent) -> Void) {
        _store = StateObject(wrappedValue: QuestionStore(route: route, repository: repository))
        self.onNavigate = onNavigate
    }

    var body: some View { QuestionNativeView(store: store, onNavigate: onNavigate) }
}

private struct NativePersonRouteView: View {
    @StateObject private var model: PersonHostModel

    init(
        payload: PersonRoutePayload,
        accountStore: AccountJSONStore,
        diagnostics: PerformanceDiagnosticsClient = .disabled,
        onNavigate: @escaping (PersonNavigationIntent) -> Void
    ) {
        _model = StateObject(wrappedValue: PersonHostModel(
            routeEntry: PersonRouteEntry(payload: payload),
            accountStore: accountStore,
            diagnostics: diagnostics,
            onNavigate: onNavigate
        ))
    }

    // Pushing a child route makes this view disappear temporarily. Do not dispose here: returning
    // must preserve the profile tab, paging state and scroll context.
    var body: some View { PersonHostView(model: model) }
}

private struct NativePersonConnectionsRouteView: View {
    @StateObject private var model: PersonHostModel
    private let title: String

    init(
        route: PersonConnectionsRoute,
        accountStore: AccountJSONStore,
        diagnostics: PerformanceDiagnosticsClient = .disabled,
        onNavigate: @escaping (PersonNavigationIntent) -> Void
    ) {
        title = route.title
        _model = StateObject(wrappedValue: PersonHostModel(
            routeEntry: PersonRouteEntry(payload: route.person),
            accountStore: accountStore,
            diagnostics: diagnostics,
            onNavigate: onNavigate
        ))
    }

    var body: some View {
        PersonConnectionsView(model: model, title: title)
    }
}

@available(iOS 16.0, *)
private struct NativeCommentNavigationRouteView: View {
    @StateObject private var model: CommentHostModel

    init(route: CommentThreadRouteDTO, accountStore: AccountJSONStore, onPersonNavigate: @escaping (PersonNavigationIntent) -> Void) {
        _model = StateObject(wrappedValue: CommentHostModel(
            route: route,
            accountStore: accountStore,
            onPersonNavigate: onPersonNavigate
        ))
    }

    var body: some View { CommentNavigationPage(model: model) }
}

private struct NativeSharePresentation: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

private struct NativeShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private struct NativeSignedOutLibraryView: View {
    let title: String
    let openLogin: () -> Void
    var body: some View {
        NativeUnavailableState(
            title: title,
            message: "登录状态由本机 Keychain 安全保存",
            actionTitle: "登录知乎",
            action: openLogin
        )
        .navigationTitle("知乎++")
    }
}
