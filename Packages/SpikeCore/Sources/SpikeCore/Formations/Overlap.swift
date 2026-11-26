/// The overlap rule at the moment of the serve (spec §4.1). Each front-row
/// player must be closer to the net than their back-row partner (4 with 5,
/// 3 with 6, 2 with 1), and within each row the order left to right must be
/// 4, 3, 2 and 5, 6, 1. Only neighbours are compared, as in the real rule.
/// The server is exempt.
public enum Overlap {
    static let columns: [(front: Zone, back: Zone)] = [(.z4, .z5), (.z3, .z6), (.z2, .z1)]
    static let rows: [(left: Zone, right: Zone)] = [(.z4, .z3), (.z3, .z2), (.z5, .z6), (.z6, .z1)]

    /// Every broken pair, like `"z4 not ahead of z5"` or `"z5 not left of z6"`.
    /// Each pair must be apart by at least `margin` metres so a legal line-up
    /// is visibly legal. Empty when legal.
    public static func violations(_ spots: [Zone: LocalSpot], isServing: Bool, margin: Float = 0.1) -> [String] {
        var problems: [String] = []
        // A hair of slack so a table authored at exactly `margin` stays legal
        // after Float rounding.
        let need = margin - 1e-4
        for (front, back) in columns where !(isServing && back == .z1) {
            guard let f = spots[front], let b = spots[back] else { continue }
            if b.d - f.d < need { problems.append("z\(front.rawValue) not ahead of z\(back.rawValue)") }
        }
        for (left, right) in rows where !(isServing && right == .z1) {
            guard let a = spots[left], let b = spots[right] else { continue }
            if b.l - a.l < need { problems.append("z\(left.rawValue) not left of z\(right.rawValue)") }
        }
        return problems
    }
}
