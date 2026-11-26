/// A human touch's timing grade (spec §4.2), from the spike.
public enum Grade: String, Codable, Sendable, CaseIterable {
    case perfect, good, early, late, wayEarly, wayLate, miss

    /// The timing a grade plays with (`TouchContext.timing`). A miss always
    /// errs whatever this says.
    public var quality: Float {
        switch self {
        case .perfect: 1.0
        case .good: 0.75
        case .early, .late: 0.45
        case .wayEarly, .wayLate, .miss: 0.2
        }
    }
}

/// Grades an input against the contact moment (spec §4.2): PERFECT within
/// 60 ms, GOOD within 130 ms, EARLY or LATE within 250 ms, WAY EARLY or WAY
/// LATE beyond, and MISS without an input.
public enum TimingJudge {
    /// Times are match seconds (`tick × dt + offset`).
    public static func grade(inputTime: Double?, contactTime: Double) -> Grade {
        guard let t = inputTime else { return .miss }
        let d = t - contactTime
        // Whole milliseconds decide, so 60 ms stamped as a tick plus an offset
        // is still 60.
        let ms = (abs(d) * 1000 * 1000).rounded() / 1000
        if ms <= Tuning.perfectWindow * 1000 { return .perfect }
        if ms <= Tuning.goodWindow * 1000 { return .good }
        if ms <= Tuning.earlyLateWindow * 1000 { return d < 0 ? .early : .late }
        return d < 0 ? .wayEarly : .wayLate
    }
}
