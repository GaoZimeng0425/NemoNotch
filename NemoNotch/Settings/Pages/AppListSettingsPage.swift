import SwiftUI

/// 应用列表:展示/删除/拖拽排序已固定应用,底部"添加应用"打开选择 sheet。
struct AppListSettingsPage: View {
    @Environment(LauncherService.self) var launcherService

    @State private var showAppPicker = false

    var body: some View {
        List {
            ForEach(Array(launcherService.apps.enumerated()), id: \.element.id) { index, app in
                HStack(spacing: 10) {
                    if let image = launcherService.icon(for: app) {
                        Image(nsImage: image)
                            .resizable()
                            .frame(width: 28, height: 28)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(app.name)
                            .font(.body)
                        Text(app.bundleIdentifier)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        launcherService.removeApp(at: index)
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .font(.title3)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 2)
            }
            .onMove { source, destination in
                launcherService.moveApp(from: source, to: destination)
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Text("settings.apps_count \(launcherService.apps.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    launcherService.scanInstalledApps()
                    showAppPicker = true
                } label: {
                    Label("settings.add_app", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)
        }
        .sheet(isPresented: $showAppPicker) {
            appPickerSheet
        }
    }

    private var appPickerSheet: some View {
        VStack(spacing: 0) {
            Text("settings.app_picker_title")
                .font(.headline)
                .padding(.top, 16)
                .padding(.bottom, 8)

            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("launcher.search_apps", text: Binding(
                    get: { launcherService.scanSearchText },
                    set: { launcherService.scanSearchText = $0 }
                ))
                .textFieldStyle(.plain)
                if !launcherService.scanSearchText.isEmpty {
                    Button {
                        launcherService.scanSearchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(.bar)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            List(launcherService.filteredScannedApps) { app in
                let isSelected = launcherService.apps.contains { $0.bundleIdentifier == app.bundleIdentifier }
                HStack(spacing: 10) {
                    if let icon = launcherService.icon(forBundleID: app.bundleIdentifier) {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 28, height: 28)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(app.name)
                            .font(.body)
                        Text(app.bundleIdentifier)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .foregroundStyle(isSelected ? .blue : .secondary.opacity(0.5))
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    launcherService.toggleInstalledApp(app)
                }
                .padding(.vertical, 2)
            }
            .listStyle(.plain)

            HStack {
                Text("settings.apps_selected_count \(launcherService.apps.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("common.done") {
                    showAppPicker = false
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(width: 400, height: 500)
    }
}
