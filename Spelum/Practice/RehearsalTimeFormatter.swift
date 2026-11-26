import Foundation

enum RehearsalTimeFormatter {
    static func clockString(for seconds: TimeInterval) -> String {
        let clamped = max(0, seconds.isFinite ? seconds : 0)
        let totalTenths = Int((clamped * 10).rounded(.down))
        let minutes = totalTenths / 600
        let remainingSeconds = (totalTenths % 600) / 10
        let tenths = totalTenths % 10
        return String(format: "%d:%02d.%d", minutes, remainingSeconds, tenths)
    }

    static func shortDurationString(for seconds: TimeInterval) -> String {
        let clamped = max(0, seconds.isFinite ? seconds : 0)
        let totalSeconds = Int(clamped.rounded())
        let minutes = totalSeconds / 60
        let remainingSeconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, remainingSeconds)
    }

    static func accessibleDurationString(for seconds: TimeInterval) -> String {
        let clamped = max(0, seconds.isFinite ? seconds : 0)
        let minutes = Int(clamped) / 60
        let remaining = clamped.truncatingRemainder(dividingBy: 60)
        if minutes > 0 {
            let wholeSeconds = Int(remaining.rounded())
            let minuteUnit = minutes == 1 ? "minute" : "minutes"
            let secondUnit = wholeSeconds == 1 ? "second" : "seconds"
            return "\(minutes) \(minuteUnit) \(wholeSeconds) \(secondUnit)"
        }
        let roundedTenths = (remaining * 10).rounded() / 10
        if roundedTenths == roundedTenths.rounded() {
            let whole = Int(roundedTenths)
            return whole == 1 ? "1 second" : "\(whole) seconds"
        }
        return String(format: "%.1f seconds", roundedTenths)
    }
}
