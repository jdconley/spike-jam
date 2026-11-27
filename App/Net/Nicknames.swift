import Foundation

/// The names phones go by on the same Wi-Fi (spec §5.6): generated from a list, rerolled with the
/// dice, never typed, so a child's phone never shows a real name. Each is a volleyball word and an
/// animal.
enum Nicknames {
    static let first = [
        "Pancake", "Floater", "Topspin", "Jump", "Rally", "Kong", "Tipper", "Sideout", "Bump", "Ace",
        "Quick", "Slide", "Pipe", "Rocket", "Roof", "Libero", "Dig", "Spike", "Jumbo", "Turbo",
    ]
    static let second = [
        "Otter", "Pelican", "Gecko", "Koala", "Falcon", "Narwhal", "Panda", "Yak", "Moose", "Lemur",
        "Puffin", "Badger", "Walrus", "Iguana", "Bison", "Ferret", "Toucan", "Marmot", "Llama", "Squid",
    ]

    /// Every nickname there is.
    static let all: [String] = first.flatMap { a in second.map { "\(a) \($0)" } }

    static func random<R: RandomNumberGenerator>(rng: inout R) -> String {
        all.randomElement(using: &rng)!
    }

    static func random() -> String {
        var rng = SystemRandomNumberGenerator()
        return random(rng: &rng)
    }

    /// A different one, for the dice.
    static func reroll<R: RandomNumberGenerator>(_ current: String, rng: inout R) -> String {
        var next = random(rng: &rng)
        while next == current { next = random(rng: &rng) }
        return next
    }
}

/// This phone's nickname and its private token, kept between launches. The token tells the host
/// it's the same phone coming back (a rejoin) even if two phones roll the same nickname; it's a
/// random number, never shown.
struct NetIdentity: Equatable, Sendable {
    var nickname: String
    var token: UInt64

    static let nicknameKey = "net.nickname"
    static let tokenKey = "net.token"

    /// This phone's, made the first time. A stored nickname that isn't on the list is replaced.
    static func load(_ defaults: UserDefaults = .standard) -> NetIdentity {
        var nickname = defaults.string(forKey: nicknameKey) ?? ""
        if !Nicknames.all.contains(nickname) {
            nickname = Nicknames.random()
            defaults.set(nickname, forKey: nicknameKey)
        }
        var token = UInt64(bitPattern: Int64(defaults.integer(forKey: tokenKey)))
        if token == 0 {
            token = UInt64.random(in: 1...UInt64(Int64.max))
            defaults.set(Int(Int64(bitPattern: token)), forKey: tokenKey)
        }
        return NetIdentity(nickname: nickname, token: token)
    }

    /// Rolls a new nickname and keeps it.
    static func reroll(_ defaults: UserDefaults = .standard) -> NetIdentity {
        var me = load(defaults)
        var rng = SystemRandomNumberGenerator()
        me.nickname = Nicknames.reroll(me.nickname, rng: &rng)
        defaults.set(me.nickname, forKey: nicknameKey)
        return me
    }
}
