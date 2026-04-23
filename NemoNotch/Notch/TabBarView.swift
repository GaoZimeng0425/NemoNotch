import SwiftUI

struct TabBarView: View {
    @Environment(NotchCoordinator.self) var coordinator
    @Environment(AppSettings.self) var appSettings

    var body: some View {
        HStack(spacing: 12) {
            ForEach(Tab.sorted(appSettings.enabledTabs)) { tab in
                let selected = coordinator.selectedTab == tab
                Button {
                    coordinator.selectedTab = tab
                } label: {
                    Image(systemName: tab.icon)
                        .font(.system(size: 12, weight: selected ? .semibold : .regular, design: .rounded))
                        .foregroundStyle(selected ? NotchTheme.textPrimary : NotchTheme.textTertiary)
                        .frame(width: 28, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(selected ? NotchTheme.surfaceEmphasis : .clear)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }
}
