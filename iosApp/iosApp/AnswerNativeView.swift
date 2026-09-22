import SwiftUI
import UIKit

struct AnswerNativeView: View {
    @ObservedObject var store: AnswerStore
    let pinAnswerDate: Bool
    let onNavigate: (QANavigationIntent) -> Void

    @State private var showsCollections = false

    var body: some View {
        Group {
            if let content = store.content {
                loaded(content)
            } else {
                switch store.loadState {
                case let .failed(message):
                    QAErrorState(message: message, actionTitle: "重试") {
                        Task { await store.retry() }
                    }
                case .idle, .loading, .loaded:
                    ProgressView("正在加载正文")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .navigationTitle(store.initialRoute.kind == .answer ? "回答" : "文章")
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.loadIfNeeded() }
        .sheet(isPresented: $showsCollections) {
            QACollectionsSheet(store: store)
        }
        .alert(item: messageBinding) { message in
            Alert(
                title: Text("操作结果"),
                message: Text(message.text),
                dismissButton: .default(Text("知道了")) { store.dismissMessage() }
            )
        }
    }

    private func loaded(_ content: AnswerDTO) -> some View {
        let metadata = QAMetadataPlacement(pinAnswerDate: pinAnswerDate)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                if content.route.kind == .answer {
                    Button {
                        if let questionID = content.questionID {
                            onNavigate(.question(QuestionRouteDTO(questionID: questionID, provisionalTitle: content.title)))
                        }
                    } label: {
                        Text(content.title)
                            .font(.title3.bold())
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                    }
                    .buttonStyle(.plain)
                    .disabled(content.questionID == nil)
                } else {
                    Text(content.title)
                        .font(.title2.bold())
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }

                QAAuthorRow(author: content.author) {
                    if let intent = content.author.personIntent { onNavigate(intent) }
                }

                if !content.endorsements.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(content.endorsements) { endorsement in
                                if let url = endorsement.actionURL {
                                    Button {
                                        onNavigate(.endorsement(url))
                                    } label: {
                                        QAEndorsementLabel(endorsement: endorsement, isActionable: true)
                                    }
                                    .buttonStyle(.plain)
                                } else {
                                    QAEndorsementLabel(endorsement: endorsement, isActionable: false)
                                }
                            }
                        }
                    }
                }

                if metadata.dateEdge == .leading {
                    QADateMetadata(content: content)
                }

                if let invitation = content.invitationPreface, !invitation.isEmpty {
                    Label(invitation, systemImage: "person.crop.circle.badge.questionmark")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                QABodyView(
                    blocks: content.blocks,
                    segmentSubject: content.route.kind == .answer
                        ? .answer(content.route.contentID)
                        : .article(content.route.contentID),
                    onNavigate: onNavigate
                )

                if let attachment = content.attachment {
                    QABodyView(
                        blocks: [.video(UUID(), attachment)],
                        segmentSubject: content.route.kind == .answer
                            ? .answer(content.route.contentID)
                            : .article(content.route.contentID),
                        onNavigate: onNavigate
                    )
                }

                VStack(alignment: .trailing, spacing: 5) {
                    if metadata.dateEdge == .trailing { QADateMetadata(content: content) }
                    if let ip = content.ipLocation, !ip.isEmpty {
                        Text("IP属地：\(ip)")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.top, 8)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
        }
        .safeAreaInset(edge: .bottom) {
            AnswerActionBar(
                content: content,
                voteInFlight: store.isVoteMutationInFlight,
                onVoteUp: {
                    let target: QAVoteState = content.voteState == .up ? .neutral : .up
                    Task { await store.setVote(target) }
                },
                onVoteDown: {
                    let target: QAVoteState = content.voteState == .down ? .neutral : .down
                    Task { await store.setVote(target) }
                },
                onFavorite: {
                    showsCollections = true
                    Task { await store.loadCollections() }
                },
                onComments: {
                    let subject: CommentSubjectDTO = content.route.kind == .answer
                        ? .answer(content.route.contentID)
                        : .article(content.route.contentID)
                    onNavigate(.comments(CommentThreadRouteDTO(
                        subject: subject,
                        shareContext: CommentShareContextDTO(
                            title: content.title,
                            excerpt: commentShareExcerpt(from: content.blocks),
                            sourceURL: content.sourceURL
                        )
                    )))
                }
            )
        }
    }

    private func commentShareExcerpt(from blocks: [QABodyBlock]) -> String? {
        let text = blocks
            .compactMap(commentShareText)
            .joined(separator: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !text.isEmpty else { return nil }
        let limit = text.index(text.startIndex, offsetBy: min(160, text.count))
        return String(text[..<limit])
    }

    private func commentShareText(_ block: QABodyBlock) -> String? {
        switch block {
        case let .paragraph(_, runs),
             let .heading(_, _, runs),
             let .quote(_, runs),
             let .segment(_, _, runs):
            return runs.map(\.text).joined()
        case let .list(_, _, items):
            return items.flatMap { item in
                [item.runs.map(\.text).joined()] + item.nestedLists.flatMap(commentShareListText)
            }.joined(separator: " ")
        case let .code(_, _, text), let .formula(_, text):
            return text
        case .image, .video, .divider:
            return nil
        }
    }

    private func commentShareListText(_ list: QAListGroup) -> [String] {
        list.items.flatMap { item in
            [item.runs.map(\.text).joined()] + item.nestedLists.flatMap(commentShareListText)
        }
    }

    private var messageBinding: Binding<QAUserMessage?> {
        Binding(get: { store.message }, set: { _ in store.dismissMessage() })
    }
}

private struct QAAuthorRow: View {
    let author: QAAuthorDTO
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                AsyncImage(url: author.avatarURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Image(systemName: "person.crop.circle.fill").resizable().foregroundStyle(.tertiary)
                }
                .frame(width: 42, height: 42)
                .clipShape(Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(author.displayName).font(.headline)
                    if !author.headline.isEmpty {
                        Text(author.headline).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(author.personIntent == nil)
        .accessibilityHint(author.personIntent == nil ? "" : "打开作者主页")
    }
}

private struct QAEndorsementLabel: View {
    let endorsement: QAEndorsementDTO
    let isActionable: Bool

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "checkmark.seal")
            Text(endorsement.text)
            if isActionable { Image(systemName: "chevron.right").font(.caption2) }
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(isActionable ? Color.accentColor : Color(uiColor: .secondaryLabel))
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.quaternary, in: Capsule())
    }
}

private struct QADateMetadata: View {
    let content: AnswerDTO

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if content.createdTimeSeconds > 0 {
                Text("发布于 \(date(content.createdTimeSeconds))")
            }
            if content.updatedTimeSeconds > 0,
               content.updatedTimeSeconds != content.createdTimeSeconds {
                Text("编辑于 \(date(content.updatedTimeSeconds))")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func date(_ seconds: Int64) -> String {
        Date(timeIntervalSince1970: TimeInterval(seconds)).formatted(
            .dateTime.year().month().day().hour().minute()
        )
    }
}

private struct AnswerActionBar: View {
    let content: AnswerDTO
    let voteInFlight: Bool
    let onVoteUp: () -> Void
    let onVoteDown: () -> Void
    let onFavorite: () -> Void
    let onComments: () -> Void

    var body: some View {
        actions
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.ultraThinMaterial, in: Capsule())
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
    }

    private var actions: some View {
        HStack(spacing: 4) {
            action("hand.thumbsup", count: content.voteUpCount, selected: content.voteState == .up, action: onVoteUp)
                .disabled(voteInFlight)
            action("hand.thumbsdown", label: "反对", selected: content.voteState == .down, action: onVoteDown)
                .disabled(voteInFlight || content.route.kind == .article)
            action(
                content.favoriteState == .favorited ? "star.fill" : "star",
                count: content.favoriteCount,
                selected: content.favoriteState == .favorited,
                action: onFavorite
            )
            action("bubble.left", count: content.commentCount, selected: false, action: onComments)
        }
    }

    private func action(
        _ systemName: String,
        count: Int? = nil,
        label: String? = nil,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: systemName).font(.system(size: 20, weight: selected ? .semibold : .regular))
                Text(label ?? count.map(String.init) ?? "")
                    .font(.caption2.monospacedDigit())
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? Color.accentColor : Color(uiColor: .label))
    }
}

private struct QACollectionsSheet: View {
    @ObservedObject var store: AnswerStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            Group {
                if store.collections.isEmpty {
                    switch store.collectionsState {
                    case let .failed(message):
                        QAErrorState(message: message, actionTitle: "重试") {
                            Task { await store.loadCollections(force: true) }
                        }
                    case .idle, .loading, .loaded:
                        ProgressView("正在加载收藏夹")
                    }
                } else {
                    List(store.collections) { collection in
                        Button {
                            Task { await store.setCollection(collection, selected: !collection.isFavorited) }
                        } label: {
                            HStack {
                                Text(collection.title).foregroundStyle(.primary)
                                Spacer()
                                if store.activeCollectionID == collection.id {
                                    ProgressView()
                                } else if collection.isFavorited {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(store.activeCollectionID != nil)
                    }
                    .refreshable { await store.loadCollections(force: true) }
                }
            }
            .navigationTitle("收藏到")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
        .modifier(QACollectionSheetPresentationModifier())
    }
}

private struct QACollectionSheetPresentationModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content.presentationDetents([.medium, .large])
        } else {
            content
        }
    }
}
