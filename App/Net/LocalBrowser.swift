import Foundation
import Network
import Observation

/// A phone hosting a match on this Wi-Fi: its nickname, and where to reach it.
struct NearbyHost: Identifiable, Hashable, Sendable {
    var name: String
    var endpoint: NWEndpoint
    var id: String { name }
}

/// The hosts nearby, found with Bonjour (`NWBrowser` for `_spikejam._udp`), for the Join list.
@MainActor
@Observable
final class LocalBrowser {
    private(set) var hosts: [NearbyHost] = []
    /// Why nothing can be found, if something's wrong (local network access off, no Wi-Fi).
    private(set) var problem: String?
    private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        let b = NWBrowser(for: .bonjour(type: LocalTransport.serviceType, domain: nil), using: LocalTransport.parameters())
        b.browseResultsChangedHandler = { [weak self] results, _ in
            let hosts = Self.hosts(in: results)
            MainActor.assumeIsolated { self?.hosts = hosts }
        }
        b.stateUpdateHandler = { [weak self] st in
            let problem: String? = switch st {
            case .waiting(let e), .failed(let e): LocalTransport.describe(e)
            default: nil
            }
            MainActor.assumeIsolated { self?.problem = problem }
        }
        b.start(queue: .main)
        browser = b
    }

    func stop() {
        browser?.cancel()
        browser = nil
        hosts = []
    }

    /// One entry per name (a host shows up once per network interface), sorted.
    nonisolated static func hosts(in results: Set<NWBrowser.Result>) -> [NearbyHost] {
        var byName: [String: NearbyHost] = [:]
        for r in results {
            guard case .service(let name, let type, let domain, _) = r.endpoint else { continue }
            // Any interface: the connection picks the one that reaches it.
            byName[name] = NearbyHost(name: name, endpoint: .service(name: name, type: type, domain: domain, interface: nil))
        }
        return byName.values.sorted { $0.name < $1.name }
    }
}
