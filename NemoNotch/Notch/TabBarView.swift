import SwiftUI

struct TabBarView: View {
    @Environment(NotchCoordinator.self) var coordinator
    @Environment(AppSettings.self) var appSettings

    var body: some View {
        HStack(spacing: 12) {
            ForEach(Tab.sorted(appSettings.enabledTabs)) { tab in
                let selected = coordinator.selectedTab == tab
                Button {
                    withAnimation(.interactiveSpring(duration: 0.3)) {
                        coordinator.selectedTab = tab
                    }
                } label: {
                    Image(systemName: tab.icon)
                        .font(.system(size: 12))
                        .foregroundStyle(selected ? .white : .white.opacity(0.35))
                        .frame(width: 28, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(selected ? .white.opacity(0.15) : .clear)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }
}
