import AppKit
import SwiftUI

/// What happened in the agent's lifecycle — drives the card's wording.
/// The second axis next to `CompletionSource` (who): kind never changes the
/// logo, and source never changes the kind.
///
/// Spec: docs/superpowers/specs/2026-11-03-reminder-kind-tone-design.md —
/// "只有需要用户接手的时刻才提醒;颜色表达接手原因,枚举表达具体事件。"
enum ReminderKind: Equatable {
    /// A turn finished (Stop / AfterAgent) — the floor is yours.
    case turnDone
    /// AskUserQuestion is parked on the user's choice.
    case needsDecision
    /// ExitPlanMode is parked on the user's plan review.
    case needsPlanApproval
    /// A tool permission (Bash / Edit / …) is parked on the user's click.
    case needsApproval
    /// An OpenClaw/Hermes agent ended in its error state.
    case agentError
    /// The CLI hit an API error / rate limit and stopped mid-turn.
    case apiError
    /// The CLI process vanished with work unfinished (no Stop ever came).
    case sessionLost

    var tone: ReminderTone {
        switch self {
        case .turnDone: .green
        case .needsDecision, .needsPlanApproval: .amber
        case .needsApproval: .blue
        case .agentError, .apiError, .sessionLost: .red
        }
    }

    /// The attention kind for a tool that is awaiting approval:
    /// question-shaped tools want a decision, plan approval wants a review,
    /// everything else — including an unknown or missing tool name — wants a
    /// permission click. Same normalization as
    /// `PermissionContext.isInteractiveTool` (SessionPhase.swift).
    static func attentionKind(forToolName toolName: String?) -> ReminderKind {
        let normalized = (toolName ?? "").replacingOccurrences(of: "_", with: "").lowercased()
        if normalized == "askuserquestion" || normalized == "askuser" {
            return .needsDecision
        }
        if normalized == "exitplanmode" {
            return .needsPlanApproval
        }
        return .needsApproval
    }
}

/// The reaction the user must have — drives the card ring and the full-screen
/// glow. Colors encode "how you're needed", never "which event": peripheral
/// vision separates at most ~4 hues, so every future kind maps onto one of
/// these instead of inventing a color. Single source of truth for every
/// reminder surface (edge bar precedent: `EdgeBarPalette`).
enum ReminderTone: CaseIterable, Equatable {
    /// Come back and look — work finished.
    case green
    /// Come decide — a question/plan is parked on you.
    case amber
    /// Come click allow — a permission is parked on you.
    case blue
    /// Come rescue — something broke.
    case red

    /// The tone's base/light/deep triple (spec's verbatim palette).
    private var triple: (main: Color, light: Color, deep: Color) {
        switch self {
        case .green:
            (
                Color(red: 0.30, green: 0.85, blue: 0.45),
                Color(red: 0.71, green: 0.95, blue: 0.78),
                Color(red: 0.13, green: 0.66, blue: 0.33)
            )
        case .amber:
            (
                Color(red: 1.0, green: 0.72, blue: 0.18),
                Color(red: 1.0, green: 0.88, blue: 0.54),
                Color(red: 0.88, green: 0.56, blue: 0.0)
            )
        case .blue:
            (
                Color(red: 0.25, green: 0.62, blue: 1.0),
                Color(red: 0.65, green: 0.82, blue: 1.0),
                Color(red: 0.12, green: 0.44, blue: 0.82)
            )
        case .red:
            (
                Color(red: 1.0, green: 0.37, blue: 0.34),
                Color(red: 1.0, green: 0.70, blue: 0.68),
                Color(red: 0.85, green: 0.19, blue: 0.15)
            )
        }
    }

    /// The conic ring stops for the card border: main → light → deep → main
    /// (first == last keeps the gradient seamless through the turn).
    var ring: [NSColor] {
        [NSColor(triple.main), NSColor(triple.light), NSColor(triple.deep), NSColor(triple.main)]
    }

    /// Main color for the full-screen glow's outer strokes.
    var main: Color {
        triple.main
    }

    /// Hotter, more saturated partner for the glow's inner rim
    /// (replaces `NotchTheme.accentHot`'s role in the neon stack).
    var hot: Color {
        switch self {
        case .green: Color(red: 0.44, green: 0.96, blue: 0.59)
        case .amber: Color(red: 1.0, green: 0.62, blue: 0.10)
        case .blue: Color(red: 0.17, green: 0.55, blue: 1.0)
        case .red: Color(red: 1.0, green: 0.48, blue: 0.45)
        }
    }

    /// Same-batch glow arbitration: red outranks amber outranks blue
    /// outranks green — rescue first (spec, 审计口径 5).
    var flashPriority: Int {
        switch self {
        case .red: 3
        case .amber: 2
        case .blue: 1
        case .green: 0
        }
    }

    /// The one tone whose glow flashes when several arrive in the same
    /// batch; nil when the batch is empty.
    static func pick(_ tones: [ReminderTone]) -> ReminderTone? {
        tones.max { $0.flashPriority < $1.flashPriority }
    }
}
