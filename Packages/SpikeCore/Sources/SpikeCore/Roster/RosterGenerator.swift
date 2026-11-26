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
            func trait() -> Float { rng.float(in: 0.45...0.9) }
            let traits = Traits(serve: trait(), pass: trait(), set: trait(), attack: trait(),
                                block: trait(), defense: trait(), speed: trait())
            athletes.append(Athlete(id: AthleteID(team: team, index: i), name: name, number: number,
                                    position: position, heightM: height, skinTone: tone, traits: traits))
        }
        return Roster(athletes: athletes)
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
