import SwiftUI

struct LauncherTab: View {
    let launcherService: LauncherService
    let onLaunch: () -> Void

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    var body: some View {
        VStack(spacing: 10) {
            searchField

            ScrollView {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(Array(launcherService.filteredApps.enumerated()), id: \.element.id) { index, app in
                        appButton(app: app, index: index)
                    }
                }
                .padding(.horizontal, 8)
            }
        }
        .padding(.horizontal, 4)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.4))
            TextField("搜索应用", text: Binding(
                get: { launcherService.searchText },
                set: { launcherService.searchText = $0 }
            ))
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(.white)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.white.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func appButton(app: AppItem, index: Int) -> some View {
        Button {
            launcherService.launchApp(at: index)
            onLaunch()
        } label: {
            VStack(spacing: 4) {
                Group {
                    if let data = app.iconData, let nsImage = NSImage(data: data) {
                        Image(nsImage: nsImage)
                            .resizable()
                    } else {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(.white.opacity(0.1))
                            .overlay {
                                Image(systemName: "app")
                                    .foregroundStyle(.white.opacity(0.3))
                            }
                    }
                }
                .frame(width: 36, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                Text(app.name)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .buttonStyle(.plain)
    }
}
