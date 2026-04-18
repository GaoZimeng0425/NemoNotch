import SwiftUI

struct NotchView: View {
    let coordinator: NotchCoordinator
    let enabledTabs: Set<Tab>

    private var screen: NSScreen { NSScreen.main! }
    private var hasNotch: Bool { screen.hasNotch }
    private var hardwareNotchSize: NSSize { coordinator.notchSize }

    private var notchSize: CGSize {
        switch coordinator.status {
        case .closed:
            CGSize(width: hardwareNotchSize.width - 4, height: hardwareNotchSize.height - 4)
        case .popping:
            CGSize(width: hardwareNotchSize.width, height: hardwareNotchSize.height + 4)
        case .opened:
            CGSize(width: 500, height: 260)
        }
    }

    private var notchCornerRadius: CGFloat {
        switch coordinator.status {
        case .closed: 8
        case .popping: 10
        case .opened: 24
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            notchShape
                .zIndex(0)

            if coordinator.status == .popping {
                poppingButtons
                    .zIndex(1)
                    .transition(.opacity)
            }

            if coordinator.status == .opened {
                openedContent
                    .zIndex(1)
                    .transition(.scale.combined(with: .opacity).combined(with: .offset(y: -130)))
            }
        }
        .animation(.interactiveSpring(duration: 0.314), value: coordinator.status)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
    }

    private var notchShape: some View {
        NotchBackgroundView(
            status: coordinator.status,
            notchSize: notchSize,
            hasNotch: hasNotch,
            cornerRadius: notchCornerRadius,
            spacing: 16
        )
    }

    private var poppingButtons: some View {
        HStack(spacing: 14) {
            ForEach(sortedTabs) { tab in
                Button {
                    coordinator.notchOpen(tab: tab)
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 14, weight: .medium))
                        Text(tab.title)
                            .font(.system(size: 8))
                    }
                    .foregroundStyle(.white.opacity(0.9))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, hardwareNotchSize.height + 8)
    }

    private var openedContent: some View {
        VStack(spacing: 0) {
            TabBarView(coordinator: coordinator, enabledTabs: enabledTabs)
                .padding(.top, hardwareNotchSize.height + 10)

            Spacer()

            Text(coordinator.selectedTab.title)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.4))
                .padding(.bottom, 14)
        }
        .padding(.horizontal, 20)
        .frame(width: notchSize.width + notchCornerRadius * 2, height: notchSize.height)
    }

    private var sortedTabs: [Tab] {
        enabledTabs.sorted { Tab.allCases.firstIndex(of: $0)! < Tab.allCases.firstIndex(of: $1)! }
    }
}
