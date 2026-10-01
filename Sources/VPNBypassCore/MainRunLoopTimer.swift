import Foundation

extension Timer {
    /// Schedules a timer on the main run loop in its common modes.
    ///
    /// `Timer.scheduledTimer` adds the timer in the default mode only. AppKit runs a modal
    /// alert (`NSAlert.runModal`, such as the mode switch question) in the modal panel mode
    /// and an open menu in the event tracking mode, so a default-mode timer does not fire
    /// until the alert is answered or the menu closes. The common modes include both.
    @discardableResult
    static func scheduledInCommonModes(
        withTimeInterval interval: TimeInterval,
        repeats: Bool,
        block: @escaping @Sendable (Timer) -> Void
    ) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: repeats, block: block)
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }
}
