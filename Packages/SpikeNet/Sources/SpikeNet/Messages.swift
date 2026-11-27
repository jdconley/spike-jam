#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import SpikeCore

/// Everything host and guests say to each other (spec §5.3). One protocol for local play now and
/// online later: nothing here assumes a LAN.
public enum Message: Codable, Equatable, Sendable {
    /// Guest → host, until welcomed. The nickname is generated, never typed (spec §5.6).
    case hello(nickname: String, version: Int)
    /// Host → guest, resent until the guest's first inputs arrive: who they are, the match, and
    /// the host's tick as it was sent. The rosters follow from the settings, so they aren't sent
    /// (`GameState(settings:)` makes them, on both ends).
    case welcome(human: HumanID, settings: MatchSettings, startTick: Int)
    /// Guest → host every step: the guest's current tick, the newest snapshot it has, and its
    /// unconfirmed inputs, numbered from `first`, so each goes again in every packet until a
    /// snapshot confirms it (spec §5.3: redundant and unreliable). A touch carries the contact's
    /// tick as the guest saw it, which the host judges it against.
    case inputs(tick: Int, ack: Int, first: UInt32, items: [NetInput])
    /// Host → guest, every second step.
    case snapshot(Snapshot)
    /// Host → guest: run this many parts per million faster (or, negative, slower), so the host's
    /// buffer of the guest's inputs stays at 1–2 steps.
    case timeHint(adjustPPM: Int16)
    /// Guest → host, resent until acked: a huddle action (pick, call, combo, ready, team settings).
    case reliable(seq: UInt32, InputAction)
    /// Host → guest: the reliable actions through `seq` arrived.
    case ack(seq: UInt32)
    /// Either way: leaving.
    case bye
    /// Host → guest, a few copies at once: the host stopped at `tick` (its app left the screen,
    /// and iOS doesn't let a host run in the background). A snapshot after `tick` means it's back.
    case paused(tick: Int)
}

/// The wire format (plan 6): a format byte, then the message in `BinaryEncoder`'s encoding.
public enum Wire {
    /// The first byte of every packet; anything else is ignored.
    public static let format: UInt8 = 0x53
    /// The most bytes a packet may have, so nothing fragments (spec §5.4).
    public static let maxPacket = 1200
    /// The protocol version guests say hello with.
    public static let version = 1

    public static func encode(_ m: Message) throws -> Data {
        Data([format] + (try BinaryEncoder().encode(m)))
    }

    public static func decode(_ d: Data) throws -> Message {
        let bytes = [UInt8](d)
        guard bytes.first == format else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "not a Spike Jam packet"))
        }
        return try BinaryDecoder().decode(Message.self, from: Array(bytes.dropFirst()))
    }
}
