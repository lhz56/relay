import Foundation

public enum ChromeLaunchPolicy {
    /// Decode only argv from KERN_PROCARGS2; environment entries are not arguments.
    public static func isHeadless(_ data: Data) -> Bool? {
        let bytes = Array(data)
        guard bytes.count > 4 else { return nil }
        let count = (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[$1]) << ($1 * 8) }
        guard count > 0, count <= 4096 else { return nil }
        var cursor = 4
        // Executable path followed by padding, then argc null-terminated arguments.
        while cursor < bytes.count, bytes[cursor] != 0 { cursor += 1 }
        while cursor < bytes.count, bytes[cursor] == 0 { cursor += 1 }
        var headless = false
        for index in 0..<Int(count) {
            let start = cursor
            while cursor < bytes.count, bytes[cursor] != 0 { cursor += 1 }
            guard cursor < bytes.count,
                  let argument = String(bytes: bytes[start..<cursor], encoding: .utf8) else { return nil }
            if index > 0, argument == "--headless" || argument.hasPrefix("--headless=") { headless = true }
            cursor += 1
        }
        return headless
    }

    public static func needsVisibleInstance(_ headlessStates: [Bool?]) -> Bool {
        !headlessStates.isEmpty && headlessStates.allSatisfy { $0 == true }
    }
}
