import SwiftUI

struct TabBarView: View {
    @Environment(NotchCoordinator.self) var coordinator
    @Environment(AppSettings.self) var appSettings

    var body: some View {
        VStack(spacing: 6) {
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

            let tabs = Tab.sorted(appSettings.enabledTabs)
            if tabs.count > 1 {
                HStack(spacing: 4) {
                    ForEach(tabs) { tab in
                        Circle()
                            .fill(coordinator.selectedTab == tab ? .white : .white.opacity(0.3))
                            .frame(width: 4, height: 4)
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: coordinator.selectedTab)
            }
        }
    }
}
