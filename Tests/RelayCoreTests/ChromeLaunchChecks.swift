import Foundation
import RelayCore

enum ChromeLaunchChecks {
    private static func fixture(_ arguments: [String], environment: [String] = []) -> Data {
        var count = UInt32(arguments.count).littleEndian
        var data = withUnsafeBytes(of: &count) { Data($0) }
        data.append(contentsOf: Array("/Applications/Chrome".utf8) + [0, 0, 0])
        for argument in arguments + environment { data.append(contentsOf: Array(argument.utf8) + [0]) }
        return data
    }
    static func run() {
        // 1. Both supported flag forms identify a background browser.
        checkEqual(ChromeLaunchPolicy.isHeadless(fixture(["Chrome", "--headless"])), true)
        checkEqual(ChromeLaunchPolicy.isHeadless(fixture(["Chrome", "--headless=new"])), true)
        // 2. A URL, profile path or environment value must not count as a flag.
        checkEqual(ChromeLaunchPolicy.isHeadless(fixture(["Chrome", "https://example.com/--headless", "--user-data-dir=/tmp/--headless"], environment: ["--headless"])), false)
        // 3. Empty argv entries do not hide later flags.
        checkEqual(ChromeLaunchPolicy.isHeadless(fixture(["Chrome", "", "--headless"])), true)
        // 4. Corrupt/incomplete data must not launch another browser instance.
        checkEqual(ChromeLaunchPolicy.isHeadless(Data([1, 0, 0, 0])), nil)
        checkEqual(ChromeLaunchPolicy.isHeadless(fixture(["Chrome", "--headless"]).dropLast()), nil)
        // 5. Only a confirmed all-headless set needs a visible instance.
        checkTrue(ChromeLaunchPolicy.needsVisibleInstance([true, true]))
        checkFalse(ChromeLaunchPolicy.needsVisibleInstance([]))
        checkFalse(ChromeLaunchPolicy.needsVisibleInstance([true, nil]))
        checkFalse(ChromeLaunchPolicy.needsVisibleInstance([true, false]))
    }
}
