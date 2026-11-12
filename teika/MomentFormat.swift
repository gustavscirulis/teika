import Foundation

/// Formats dates with moment.js tokens, the syntax Obsidian uses for unique-note file
/// names, `{{date}}` and `{{time}}`, so a vault's own formats produce the same text
/// here that Obsidian would. `[text]` is a literal; anything that is not a token
/// passes through unchanged, as in moment.
nonisolated enum MomentFormat {
    /// Longest first, so `YYYY` is never read as two `YY`s.
    private static let tokens = [
        "YYYY", "GGGG", "gggg", "MMMM", "dddd", "DDDD", "SSS",
        "YY", "GG", "gg", "MMM", "ddd", "DDD", "Mo", "MM", "Do", "DD", "dd", "WW", "ww",
        "HH", "hh", "kk", "mm", "ss", "SS", "ZZ",
        "Y", "Q", "M", "D", "d", "E", "e", "W", "w", "H", "h", "k", "m", "s", "S",
        "A", "a", "Z", "X", "x",
    ]

    static func string(
        from date: Date, format: String,
        locale: Locale = .current, timeZone: TimeZone = .current
    ) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.locale = locale
        var iso = Calendar(identifier: .iso8601)
        iso.timeZone = timeZone
        let c = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second, .nanosecond, .weekday,
             .weekOfYear, .yearForWeekOfYear],
            from: date)
        let isoWeek = iso.component(.weekOfYear, from: date)
        let isoYear = iso.component(.yearForWeekOfYear, from: date)
        let dayOfYear = calendar.ordinality(of: .day, in: .year, for: date) ?? 1
        let weekdayIndex = (c.weekday ?? 1) - 1  // 0 = Sunday, as moment's `d`
        let symbols = DateFormatter()
        symbols.locale = locale
        let hour = c.hour ?? 0
        let hour12 = hour % 12 == 0 ? 12 : hour % 12
        let millis = (c.nanosecond ?? 0) / 1_000_000

        func pad(_ n: Int, _ width: Int) -> String {
            let s = String(abs(n))
            return (n < 0 ? "-" : "") + String(repeating: "0", count: max(0, width - s.count)) + s
        }
        func offset(separator: String) -> String {
            let seconds = timeZone.secondsFromGMT(for: date)
            let sign = seconds < 0 ? "-" : "+"
            return sign + pad(abs(seconds) / 3600, 2) + separator + pad(abs(seconds) % 3600 / 60, 2)
        }

        func value(_ token: String) -> String {
            switch token {
            case "YYYY": pad(c.year ?? 0, 4)
            case "YY": pad((c.year ?? 0) % 100, 2)
            case "Y": String(c.year ?? 0)
            case "GGGG": pad(isoYear, 4)
            case "GG": pad(isoYear % 100, 2)
            case "gggg": pad(c.yearForWeekOfYear ?? 0, 4)
            case "gg": pad((c.yearForWeekOfYear ?? 0) % 100, 2)
            case "Q": String(((c.month ?? 1) - 1) / 3 + 1)
            case "MMMM": symbols.standaloneMonthSymbols[(c.month ?? 1) - 1]
            case "MMM": symbols.shortStandaloneMonthSymbols[(c.month ?? 1) - 1]
            case "MM": pad(c.month ?? 1, 2)
            case "Mo": ordinal(c.month ?? 1)
            case "M": String(c.month ?? 1)
            case "DDDD": pad(dayOfYear, 3)
            case "DDD": String(dayOfYear)
            case "DD": pad(c.day ?? 1, 2)
            case "Do": ordinal(c.day ?? 1)
            case "D": String(c.day ?? 1)
            case "dddd": symbols.weekdaySymbols[weekdayIndex]
            case "ddd": symbols.shortWeekdaySymbols[weekdayIndex]
            case "dd": String(symbols.shortWeekdaySymbols[weekdayIndex].prefix(2))
            case "d", "e": String(weekdayIndex)
            case "E": String(weekdayIndex == 0 ? 7 : weekdayIndex)
            case "WW": pad(isoWeek, 2)
            case "W": String(isoWeek)
            case "ww": pad(c.weekOfYear ?? 1, 2)
            case "w": String(c.weekOfYear ?? 1)
            case "HH": pad(hour, 2)
            case "H": String(hour)
            case "hh": pad(hour12, 2)
            case "h": String(hour12)
            case "kk": pad(hour == 0 ? 24 : hour, 2)
            case "k": String(hour == 0 ? 24 : hour)
            case "mm": pad(c.minute ?? 0, 2)
            case "m": String(c.minute ?? 0)
            case "ss": pad(c.second ?? 0, 2)
            case "s": String(c.second ?? 0)
            case "SSS": pad(millis, 3)
            case "SS": pad(millis / 10, 2)
            case "S": String(millis / 100)
            case "A": hour < 12 ? "AM" : "PM"
            case "a": hour < 12 ? "am" : "pm"
            case "ZZ": offset(separator: "")
            case "Z": offset(separator: ":")
            case "X": String(Int(date.timeIntervalSince1970))
            case "x": String(Int((date.timeIntervalSince1970 * 1000).rounded(.down)))
            default: token
            }
        }

        var out = ""
        var rest = Substring(format)
        outer: while !rest.isEmpty {
            if rest.first == "[" {
                if let close = rest.firstIndex(of: "]") {
                    out += rest[rest.index(after: rest.startIndex)..<close]
                    rest = rest[rest.index(after: close)...]
                    continue
                }
            }
            for token in tokens where rest.hasPrefix(token) {
                out += value(token)
                rest = rest.dropFirst(token.count)
                continue outer
            }
            out.append(rest.removeFirst())
        }
        return out
    }

    private static func ordinal(_ n: Int) -> String {
        let suffix: String
        switch (n % 10, n % 100) {
        case (_, 11...13): suffix = "th"
        case (1, _): suffix = "st"
        case (2, _): suffix = "nd"
        case (3, _): suffix = "rd"
        default: suffix = "th"
        }
        return "\(n)\(suffix)"
    }
}
