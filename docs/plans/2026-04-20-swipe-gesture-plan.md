# Swipe Gesture Tab Switching Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add left/right swipe gestures to the notch panel's tab content area to switch between adjacent tabs, with a sliding transition animation and dot indicators.

**Architecture:** Wrap the tab content area in a `DragGesture` handler. Track drag translation to create a live slide effect. On gesture end, if the drag exceeds a threshold, switch to the adjacent tab. Tab content uses `.id()` + transition to animate between tabs. Dot indicators below the tab bar show current position.

**Tech Stack:** Swift 5, SwiftUI (DragGesture, transitions, animation)

---

### Task 1: Add adjacent tab switching method to NotchCoordinator

**Files:**
- Modify: `NemoNotch/Notch/NotchCoordinator.swift`

Add two methods after `notchClose()`:

```swift
func selectNextTab() {
    let tabs = Tab.sorted(appSettings.enabledTabs)
    guard let index = tabs.firstIndex(of: selectedTab), index + 1 < tabs.count else { return }
    withAnimation(.interactiveSpring(duration: 0.3)) {
        selectedTab = tabs[index + 1]
    }
}

func selectPreviousTab() {
    let tabs = Tab.sorted(appSettings.enabledTabs)
    guard let index = tabs.firstIndex(of: selectedTab), index > 0 else { return }
    withAnimation(.interactiveSpring(duration: 0.3)) {
        selectedTab = tabs[index - 1]
    }
}
```

**Note:** `appSettings` needs to be accessible from NotchCoordinator. Since the coordinator is created with a closure in `AppDelegate`, add an `appSettings` property:

```swift
var appSettings: AppSettings?
```

And set it in AppDelegate after creation:
```swift
notchCoordinator.appSettings = settings
```

Commit: `feat: add selectNextTab/selectPreviousTab to NotchCoordinator`

---

### Task 2: Add swipe gesture to tab content area

**Files:**
- Modify: `NemoNotch/Notch/NotchView.swift`

Replace the `tabContent` section in `openedContent` with a swipe-enabled version.

Add a `@State` property for tracking drag:
```swift
@State private var dragOffset: CGFloat = 0
```

Replace the `openedContent` computed property's inner content area:

```swift
private var openedContent: some View {
    VStack(spacing: 0) {
        TabBarView()
            .padding(.top, hardwareNotchSize.height + NotchConstants.tabBarTopPadding)

        swipeableContent
            .padding(.top, NotchConstants.tabContentTopPadding)

        Spacer(minLength: 0)
    }
    .padding(.horizontal, NotchConstants.tabContentHorizontalPadding)
    .frame(width: notchSize.width + notchCornerRadius * 2, height: notchSize.height)
}
```

Add the new `swipeableContent` computed property:

```swift
private var swipeableContent: some View {
    let tabs = Tab.sorted(appSettings.enabledTabs)
    let currentIndex = tabs.firstIndex(of: coordinator.selectedTab) ?? 0

    return tabContent
        .id(coordinator.selectedTab)
        .offset(x: dragOffset)
        .gesture(
            DragGesture(minimumDistance: 30)
                .onChanged { value in
                    // Only allow horizontal drag
                    dragOffset = value.translation.width
                }
                .onEnded { value in
                    let threshold: CGFloat = 80
                    withAnimation(.interactiveSpring(duration: 0.3)) {
                        dragOffset = 0
                    }
                    if value.translation.width < -threshold && currentIndex + 1 < tabs.count {
                        coordinator.selectNextTab()
                    } else if value.translation.width > threshold && currentIndex > 0 {
                        coordinator.selectPreviousTab()
                    }
                }
        )
}
```

The `tabContent` view stays as-is. The `.id()` modifier causes SwiftUI to re-create the view on tab change, triggering the transition. The `offset(x: dragOffset)` provides live drag feedback.

Commit: `feat: add swipe gesture to tab content for tab switching`

---

### Task 3: Add dot indicators to TabBarView

**Files:**
- Modify: `NemoNotch/Notch/TabBarView.swift`

Add dot indicators below the tab icons:

```swift
struct TabBarView: View {
    @Environment(NotchCoordinator.self) var coordinator
    @Environment(AppSettings.self) var appSettings

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 16) {
                ForEach(Tab.sorted(appSettings.enabledTabs)) { tab in
                    Button {
                        withAnimation(.interactiveSpring(duration: 0.3)) {
                            coordinator.selectedTab = tab
                        }
                    } label: {
                        Image(systemName: tab.icon)
                            .font(.system(size: 14))
                            .foregroundStyle(coordinator.selectedTab == tab ? .white : .gray)
                    }
                    .buttonStyle(.plain)
                }
            }

            // Dot indicators
            let tabs = Tab.sorted(appSettings.enabledTabs)
            if tabs.count > 1 {
                HStack(spacing: 4) {
                    ForEach(tabs) { tab in
                        Circle()
                            .fill(coordinator.selectedTab == tab ? .white : .white.opacity(0.3))
                            .frame(width: 4, height: 4)
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: coordinator.selectedTab)
            }
        }
    }
}
```

Commit: `feat: add dot indicators to TabBarView`

---

### Task 4: Build and verify

Build the project. Fix any compilation errors.

Test behaviors:
1. Open notch → see dot indicators below tab icons
2. Drag left on content → switches to next tab (if exists)
3. Drag right on content → switches to previous tab (if exists)
4. Small drag → snaps back to current tab
5. Tab bar clicks still work
6. Tab transitions animate smoothly

Commit fixes if needed: `fix: polish swipe gesture transitions`
