import SwiftUI

struct TabBarView: View {
    @Bindable var coordinator: NotchCoordinator
    let enabledTabs: Set<Tab>

    var body: some View {
        HStack(spacing: 16) {
            ForEach(Array(enabledTabs.sorted { Tab.allCases.firstIndex(of: $0)! < Tab.allCases.firstIndex(of: $1)! })) { tab in
                Button {
                    coordinator.selectedTab = tab
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
