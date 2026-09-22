import SwiftUI

struct PersonProfileHeader: View {
    let profile: PersonProfile
    let followState: PersonActionState
    let blockState: PersonActionState
    let onSelectTab: (PersonTab) -> Void
    let onFollow: () -> Void
    let onRetryFollow: () -> Void
    let onBlock: () -> Void
    let onRetryBlock: () -> Void
    let onAvatar: (URL) -> Void
    let onBadges: ([PersonOfficialBadge]) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            identity
            statistics
            actions
            actionFailures
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("person_profile_header")
    }

    private var identity: some View {
        HStack(alignment: .top, spacing: 16) {
            avatar
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(profile.displayName)
                        .font(.title2.weight(.semibold))
                        .lineLimit(2)
                    if let badge = profile.primaryOfficialBadge {
                        badgeIcon(badge)
                    }
                }
                if !profile.headline.isEmpty {
                    Text(profile.headline)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !profile.officialBadgeDetails.isEmpty {
                    Button {
                        onBadges(profile.officialBadgeDetails)
                    } label: {
                        Label("查看认证信息", systemImage: "checkmark.seal")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                }
            }
        }
    }

    @ViewBuilder
    private var avatar: some View {
        if let url = profile.avatarURL {
            Button { onAvatar(url) } label: {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case let .success(image): image.resizable().scaledToFill()
                    case .failure: avatarFallback
                    case .empty: ProgressView()
                    @unknown default: avatarFallback
                    }
                }
                .frame(width: 80, height: 80)
                .background(Color.secondary.opacity(0.08))
                .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("查看 \(profile.displayName) 的头像")
        } else {
            avatarFallback.frame(width: 80, height: 80)
        }
    }

    private var avatarFallback: some View {
        Image(systemName: "person.crop.circle.fill")
            .resizable()
            .scaledToFit()
            .foregroundStyle(.secondary)
    }

    private func badgeIcon(_ badge: PersonOfficialBadge) -> some View {
        Group {
            if let url = badge.iconURL {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    Image(systemName: "checkmark.seal.fill")
                }
            } else {
                Image(systemName: "checkmark.seal.fill")
            }
        }
        .frame(width: 18, height: 18)
        .foregroundStyle(Color.accentColor)
        .accessibilityLabel(badge.description)
    }

    private var statistics: some View {
        HStack(spacing: 0) {
            statistic(profile.answerCount, "回答", .answers)
            statistic(profile.articleCount, "文章", .articles)
            statistic(profile.followerCount, "粉丝", .followers)
            statistic(profile.followingCount, "关注", .following)
        }
    }

    private func statistic(_ count: Int, _ label: String, _ tab: PersonTab) -> some View {
        Button { onSelectTab(tab) } label: {
            VStack(spacing: 3) {
                Text(count.formatted(.number.notation(.compactName)))
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.primary)
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(count) \(label)")
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 12) {
            followButton.buttonStyle(.borderedProminent)
            blockButton.buttonStyle(.bordered)
        }
    }

    private var followButton: some View {
        Button(action: onFollow) {
            actionLabel(
                title: profile.isFollowing ? "取消关注" : "关注",
                systemImage: profile.isFollowing ? "person.badge.minus" : "person.badge.plus",
                isLoading: followState.isInFlight
            )
        }
        .disabled(followState.isInFlight)
        .accessibilityIdentifier("person_follow_button")
    }

    private var blockButton: some View {
        Button(action: onBlock) {
            actionLabel(
                title: profile.isBlocking ? "取消拉黑" : "拉黑",
                systemImage: profile.isBlocking ? "person.crop.circle.badge.checkmark" : "person.crop.circle.badge.xmark",
                isLoading: blockState.isInFlight
            )
        }
        .disabled(blockState.isInFlight)
        .accessibilityIdentifier("person_block_button")
    }

    private func actionLabel(title: String, systemImage: String, isLoading: Bool) -> some View {
        HStack(spacing: 6) {
            if isLoading { ProgressView().controlSize(.small) } else { Image(systemName: systemImage) }
            Text(title)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var actionFailures: some View {
        if case let .failed(error) = followState {
            InlinePersonFailure(message: error.message, retryTitle: "重试关注操作", retry: onRetryFollow)
        }
        if case let .failed(error) = blockState {
            InlinePersonFailure(message: error.message, retryTitle: "重试拉黑操作", retry: onRetryBlock)
        }
    }
}

struct InlinePersonFailure: View {
    let message: String
    let retryTitle: String
    let retry: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("重试", action: retry)
                .font(.callout.weight(.semibold))
                .accessibilityLabel(retryTitle)
        }
        .padding(.vertical, 4)
    }
}
