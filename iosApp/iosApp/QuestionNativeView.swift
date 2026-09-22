import SwiftUI

struct QuestionNativeView: View {
    @ObservedObject var store: QuestionStore
    let onNavigate: (QANavigationIntent) -> Void
    @Environment(\.nativeContentPresentation) private var contentPresentation
    @ScaledMetric(relativeTo: .subheadline) private var detailSummaryPointSize: CGFloat = 15

    var body: some View {
        Group {
            if store.question != nil {
                questionContent
            } else {
                switch store.initialLoad {
                case let .failed(message):
                    QAErrorState(message: message, actionTitle: "重试") {
                        Task { await store.refresh() }
                    }
                case .idle, .loading, .loaded:
                    ProgressView("正在加载问题")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .navigationTitle("问题")
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.loadIfNeeded() }
        .alert(item: messageBinding) { message in
            Alert(
                title: Text("操作结果"),
                message: Text(message.text),
                dismissButton: .default(Text("知道了")) { store.dismissMessage() }
            )
        }
    }

    @ViewBuilder
    private var questionContent: some View {
        if let question = store.question {
            List {
                VStack(alignment: .leading, spacing: 18) {
                    Text(question.title)
                        .font(.title2.bold())
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)

                    if !question.detailBlocks.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) { store.isDetailExpanded.toggle() }
                            } label: {
                                HStack {
                                    Text("问题描述")
                                        .font(.headline)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    Image(systemName: "chevron.down")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                        .rotationEffect(.degrees(store.isDetailExpanded ? 180 : 0))
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            if store.isDetailExpanded {
                                QABodyView(
                                    blocks: question.detailBlocks,
                                    segmentSubject: .question(question.id),
                                    onNavigate: onNavigate
                                )
                            } else {
                                Text(QARichContentParser.plainText(question.detailHTML))
                                    .font(.system(size: detailSummaryPointSize * contentPresentation.fontScale))
                                    .lineSpacing(contentPresentation.extraLineSpacing(
                                        for: detailSummaryPointSize * contentPresentation.fontScale
                                    ))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                            }
                        }
                    }

                    if !question.topics.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(question.topics) { topic in
                                    if let url = topic.url {
                                        Button(topic.name) { onNavigate(.endorsement(url)) }
                                            .buttonStyle(.bordered)
                                            .controlSize(.small)
                                    } else {
                                        Text(topic.name)
                                            .font(.caption)
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 6)
                                            .background(.quaternary, in: Capsule())
                                    }
                                }
                            }
                        }
                    }

                    QAQuestionStats(question: question)
                    Picker("回答排序", selection: sortBinding) {
                        ForEach(QuestionAnswerSort.allCases) { sort in
                            Text(sort.title).tag(sort)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                .padding(.vertical, 6)
                .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 14, trailing: 16))
                .listRowSeparator(.hidden)

                Section("\(question.answerCount) 个回答") {
                    ForEach(store.answers) { answer in
                        Button {
                            onNavigate(.answer(store.answerRoute(for: answer)))
                        } label: {
                            QAAnswerPreviewRow(answer: answer)
                        }
                        .buttonStyle(.plain)
                        .task {
                            if answer.id == store.answers.last?.id { await store.loadMore() }
                        }
                    }

                    switch store.nextPage {
                    case .loading:
                        HStack { Spacer(); ProgressView(); Spacer() }
                    case let .failed(message):
                        Button("加载更多失败，点此重试") { Task { await store.loadMore() } }
                            .foregroundStyle(.red)
                            .accessibilityHint(message)
                    case .idle:
                        if store.answers.isEmpty { Text("还没有回答").foregroundStyle(.secondary) }
                    }
                }
            }
            .listStyle(.plain)
            .refreshable { await store.refresh() }
            .safeAreaInset(edge: .bottom) {
                QuestionActionBar(
                    question: question,
                    followInFlight: store.isFollowMutationInFlight,
                    onFollow: { Task { await store.toggleFollowing() } },
                    onWrite: {
                        onNavigate(.writeAnswer(.init(questionID: question.id, questionTitle: question.title)))
                    },
                    onComments: {
                        onNavigate(.comments(CommentThreadRouteDTO(
                            subject: .question(question.id),
                            shareContext: CommentShareContextDTO(
                                title: question.title,
                                excerpt: QARichContentParser.plainText(question.detailHTML),
                                sourceURL: URL(string: "https://www.zhihu.com/question/\(question.id)")!
                            )
                        )))
                    },
                    onShare: {
                        if let url = URL(string: "https://www.zhihu.com/question/\(question.id)") {
                            onNavigate(.share(url))
                        }
                    }
                )
            }
        }
    }

    private var sortBinding: Binding<QuestionAnswerSort> {
        Binding(
            get: { store.sort },
            set: { value in Task { await store.selectSort(value) } }
        )
    }

    private var messageBinding: Binding<QAUserMessage?> {
        Binding(get: { store.message }, set: { _ in store.dismissMessage() })
    }
}

private struct QAQuestionStats: View {
    let question: QuestionDTO

    var body: some View {
        HStack(spacing: 0) {
            stat("回答", question.answerCount)
            stat("浏览", question.visitCount)
            stat("评论", question.commentCount)
            stat("关注", question.followerCount)
        }
        .accessibilityElement(children: .combine)
    }

    private func stat(_ label: String, _ value: Int) -> some View {
        VStack(spacing: 3) {
            Text(value, format: .number.notation(.compactName)).font(.headline.monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct QAAnswerPreviewRow: View {
    let answer: AnswerPreviewDTO

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                AsyncImage(url: answer.author.avatarURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Image(systemName: "person.crop.circle.fill").resizable().foregroundStyle(.tertiary)
                }
                .frame(width: 30, height: 30)
                .clipShape(Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text(answer.author.displayName).font(.subheadline.weight(.medium))
                    if !answer.author.headline.isEmpty {
                        Text(answer.author.headline).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            if !answer.excerpt.isEmpty {
                Text(answer.excerpt).font(.body).lineLimit(4)
            }
            Text("\(answer.voteUpCount) 赞同 · \(answer.commentCount) 评论")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }
}

private struct QuestionActionBar: View {
    let question: QuestionDTO
    let followInFlight: Bool
    let onFollow: () -> Void
    let onWrite: () -> Void
    let onComments: () -> Void
    let onShare: () -> Void

    var body: some View {
        actions
            .padding(7)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
    }

    private var actions: some View {
        HStack(spacing: 4) {
            Button(action: onFollow) {
                Label(question.isFollowing ? "已关注" : "关注", systemImage: question.isFollowing ? "checkmark" : "plus")
            }
            .disabled(followInFlight)
            Button(action: onWrite) {
                Label("写回答", systemImage: "square.and.pencil")
            }
            Spacer(minLength: 4)
            Button(action: onComments) {
                Label("\(question.commentCount)", systemImage: "bubble.left")
            }
            Button(action: onShare) {
                Image(systemName: "square.and.arrow.up").accessibilityLabel("分享问题")
            }
        }
    }
}

struct QAErrorState: View {
    let message: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle").font(.title2).foregroundStyle(.secondary)
            Text(message).multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button(actionTitle, action: action).buttonStyle(.borderedProminent)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
