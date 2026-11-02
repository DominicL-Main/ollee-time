import Foundation

/// Turns a spoken phrase such as "ten thirty" or "quarter to nine pm" into a wall-clock time.
///
/// Recognition hands over partial transcripts that grow word by word, so a phrase is only accepted
/// once it is *complete*: a lone "ten" could still turn into "ten thirty" or "ten to nine", and
/// firing on it would set the watch twice. A time without an am/pm marker is resolved to whichever
/// of the two readings is closer to now, so "seven" said at 18:50 means 19:00.
enum SpokenTime {

    struct Reading: Equatable {
        let hour: Int
        let minute: Int

        var label: String { String(format: "%02d:%02d", hour, minute) }
    }

    /// Returns the last complete time mentioned in `text`, or nil while the phrase is unfinished.
    static func parse(_ text: String,
                      now: Date = Date(),
                      calendar: Calendar = .current) -> Reading? {
        let tokens = tokenize(text)
        guard !tokens.isEmpty else { return nil }

        var found: Reading?
        var index = 0
        while index < tokens.count {
            var start = index
            if let reading = match(tokens, at: &start, now: now, calendar: calendar) {
                found = reading
                index = max(start, index + 1)
            } else {
                index += 1
            }
        }
        return found
    }

    // MARK: - Grammar

    private enum Meridiem { case am, pm }

    private enum Direction { case past, to }

    private static func match(_ tokens: [String],
                              at start: inout Int,
                              now: Date,
                              calendar: Calendar) -> Reading? {
        let i = start
        guard i < tokens.count else { return nil }

        switch tokens[i] {
        case "noon":
            start = i + 1
            return Reading(hour: 12, minute: 0)
        case "midnight":
            start = i + 1
            return Reading(hour: 0, minute: 0)
        default:
            break
        }

        // "1030" or "945" written as one number.
        if tokens[i].count == 3 || tokens[i].count == 4,
           let packed = Int(tokens[i]), packed / 100 < 24, packed % 100 < 60 {
            var j = i + 1
            var meridiem: Meridiem?
            j = consumeMeridiem(tokens, from: j, into: &meridiem)
            start = j
            let hour = meridiem.map { apply($0, to: packed / 100) }
                ?? nearest(packed / 100, minute: packed % 100, now: now, calendar: calendar)
            return Reading(hour: hour % 24, minute: packed % 100)
        }

        // "quarter past nine", "twenty to ten", "half past six".
        if let lead = leadingMinutes(tokens, from: i) {
            var j = lead.next
            guard let spokenHour = number(tokens, at: &j), spokenHour <= 24 else { return nil }
            var hour = spokenHour
            var minute = lead.minutes
            if lead.direction == .to {
                hour = (spokenHour + 23) % 24
                minute = (60 - lead.minutes) % 60
            }
            var meridiem: Meridiem?
            j = consumeMeridiem(tokens, from: j, into: &meridiem)
            start = j
            let resolved = meridiem.map { apply($0, to: hour) }
                ?? nearest(hour, minute: minute, now: now, calendar: calendar)
            return Reading(hour: resolved % 24, minute: minute)
        }

        // "ten thirty", "seven o'clock", "ten oh five", "ten am".
        var j = i
        guard let spokenHour = number(tokens, at: &j), spokenHour <= 24 else { return nil }
        var minute = 0
        var complete = false

        if j + 1 < tokens.count, tokens[j] == "o", tokens[j + 1] == "clock" {
            j += 2
            complete = true
        } else if j + 1 < tokens.count, tokens[j] == "oh", let unit = units[tokens[j + 1]], unit < 10 {
            j += 2
            minute = unit
            complete = true
        } else if let value = minuteValue(tokens, at: &j) {
            minute = value
            complete = true
        }

        var meridiem: Meridiem?
        j = consumeMeridiem(tokens, from: j, into: &meridiem)
        if meridiem != nil { complete = true }
        guard complete else { return nil }

        start = j
        let resolved = meridiem.map { apply($0, to: spokenHour) }
            ?? nearest(spokenHour, minute: minute, now: now, calendar: calendar)
        return Reading(hour: resolved % 24, minute: minute)
    }

    /// "quarter past", "twenty to", "half past" — a minute amount followed by a direction word.
    private static func leadingMinutes(_ tokens: [String], from index: Int)
        -> (minutes: Int, direction: Direction, next: Int)? {
        var j = index
        let minutes: Int
        if j < tokens.count, tokens[j] == "quarter" {
            minutes = 15
            j += 1
        } else if j < tokens.count, tokens[j] == "half" {
            minutes = 30
            j += 1
        } else if let value = number(tokens, at: &j), value > 0, value < 60 {
            minutes = value
        } else {
            return nil
        }

        guard j < tokens.count else { return nil }
        let direction: Direction
        switch tokens[j] {
        case "past", "after": direction = .past
        case "to", "till", "til", "before": direction = .to
        default: return nil
        }
        return (minutes, direction, j + 1)
    }

    private static func minuteValue(_ tokens: [String], at index: inout Int) -> Int? {
        var j = index
        guard let value = number(tokens, at: &j), value >= 0, value < 60 else { return nil }
        index = j
        return value
    }

    private static func consumeMeridiem(_ tokens: [String],
                                        from index: Int,
                                        into out: inout Meridiem?) -> Int {
        let j = index
        guard j < tokens.count else { return j }

        if tokens[j] == "am" { out = .am; return j + 1 }
        if tokens[j] == "pm" { out = .pm; return j + 1 }
        if j + 1 < tokens.count {
            let pair = tokens[j] + tokens[j + 1]
            if pair == "am" { out = .am; return j + 2 }
            if pair == "pm" { out = .pm; return j + 2 }
        }
        if j + 2 < tokens.count, tokens[j] == "in", tokens[j + 1] == "the" {
            switch tokens[j + 2] {
            case "morning": out = .am; return j + 3
            case "afternoon", "evening": out = .pm; return j + 3
            default: break
            }
        }
        if j + 1 < tokens.count, tokens[j] == "at", tokens[j + 1] == "night" {
            out = .pm
            return j + 2
        }
        return j
    }

    // MARK: - Numbers

    private static let units: [String: Int] = [
        "zero": 0, "oh": 0, "o": 0,
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
        "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
        "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19
    ]

    private static let tens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fourty": 40, "fifty": 50
    ]

    private static func number(_ tokens: [String], at index: inout Int) -> Int? {
        guard index < tokens.count else { return nil }
        if let digits = Int(tokens[index]) {
            index += 1
            return digits
        }
        if let ten = tens[tokens[index]] {
            index += 1
            if index < tokens.count, let unit = units[tokens[index]], unit < 10 {
                index += 1
                return ten + unit
            }
            return ten
        }
        if let unit = units[tokens[index]] {
            index += 1
            return unit
        }
        return nil
    }

    // MARK: - Clock arithmetic

    private static func apply(_ meridiem: Meridiem, to hour: Int) -> Int {
        switch meridiem {
        case .am: return hour == 12 ? 0 : hour % 12
        case .pm: return hour == 12 ? 12 : (hour % 12) + 12
        }
    }

    /// Picks the reading of an hour 1…12 that lands closest to the current time.
    private static func nearest(_ hour: Int, minute: Int, now: Date, calendar: Calendar) -> Int {
        guard hour >= 1, hour <= 12 else { return hour }
        let minutesNow = calendar.component(.hour, from: now) * 60
            + calendar.component(.minute, from: now)
        let asSpoken = hour * 60 + minute
        let plusTwelve = (hour + 12) * 60 + minute
        return circleDistance(asSpoken, minutesNow) <= circleDistance(plusTwelve, minutesNow)
            ? hour
            : hour + 12
    }

    private static func circleDistance(_ a: Int, _ b: Int) -> Int {
        let day = 24 * 60
        let raw = abs(a - b) % day
        return min(raw, day - raw)
    }

    // MARK: - Tokenizing

    private static func tokenize(_ text: String) -> [String] {
        var cleaned = ""
        for character in text.lowercased() {
            if character.isLetter || character.isNumber {
                cleaned.append(character)
            } else {
                cleaned.append(" ")
            }
        }
        return cleaned.split(separator: " ").map(String.init)
    }
}
