import XCTest
@testable import AppPorts

final class SponsorsTests: XCTestCase {
    private var cacheURL: URL!
    private var session: URLSession!

    override func setUpWithError() throws {
        cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppPorts-SponsorsTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("sponsors-cache.json")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockSponsorsURLProtocol.self]
        session = URLSession(configuration: configuration)
    }

    override func tearDownWithError() throws {
        session.invalidateAndCancel()
        MockSponsorsURLProtocol.setResponse(.failure(URLError(.notConnectedToInternet)))
        let directory = cacheURL.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    func testMissingLinkPreservesSponsorAndFractionalAmount() throws {
        let data = Data(#"{"name":"符华","amount":0.63,"date":"2026-09-16"}"#.utf8)
        let sponsor = try JSONDecoder().decode(Sponsor.self, from: data)
        XCTAssertEqual(sponsor.name, "符华")
        XCTAssertEqual(sponsor.amount, 0.63, accuracy: 0.0001)
        XCTAssertEqual(sponsor.id, "符华")
        XCTAssertNil(sponsor.profileURL)
    }

    func testOnlyUsableWebLinksAreClickable() {
        for link in ["", " \n", "relative/path", "javascript:alert(1)", "file:///tmp/profile", "https://"] {
            XCTAssertNil(Sponsor(name: "Example", link: link).profileURL, link)
        }
        XCTAssertEqual(
            Sponsor(name: "Example", link: " https://example.com/profile ").profileURL?.absoluteString,
            "https://example.com/profile"
        )
    }

    func testWebsiteWinsEvenWithOlderMissingOrInvalidTimestamp() async throws {
        let service = makeService()
        for timestamp: String? in ["2000-01-01", nil, "not a date"] {
            service.saveSponsorsToCache(payload("2099-01-01", names: ["Cached"]))
            let website = payload(timestamp, names: ["Online"])
            try respond(with: website)

            let selected = await service.loadSponsors()

            XCTAssertEqual(selected?.sponsors, website.sponsors)
            XCTAssertEqual(service.loadCachedSponsors()?.sponsors, website.sponsors)
            XCTAssertEqual(service.loadCachedSponsors()?.updatedAt, timestamp)
        }
    }

    func testEmptyWebsiteClearsCacheAndRemainsEmptyWhenOffline() async throws {
        let service = makeService()
        service.saveSponsorsToCache(payload("2099-01-01", names: ["Removed"]))
        try respond(with: payload(nil, names: []))

        let online = await service.loadSponsors()

        XCTAssertEqual(online?.sponsors, [])
        XCTAssertEqual(service.loadCachedSponsors()?.sponsors, [])
        MockSponsorsURLProtocol.setResponse(.failure(URLError(.notConnectedToInternet)))

        let offline = await service.loadSponsors()

        XCTAssertEqual(offline?.sponsors, [])
    }

    func testNetworkFailureUsesLegacyCacheBeforeBundle() async throws {
        let service = makeService()
        let legacy = try JSONDecoder().decode(SponsorsPayload.self, from: Data(#"{"sponsors":[{"name":"Cached"}]}"#.utf8))
        service.saveSponsorsToCache(legacy)
        MockSponsorsURLProtocol.setResponse(.failure(URLError(.notConnectedToInternet)))

        let selected = await service.loadSponsors()

        XCTAssertEqual(selected?.sponsors, legacy.sponsors)
    }

    func testInvalidWebsiteKeepsLastSuccessfulCache() async throws {
        let service = makeService()
        let cached = payload(nil, names: ["Cached"])
        service.saveSponsorsToCache(cached)
        for response in ["not json", #"{"updatedAt":"2026-09-29"}"#] {
            MockSponsorsURLProtocol.setResponse(.success((200, Data(response.utf8))))

            let selected = await service.loadSponsors()

            XCTAssertEqual(selected?.sponsors, cached.sponsors)
            XCTAssertEqual(service.loadCachedSponsors()?.sponsors, cached.sponsors)
        }
    }

    func testHTTPFailureDoesNotCacheErrorResponse() async throws {
        let service = makeService()
        let cached = payload(nil, names: ["Cached"])
        service.saveSponsorsToCache(cached)
        let body = try JSONEncoder().encode(payload(nil, names: ["Error response"]))
        MockSponsorsURLProtocol.setResponse(.success((503, body)))

        let selected = await service.loadSponsors()

        XCTAssertEqual(selected?.sponsors, cached.sponsors)
        XCTAssertEqual(service.loadCachedSponsors()?.sponsors, cached.sponsors)
    }

    func testUnavailableOrCorruptCacheFallsBackToBundle() async throws {
        let service = makeService()
        let bundled = try XCTUnwrap(service.loadBundledSponsors())
        MockSponsorsURLProtocol.setResponse(.failure(URLError(.timedOut)))

        let withoutCache = await service.loadSponsors()

        XCTAssertEqual(withoutCache?.sponsors, bundled.sponsors)
        try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("invalid cache".utf8).write(to: cacheURL)

        let corruptCache = await service.loadSponsors()

        XCTAssertEqual(corruptCache?.sponsors, bundled.sponsors)
    }

    func testUnavailableCacheDoesNotPreventOnlineResult() async throws {
        let service = SponsorsService(session: session, cacheURL: nil)
        let website = payload(nil, names: ["Online"])
        try respond(with: website)

        let selected = await service.loadSponsors()

        XCTAssertEqual(selected?.sponsors, website.sponsors)
    }

    func testCachedSnapshotRoundTripKeepsRevisionAndUnlinkedSponsor() throws {
        let original = SponsorsPayload(updatedAt: "2026-09-29T04:00:00Z", sponsors: [Sponsor(name: "符华", link: "", amount: 0.63)])
        let service = makeService()
        service.saveSponsorsToCache(original)
        let restored = try XCTUnwrap(service.loadCachedSponsors())
        XCTAssertEqual(restored.updatedAt, original.updatedAt)
        XCTAssertEqual(restored.sponsors, original.sponsors)
        XCTAssertNil(restored.sponsors.first?.profileURL)
    }

    func testApplicationBundleContainsSponsorSource() throws {
        let bundled = try XCTUnwrap(SponsorsService().loadBundledSponsors())
        XCTAssertFalse(bundled.sponsors.isEmpty)
        XCTAssertNotNil(bundled.updatedAt)
    }

    func testRankedBySponsorshipSortsUnpaddedDatesChronologically() {
        let ranked = [
            Sponsor(name: "Late", link: "", amount: 50, date: "2026-10-12"),
            Sponsor(name: "Early", link: "", amount: 50, date: "2026-10-5"),
            Sponsor(name: "Top", link: "", amount: 100, date: "2026-11-1")
        ].rankedBySponsorship()
        XCTAssertEqual(ranked.map(\.name), ["Top", "Early", "Late"])
    }

    private func makeService() -> SponsorsService {
        SponsorsService(session: session, cacheURL: cacheURL)
    }

    private func respond(with payload: SponsorsPayload) throws {
        MockSponsorsURLProtocol.setResponse(.success((200, try JSONEncoder().encode(payload))))
    }

    private func payload(_ updatedAt: String?, names: [String]) -> SponsorsPayload {
        SponsorsPayload(updatedAt: updatedAt, sponsors: names.map { Sponsor(name: $0, link: "") })
    }
}

private final class MockSponsorsURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var response: Result<(Int, Data), Error> = .failure(URLError(.notConnectedToInternet))

    static func setResponse(_ value: Result<(Int, Data), Error>) {
        lock.lock()
        defer { lock.unlock() }
        response = value
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let result = Self.response
        Self.lock.unlock()
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
        switch result {
        case let .success((status, data)):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case let .failure(error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
