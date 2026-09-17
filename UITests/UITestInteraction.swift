import XCTest

/// Interacting with an element that exists but is not ready yet is the single most common way a
/// UI test in this suite fails for a reason that has nothing to do with what it is testing.
///
/// Three of them were observed in one day: a tap delivered while a form sheet was still animating
/// in was dropped and the test waited out a button that would never come (#35); a text field was
/// tapped before its sheet had presented and reported "No matches found"; and a tap on Settings
/// reported "Timed out while synthesizing event" after the app spent half a minute not idle.
///
/// `waitForExistence` does not cover any of those. An element exists as soon as it is in the
/// accessibility tree, which is before it has arrived where it is going and before it can be
/// touched. `isHittable` is the question worth asking, and asking it is what these do.
extension XCUIElement {
    /// Waits for the element to be there and touchable, then taps it.
    ///
    /// The timeout is patience, not a deadline anything has to meet: reaching it means the test
    /// was going to fail regardless, and twenty seconds is not long on a CI runner that has been
    /// building for half an hour and is on its second simulator.
    ///
    /// Throws rather than only recording a failure. `continueAfterFailure` is true by default, so
    /// a helper that failed and returned would let the caller carry on: `typeWhenReady` would
    /// then type into nothing and raise a second, unrelated "no keyboard focus" error on top of
    /// the real one, and every later helper in the test would spend its own twenty seconds
    /// before doing the same — three times over, now that CI retries. Stopping at the first
    /// unmet precondition keeps the report about the thing that actually went wrong.
    @MainActor
    func tapWhenReady(timeout: TimeInterval = 20, file: StaticString = #filePath, line: UInt = #line) throws {
        guard waitUntilHittable(timeout: timeout) else {
            XCTFail("\(self) never became hittable", file: file, line: line)
            throw UITestInteractionError.neverBecameHittable(String(describing: self))
        }
        tap()
    }

    /// Taps and types in one step, which is the shape every form in these tests uses.
    @MainActor
    func typeWhenReady(_ text: String, timeout: TimeInterval = 20,
                       file: StaticString = #filePath, line: UInt = #line) throws {
        try tapWhenReady(timeout: timeout, file: file, line: line)
        typeText(text)
    }

    /// True once the element is present and can receive a touch. Polls rather than using a
    /// predicate expectation so a caller can decide what a timeout means.
    @MainActor
    @discardableResult
    func waitUntilHittable(timeout: TimeInterval = 20) -> Bool {
        if exists, isHittable { return true }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if exists, isHittable { return true }
            // An explicit sleep, not `waitForExistence(timeout:)`. That returns immediately when
            // the element already exists, which is exactly the case here — present but not yet
            // touchable — so using it as the throttle spins on back-to-back accessibility
            // snapshots for the whole timeout. Querying the app that hard is a poor way to wait
            // for it to settle.
            Thread.sleep(forTimeInterval: 0.05)
        }
        return exists && isHittable
    }
}

enum UITestInteractionError: Error, CustomStringConvertible {
    case neverBecameHittable(String)

    var description: String {
        switch self {
        case let .neverBecameHittable(element): return "\(element) never became hittable"
        }
    }
}
