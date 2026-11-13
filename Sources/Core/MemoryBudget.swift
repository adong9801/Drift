import Foundation

/// A target, not a process kill limit: visible pages and unsaved work win.
enum MemoryBudget {
    static let choices = [0, 512, 1024, 2048, 4096, 8192]
    /// A quarter of the machine's memory, to the nearest choice, and never
    /// under 2 GB. Two gigabytes on a 24 GB Mac had heavy pages such as Docs
    /// and YouTube sleeping within a minute of being left, and every switch
    /// back was a reload.
    static var defaultMB: Int { defaultMB(forPhysicalMemoryBytes: ProcessInfo.processInfo.physicalMemory) }

    static func defaultMB(forPhysicalMemoryBytes memory: UInt64) -> Int {
        let quarter = Int(memory / 4 / 1_048_576)
        return choices.filter { $0 > 0 && $0 <= quarter }.max() ?? 2048
    }
    static let settlingTime: TimeInterval = 3

    static func bytes(forMB value: Int) -> UInt64? {
        guard value > 0 else { return nil }
        return UInt64(min(value, 65_536)) * 1_048_576
    }

    /// Once over budget, make a little room so small fluctuations do not
    /// repeatedly unload tabs. Only start reclaiming after crossing the limit.
    static func needsReclaim(bytes: UInt64, limitMB: Int, reclaiming: Bool) -> Bool {
        guard let limit = self.bytes(forMB: limitMB) else { return false }
        let target = reclaiming ? limit - limit / 10 : limit
        return bytes > target
    }
}
