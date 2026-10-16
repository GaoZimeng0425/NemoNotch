import SwiftUI

/// The chat bubble's content: message list (assistant text rendered as
/// markdown), a permission card when the session waits for approval, and a
/// single-line input. The permission card reuses the store phase maintained
/// by the CLI's own hooks — the bubble adds no second permission mechanism.
struct ChatBubbleView: View {
    @Environment(ChatBubbleController.self) var controller
    @Environment(AISessionStore.self) var store

    @State private var draft = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(NotchTheme.stroke)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if controller.messages.isEmpty {
                            emptyHint
                        }
                        ForEach(controller.messages) { message in
                            messageRow(message).id(message.id)
                        }
                        if let tool = controller.runningTool {
                            toolBadge(tool)
                        }
                        permissionCard
                    }
                    .padding(12)
                }
                .onChange(of: controller.messages.count) { _, _ in
                    withAnimation(.snappy) {
                        proxy.scrollTo(controller.messages.last?.id, anchor: .bottom)
                    }
                }
                .onChange(of: controller.messages.last?.text) { _, _ in
                    proxy.scrollTo(controller.messages.last?.id, anchor: .bottom)
                }
            }
            inputBar
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(LinearGradient(
                    colors: [NotchTheme.panelRaised, NotchTheme.panelBase],
                    startPoint: .top,
                    endPoint: .bottom
                ))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(NotchTheme.stroke, lineWidth: 0.6)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(NotchTheme.accentText)
            Text("Claude")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(NotchTheme.textPrimary)
            Spacer()
            Button {
                controller.hide()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(NotchTheme.textSecondary)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(NotchTheme.surface))
                    .overlay(Circle().stroke(NotchTheme.stroke, lineWidth: 0.6))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var emptyHint: some View {
        Text("chat_bubble.empty_hint")
            .font(.system(size: 11))
            .foregroundStyle(NotchTheme.textTertiary)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func messageRow(_ message: ChatBubbleController.BubbleMessage) -> some View {
        switch message.role {
        case .user:
            HStack(alignment: .top, spacing: 6) {
                Text(message.text)
                    .font(.system(size: 11))
                    .foregroundStyle(NotchTheme.textSecondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(NotchTheme.accent.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                Spacer(minLength: 24)
            }
        case .assistant:
            HStack(alignment: .top, spacing: 0) {
                if message.text.isEmpty, message.isStreaming {
                    Text("…")
                        .font(.system(size: 11))
                        .foregroundStyle(NotchTheme.textTertiary)
                } else {
                    MarkdownRenderer.render(message.text)
                        .font(.system(size: 11))
                        .foregroundStyle(NotchTheme.textPrimary)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 12)
            }
        }
    }

    private func toolBadge(_ tool: String) -> some View {
        HStack(spacing: 5) {
            ProgressView()
                .controlSize(.mini)
            Text(tool)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(NotchTheme.textSecondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(NotchTheme.surface)
        .clipShape(Capsule(style: .continuous))
    }

    @ViewBuilder
    private var permissionCard: some View {
        if let session = store.get(controller.claudeSessionId),
           case let .waitingForApproval(ctx) = session.phase {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color(red: 1.0, green: 0.34, blue: 0.28))
                        .frame(width: 7, height: 7)
                    Text("chat_bubble.permission_title")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(NotchTheme.textPrimary)
                }
                Text(ctx.toolName)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(NotchTheme.textSecondary)
                HStack(spacing: 6) {
                    answerButton("chat_bubble.deny", tint: Color(red: 1.0, green: 0.34, blue: 0.28)) {
                        controller.respondToPermission(approved: false)
                    }
                    answerButton("chat_bubble.allow", tint: Color(red: 0.30, green: 0.85, blue: 0.45)) {
                        controller.respondToPermission(approved: true)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(red: 1.0, green: 0.34, blue: 0.28).opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color(red: 1.0, green: 0.34, blue: 0.28).opacity(0.35), lineWidth: 0.8)
            )
        }
    }

    private func answerButton(_ titleKey: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(LocalizedStringKey(titleKey))
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(tint)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(tint.opacity(0.16))
                .clipShape(Capsule(style: .continuous))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("chat_bubble.placeholder", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(NotchTheme.textPrimary)
                .lineLimit(1 ... 4)
                .focused($inputFocused)
                .onSubmit { submit() }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(NotchTheme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            if controller.isTurnRunning {
                Button {
                    controller.stopTurn()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color(red: 1.0, green: 0.34, blue: 0.28))
                        .frame(width: 30, height: 30)
                        .background(NotchTheme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("chat_bubble.stop")
            } else {
                Button {
                    submit()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(draft.trimmingCharacters(in: .whitespaces).isEmpty ? NotchTheme
                            .textTertiary : NotchTheme.accentText)
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .onAppear { inputFocused = true }
    }

    private func submit() {
        let text = draft
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty, !controller.isTurnRunning else { return }
        draft = ""
        controller.send(text)
    }
}
