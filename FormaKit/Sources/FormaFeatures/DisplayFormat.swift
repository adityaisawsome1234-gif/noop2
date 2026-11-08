import Foundation
import FormaCore

/// Small, deterministic formatters shared by screens and tests. Numbers use "." as the decimal
/// separator and a true minus sign; times use the 24-hour clock in the supplied calendar's zone.
public enum DisplayFormat {
    /// Fixed-point number with `digits` decimals (0…3). Non-finite input yields "—".
    public static func number(_ value: Double, digits: Int) -> String {
        guard value.isFinite else { return "—" }
        let d = max(0, min(3, digits))
        // From 1e15 on, the fixed-point arithmetic below would overflow Int64 (and such values carry no
        // meaningful fractional digits): print the exact decimal expansion instead of trapping.
        if abs(value) >= 1e15 {
            let text = String(format: "%.\(d)f", locale: Locale(identifier: "en_US_POSIX"), abs(value))
            return value < 0 ? "\u{2212}" + text : text
        }
        let factor = pow(10.0, Double(d))
        let rounded = (abs(value) * factor).rounded() / factor
        let negative = value < 0 && rounded != 0
        var text: String
        if d == 0 {
            text = String(Int64(rounded))
        } else {
            let whole = Int64(rounded.rounded(.towardZero))
            let frac = Int64(((rounded - Double(whole)) * factor).rounded())
            var fracText = String(frac)
            while fracText.count < d { fracText = "0" + fracText }
            text = "\(whole).\(fracText)"
        }
        if negative { text = "\u{2212}" + text }
        return text
    }

    /// Signed number: "+0.4", "−1.2", "0.0".
    public static func signed(_ value: Double, digits: Int) -> String {
        guard value.isFinite else { return "—" }
        let text = number(value, digits: digits)
        if text.hasPrefix("\u{2212}") { return text }
        let isZero = number(abs(value), digits: digits) == number(0, digits: digits)
        return isZero ? text : "+" + text
    }

    /// "86%" from a 0…1 fraction.
    public static func percent(_ fraction: Double) -> String {
        guard fraction.isFinite else { return "—" }
        return number(fraction * 100, digits: 0) + "%"
    }

    /// "23:05" in the calendar's time zone.
    public static func clock(_ t: EpochMillis, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: t.date)
        let h = c.hour ?? 0
        let m = c.minute ?? 0
        return (h < 10 ? "0" : "") + "\(h):" + (m < 10 ? "0" : "") + "\(m)"
    }

    /// "23:05–06:50".
    public static func range(_ r: TimeRange, calendar: Calendar) -> String {
        "\(clock(r.start, calendar: calendar))\u{2013}\(clock(r.end, calendar: calendar))"
    }

    /// "7 h 45 min", "45 min", "0 min".
    public static func duration(millis: Int64) -> String {
        let totalMinutes = max(0, Int((Double(millis) / 60_000).rounded()))
        let h = totalMinutes / 60
        let m = totalMinutes % 60
        if h == 0 { return "\(m) min" }
        return m == 0 ? "\(h) h" : "\(h) h \(m) min"
    }

    /// "1:05:09" or "5:09" for running timers.
    public static func timer(millis: Int64) -> String {
        let s = max(0, millis / 1_000)
        let h = s / 3_600
        let m = (s % 3_600) / 60
        let sec = s % 60
        let mm = (m < 10 && h > 0 ? "0" : "") + "\(m)"
        let ss = (sec < 10 ? "0" : "") + "\(sec)"
        return h > 0 ? "\(h):\(mm):\(ss)" : "\(mm):\(ss)"
    }

    /// Weekday + day label, e.g. "Sat 8 Nov".
    public static func dayLabel(_ day: LocalDay, calendar: Calendar) -> String {
        let start = day.range(calendar: calendar).start.date
        let weekday = calendar.component(.weekday, from: start) // 1 = Sunday
        let names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        let wd = names[max(0, min(6, weekday - 1))]
        let mo = months[max(0, min(11, day.month - 1))]
        return "\(wd) \(day.day) \(mo)"
    }

    /// Value with unit for a metric, or nil when unavailable.
    public static func metric(_ value: MetricValue<Double>, digits: Int) -> String? {
        guard value.availability.isAvailable, let v = value.value else { return nil }
        return number(v, digits: digits)
    }
}
