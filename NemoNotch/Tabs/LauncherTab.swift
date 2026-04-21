import SwiftUI

struct LauncherTab: View {
    @Environment(LauncherService.self) var launcherService
    let onLaunch: () -> Void

    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
    ]

    var body: some View {
        VStack(spacing: 10) {
            searchField

            ScrollView {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(Array(launcherService.filteredApps.enumerated()), id: \.element.id) { index, app in
                        appButton(app: app, index: index)
                    }
                }
                .padding(.horizontal, 6)
            }
        }
        .padding(.horizontal, 4)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.35))
            TextField("搜索应用", text: Binding(
                get: { launcherService.searchText },
                set: { launcherService.searchText = $0 }
            ))
            .textFieldStyle(.plain)
            .font(.system(size: 11))
            .foregroundStyle(.white)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.white.opacity(0.08))
        )
    }

    private func appButton(app: AppItem, index: Int) -> some View {
        Button {
            launcherService.launchApp(at: index)
            onLaunch()
        } label: {
            VStack(spacing: 4) {
                if let image = launcherService.icon(for: app) {
                    Image(nsImage: image)
                        .resizable()
                        .frame(width: 32, height: 32)
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.white.opacity(0.08))
                        .frame(width: 32, height: 32)
                        .overlay {
                            Image(systemName: "app")
                                .font(.system(size: 14))
                                .foregroundStyle(.white.opacity(0.3))
                        }
                }

                Text(app.name)
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(.white.opacity(0.04))
            )
        }
        .buttonStyle(.plain)
    }
}
