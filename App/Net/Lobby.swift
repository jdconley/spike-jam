import Foundation
import SpikeCore
import SpikeNet

/// The room on the same Wi-Fi, before and around a match: who's in, on which side, and what the
/// host picked. It goes on the same UDP connection as SpikeNet's packets, under its own first
/// byte, which SpikeNet's loops ignore. It's small and repeated (every quarter second), so it
/// needs nothing reliable: the newest copy is the room.
enum LobbyMessage: Codable, Equatable, Sendable {
    /// Guest → host, repeated until the guest is playing: who this phone is (a generated
    /// nickname, and a private token so a rejoin finds its old slot) and the side it picked.
    case join(nickname: String, token: UInt64, team: TeamSide, version: Int)
    /// Host → guest, repeated: the room as that guest sees it.
    case room(Room)
    /// Guest → host: left the lobby.
    case leave

    /// The first byte of every lobby packet (SpikeNet's is `Wire.format`).
    static let format: UInt8 = 0x4C

    func encoded() -> Data {
        var d = Data([Self.format])
        d.append((try? JSONEncoder().encode(self)) ?? Data())
        return d
    }

    static func decode(_ d: Data) -> LobbyMessage? {
        guard d.first == format else { return nil }
        return try? JSONDecoder().decode(LobbyMessage.self, from: d.dropFirst())
    }
}

/// The room as one phone sees it.
struct Room: Codable, Equatable, Sendable {
    struct Player: Codable, Equatable, Sendable, Identifiable {
        var nickname: String
        var team: TeamSide
        var isHost: Bool
        /// The phone this room went to.
        var isYou: Bool
        /// Heard from lately (in a match: not dropped).
        var connected: Bool
        var id: String { "\(isHost ? "h" : "g") \(nickname) \(team.rawValue)" }
    }

    var host: String
    var gameType: GameType
    var tempo: Tempo
    var difficulty: Difficulty
    var players: [Player]
    /// The match has started (a guest that isn't in it can still join, mid-match).
    var started: Bool
    /// Why this phone can't join: another version of the game, or the room is full.
    var refused: String?

    /// The phone's own team, if it's in the room.
    var you: Player? { players.first { $0.isYou } }

    /// What the two phones are to each other, for the lobby: teammates or opponents.
    static func relation(_ a: TeamSide, _ b: TeamSide) -> String {
        a == b ? "TEAMMATES" : "OPPONENTS"
    }
}
