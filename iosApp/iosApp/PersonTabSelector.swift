import SwiftUI

struct PersonTabSelector: View {
    let selection: PersonTab
    let onSelect: (PersonTab) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            tabs
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.horizontal, 4)
        }
        .accessibilityIdentifier("person_main_tabs")
    }

    private var tabs: some View {
        HStack(spacing: 8) {
            ForEach(PersonTab.profileContentTabs) { tab in
                Button(tab.title) { onSelect(tab) }
                    .font(.subheadline.weight(selection == tab ? .semibold : .regular))
                    .buttonStyle(PersonGlassTabButtonStyle(isSelected: selection == tab))
                    .accessibilityAddTraits(selection == tab ? .isSelected : [])
                    .accessibilityIdentifier("person_tab_\(tab.rawValue)")
            }
        }
    }
}

struct PersonSubscriptionTabSelector: View {
    let selection: PersonSubscriptionTab
    let onSelect: (PersonSubscriptionTab) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(PersonSubscriptionTab.allCases) { tab in
                    Button(tab.title) { onSelect(tab) }
                        .font(.caption.weight(selection == tab ? .semibold : .regular))
                        .buttonStyle(PersonGlassTabButtonStyle(isSelected: selection == tab))
                        .accessibilityAddTraits(selection == tab ? .isSelected : [])
                        .accessibilityIdentifier("person_subscription_tab_\(tab.rawValue)")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .accessibilityIdentifier("person_subscription_tabs")
    }
}

private struct PersonGlassTabButtonStyle: ButtonStyle {
    let isSelected: Bool

    @ViewBuilder
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .padding(.horizontal, 14)
            .frame(minHeight: 38)
            .background(isSelected ? Color.accentColor : Color.secondary.opacity(0.1), in: Capsule())
            .opacity(configuration.isPressed ? 0.78 : 1)
    }
}

struct PersonSortControl: View {
    let selection: PersonContentSort
    let onSelect: (PersonContentSort) -> Void

    var body: some View {
        Picker("排序", selection: Binding(get: { selection }, set: onSelect)) {
            ForEach(PersonContentSort.allCases) { sort in
                Text(sort.title).tag(sort)
            }
        }
        .pickerStyle(.segmented)
        .padding(.vertical, 6)
        .accessibilityIdentifier("person_sort_control")
    }
}
