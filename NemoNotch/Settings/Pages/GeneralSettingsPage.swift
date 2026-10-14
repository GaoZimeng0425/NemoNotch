import SwiftUI

/// 通用设置:可见标签页 / 默认标签页 / 天气城市 / 语言。
struct GeneralSettingsPage: View {
    @Environment(AppSettings.self) var appSettings
    @Environment(WeatherService.self) var weatherService

    @State private var cityDebounceTask: Task<Void, Never>? = nil

    var body: some View {
        Form {
            Section("settings.visible_tabs") {
                ForEach(Tab.allCases) { tab in
                    Toggle(tab.title, isOn: Binding(
                        get: { appSettings.enabledTabs.contains(tab) },
                        set: { enabled in
                            if enabled {
                                appSettings.enabledTabs.insert(tab)
                            } else if appSettings.enabledTabs.count > 1 {
                                appSettings.enabledTabs.remove(tab)
                            }
                        }
                    ))
                }
            }

            Section("settings.default_tab") {
                Picker("settings.default_tab_picker", selection: Binding(
                    get: { appSettings.defaultTab },
                    set: { appSettings.defaultTab = $0 }
                )) {
                    ForEach(Tab.sorted(appSettings.enabledTabs)) { tab in
                        Text(tab.title).tag(tab)
                    }
                }
            }

            Section {
                TextField("settings.weather_city_placeholder", text: Binding(
                    get: { appSettings.weatherCity },
                    set: { appSettings.weatherCity = $0 }
                ))
                .onChange(of: appSettings.weatherCity) { _, newCity in
                    cityDebounceTask?.cancel()
                    cityDebounceTask = Task {
                        try? await Task.sleep(for: .milliseconds(800))
                        guard !Task.isCancelled else { return }
                        weatherService.updateCity(newCity)
                    }
                }
            } header: {
                Text("settings.weather_city")
            } footer: {
                Text("settings.weather_city_footer")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("settings.language") {
                Picker("settings.language", selection: Binding(
                    get: { appSettings.language },
                    set: { appSettings.language = $0 }
                )) {
                    ForEach(AppLanguage.allCases, id: \.self) { lang in
                        Text(languageDisplayName(lang)).tag(lang)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func languageDisplayName(_ language: AppLanguage) -> String {
        switch language {
        case .system: return String(localized: "settings.language.system")
        case .en: return String(localized: "settings.language.en")
        case .zhHans: return String(localized: "settings.language.zh")
        }
    }
}
