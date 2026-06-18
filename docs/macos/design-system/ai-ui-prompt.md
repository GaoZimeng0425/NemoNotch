---
summary: 'Reusable prompt for asking AI assistants to implement NemoNotch UI in the Warm Noir Utility style.'
read_when:
  - 'starting an AI-assisted UI implementation task'
  - 'copying design instructions into another AI coding session'
---

# AI UI Prompt

Use this prompt when asking an AI assistant to build, refactor, or review NemoNotch UI.

```text
You are working in the NemoNotch macOS app.

Before changing UI, read:
- docs/macos/design-system/warm-noir-utility.md
- NemoNotch/Helpers/ViewModifiers.swift
- NemoNotch/Helpers/Constants.swift
- the nearest existing component for the target surface:
  - AI/session UI: NemoNotch/Tabs/AIChatTab.swift
  - agent UI: NemoNotch/Tabs/AgentMonitorTab.swift
  - metrics/system UI: NemoNotch/Tabs/SystemTab.swift
  - shell/navigation/HUD: NemoNotch/Notch/NotchView.swift and NemoNotch/Notch/HUDOverlayView.swift

Implement the requested UI in the Warm Noir Utility style:
- black floating macOS HUD surfaces
- restrained warm orange state/action accents
- SF Pro-like system typography
- compact utility layout
- subtle 0.6-1px borders
- source/status badges as compact capsules
- active state dot/glow only where meaningful
- no marketing-page composition
- no decorative gradients/orbs/bokeh
- no glass-card dashboard look
- no large orange panels
- no emoji for core controls

Reuse NotchTheme, NotchConstants, notchCard, NotchPillButtonStyle, PulseModifier, GlowPulseModifier, and notchScrollEdgeShadow where appropriate. Keep dynamic text stable with lineLimit/truncation/fixed slots. Use monospaced numbers for metrics. Localize user-facing strings.

Before finishing, check the result against docs/macos/design-system/ui-review-checklist.md.
```

