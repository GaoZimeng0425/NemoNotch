import SwiftUI

struct TabBarView: View {
    @Environment(NotchCoordinator.self) var coordinator
    @Environment(AppSettings.self) var appSettings

    var body: some View {
        HStack(spacing: 16) {
            ForEach(Tab.sorted(appSettings.enabledTabs)) { tab in
                Button {
                    withAnimation(.interactiveSpring(duration: 0.3)) {
                        coordinator.selectedTab = tab
                    }
                } label: {
                    Image(systemName: tab.icon)
                        .font(.system(size: 14))
                        .foregroundStyle(coordinator.selectedTab == tab ? .white : .gray)
                }
                .buttonStyle(.plain)
            }
        }
    }
}
