import XCTest
@testable import AppPorts

final class UpdateCheckerTests: XCTestCase {
    override func tearDown() {
        MockUpdateURLProtocol.reset()
        super.tearDown()
    }

    func testGitHubOnlyNewVersionUsesGitHubReleaseNotes() async throws {
        let checker = makeChecker(
            github: .json(gitHubRelease(tag: "1.7.0", body: "GitHub notes")),
            official: .status(404)
        )

        let update = await checker.checkForUpdates()

        XCTAssertEqual(update?.source, .github)
        XCTAssertEqual(update?.version, "1.7.0")
        XCTAssertEqual(update?.releaseNotesMarkdown, "GitHub notes")
        XCTAssertEqual(update?.githubURL?.absoluteString, "https://github.com/wzh4869/AppPorts/releases/tag/1.7.0")
        XCTAssertEqual(update?.chinaDownloadURL.absoluteString, "https://file.shimoko.com/AppPorts")
    }

    func testOfficialOnlyNewVersionUsesOfficialReleaseNotes() async throws {
        let checker = makeChecker(
            github: .status(503),
            official: .json(officialRelease(version: "1.7.0", notes: ["zh-Hans": "官网说明", "en": "Official notes"])),
            language: "zh-Hans"
        )

        let update = await checker.checkForUpdates()

        XCTAssertEqual(update?.source, .official)
        XCTAssertEqual(update?.version, "1.7.0")
        XCTAssertEqual(update?.releaseNotesMarkdown, "官网说明")
        XCTAssertEqual(update?.githubURL?.absoluteString, "https://github.com/wzh4869/AppPorts/releases/tag/1.7.0")
        XCTAssertEqual(update?.chinaDownloadURL.absoluteString, "https://file.shimoko.com/AppPorts")
    }

    func testHigherVersionWinsWhenBothSourcesHaveDifferentNewVersions() async throws {
        let checker = makeChecker(
            github: .json(gitHubRelease(tag: "1.7.0", body: "GitHub notes")),
            official: .json(officialRelease(version: "1.8.0", notes: ["zh-Hans": "官网高版本"])),
            language: "zh-Hans"
        )

        let update = await checker.checkForUpdates()

        XCTAssertEqual(update?.source, .official)
        XCTAssertEqual(update?.version, "1.8.0")
        XCTAssertEqual(update?.releaseNotesMarkdown, "官网高版本")
    }

    func testSameNewVersionPrefersGitHubWhenGitHubSucceeds() async throws {
        let checker = makeChecker(
            github: .json(gitHubRelease(tag: "v1.7.0", body: "GitHub notes")),
            official: .json(officialRelease(version: "1.7.0", notes: ["zh-Hans": "官网说明"])),
            language: "zh-Hans"
        )

        let update = await checker.checkForUpdates()

        XCTAssertEqual(update?.source, .github)
        XCTAssertEqual(update?.version, "1.7.0")
        XCTAssertEqual(update?.releaseNotesMarkdown, "GitHub notes")
    }

    func testSameNewVersionUsesOfficialWhenGitHubFails() async throws {
        let checker = makeChecker(
            github: .status(500),
            official: .json(officialRelease(version: "1.7.0", notes: ["zh-Hans": "官网说明"])),
            language: "zh-Hans"
        )

        let update = await checker.checkForUpdates()

        XCTAssertEqual(update?.source, .official)
        XCTAssertEqual(update?.version, "1.7.0")
        XCTAssertEqual(update?.releaseNotesMarkdown, "官网说明")
    }

    func testGitHubFailureDoesNotBlockOfficialUpdate() async throws {
        let checker = makeChecker(
            github: .error(URLError(.cannotConnectToHost)),
            official: .json(officialRelease(version: "1.7.0", notes: ["en": "Official notes"])),
            language: "en"
        )

        let update = await checker.checkForUpdates()

        XCTAssertEqual(update?.source, .official)
        XCTAssertEqual(update?.releaseNotesMarkdown, "Official notes")
    }

    func testOfficialFailureDoesNotBlockGitHubUpdate() async throws {
        let checker = makeChecker(
            github: .json(gitHubRelease(tag: "1.7.0", body: "GitHub notes")),
            official: .error(URLError(.timedOut))
        )

        let update = await checker.checkForUpdates()

        XCTAssertEqual(update?.source, .github)
        XCTAssertEqual(update?.releaseNotesMarkdown, "GitHub notes")
    }

    func testGitHubAPIFailureFallsBackToAtomFeed() async throws {
        let checker = makeChecker(
            github: .status(403),
            official: .status(404),
            atom: .text(gitHubAtomFeed(tag: "v1.7.0", htmlBody: "<h2>GitHub Atom Notes</h2><p><strong>Fixed</strong> update checks.</p>"))
        )

        let update = await checker.checkForUpdates()

        XCTAssertEqual(update?.source, .github)
        XCTAssertEqual(update?.version, "1.7.0")
        XCTAssertEqual(update?.githubURL?.absoluteString, "https://github.com/wzh4869/AppPorts/releases/tag/1.7.0")
        XCTAssertTrue(update?.releaseNotesMarkdown.contains("GitHub Atom Notes") == true)
        XCTAssertTrue(update?.releaseNotesMarkdown.contains("**Fixed** update checks.") == true)
    }

    func testGitHubDisabledUsesOfficialUpdateEvenWhenGitHubHasHigherVersion() async throws {
        let checker = makeChecker(
            github: .json(gitHubRelease(tag: "1.8.0", body: "GitHub notes")),
            official: .json(officialRelease(version: "1.7.0", notes: ["zh-Hans": "官网说明"])),
            language: "zh-Hans",
            githubUpdatesDisabled: true
        )

        let update = await checker.checkForUpdates()

        XCTAssertEqual(update?.source, .official)
        XCTAssertEqual(update?.version, "1.7.0")
        XCTAssertEqual(update?.releaseNotesMarkdown, "官网说明")
    }

    func testBothSourcesFailReturnsNil() async throws {
        let checker = makeChecker(
            github: .status(503),
            official: .error(URLError(.notConnectedToInternet))
        )

        let update = await checker.checkForUpdates()

        XCTAssertNil(update)
    }

    func testOfficialVersionNormalizesLeadingV() async throws {
        let checker = makeChecker(
            github: .status(404),
            official: .json(officialRelease(version: "v1.7.0", tag: "v1.7.0", notes: ["zh-Hans": "官网说明"])),
            language: "zh-Hans"
        )

        let update = await checker.checkForUpdates()

        XCTAssertEqual(update?.source, .official)
        XCTAssertEqual(update?.version, "1.7.0")
        XCTAssertEqual(update?.githubURL?.absoluteString, "https://github.com/wzh4869/AppPorts/releases/tag/1.7.0")
    }

    func testOfficialReleaseNotesFallbackToSimplifiedChineseThenEnglish() async throws {
        let checker = makeChecker(
            github: .status(404),
            official: .json(officialRelease(version: "1.7.0", notes: ["zh-Hans": "中文说明", "en": "English notes"])),
            language: "de"
        )

        let update = await checker.checkForUpdates()

        XCTAssertEqual(update?.releaseNotesMarkdown, "中文说明")
    }

    func testManualCheckReportsLatestWhenOneSourceSucceeds() async {
        let checker = makeChecker(github: .status(503), official: .json(officialRelease(version: "1.6.0", notes: [:])))
        let result = await checker.checkForUpdatesResult()
        XCTAssertEqual(result, .upToDate)
    }

    func testManualCheckReportsFailureWhenBothSourcesFail() async {
        let checker = makeChecker(github: .status(503), official: .error(URLError(.notConnectedToInternet)))
        let result = await checker.checkForUpdatesResult()
        XCTAssertEqual(result, .failed)
    }

    func testDisabledGitHubDoesNotCountAsSuccessfulCheck() async {
        let checker = makeChecker(github: .status(200), official: .status(503), githubUpdatesDisabled: true)
        let result = await checker.checkForUpdatesResult()
        XCTAssertEqual(result, .failed)
    }

    func testMalformedVersionsAreNotReportedAsLatest() async {
        let checker = makeChecker(github: .json(gitHubRelease(tag: "invalid", body: "")), official: .json(officialRelease(version: "invalid", notes: [:])))
        let result = await checker.checkForUpdatesResult()
        XCTAssertEqual(result, .failed)
    }

    func testManualCheckReportsAvailableVersion() async {
        let checker = makeChecker(github: .json(gitHubRelease(tag: "1.7.0", body: "Notes")), official: .status(503))
        let result = await checker.checkForUpdatesResult()
        guard case let .available(update) = result else { return XCTFail("Expected available update") }
        XCTAssertEqual(update.version, "1.7.0")
    }

    func testInvalidInstalledVersionReportsFailure() async {
        let checker = makeChecker(github: .status(503), official: .status(503), currentVersion: "")
        let result = await checker.checkForUpdatesResult()
        XCTAssertEqual(result, .failed)
    }

    func testDomesticChannelDoesNotRequestGitHub() async {
        let checker = makeChecker(
            github: .json(gitHubRelease(tag: "9.0.0", body: "GitHub notes")),
            official: .json(officialRelease(version: "1.7.0", notes: ["en": "Official notes"]))
        )
        let result = await checker.checkForUpdatesResult(channel: .official)
        guard case let .available(update) = result else { return XCTFail("Expected domestic update") }
        XCTAssertEqual(update.source, .official)
        XCTAssertEqual(update.version, "1.7.0")
        XCTAssertEqual(MockUpdateURLProtocol.requestedURLs, ["https://appports.shimoko.com/latest.json"])
    }

    func testGitHubUpdateIncludesVerifiedReleaseAssetForInstallation() async {
        var release = gitHubRelease(tag: "v1.7.0", body: "GitHub notes")
        release["assets"] = [[
            "name": "AppPorts1.7.0.dmg",
            "size": 12345,
            "browser_download_url": "https://github.com/wzh4869/AppPorts/releases/download/1.7.0/AppPorts1.7.0.dmg",
            "digest": "sha256:" + String(repeating: "a", count: 64)
        ]]
        let checker = makeChecker(github: .json(release), official: .status(404))
        let update = await checker.checkForUpdates(channel: .github)
        XCTAssertEqual(update?.githubAsset?.name, "AppPorts1.7.0.dmg")
        XCTAssertEqual(update?.githubAsset?.sha256, String(repeating: "a", count: 64))
    }

    func testGitHubChannelDoesNotRequestDomesticFeed() async {
        let checker = makeChecker(
            github: .json(gitHubRelease(tag: "1.7.0", body: "GitHub notes")),
            official: .json(officialRelease(version: "9.0.0", notes: ["en": "Official notes"]))
        )
        let result = await checker.checkForUpdatesResult(channel: .github)
        guard case let .available(update) = result else { return XCTFail("Expected GitHub update") }
        XCTAssertEqual(update.source, .github)
        XCTAssertEqual(update.version, "1.7.0")
        XCTAssertEqual(MockUpdateURLProtocol.requestedURLs, ["https://api.github.com/repos/wzh4869/AppPorts/releases/latest"])
    }

    func testDomesticFailureDoesNotFallBackToGitHub() async {
        let checker = makeChecker(
            github: .json(gitHubRelease(tag: "1.7.0", body: "GitHub notes")),
            official: .error(URLError(.timedOut))
        )
        let result = await checker.checkForUpdatesResult(channel: .official)
        XCTAssertEqual(result, .failed)
        XCTAssertEqual(MockUpdateURLProtocol.requestedURLs, ["https://appports.shimoko.com/latest.json"])
    }

    private func makeChecker(
        github: MockUpdateURLProtocol.MockResponse,
        official: MockUpdateURLProtocol.MockResponse,
        atom: MockUpdateURLProtocol.MockResponse = .status(404),
        language: String = "en",
        currentVersion: String = "1.6.0",
        githubUpdatesDisabled: Bool = false
    ) -> UpdateChecker {
        MockUpdateURLProtocol.setResponses([
            "https://api.github.com/repos/wzh4869/AppPorts/releases/latest": github,
            "https://github.com/wzh4869/AppPorts/releases.atom": atom,
            "https://appports.shimoko.com/latest.json": official
        ])

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockUpdateURLProtocol.self]
        let session = URLSession(configuration: configuration)

        return UpdateChecker(
            session: session,
            currentVersionProvider: { currentVersion },
            languageProvider: { language },
            preferredLanguagesProvider: { [language] },
            githubUpdatesDisabledProvider: { githubUpdatesDisabled }
        )
    }

    private func gitHubRelease(
        tag: String,
        body: String,
        htmlURL: String? = nil
    ) -> [String: Any] {
        [
            "tag_name": tag,
            "html_url": htmlURL ?? "https://github.com/wzh4869/AppPorts/releases/tag/\(tag.trimmingLeadingV())",
            "body": body
        ]
    }

    private func gitHubAtomFeed(tag: String, htmlBody: String) -> String {
        let normalizedTag = tag.trimmingLeadingV()
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom">
          <entry>
            <link rel="alternate" type="text/html" href="https://github.com/wzh4869/AppPorts/releases/tag/\(normalizedTag)"/>
            <title>\(tag)</title>
            <content type="html">\(escapeXML(htmlBody))</content>
          </entry>
        </feed>
        """
    }

    private func officialRelease(
        version: String,
        tag: String? = nil,
        notes: [String: String],
        githubURL: String? = nil
    ) -> [String: Any] {
        let normalizedTag = (tag ?? version).trimmingLeadingV()
        return [
            "version": version,
            "tag": tag ?? version,
            "build": 1,
            "publishedAt": "2026-05-27T00:00:00Z",
            "minimumSupportedVersion": "1.0.0",
            "releaseNotes": notes,
            "links": [
                "github": githubURL ?? "https://github.com/wzh4869/AppPorts/releases/tag/\(normalizedTag)",
                "primaryDownload": "https://file.shimoko.com/AppPorts",
                "mirrorDownload": "https://github.com/wzh4869/AppPorts/releases/download/\(normalizedTag)/AppPorts.zip"
            ],
            "sha256": ""
        ]
    }
}

private final class MockUpdateURLProtocol: URLProtocol {
    enum MockResponse {
        case json([String: Any])
        case text(String)
        case status(Int)
        case error(Error)
    }

    private static var responses: [String: MockResponse] = [:]
    private static var requests: [String] = []
    private static let lock = NSLock()

    static var requestedURLs: [String] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    static func setResponses(_ newResponses: [String: MockResponse]) {
        lock.lock()
        responses = newResponses
        requests = []
        lock.unlock()
    }

    static func reset() {
        lock.lock()
        responses = [:]
        requests = []
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        let response = Self.response(for: url.absoluteString)
        switch response {
        case let .json(object):
            do {
                let data = try JSONSerialization.data(withJSONObject: object)
                send(statusCode: 200, data: data)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        case let .text(text):
            send(statusCode: 200, data: Data(text.utf8))
        case let .status(statusCode):
            send(statusCode: statusCode, data: Data())
        case let .error(error):
            client?.urlProtocol(self, didFailWithError: error)
        case nil:
            send(statusCode: 404, data: Data())
        }
    }

    override func stopLoading() {}

    private static func response(for urlString: String) -> MockResponse? {
        lock.lock()
        defer { lock.unlock() }
        requests.append(urlString)
        return responses[urlString]
    }

    private func send(statusCode: Int, data: Data) {
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

private extension String {
    func trimmingLeadingV() -> String {
        guard lowercased().hasPrefix("v") else { return self }
        return String(dropFirst())
    }
}

private func escapeXML(_ value: String) -> String {
    value
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "'", with: "&apos;")
}
