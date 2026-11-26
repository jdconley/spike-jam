/// Generates original rosters. Never real athletes (spec §4.4, §2).
public enum RosterGenerator {
    /// Fixed index order; `Lineup` relies on it.
    /// 5-1: S, OH1, MB1, OPP, OH2, MB2, L. 6-2: S1, OH1, MB1, S2, OH2, MB2, L.
    static func positions(_ system: OffenseSystem) -> [Position] {
        switch system {
        case .fiveOne: [.setter, .outside, .middle, .opposite, .outside, .middle, .libero]
        case .sixTwo: [.setter, .outside, .middle, .setter, .outside, .middle, .libero]
        }
    }

    static func heightRange(_ game: GameType) -> ClosedRange<Float> {
        switch game {
        case .mens: 1.78...2.08
        case .womens: 1.68...1.93
        }
    }

    /// The slice of the height range a position draws from (Claude's call):
    /// middles and opposites the top third, liberos and setters the bottom
    /// half, outsides the middle.
    static func heightBand(_ p: Position, _ game: GameType) -> ClosedRange<Float> {
        let r = heightRange(game)
        let lo = r.lowerBound, span = r.upperBound - r.lowerBound
        func band(_ a: Float, _ b: Float) -> ClosedRange<Float> { (lo + span * a)...(lo + span * b) }
        switch p {
        case .middle, .opposite: return band(2.0 / 3.0, 1)
        case .libero, .setter: return band(0, 0.5)
        case .outside: return band(1.0 / 3.0, 2.0 / 3.0)
        }
    }

    public static func make(team: TeamSide, gameType: GameType, system: OffenseSystem, rng: inout SeededRNG) -> Roster {
        let firsts = gameType == .mens ? menFirstNames : womenFirstNames
        var numbers = Array(1...99)
        var tones = Array(0..<10)
        var athletes: [Athlete] = []
        for (i, position) in positions(system).enumerated() {
            let name = firsts[rng.int(in: 0..<firsts.count)] + " " + lastNames[rng.int(in: 0..<lastNames.count)]
            let number = numbers.remove(at: rng.int(in: 0..<numbers.count))
            let tone = tones.remove(at: rng.int(in: 0..<tones.count))
            let height = rng.float(in: heightBand(position, gameType))
            let traits = shapedTraits(position, rng: &rng)
            athletes.append(Athlete(id: AthleteID(team: team, index: i), name: name, number: number,
                                    position: position, heightM: height, skinTone: tone, traits: traits))
        }
        return Roster(athletes: athletes)
    }

    /// The mean traits of each position (Claude's numbers): setters set,
    /// liberos pass and dig and never attack or block, middles block and hit
    /// but pass little, outsides are all-round with a good pass, opposites
    /// hit and block.
    static func meanTraits(_ p: Position) -> Traits {
        switch p {
        case .setter:
            Traits(serve: 0.62, pass: 0.58, set: 0.86, attack: 0.45, block: 0.5, defense: 0.62, speed: 0.66)
        case .libero:
            Traits(serve: 0.4, pass: 0.84, set: 0.45, attack: 0, block: 0, defense: 0.86, speed: 0.74)
        case .middle:
            Traits(serve: 0.56, pass: 0.38, set: 0.38, attack: 0.76, block: 0.84, defense: 0.45, speed: 0.58)
        case .outside:
            Traits(serve: 0.64, pass: 0.72, set: 0.42, attack: 0.72, block: 0.6, defense: 0.66, speed: 0.66)
        case .opposite:
            Traits(serve: 0.66, pass: 0.45, set: 0.42, attack: 0.8, block: 0.72, defense: 0.5, speed: 0.62)
        }
    }

    /// The traits that make the position, which a personality never lowers.
    static func signature(_ p: Position) -> Set<Int> {
        switch p {
        case .setter: [2]
        case .libero: [1, 5]
        case .middle: [4]
        case .outside: [1]
        case .opposite: [3]
        }
    }

    /// Each trait drawn within ±0.12 of the position's mean, then one
    /// personality: +0.15 on one random trait and −0.1 on another (never a
    /// signature trait), clipped to 0...1. A libero's attack and block stay 0.
    static func shapedTraits(_ p: Position, rng: inout SeededRNG) -> Traits {
        let mean = meanTraits(p)
        var v = [mean.serve, mean.pass, mean.set, mean.attack, mean.block, mean.defense, mean.speed]
        for i in v.indices { v[i] += rng.float(in: -0.12...0.12) }
        let up = rng.int(in: 0..<v.count)
        let downs = v.indices.filter { $0 != up && !signature(p).contains($0) }
        let down = downs[rng.int(in: 0..<downs.count)]
        v[up] += 0.15
        v[down] -= 0.1
        v = v.map { min(max($0, 0), 1) }
        var t = Traits(serve: v[0], pass: v[1], set: v[2], attack: v[3], block: v[4], defense: v[5], speed: v[6])
        if p == .libero {
            t.attack = 0
            t.block = 0
        }
        return t
    }

    // Original, generated-sounding names. None is a real athlete.
    static let menFirstNames = [
        "Arlo", "Bram", "Cael", "Dax", "Emrys", "Fenn", "Gideon", "Hollis", "Idris", "Jory",
        "Kasimir", "Lennox", "Marek", "Niall", "Orrin", "Pax", "Quill", "Rafe", "Soren", "Tamsin",
        "Ulric", "Vance", "Wilder", "Xan", "Yorick", "Zev", "Abel", "Bastian", "Cormac", "Dorian",
        "Ezra", "Florian", "Gael", "Hale", "Ivo", "Jasper", "Koa", "Lucan", "Milo", "Nico",
        "Otis", "Pike", "Rhett", "Silas", "Teo", "Wren",
    ]

    static let womenFirstNames = [
        "Aria", "Briar", "Cleo", "Dahlia", "Elowen", "Fia", "Greer", "Halle", "Isla", "Juno",
        "Kaia", "Liora", "Maren", "Noor", "Odette", "Pia", "Quinn", "Rosalind", "Sable", "Tova",
        "Una", "Vesper", "Willa", "Xiomara", "Yara", "Zinnia", "Adair", "Bex", "Cassia", "Delphine",
        "Esme", "Fable", "Gemma", "Hana", "Ines", "Jessa", "Kenna", "Lark", "Mira", "Nell",
        "Oona", "Priya", "Rhea", "Saoirse", "Thea", "Wynn",
    ]

    static let lastNames = [
        "Ashgrove", "Blackwood", "Calder", "Dunmore", "Ellery", "Farrow", "Galloway", "Hartwell",
        "Ingram", "Jessup", "Kestrel", "Lockhart", "Merriweather", "Northcott", "Okonkwo", "Pemberly",
        "Quarrie", "Ravensworth", "Sallow", "Thistlewood", "Underhill", "Vantongeren", "Whitlock",
        "Yarborough", "Zabala", "Abernethy", "Brightwater", "Castellano", "Delacroix", "Esparza",
        "Fairbairn", "Greaves", "Halvorsen", "Iwasaki", "Jaramillo", "Kowalczyk", "Lindqvist",
        "Mbeki", "Nakamura", "Oyelaran", "Pradhan", "Rasmussen", "Stavros", "Tanaka-Reyes",
        "Velasquez", "Wainwright",
    ]
}
