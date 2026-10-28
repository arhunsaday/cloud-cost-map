import Foundation

/// A calendar month, which is how every supported provider bills.
public struct BillingPeriod: Hashable, Comparable, Codable, Sendable, Identifiable, CustomStringConvertible {
    public let year: Int
    public let month: Int

    public init(year: Int, month: Int) {
        precondition((1...12).contains(month), "month out of range")
        self.year = year
        self.month = month
    }

    public init(containing date: Date, calendar: Calendar = .current) {
        let parts = calendar.dateComponents([.year, .month], from: date)
        self.init(year: parts.year!, month: parts.month!)
    }

    /// Parses "2026-10".
    public init?(code: String) {
        let parts = code.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2, (1...12).contains(parts[1]) else { return nil }
        self.init(year: parts[0], month: parts[1])
    }

    public static func current(_ now: Date = .now) -> BillingPeriod { BillingPeriod(containing: now) }

    /// The `count` most recent periods ending with the one containing `now`, oldest first.
    public static func recent(_ count: Int, now: Date = .now) -> [BillingPeriod] {
        var period = current(now)
        var out = [period]
        for _ in 1..<max(count, 1) {
            period = period.previous
            out.append(period)
        }
        return out.reversed()
    }

    public var id: String { code }
    public var code: String { String(format: "%04d-%02d", year, month) }
    public var description: String { code }

    public var previous: BillingPeriod {
        month == 1 ? BillingPeriod(year: year - 1, month: 12) : BillingPeriod(year: year, month: month - 1)
    }

    public var next: BillingPeriod {
        month == 12 ? BillingPeriod(year: year + 1, month: 1) : BillingPeriod(year: year, month: month + 1)
    }

    public func start(calendar: Calendar = .current) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: 1))!
    }

    public func end(calendar: Calendar = .current) -> Date {
        next.start(calendar: calendar)
    }

    public func dayCount(calendar: Calendar = .current) -> Int {
        calendar.range(of: .day, in: .month, for: start(calendar: calendar))!.count
    }

    public func isCurrent(_ now: Date = .now) -> Bool { self == .current(now) }

    /// Share of the month already elapsed: 1 for past months, 0…1 for the current one.
    public func elapsedFraction(_ now: Date = .now, calendar: Calendar = .current) -> Double {
        let start = start(calendar: calendar), end = end(calendar: calendar)
        if now >= end { return 1 }
        if now <= start { return 0 }
        return now.timeIntervalSince(start) / end.timeIntervalSince(start)
    }

    /// "October 2026".
    public var title: String {
        start().formatted(.dateTime.month(.wide).year())
    }

    /// "Oct".
    public var shortTitle: String {
        start().formatted(.dateTime.month(.abbreviated))
    }

    public static func < (lhs: BillingPeriod, rhs: BillingPeriod) -> Bool {
        (lhs.year, lhs.month) < (rhs.year, rhs.month)
    }
}
