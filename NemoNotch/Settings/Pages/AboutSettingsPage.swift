import SwiftUI

/// 关于:应用图标 / 版本 / 仓库链接 / 开源致谢。
struct AboutSettingsPage: View {
    private static let githubURL = URL(string: "https://github.com/GaoZimeng0425/NemoNotch")!
    private static let releasesURL = URL(string: "https://github.com/GaoZimeng0425/NemoNotch/releases")!
    private static let issuesURL = URL(string: "https://github.com/GaoZimeng0425/NemoNotch/issues/new")!

    /// App version for display, e.g. "1.0 (1)". Read from the built Info.plist
    /// (populated from MARKETING_VERSION / CURRENT_PROJECT_VERSION in
    /// project.pbxproj since GENERATE_INFOPLIST_FILE = YES).
    private var appVersionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    /// Bundled open-source dependencies credited in the About tab, matching the
    /// resolved Swift Package graph (Package.resolved).
    private static let acknowledgements: [(name: String, url: URL)] = [
        ("CocoaLumberjack", URL(string: "https://github.com/CocoaLumberjack/CocoaLumberjack")!),
        ("KeyboardShortcuts", URL(string: "https://github.com/sindresorhus/KeyboardShortcuts")!),
        ("mediaremote-adapter", URL(string: "https://github.com/ejbills/mediaremote-adapter")!),
        ("swift-log", URL(string: "https://github.com/apple/swift-log")!),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if let icon = NSApp.applicationIconImage {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 96, height: 96)
                        .accessibilityHidden(true)
                }

                VStack(spacing: 4) {
                    Text("NemoNotch \(appVersionString)")
                        .font(.title3).fontWeight(.semibold)
                        .textSelection(.enabled)
                    Text("settings.about.tagline")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 18) {
                    Link("settings.about.github", destination: Self.githubURL)
                    Link("settings.about.check_updates", destination: Self.releasesURL)
                    Link("settings.about.report_issue", destination: Self.issuesURL)
                }
                .font(.callout)

                Divider().padding(.vertical, 2)

                VStack(spacing: 6) {
                    Text("settings.about.acknowledgements")
                        .font(.caption).fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                    ForEach(Self.acknowledgements, id: \.name) { dep in
                        Link(dep.name, destination: dep.url)
                            .font(.callout)
                    }
                }

                Text("settings.about.copyright")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
            }
            .frame(maxWidth: .infinity)
            .padding()
        }
    }
}
