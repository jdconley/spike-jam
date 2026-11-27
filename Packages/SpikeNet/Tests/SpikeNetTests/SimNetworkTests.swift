import Foundation
import Synchronization
import Testing
@testable import SpikeNet

/// What an endpoint received, with the virtual time it arrived.
final class Received: Sendable {
    let items = Mutex<[(Data, PeerID, Double)]>([])

    func listen(_ t: SimTransport, on net: SimNetwork) {
        t.onReceive = { [weak net] d, from in
            let now = net?.now ?? -1
            self.items.withLock { $0.append((d, from, now)) }
        }
    }

    var all: [(Data, PeerID, Double)] { items.withLock { $0 } }
}

@Suite struct SimNetworkTests {
    @Test func delays() {
        let net = SimNetwork(seed: 1)
        let (a, b) = net.connect(.init(oneWayDelay: 0.050))
        let got = Received()
        got.listen(b, on: net)
        net.advance(by: 0.013)
        a.send(Data([1]), to: b.id)
        net.advance(by: 0.049)
        #expect(got.all.isEmpty)
        net.advance(by: 0.002)
        #expect(got.all.count == 1)
        #expect(abs(got.all[0].2 - 0.063) < 1e-9)
        #expect(got.all[0].1 == a.id)
    }

    @Test func lossRate() {
        let net = SimNetwork(seed: 2)
        let (a, b) = net.connect(.init(oneWayDelay: 0.010, loss: 0.05))
        let got = Received()
        got.listen(b, on: net)
        for i in 0..<10_000 {
            a.send(Data([UInt8(i & 0xff)]), to: b.id)
            net.advance(by: 0.001)
        }
        net.advance(by: 1)
        let dropped = 1 - Double(got.all.count) / 10_000
        #expect(dropped >= 0.04 && dropped <= 0.06, "dropped \(dropped)")
    }

    @Test func reorders() {
        let net = SimNetwork(seed: 3)
        let (a, b) = net.connect(.init(oneWayDelay: 0.020, jitter: 0.030))
        let got = Received()
        got.listen(b, on: net)
        for i in 0..<200 {
            a.send(Data([UInt8(i)]), to: b.id)
            net.advance(by: 1.0 / 60)
        }
        net.advance(by: 1)
        let order = got.all.map { Int($0.0[0]) }
        #expect(order.count == 200)
        #expect(order != order.sorted())
        // Each link direction has its own conditions.
        #expect(net.link(from: b.id, to: a.id).jitter == 0.030)
        net.setLink(.perfect, from: b.id, to: a.id)
        #expect(net.link(from: a.id, to: b.id).jitter == 0.030)
    }
}
