import Foundation

/// Runs `item` after `delay`, ON THE MAIN QUEUE (the items assume the main
/// actor). Injected wherever a timing decision needs a unit test that fires
/// the pending work by hand instead of waiting on the wall clock
/// (`EdgeBarHoverIntent`, `EdgeBarRowSwitch`, the badge debounce).
typealias DelayScheduler = (TimeInterval, DispatchWorkItem) -> Void

func mainDelayScheduler(_ delay: TimeInterval, _ item: DispatchWorkItem) {
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
}
