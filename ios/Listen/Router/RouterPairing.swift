import Foundation
import Observation

/// One explicit pairing proposal. Scanning only changes what the owner reviews.
@MainActor @Observable
final class RouterPairing {
    enum Phase: Equatable { case review, pairing, paired }
    private(set) var link: RouterLink
    private(set) var selectedHost = 0
    private(set) var phase = Phase.review
    private(set) var failure: RouterFailure?
    private(set) var needsNewCode = false
    @ObservationIgnored private let store: RouterStore

    init(link: RouterLink, store: RouterStore) {
        self.link = link
        self.store = store
    }

    var canPair: Bool { phase == .review && !needsNewCode }

    func selectHost(_ index: Int) {
        guard phase == .review, link.hosts.indices.contains(index) else { return }
        selectedHost = index
    }

    func review(_ code: String) {
        guard phase == .review else { return }
        do { review(try RouterLink.parse(code)) }
        catch { failure = .invalidLink }
    }

    func review(_ next: RouterLink) {
        guard phase == .review else { return }
        let host = link.hosts[selectedHost]
        link = next
        selectedHost = next.hosts.firstIndex(of: host) ?? 0
        needsNewCode = false
        failure = nil
    }

    @discardableResult
    func pair(deviceName: String) -> Task<Void, Never>? {
        guard canPair else { return nil }
        let proposal = link
        let host = proposal.hosts[selectedHost]
        phase = .pairing
        failure = nil
        return Task {
            do {
                try await store.pair(proposal, host: host, deviceName: deviceName)
                phase = .paired
            } catch {
                let failure = RouterConnection.failure(error)
                self.failure = failure
                needsNewCode = failure == .expiredCode || failure == .wrongCode
                phase = .review
            }
        }
    }
}
