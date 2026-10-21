import ApplicationServices

enum RelayKeyboardEvent {
    static let marker: Int64 = 0x52454C4159
    static func post(_ event: CGEvent?) {
        event?.setIntegerValueField(.eventSourceUserData, value: marker)
        event?.post(tap: .cghidEventTap)
    }
}
