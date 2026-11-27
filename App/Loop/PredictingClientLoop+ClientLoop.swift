import SpikeNet

/// SpikeNet's networked client is a `ClientLoop` as it stands: same members, so the game loop and
/// the UI drive a networked match exactly like a solo one (plan 6).
extension PredictingClientLoop: ClientLoop {}
