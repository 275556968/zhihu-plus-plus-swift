import Foundation
import SwiftUI
import UIKit

struct NativeAccountIdentity: Equatable, Hashable {
    let id: String
    let name: String
    let urlToken: String?
    let userType: String
    let avatarURL: URL?

    var collectionToken: String? {
        let token = urlToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let token, !token.isEmpty { return token }
        let identifier = id.trimmingCharacters(in: .whitespacesAndNewlines)
        return identifier.isEmpty ? nil : identifier
    }
}

struct NativeStoredAccount: Equatable {
    let isLoggedIn: Bool
    let username: String
    let identity: NativeAccountIdentity?
}

struct NativeAccountRepository {
    var load: () throws -> NativeStoredAccount
    var refreshProfile: () async throws -> NativeStoredAccount
    var signOut: () throws -> Void
    var listAccounts: () throws -> [NativeSavedAccountSummary]
    var currentAccountID: () throws -> String?
    var switchAccount: (_ accountID: String) throws -> NativeStoredAccount
    var deleteAccount: (_ accountID: String) throws -> Void

    init(
        load: @escaping () throws -> NativeStoredAccount,
        refreshProfile: @escaping () async throws -> NativeStoredAccount,
        signOut: @escaping () throws -> Void,
        listAccounts: @escaping () throws -> [NativeSavedAccountSummary] = { [] },
        currentAccountID: @escaping () throws -> String? = { nil },
        switchAccount: @escaping (_ accountID: String) throws -> NativeStoredAccount = { _ in
            throw MultipleAccountStoreError.accountNotFound
        },
        deleteAccount: @escaping (_ accountID: String) throws -> Void = { _ in
            throw MultipleAccountStoreError.accountNotFound
        }
    ) {
        self.load = load
        self.refreshProfile = refreshProfile
        self.signOut = signOut
        self.listAccounts = listAccounts
        self.currentAccountID = currentAccountID
        self.switchAccount = switchAccount
        self.deleteAccount = deleteAccount
    }

    static func live(accountStore: AccountJSONStore, client: ZhihuAPIClient) -> NativeAccountRepository {
        let multipleAccountStore = accountStore as? MultipleAccountJSONStore
        return NativeAccountRepository(
            load: {
                try NativeAccountCodec.decode(accountStore.load())
            },
            refreshProfile: {
                let url = URL(string: "https://www.zhihu.com/api/v4/me")!
                let data = try await client.data(for: url, authentication: .accountRequired)
                let profile = try NativeAccountCodec.decodeProfileResponse(data)
                try accountStore.update { existingJSON in
                    try NativeAccountCodec.merging(profile: profile, into: existingJSON)
                }
                return try NativeAccountCodec.decode(accountStore.load())
            },
            signOut: {
                if let multipleAccountStore {
                    try multipleAccountStore.clearCurrentAccount()
                } else {
                    try accountStore.clear()
                }
            },
            listAccounts: {
                if let multipleAccountStore {
                    return try multipleAccountStore.listAccounts()
                }
                let current = try NativeAccountCodec.decode(accountStore.load())
                guard current.isLoggedIn, let identity = current.identity else { return [] }
                return [NativeSavedAccountSummary(
                    id: identity.id,
                    name: identity.name,
                    urlToken: identity.urlToken,
                    avatarURL: identity.avatarURL
                )]
            },
            currentAccountID: {
                if let multipleAccountStore {
                    return try multipleAccountStore.currentAccountID()
                }
                return try NativeAccountCodec.decode(accountStore.load()).identity?.id
            },
            switchAccount: { accountID in
                guard let multipleAccountStore else {
                    throw MultipleAccountStoreError.accountNotFound
                }
                try multipleAccountStore.switchAccount(to: accountID)
                return try NativeAccountCodec.decode(accountStore.load())
            },
            deleteAccount: { accountID in
                guard let multipleAccountStore else {
                    throw MultipleAccountStoreError.accountNotFound
                }
                try multipleAccountStore.deleteAccount(accountID)
            }
        )
    }
}

enum NativeAccountCodec {
    enum CodecError: LocalizedError {
        case malformedAccount
        case malformedProfile

        var errorDescription: String? {
            switch self {
            case .malformedAccount: return "账号信息无法读取，请重新登录"
            case .malformedProfile: return "服务器返回的账号资料无法识别"
            }
        }
    }

    static func decode(_ accountJSON: String?) throws -> NativeStoredAccount {
        guard let accountJSON, !accountJSON.isEmpty else {
            return NativeStoredAccount(isLoggedIn: false, username: "", identity: nil)
        }
        guard let data = accountJSON.data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw CodecError.malformedAccount }
        let login = root["login"] as? Bool ?? false
        let username = root["username"] as? String ?? ""
        let profile = root["profile"] as? [String: Any]
        let identity = profile.flatMap { profile -> NativeAccountIdentity? in
            let id = profile["id"] as? String ?? ""
            let name = profile["name"] as? String ?? username
            let urlToken = profile["urlToken"] as? String
            let userType = profile["userType"] as? String ?? ""
            let avatar = (profile["avatarUrl"] as? String).flatMap(URL.init(string:))
            guard !id.isEmpty || !(urlToken ?? "").isEmpty || !name.isEmpty else { return nil }
            return NativeAccountIdentity(
                id: id,
                name: name,
                urlToken: urlToken,
                userType: userType,
                avatarURL: avatar
            )
        }
        return NativeStoredAccount(isLoggedIn: login, username: username, identity: identity)
    }

    static func decodeProfileResponse(_ data: Data) throws -> NativeAccountIdentity {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodecError.malformedProfile
        }
        let id = root["id"] as? String ?? ""
        let name = root["name"] as? String ?? ""
        let urlToken = root["url_token"] as? String ?? root["urlToken"] as? String
        let userType = root["user_type"] as? String ?? root["userType"] as? String ?? ""
        let avatar = (root["avatar_url"] as? String ?? root["avatarUrl"] as? String).flatMap(URL.init(string:))
        guard !id.isEmpty, !name.isEmpty else { throw CodecError.malformedProfile }
        return NativeAccountIdentity(
            id: id,
            name: name,
            urlToken: urlToken,
            userType: userType,
            avatarURL: avatar
        )
    }

    static func merging(profile: NativeAccountIdentity, into accountJSON: String?) throws -> String {
        guard let accountJSON,
              let data = accountJSON.data(using: .utf8),
              var root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw CodecError.malformedAccount }
        root["login"] = true
        root["username"] = profile.name
        var storedProfile: [String: Any] = [
            "id": profile.id,
            "name": profile.name,
            "userType": profile.userType,
        ]
        storedProfile["urlToken"] = profile.urlToken ?? NSNull()
        storedProfile["avatarUrl"] = profile.avatarURL?.absoluteString ?? NSNull()
        root["profile"] = storedProfile
        let updated = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        guard let result = String(data: updated, encoding: .utf8) else {
            throw CodecError.malformedAccount
        }
        return result
    }
}

@MainActor
final class NativeAccountStore: ObservableObject {
    enum State: Equatable {
        case loading
        case signedOut
        case signedIn(NativeAccountIdentity)
        case failed(message: String, retainedIdentity: NativeAccountIdentity?)
    }

    @Published private(set) var state: State = .loading
    @Published private(set) var isRefreshing = false
    @Published private(set) var isSigningOut = false
    @Published private(set) var accounts: [NativeSavedAccountSummary] = []
    @Published private(set) var currentAccountID: String?
    @Published private(set) var switchingToAccountID: String?
    @Published private(set) var deletingAccountID: String?

    private let repository: NativeAccountRepository
    init(repository: NativeAccountRepository) {
        self.repository = repository
    }

    var identity: NativeAccountIdentity? {
        switch state {
        case let .signedIn(identity): return identity
        case let .failed(_, retainedIdentity): return retainedIdentity
        case .loading, .signedOut: return nil
        }
    }

    var isSignedIn: Bool { identity != nil }

    func reloadFromKeychain() {
        do {
            apply(try repository.load())
            try reloadAccountList()
        } catch {
            state = .failed(message: error.localizedDescription, retainedIdentity: identity)
        }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            apply(try await repository.refreshProfile())
            try reloadAccountList()
        } catch is CancellationError {
            return
        } catch {
            state = .failed(message: error.localizedDescription, retainedIdentity: identity)
        }
    }

    func signOut() {
        guard !isSigningOut else { return }
        isSigningOut = true
        defer { isSigningOut = false }
        do {
            try repository.signOut()
            state = .signedOut
            try reloadAccountList()
        } catch {
            state = .failed(message: error.localizedDescription, retainedIdentity: identity)
        }
    }

    func switchAccount(to accountID: String) {
        guard switchingToAccountID == nil, deletingAccountID == nil, currentAccountID != accountID else { return }
        switchingToAccountID = accountID
        defer { switchingToAccountID = nil }
        do {
            apply(try repository.switchAccount(accountID))
            try reloadAccountList()
        } catch {
            state = .failed(message: error.localizedDescription, retainedIdentity: identity)
        }
    }

    func deleteAccount(_ accountID: String) {
        guard switchingToAccountID == nil,
              deletingAccountID == nil,
              currentAccountID != accountID
        else { return }
        deletingAccountID = accountID
        defer { deletingAccountID = nil }
        do {
            try repository.deleteAccount(accountID)
            try reloadAccountList()
        } catch {
            state = .failed(message: error.localizedDescription, retainedIdentity: identity)
        }
    }

    private func apply(_ account: NativeStoredAccount) {
        if account.isLoggedIn, let identity = account.identity {
            state = .signedIn(identity)
        } else {
            state = .signedOut
        }
    }

    private func reloadAccountList() throws {
        accounts = try repository.listAccounts()
        currentAccountID = try repository.currentAccountID()
    }
}

struct NativeAccountActions {
    let openLogin: () -> Void
    let openQrAuthorization: () -> Void
    let openProfile: (NativeAccountIdentity) -> Void
}

@available(iOS 16.0, *)
struct NativeAccountView: View {
    @ObservedObject var store: NativeAccountStore
    let actions: NativeAccountActions

    @State private var confirmsSignOut = false
    @State private var titleCollapseProgress: CGFloat = 0

    var body: some View {
        List {
            NativeRootLargeTitle(
                "账号",
                coordinateSpaceName: "account-root-scroll",
                collapseProgress: $titleCollapseProgress
            )
            accountSection
            accountManagementSection
            if let identity = store.identity {
                librarySection(identity: identity)
            }
            settingsSection
            aboutSection
        }
        .listStyle(.insetGrouped)
        .coordinateSpace(name: "account-root-scroll")
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if NativeRootCompactTitle.shouldRender(collapseProgress: titleCollapseProgress) {
                ToolbarItem(placement: .navigationBarLeading) {
                    NativeRootCompactTitle("账号", collapseProgress: titleCollapseProgress)
                }
            }
        }
        .refreshable {
            if store.isSignedIn { await store.refresh() }
        }
        .task {
            if case .loading = store.state { store.reloadFromKeychain() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            store.reloadFromKeychain()
        }
        .alert("退出登录", isPresented: $confirmsSignOut) {
            Button("取消", role: .cancel) {}
            Button("退出", role: .destructive, action: store.signOut)
        } message: {
            Text("退出后，当前账号保存的知乎登录状态将从本机移除，其他已保存账号不受影响。")
        }
    }

    @ViewBuilder
    private var accountManagementSection: some View {
        if store.isSignedIn || !store.accounts.isEmpty {
            Section {
                ForEach(store.accounts) { account in
                    Button {
                        store.switchAccount(to: account.id)
                    } label: {
                        HStack(spacing: 12) {
                            NativeSavedAccountAvatar(account: account, diameter: 40)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(account.name)
                                    .foregroundStyle(.primary)
                                if let token = account.urlToken, !token.isEmpty {
                                    Text("@\(token)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text("已验证账号")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if store.currentAccountID == account.id {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.tint)
                                    .accessibilityLabel("当前账号")
                            } else if store.switchingToAccountID == account.id {
                                ProgressView()
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(
                        store.currentAccountID == account.id ||
                        store.switchingToAccountID != nil ||
                        store.deletingAccountID != nil
                    )
                    .swipeActions {
                        if store.currentAccountID != account.id {
                            Button(role: .destructive) {
                                store.deleteAccount(account.id)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                }

                Button(action: actions.openLogin) {
                    Label("添加账号", systemImage: "person.crop.circle.badge.plus")
                }
                .disabled(store.switchingToAccountID != nil || store.deletingAccountID != nil)
            } header: {
                Text("账号管理")
            } footer: {
                Text("账号登录状态仅保存在本机 Keychain 中。")
            }
        }
    }

    @ViewBuilder
    private var accountSection: some View {
        Section {
            if let identity = store.identity {
                Button {
                    actions.openProfile(identity)
                } label: {
                    HStack(spacing: 14) {
                        NativeAccountAvatar(identity: identity, diameter: 58)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(identity.name).font(.headline).foregroundStyle(.primary)
                            Text("查看个人主页").font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                    actions.openQrAuthorization()
                } label: {
                    Label("扫描二维码授权登录", systemImage: "qrcode.viewfinder")
                }

                Button(role: .destructive) {
                    confirmsSignOut = true
                } label: {
                    Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right")
                }
                .disabled(store.isSigningOut)
            } else {
                Button(action: actions.openLogin) {
                    Label("登录知乎", systemImage: "person.crop.circle.badge.plus")
                }
            }

            if case let .failed(message, _) = store.state {
                VStack(alignment: .leading, spacing: 8) {
                    Text(message).font(.footnote).foregroundStyle(.secondary)
                    Button("重新读取", action: store.reloadFromKeychain)
                        .font(.footnote.weight(.semibold))
                }
            }
        }
    }

    private func librarySection(identity: NativeAccountIdentity) -> some View {
        Section("我的内容") {
            if let token = identity.collectionToken {
                NavigationLink(value: NativeShellRoute.collections(userToken: token)) {
                    Label("收藏夹", systemImage: "bookmark")
                }
            }
            NavigationLink(value: NativeShellRoute.history) {
                Label("浏览历史", systemImage: "clock.arrow.circlepath")
            }
            NavigationLink(value: NativeShellRoute.notifications) {
                Label("通知", systemImage: "bell")
            }
        }
    }

    private var settingsSection: some View {
        Section {
            NavigationLink(value: NativeShellRoute.settings) {
                Label("设置", systemImage: "gearshape")
            }
        }
    }

    private var aboutSection: some View {
        Section {
            LabeledContent("知乎++", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
            NavigationLink(value: NativeShellRoute.systemAndUpdate) {
                Label("系统与更新", systemImage: "info.circle")
            }
        } header: {
            Text("关于")
        } footer: {
            Text("本软件仅供学习交流使用，应用内内容由知乎网站提供。")
        }
    }
}

struct NativeAccountAvatar: View {
    let identity: NativeAccountIdentity?
    let diameter: CGFloat

    var body: some View {
        AsyncImage(url: identity?.avatarURL) { phase in
            if case let .success(image) = phase {
                image.resizable().scaledToFill()
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: diameter, height: diameter)
        .clipShape(Circle())
        .accessibilityLabel(identity.map { "\($0.name)的头像" } ?? "账号")
    }
}

private struct NativeSavedAccountAvatar: View {
    let account: NativeSavedAccountSummary
    let diameter: CGFloat

    var body: some View {
        AsyncImage(url: account.avatarURL) { phase in
            if case let .success(image) = phase {
                image.resizable().scaledToFill()
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: diameter, height: diameter)
        .clipShape(Circle())
        .accessibilityLabel("\(account.name)的头像")
    }
}
