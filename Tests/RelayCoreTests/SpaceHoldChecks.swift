import RelayCore

enum SpaceHoldChecks {
    static func run() {
        var hold = SpaceHoldGate()
        // 1. A quick tap or a slightly short hold cannot start the microphone.
        checkTrue(hold.press(at: 10, isRepeat: false, hasModifiers: false))
        checkFalse(hold.activate(at: 12.49, spaceIsDown: true, hasModifiers: false))
        hold.cancel()
        checkFalse(hold.activate(at: 13, spaceIsDown: false, hasModifiers: false))
        // 2. Fire at exactly 2.5 seconds, once even if the key stays down.
        checkTrue(hold.press(at: 20, isRepeat: false, hasModifiers: false))
        checkTrue(hold.activate(at: 22.5, spaceIsDown: true, hasModifiers: false))
        checkFalse(hold.activate(at: 60, spaceIsDown: true, hasModifiers: false))
        checkFalse(hold.press(at: 61, isRepeat: true, hasModifiers: false))
        checkFalse(hold.activate(at: 64, spaceIsDown: true, hasModifiers: false))
        checkTrue(hold.release())
        checkFalse(hold.release())
        // 3. Auto-repeat does not reset the original deadline or start a stray hold.
        hold.cancel()
        checkFalse(hold.press(at: 70, isRepeat: true, hasModifiers: false))
        checkFalse(hold.activate(at: 73, spaceIsDown: true, hasModifiers: false))
        checkTrue(hold.press(at: 80, isRepeat: false, hasModifiers: false))
        checkFalse(hold.press(at: 81, isRepeat: true, hasModifiers: false))
        checkTrue(hold.activate(at: 82.5, spaceIsDown: true, hasModifiers: false))
        // 4. Modified Space is a different shortcut, including modifiers added mid-hold.
        hold.cancel()
        checkFalse(hold.press(at: 90, isRepeat: false, hasModifiers: true))
        checkFalse(hold.activate(at: 93, spaceIsDown: true, hasModifiers: false))
        checkTrue(hold.press(at: 100, isRepeat: false, hasModifiers: false))
        checkFalse(hold.activate(at: 103, spaceIsDown: true, hasModifiers: true))
        checkFalse(hold.activate(at: 104, spaceIsDown: true, hasModifiers: false))
        // 5. Missing a key-up event is caught by the physical key check.
        checkTrue(hold.press(at: 110, isRepeat: false, hasModifiers: false))
        checkFalse(hold.activate(at: 113, spaceIsDown: false, hasModifiers: false))
        checkFalse(hold.activate(at: 114, spaceIsDown: true, hasModifiers: false))
        // 6. A release/repress starts a fresh deadline, not the old hold's deadline.
        checkTrue(hold.press(at: 120, isRepeat: false, hasModifiers: false))
        hold.cancel()
        checkTrue(hold.press(at: 122, isRepeat: false, hasModifiers: false))
        checkFalse(hold.activate(at: 122.5, spaceIsDown: true, hasModifiers: false))
        checkTrue(hold.activate(at: 124.5, spaceIsDown: true, hasModifiers: false))
        // 7. Sleep, a different key, or a permission loss cancels a pending hold.
        hold.cancel()
        checkTrue(hold.press(at: 130, isRepeat: false, hasModifiers: false))
        hold.cancel()
        checkFalse(hold.press(at: 134, isRepeat: true, hasModifiers: false))
        checkFalse(hold.activate(at: 140, spaceIsDown: true, hasModifiers: false))
        // 8. Duplicate non-repeat delivery cannot move the deadline or fire twice.
        checkTrue(hold.press(at: 150, isRepeat: false, hasModifiers: false))
        checkFalse(hold.press(at: 151, isRepeat: false, hasModifiers: false))
        checkTrue(hold.activate(at: 152.5, spaceIsDown: true, hasModifiers: false))
        checkFalse(hold.press(at: 153, isRepeat: false, hasModifiers: false))
        checkFalse(hold.activate(at: 156, spaceIsDown: true, hasModifiers: false))
    }
}
