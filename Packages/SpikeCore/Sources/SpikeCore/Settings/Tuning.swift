/// Every placeholder number in one place, so plan 3 can replace them.
public enum Tuning {
    /// Arcade gravity from the spike, m/s².
    public static let gravity: Float = -9.8 * 1.7
    public static let stepsPerSecond = 60
    public static let dt: Double = 1.0 / 60.0
    /// Seconds between the end of the dead ball and the serve.
    public static let serveDelay: Double = 0.8
    /// Seconds the ball stays dead after a point.
    public static let deadBall: Double = 1.5
}
