import Foundation
import Testing
@testable import AppPorts

@Suite("Mount migration preflight and guidance")
struct MountMigrationPreflightTests {
    private let destination = URL(fileURLWithPath: "/Volumes/hano/AppPorts")
    private let gigabyte: Int64 = 1_000_000_000

    // MARK: 检查

    @Test("No destination is reported before any disk query")
    func noDestination() async {
        let probe = FakeProbe()
        let outcome = await MountMigrationPreflight(probe: probe.probe).evaluate(destination: nil, dataBytes: gigabyte)
        #expect(outcome == .noDestination)
        #expect(probe.volumeQueries == 0)
    }

    @Test("A disconnected destination is reported without asking diskutil")
    func disconnectedDestination() async {
        let probe = FakeProbe(pathExists: false)
        let outcome = await MountMigrationPreflight(probe: probe.probe).evaluate(destination: destination, dataBytes: gigabyte)
        #expect(outcome == .destinationUnavailable)
        #expect(probe.volumeQueries == 0)
    }

    @Test("An unreadable volume is treated as unavailable")
    func unreadableVolume() async {
        let probe = FakeProbe(info: nil)
        let outcome = await MountMigrationPreflight(probe: probe.probe).evaluate(destination: destination, dataBytes: gigabyte)
        #expect(outcome == .destinationUnavailable)
    }

    @Test("Non-APFS drives carry their file system back to the guidance", arguments: ["exfat", "ntfs", "hfs", "msdos"])
    func nonAPFS(filesystem: String) async {
        let probe = FakeProbe(info: volume(filesystem: filesystem, container: nil))
        let outcome = await MountMigrationPreflight(probe: probe.probe).evaluate(destination: destination, dataBytes: gigabyte)
        #expect(outcome == .notAPFS(filesystem: filesystem))
    }

    @Test("Encrypted APFS is refused so data never silently loses its protection")
    func encryptedAPFS() async {
        let probe = FakeProbe(info: volume(encrypted: true))
        let outcome = await MountMigrationPreflight(probe: probe.probe).evaluate(destination: destination, dataBytes: gigabyte)
        #expect(outcome == .encrypted)
    }

    @Test("Too little free space is reported with the required and available sizes")
    func insufficientSpace() async {
        let probe = FakeProbe(available: gigabyte)
        let outcome = await MountMigrationPreflight(probe: probe.probe).evaluate(destination: destination, dataBytes: 5 * gigabyte)
        #expect(outcome == .insufficientSpace(
            requiredBytes: ContainerVolumeMigrator.requiredFreeBytes(forDataBytes: 5 * gigabyte),
            availableBytes: gigabyte
        ))
    }

    @Test("Unknown data size skips the space check")
    func unknownSizeSkipsSpaceCheck() async {
        let probe = FakeProbe(available: 1)
        let outcome = await MountMigrationPreflight(probe: probe.probe).evaluate(destination: destination, dataBytes: 0)
        #expect(outcome == .ready(availableBytes: 1))
    }

    @Test("Unencrypted APFS with enough space is ready")
    func ready() async {
        let probe = FakeProbe(available: 100 * gigabyte)
        let outcome = await MountMigrationPreflight(probe: probe.probe).evaluate(destination: destination, dataBytes: gigabyte)
        #expect(outcome == .ready(availableBytes: 100 * gigabyte))
    }

    // MARK: 引导

    static let blockedOutcomes: [MountMigrationPreflight.Outcome] = [
        .noDestination,
        .destinationUnavailable,
        .notAPFS(filesystem: "exfat"),
        .notAPFS(filesystem: nil),
        .encrypted,
        .insufficientSpace(requiredBytes: 2_000_000_000, availableBytes: 1_000_000_000)
    ]

    @Test("Only a ready destination offers to migrate", arguments: blockedOutcomes)
    func blockedStatesNeverMigrate(outcome: MountMigrationPreflight.Outcome) {
        let guidance = makeGuidance(outcome)
        #expect(guidance.isReady == false)
        #expect(guidance.actions.contains { $0.kind == .migrate } == false)
        #expect(guidance.actions.isEmpty == false)
        #expect(guidance.intro.contains("%@") == false)
        #expect(guidance.title.contains("%@") == false)
    }

    @Test("A ready destination explains the change and offers one primary action")
    func readyGuidance() {
        let guidance = makeGuidance(.ready(availableBytes: nil))
        #expect(guidance.isReady)
        #expect(guidance.actions.map(\.kind) == [.migrate])
        #expect(guidance.actions.first?.isPrimary == true)
        #expect(guidance.intro.contains("WeChat"))
        // 说盘名，不说用户选的子文件夹名
        #expect(guidance.intro.contains("hano"))
        #expect(guidance.bullets.contains { $0.text.contains("2.5 GB") })
        #expect(guidance.detail?.contains("~/Library/Containers/com.tencent.xinWeChat") == true)
    }

    @Test("Without a known size the ready guidance leaves out the space bullet")
    func readyGuidanceWithoutSize() {
        let guidance = MountMigrationGuidance.make(
            outcome: .ready(availableBytes: nil),
            appName: "WeChat",
            dataSize: nil,
            sourcePath: "~/Library/Containers/com.tencent.xinWeChat",
            destinationPath: destination.path
        )
        #expect(guidance.bullets.contains { $0.icon == "internaldrive" } == false)
    }

    @Test("Drives that need changes lead with keeping things as they are", arguments: [
        MountMigrationPreflight.Outcome.notAPFS(filesystem: "exfat"),
        .encrypted
    ])
    func keepAsIsIsTheDefault(outcome: MountMigrationPreflight.Outcome) {
        let guidance = makeGuidance(outcome)
        #expect(guidance.cancelTitle == "保留现状".localized)
        #expect(guidance.actions.allSatisfy { $0.isPrimary == false })
        #expect(guidance.bullets.first?.icon == "checkmark.circle")
        #expect(guidance.actions.contains { if case .openGuide = $0.kind { return true } else { return false } })
    }

    @Test("HFS+ is pointed at lossless conversion, other formats at backup first")
    func conversionAdviceMatchesFormat() {
        let hfs = makeGuidance(.notAPFS(filesystem: "hfs"))
        let exfat = makeGuidance(.notAPFS(filesystem: "exfat"))
        #expect(hfs.bullets.last?.text == "想把这块盘改成 APFS：Mac OS 扩展（HFS+）可以用「磁盘工具」无损转换为 APFS，转换前请先备份".localized)
        #expect(exfat.bullets.last?.text != hfs.bullets.last?.text)
        #expect(exfat.bullets.last?.text.contains("ExFAT") == true)
        #expect(exfat.title.contains("ExFAT"))
    }

    @Test("Guide links point at stable anchors in the APFS page")
    func guideAnchors() {
        let kinds = [makeGuidance(.notAPFS(filesystem: "exfat")), makeGuidance(.encrypted)]
            .flatMap(\.actions).map(\.kind)
        #expect(kinds.contains(.openGuide(page: "why-apfs", anchor: "prepare-apfs")))
        #expect(kinds.contains(.openGuide(page: "why-apfs", anchor: "encrypted-drives")))
    }

    @Test("The drive is named by its volume, not by the chosen folder")
    func driveNames() {
        #expect(MountMigrationGuidance.driveName(for: "/Volumes/hano/AppPorts") == "hano")
        #expect(MountMigrationGuidance.driveName(for: "/Volumes/My Passport") == "My Passport")
        #expect(MountMigrationGuidance.driveName(for: "/Users/me/External") == "External")
    }

    @Test("Documentation links follow the interface language")
    func documentationLinks() {
        #expect(DocumentationLink.url(page: "why-apfs", anchor: "prepare-apfs", language: "zh-Hans").absoluteString
                == "https://docs-appports.shimoko.com/why-apfs.html#prepare-apfs")
        #expect(DocumentationLink.url(page: "why-apfs", language: "zh-Hant").absoluteString
                == "https://docs-appports.shimoko.com/zh-Hant/why-apfs.html")
        // The published site only ships zh-Hans, zh-Hant and en. Any other
        // interface language must fall back to the English edition instead of a
        // locale directory that was never built (which would 404).
        #expect(DocumentationLink.url(page: "datamigrae/mount-migration", language: "ja").absoluteString
                == "https://docs-appports.shimoko.com/en/datamigrae/mount-migration.html")
        #expect(DocumentationLink.url(page: "storage-capabilities", anchor: "summary", language: "en").absoluteString
                == "https://docs-appports.shimoko.com/en/storage-capabilities.html#summary")
        #expect(DocumentationLink.url(page: "storage-capabilities", anchor: "summary", language: "zh-Hans").absoluteString
                == "https://docs-appports.shimoko.com/storage-capabilities.html#summary")
        #expect(DocumentationLink.sitePrefix(for: "de-DE") == "en/")
        #expect(DocumentationLink.sitePrefix(for: "zh-Hant-TW") == "zh-Hant/")
        #expect(DocumentationLink.sitePrefix(for: "zh-martian") == "")
        #expect(DocumentationLink.sitePrefix(for: "ru") == "en/")
        #expect(DocumentationLink.sitePrefix(for: "br") == "en/")
    }

    // MARK: 辅助

    private func makeGuidance(_ outcome: MountMigrationPreflight.Outcome) -> MountMigrationGuidance {
        MountMigrationGuidance.make(
            outcome: outcome,
            appName: "WeChat",
            dataSize: "2.5 GB",
            sourcePath: "~/Library/Containers/com.tencent.xinWeChat",
            destinationPath: destination.path
        )
    }

    private func volume(filesystem: String = "apfs", container: String? = "disk7", encrypted: Bool = false) -> DiskUtility.VolumeInfo {
        DiskUtility.VolumeInfo(
            deviceIdentifier: "disk7s1",
            volumeUUID: "EXTERNAL-UUID",
            volumeName: "hano",
            filesystemType: filesystem,
            apfsContainerReference: container,
            mountPoint: "/Volumes/hano",
            isEncrypted: encrypted
        )
    }

    private final class FakeProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var queries = 0
        let pathExists: Bool
        let info: DiskUtility.VolumeInfo?
        let available: Int64?

        init(
            pathExists: Bool = true,
            info: DiskUtility.VolumeInfo? = DiskUtility.VolumeInfo(
                deviceIdentifier: "disk7s1", volumeUUID: "EXTERNAL-UUID", volumeName: "hano",
                filesystemType: "apfs", apfsContainerReference: "disk7", mountPoint: "/Volumes/hano"
            ),
            available: Int64? = nil
        ) {
            self.pathExists = pathExists
            self.info = info
            self.available = available
        }

        var volumeQueries: Int {
            lock.lock(); defer { lock.unlock() }
            return queries
        }

        var probe: MountMigrationPreflight.Probe {
            MountMigrationPreflight.Probe(
                pathExists: { _ in self.pathExists },
                volumeInfo: { _ in
                    self.lock.lock(); self.queries += 1; self.lock.unlock()
                    return self.info
                },
                availableCapacity: { _ in self.available }
            )
        }
    }
}
