import Foundation

public enum Time {
    public static func nowUs() -> Int64 {
        var ts = timespec()
        clock_gettime(CLOCK_REALTIME, &ts)
        return Int64(ts.tv_sec) * 1_000_000 + Int64(ts.tv_nsec) / 1000
    }

    public static func rfc3339(_ us: Int64) -> String {
        let days = us >= 0 ? us / 86_400_000_000 : -((-us + 86_399_999_999) / 86_400_000_000)
        let (y, m, d) = civil(fromDays: days)
        let rest = us - days * 86_400_000_000
        let seconds = rest / 1_000_000
        func pad(_ n: Int64, _ width: Int) -> String { String(repeating: "0", count: max(0, width - String(n).count)) + String(n) }
        return "\(pad(y, 4))-\(pad(m, 2))-\(pad(d, 2))T\(pad(seconds / 3600, 2)):\(pad(seconds / 60 % 60, 2)):\(pad(seconds % 60, 2)).\(pad(rest % 1_000_000, 6))Z"
    }

    public static func micros(rfc3339 text: String) -> Int64? {
        let b = Array(text.utf8)
        var i = 0
        func number(_ digits: Int) -> Int64? {
            guard i + digits <= b.count else { return nil }
            var n: Int64 = 0
            for c in b[i..<i + digits] {
                guard c >= 48, c <= 57 else { return nil }
                n = n * 10 + Int64(c - 48)
            }
            i += digits
            return n
        }
        func literal(_ c: Character) -> Bool {
            guard i < b.count, b[i] == c.asciiValue! else { return false }
            i += 1
            return true
        }
        guard let year = number(4), literal("-"), let month = number(2), literal("-"), let day = number(2),
              literal("T"), let hour = number(2), literal(":"), let minute = number(2), literal(":"), let second = number(2),
              (1...12).contains(month), (1...daysIn(month: month, year: year)).contains(day),
              hour < 24, minute < 60, second < 60
        else { return nil }

        var fraction: Int64 = 0
        if literal(".") {
            let start = i
            while i < b.count, b[i] >= 48, b[i] <= 57 { i += 1 }
            let count = i - start
            guard (1...9).contains(count) else { return nil }
            for k in 0..<6 { fraction = fraction * 10 + (k < count ? Int64(b[start + k] - 48) : 0) }
        }

        var offsetSeconds: Int64 = 0
        if !literal("Z") {
            guard i < b.count, b[i] == 43 || b[i] == 45 else { return nil }
            let sign: Int64 = b[i] == 43 ? 1 : -1
            i += 1
            guard let oh = number(2), literal(":"), let om = number(2), oh < 24, om < 60 else { return nil }
            offsetSeconds = sign * (oh * 3600 + om * 60)
        }
        guard i == b.count else { return nil }

        let seconds = daysFromCivil(year, month, day) * 86_400 + hour * 3600 + minute * 60 + second - offsetSeconds
        return seconds * 1_000_000 + fraction
    }

    private static func daysIn(month: Int64, year: Int64) -> Int64 {
        let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        return month == 2 ? (leap ? 29 : 28) : [4, 6, 9, 11].contains(month) ? 30 : 31
    }

    private static func daysFromCivil(_ y: Int64, _ m: Int64, _ d: Int64) -> Int64 {
        let y = m <= 2 ? y - 1 : y
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (m > 2 ? m - 3 : m + 9) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    private static func civil(fromDays z: Int64) -> (Int64, Int64, Int64) {
        let z = z + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return (yoe + era * 400 + (m <= 2 ? 1 : 0), m, d)
    }
}
