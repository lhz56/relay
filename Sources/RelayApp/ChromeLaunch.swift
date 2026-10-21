import AppKit
import Darwin
import RelayCore

enum ChromeLaunch {
    @MainActor static func needsVisibleInstance(for bundleID: String?) async -> Bool {
        guard bundleID == "com.google.Chrome" else { return false }
        let pids = NSWorkspace.shared.runningApplications
            .filter { $0.bundleIdentifier == bundleID && !$0.isTerminated }
            .map(\.processIdentifier)
        return await Task.detached {
            ChromeLaunchPolicy.needsVisibleInstance(pids.map { headless(pid: $0) })
        }.value
    }

    // Read only Chrome launch arguments to distinguish background automation.
    // The raw bytes never enter observations, logs, history or model requests.
    private static func headless(pid: pid_t) -> Bool? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4, size <= 2_097_152 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        let result = bytes.withUnsafeMutableBytes { buffer in
            sysctl(&mib, 3, buffer.baseAddress, &size, nil, 0)
        }
        guard result == 0 else { return nil }
        return ChromeLaunchPolicy.isHeadless(Data(bytes.prefix(size)))
    }
}
