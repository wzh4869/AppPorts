import Darwin
import XCTest
@testable import AppPorts

final class AppLoggerTests: XCTestCase {
    private let fileManager = FileManager.default
    private var defaultsSuiteName: String?
    private var logger: AppLogger!
    private var tempRootURL: URL?

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRootURL = fileManager.temporaryDirectory.appendingPathComponent("AppLoggerTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: XCTUnwrap(tempRootURL), withIntermediateDirectories: true)
        let suiteName = "AppLoggerTests.\(UUID().uuidString)"
        defaultsSuiteName = suiteName
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.set(try XCTUnwrap(tempRootURL).appendingPathComponent("AppPorts_Log.txt").path, forKey: "LogFilePath")
        defaults.set(true, forKey: "LogEnabled")
        defaults.set(8 * 1024 * 1024, forKey: "MaxLogSizeBytes")
        logger = AppLogger(userDefaults: defaults)
    }

    override func tearDownWithError() throws {
        logger = nil
        if let defaultsSuiteName {
            UserDefaults.standard.removePersistentDomain(forName: defaultsSuiteName)
        }

        if let tempRootURL {
            try? fileManager.removeItem(at: tempRootURL)
        }

        try super.tearDownWithError()
    }

    func testOperationFailureExportsAssociationAndNativeCauseWithRedactedPaths() throws {
        let root = try XCTUnwrap(tempRootURL)
        let recordID = UUID()
        let failure = OperationBlockage(reason: .signaturePreparation,
            applicationURL: URL(fileURLWithPath: "/Users/alice/Private Project/Example.app"),
            blockingOperationID: recordID, blockingPhase: "prepared",
            recordURL: URL(fileURLWithPath: "/Volumes/Private Backup/SignatureBackups/record.plist"),
            underlyingError: NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)))
        let wrapped = NSError(domain: "SyntheticWrapper", code: 99, userInfo: [NSUnderlyingErrorKey: failure as NSError])
        logger.logOperationFailure(category: "signature", operationID: "native-attempt", error: failure, stage: "preparing")
        logger.logOperationFailure(category: "signature", operationID: "wrapped-attempt", error: wrapped, stage: "verifying")
        let summaries = logger.recentOperationSummariesSnapshot()
        let native = try XCTUnwrap(summaries.first { $0.operationID == "native-attempt" })
        let nested = try XCTUnwrap(summaries.first { $0.operationID == "wrapped-attempt" })
        XCTAssertEqual(native.errorCode, failure.diagnosticCode)
        XCTAssertEqual(native.details["failure_stage"], "preparing")
        XCTAssertEqual(native.details["cause_blocking_operation_id"], recordID.uuidString)
        XCTAssertEqual(native.details["cause_blocking_phase"], "prepared")
        XCTAssertEqual(native.details["cause_underlying_domain"], NSPOSIXErrorDomain)
        XCTAssertEqual(native.details["cause_underlying_code"], String(EACCES))
        XCTAssertEqual(nested.errorCode, failure.diagnosticCode)
        XCTAssertEqual(nested.details["cause_underlying_blocking_operation_id"], recordID.uuidString)
        let export = root.appendingPathComponent("StructuredExport")
        try fileManager.createDirectory(at: export, withIntermediateDirectories: false)
        let package = try logger.buildDiagnosticPackage(in: export)
        let log = try String(contentsOf: package.appendingPathComponent("AppPorts_Log.share-safe.txt"))
        let json = try String(contentsOf: package.appendingPathComponent("recent-failures.json"))
        for text in [log, json] {
            XCTAssertTrue(text.contains(recordID.uuidString))
            XCTAssertTrue(text.contains(failure.diagnosticCode))
            XCTAssertFalse(text.contains("/Users/alice"))
            XCTAssertFalse(text.contains("Private Backup"))
        }
    }

    func testRedactedDiagnosticTextMasksUserAndVolumePaths() {
        let raw = """
        home=/Users/alice/Library/Application Support/AppPorts
        volume=/Volumes/Alice Private Disk/Apps/Foo.app
        volume_root=/Volumes/Alice Private Disk
        custom_home=/Users/Private Test User/Desktop/Foo.app
        url=file:///Volumes/Alice%20Private%20Disk/Apps/Foo.app
        volume: Alice Private Disk
        卷名称: Alice Private Disk
        [2026-03-12 20:00:00] [DISK] [session:TEST] [pid:1]   Volume Name: Alice Private Disk
        """

        let redacted = logger.redactedDiagnosticText(from: raw)

        XCTAssertFalse(redacted.contains("/Users/alice"))
        XCTAssertTrue(redacted.contains("/Users/<redacted-user>/Library/Application Support/AppPorts"))
        XCTAssertFalse(redacted.contains("Private Disk"))
        XCTAssertFalse(redacted.contains("Private Test User"))
        XCTAssertFalse(redacted.contains("Alice%20Private%20Disk"))
        XCTAssertTrue(redacted.contains("/Volumes/<redacted-volume>/Apps/Foo.app"))
        XCTAssertTrue(redacted.contains("volume_root=/Volumes/<redacted-volume>\n"))
        XCTAssertTrue(redacted.contains("custom_home=/Users/<redacted-user>/Desktop/Foo.app"))
        XCTAssertTrue(redacted.contains("Volume Name: <redacted-volume>"))
    }

    func testBuildDiagnosticPackageIncludesRedactedLogAndFailureSummary() throws {
        let tempRootURL = try XCTUnwrap(tempRootURL)
        let logURL = tempRootURL.appendingPathComponent("AppPorts_Log.txt")
        try """
        [2026-03-12 20:00:00] [ERROR] [session:TEST1234] [pid:1] source=/Users/alice/Library/Containers/com.example
        [2026-03-12 20:00:00] [ERROR] [session:TEST1234] [pid:1] volume=/Volumes/Alice Private Disk/AppPorts/Foo.app
        """.write(to: logURL, atomically: true, encoding: .utf8)
        logger.setLogPath(logURL)

        logger.logOperationSummary(
            category: "app_move /Volumes/Alice Private Disk/Category",
            operationID: "app-move-1234",
            result: "failed",
            startedAt: Date().addingTimeInterval(-1),
            errorCode: "APP-MOVE-PORTAL-CREATE-FAILED",
            details: [
                ("app_name", "Foo.app"),
                ("source_path", "/Users/alice/Library/Private Project/Foo.app"),
                ("destination_path", "/Volumes/Alice Private Disk/Apps/Foo.app"),
                ("volume", "Alice Private Disk"),
                ("description", "Failed at \"/Volumes/Alice Private Disk/Apps/Foo.app\"\nsource=/Users/alice/Library/Foo.app")
            ]
        )

        let exportRootURL = tempRootURL.appendingPathComponent("ExportRoot", isDirectory: true)
        try fileManager.createDirectory(at: exportRootURL, withIntermediateDirectories: true)

        let packageURL = try logger.buildDiagnosticPackage(in: exportRootURL)

        let redactedLog = try String(
            contentsOf: packageURL.appendingPathComponent("AppPorts_Log.share-safe.txt"),
            encoding: .utf8
        )
        XCTAssertFalse(redactedLog.contains("/Users/alice"))
        XCTAssertFalse(redactedLog.contains("Private Disk"))

        let summaryText = try String(
            contentsOf: packageURL.appendingPathComponent("diagnostic-summary.txt"),
            encoding: .utf8
        )
        XCTAssertTrue(summaryText.contains("app-move-1234"))
        XCTAssertTrue(summaryText.contains("APP-MOVE-PORTAL-CREATE-FAILED"))
        XCTAssertTrue(summaryText.contains("volume_state_inventory"))
        XCTAssertFalse(summaryText.contains("Private Disk"))

        let failuresData = try Data(contentsOf: packageURL.appendingPathComponent("recent-failures.json"))
        let failures = try JSONDecoder().decode([AppLogger.OperationSummaryRecord].self, from: failuresData)
        XCTAssertEqual(failures.last?.operationID, "app-move-1234")
        XCTAssertEqual(failures.last?.errorCode, "APP-MOVE-PORTAL-CREATE-FAILED")
        XCTAssertNotNil(failures.last?.durationMs)
        XCTAssertEqual(failures.last?.details["source_path"], "/Users/<redacted-user>/Library/Private Project/Foo.app")
        XCTAssertEqual(failures.last?.details["destination_path"], "/Volumes/<redacted-volume>/Apps/Foo.app")
        XCTAssertEqual(failures.last?.details["volume"], "<redacted-volume>")

        let operationsData = try Data(contentsOf: packageURL.appendingPathComponent("recent-operations.json"))
        let operations = try JSONDecoder().decode([AppLogger.OperationSummaryRecord].self, from: operationsData)
        XCTAssertEqual(operations.last?.category, "app_move /Volumes/<redacted-volume>/Category")
        XCTAssertEqual(operations.last?.details, failures.last?.details)

        let metadataData = try Data(contentsOf: packageURL.appendingPathComponent("diagnostic-summary.json"))
        let metadata = try JSONDecoder().decode([String: String].self, from: metadataData)
        XCTAssertEqual(metadata["redaction_mode"], "share_safe")
        XCTAssertTrue(try XCTUnwrap(metadata["volume_state_inventory"]).contains("state:"))
        XCTAssertTrue(try XCTUnwrap(metadata["update_guardian"]).contains("enabled:"))
        XCTAssertTrue(summaryText.contains("update_guardian"))

        // 检查解码后的字符串，避免 JSON 的 \/ 转义掩盖泄露。
        for fileURL in try fileManager.contentsOfDirectory(at: packageURL, includingPropertiesForKeys: nil) {
            let data = try Data(contentsOf: fileURL)
            let strings: [String]
            if fileURL.pathExtension == "json" {
                strings = stringValues(in: try JSONSerialization.jsonObject(with: data))
            } else {
                strings = [String(decoding: data, as: UTF8.self)]
            }
            for value in strings {
                XCTAssertFalse(value.contains("/Users/alice"), fileURL.lastPathComponent)
                XCTAssertFalse(value.contains("Private Disk"), fileURL.lastPathComponent)
            }
        }
    }

    func testConcurrentContextsKeepEveryFieldWithItsEvent() throws {
        let logger = try XCTUnwrap(logger)
        let eventCount = 120
        let fieldCount = 8
        DispatchQueue.concurrentPerform(iterations: eventCount) { event in
            logger.logContext(
                "EVENT|\(event)",
                details: (0..<fieldCount).map { ("field_\($0)", "OWNER|\(event)|\($0)") }
            )
        }

        logger.flush()
        let contents = try String(contentsOf: logger.logFileURL, encoding: .utf8)
        var currentEvent = ""
        var events = Set<String>()
        var fields = Set<String>()
        var mismatches = 0
        for line in contents.split(separator: "\n") {
            if let marker = line.range(of: "EVENT|") {
                currentEvent = String(line[marker.upperBound...])
                events.insert(currentEvent)
            }
            if let marker = line.range(of: "OWNER|") {
                let field = String(line[marker.upperBound...])
                fields.insert(field)
                if field.split(separator: "|").first.map(String.init) != currentEvent {
                    mismatches += 1
                }
            }
        }
        XCTAssertEqual(events.count, eventCount)
        XCTAssertEqual(fields.count, eventCount * fieldCount)
        XCTAssertEqual(mismatches, 0)
    }

    func testAutomaticRecoveryLogsOriginalFailureAndRecoveryFailure() throws {
        let operation = NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM),
            userInfo: [NSFilePathErrorKey: "/synthetic/source/payload"])
        let recovery = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError,
            userInfo: [NSFilePathErrorKey: "/synthetic/restore/staging"])
        logger.logError("RESTORED", error: ContainerVolumeMigrator.AutomaticRecoveryError.restored(
            operation: operation, retainedDetails: nil))
        logger.logError("INCOMPLETE", error: ContainerVolumeMigrator.AutomaticRecoveryError.incomplete(
            operation: operation, recovery: recovery))
        logger.flush()
        let contents = try String(contentsOf: logger.logFileURL, encoding: .utf8)
        XCTAssertTrue(contents.contains("error_underlying_domain: NSPOSIXErrorDomain"))
        XCTAssertTrue(contents.contains("error_underlying_file_path: /synthetic/source/payload"))
        XCTAssertTrue(contents.contains("error_detailed_0_domain: NSCocoaErrorDomain"))
        XCTAssertTrue(contents.contains("error_detailed_0_file_path: /synthetic/restore/staging"))
    }

    func testAppendLogDataThrowsInsteadOfRaisingAnExceptionOnWriteFailure() throws {
        let logURL = logger.logFileURL
        let original = Data("original\n".utf8)
        try original.write(to: logURL)
        let readOnlyHandle = try FileHandle(forReadingFrom: logURL)
        defer { try? readOnlyHandle.close() }

        XCTAssertThrowsError(try AppLogger.appendLogData(Data("unwritable".utf8), to: readOnlyHandle))
        XCTAssertEqual(try Data(contentsOf: logURL), original)

        let writableHandle = try FileHandle(forWritingTo: logURL)
        defer { try? writableHandle.close() }
        try AppLogger.appendLogData(Data("next\n".utf8), to: writableHandle)
        XCTAssertEqual(try String(contentsOf: logURL, encoding: .utf8), "original\nnext\n")
    }

    func testLoggingCanContinueAfterAnUnavailableDestination() throws {
        let rootURL = try XCTUnwrap(tempRootURL)
        logger.setLogPath(rootURL)
        logger.logOperationSummary(category: "copy", operationID: "retained", result: "failed")
        XCTAssertEqual(logger.recentOperationSummariesSnapshot().last?.operationID, "retained")

        let recoveredURL = rootURL.appendingPathComponent("recovered.log")
        logger.setLogPath(recoveredURL)
        logger.log("logging recovered")
        logger.flush()
        XCTAssertTrue(try String(contentsOf: recoveredURL, encoding: .utf8).contains("logging recovered"))
    }

    func testDiagnosticCommandDrainsOutputLargerThanThePipeBuffer() throws {
        let inputURL = try XCTUnwrap(tempRootURL).appendingPathComponent("large-output")
        let expected = Data(repeating: 0x61, count: 1024 * 1024)
        try expected.write(to: inputURL)

        let actual = try AppLogger.runDiagnosticCommand(
            executableURL: URL(fileURLWithPath: "/bin/cat"),
            arguments: [inputURL.path]
        )
        XCTAssertEqual(actual, expected)
    }

    func testDiagnosticCommandRejectsAnUnsuccessfulExit() {
        XCTAssertThrowsError(try AppLogger.runDiagnosticCommand(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf partial; exit 7"]
        )) { error in
            XCTAssertEqual(error as? AppLogger.DiagnosticCommandError, .unsuccessfulExit(7))
        }
    }

    func testDiagnosticCommandBoundsContinuousOutput() {
        XCTAssertThrowsError(try AppLogger.runDiagnosticCommand(
            executableURL: URL(fileURLWithPath: "/usr/bin/yes"),
            arguments: [],
            maximumOutputBytes: 32 * 1024
        )) { error in
            XCTAssertEqual(error as? AppLogger.DiagnosticCommandError, .outputLimitExceeded)
        }
    }

    func testDiagnosticCommandTimesOutAndReapsUnresponsiveProcesses() throws {
        // 覆盖管道仍打开、提前关闭 stdout，以及忽略 SIGTERM 三种情况。
        for setup in ["", "exec 1>&-; ", "trap '' TERM; "] {
            let pidURL = try XCTUnwrap(tempRootURL).appendingPathComponent("pid-\(UUID().uuidString)")
            let script = "printf '%s\\n' \"$$\" > \"$1\"; \(setup)exec /bin/sleep 60"
            let startedAt = ProcessInfo.processInfo.systemUptime
            XCTAssertThrowsError(try AppLogger.runDiagnosticCommand(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", script, "AppPortsDiagnosticTest", pidURL.path],
                timeout: 0.3
            )) { error in
                XCTAssertEqual(error as? AppLogger.DiagnosticCommandError, .timedOut)
            }
            XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - startedAt, 3)

            let pidText = try String(contentsOf: pidURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            let pid = try XCTUnwrap(Int32(pidText))
            let exists = Darwin.kill(pid, 0) == 0
            if exists { _ = Darwin.kill(pid, SIGKILL) }
            XCTAssertFalse(exists, "Timed out diagnostic process was left running")
        }
    }

    func testDiagnosticExportIncludesUpdateGuardianSummaryWithoutAppNames() throws {
        let root = try XCTUnwrap(tempRootURL)
        let dataDir = root.appendingPathComponent("GuardianData", isDirectory: true)
        let recoveryDir = dataDir.appendingPathComponent("shipit-recovery", isDirectory: true)
        try fileManager.createDirectory(at: recoveryDir, withIntermediateDirectories: true)

        let records = [
            AppSearchRecord(name: "SecretApp", localPath: "/Applications/SecretApp.app",
                            externalPath: "/Volumes/Private Disk/AppPorts.noindex/SecretApp.app",
                            volumeUUID: "VOL-1", expectsLocalEntry: true, lifecycle: .migrated,
                            remainingExternal: nil, targetBundleIdentifier: "com.example.secret"),
            AppSearchRecord(name: "RestoredApp", localPath: "/Applications/RestoredApp.app",
                            externalPath: "/Volumes/Private Disk/AppPorts.noindex/RestoredApp.app",
                            volumeUUID: "VOL-1", expectsLocalEntry: true, lifecycle: .restored,
                            remainingExternal: false, targetBundleIdentifier: "com.example.restored")
        ]
        try JSONEncoder().encode(records).write(to: dataDir.appendingPathComponent("app-search-records.json"))
        try Data("{}".utf8).write(to: recoveryDir.appendingPathComponent("abc123.json"))
        try Data("{}".utf8).write(to: recoveryDir.appendingPathComponent("abc123.task.json"))
        try Data("{}".utf8).write(to: recoveryDir.appendingPathComponent("def456.rollback-intent.json"))
        try Data("{}".utf8).write(to: recoveryDir.appendingPathComponent("def456.rollback.json"))

        let suiteName = "AppLoggerTests.Guardian.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: BackgroundAgentPreferences.updateGuardianKey)

        let snapshot = UpdateGuardianReporting.collect(defaults: defaults, dataDirectory: dataDir, readyPID: { 4242 })
        XCTAssertEqual(snapshot, .init(enabled: true, ready: true, monitoredCount: 1, receiptCount: 1, pendingRollbackCount: 1))

        let exportRoot = root.appendingPathComponent("GuardianExport", isDirectory: true)
        try fileManager.createDirectory(at: exportRoot, withIntermediateDirectories: true)
        let package = try logger.buildDiagnosticPackage(
            in: exportRoot,
            includeAppInventory: false,
            guardianSummary: UpdateGuardianReporting.diagnosticSection(snapshot)
        )

        let summaryText = try String(contentsOf: package.appendingPathComponent("diagnostic-summary.txt"), encoding: .utf8)
        let metadataData = try Data(contentsOf: package.appendingPathComponent("diagnostic-summary.json"))
        let metadata = try JSONDecoder().decode([String: String].self, from: metadataData)
        let guardianBlock = try XCTUnwrap(metadata["update_guardian"])

        for content in [summaryText, guardianBlock] {
            XCTAssertTrue(content.contains("enabled: true"))
            XCTAssertTrue(content.contains("ready: true"))
            XCTAssertTrue(content.contains("monitored_count: 1"))
            XCTAssertTrue(content.contains("receipt_count: 1"))
            XCTAssertTrue(content.contains("pending_rollback_count: 1"))
            XCTAssertFalse(content.contains("SecretApp"))
            XCTAssertFalse(content.contains("com.example.secret"))
            XCTAssertFalse(content.contains("Private Disk"))
        }
    }

    func testDefaultMaxLogSizeIs10MBAndMigrationRespectsLargerValues() throws {
        func makeIsolatedDefaults() throws -> (UserDefaults, String) {
            let name = "AppLoggerTests.Migration.\(UUID().uuidString)"
            return (try XCTUnwrap(UserDefaults(suiteName: name)), name)
        }

        // 1. Fresh user gets 10 MB default
        let (freshDefaults, freshSuite) = try makeIsolatedDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: freshSuite) }
        let freshLogger = AppLogger(userDefaults: freshDefaults)
        XCTAssertEqual(freshLogger.maxLogSize, 10 * 1024 * 1024)

        // 2. Legacy < 10 MB settings (1 MB / 2 MB / 5 MB) migrate once to 10 MB,
        //    and subsequent manual reductions are preserved across restarts.
        for legacyMB in [1, 2, 5] {
            let (defaults, suite) = try makeIsolatedDefaults()
            defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
            defaults.set(legacyMB * 1024 * 1024, forKey: "MaxLogSizeBytes")

            let migrated = AppLogger(userDefaults: defaults)
            XCTAssertEqual(migrated.maxLogSize, 10 * 1024 * 1024, "Expected \(legacyMB) MB to migrate to 10 MB")

            migrated.maxLogSize = 2 * 1024 * 1024
            let afterManualLower = AppLogger(userDefaults: defaults)
            XCTAssertEqual(afterManualLower.maxLogSize, 2 * 1024 * 1024, "Manual change after migration must be respected")
        }

        // 3. Legacy > 10 MB settings (50 MB / 100 MB) are never lowered.
        for largeMB in [50, 100] {
            let (defaults, suite) = try makeIsolatedDefaults()
            defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
            defaults.set(largeMB * 1024 * 1024, forKey: "MaxLogSizeBytes")

            let preserved = AppLogger(userDefaults: defaults)
            XCTAssertEqual(preserved.maxLogSize, Int64(largeMB) * 1024 * 1024)
        }
    }

    func testDualFileRoutingAndRenameRotationPreserveChronologicalExport() throws {
        let root = try XCTUnwrap(tempRootURL)
        logger.maxLogSize = 4096 // main single-vol ~1228 B, trace single-vol ~1024 B

        for index in 0..<25 {
            logger.log("MAIN-RECORD-\(String(format: "%02d", index)) " + String(repeating: "m", count: 80), level: "INFO")
            logger.log("TRACE-RECORD-\(String(format: "%02d", index)) " + String(repeating: "t", count: 80), level: "TRACE")
        }
        logger.flush()

        let mainCurrentURL = logger.logFileURL
        let mainArchiveURL = root.appendingPathComponent("AppPorts_Log.1.txt")
        let traceCurrentURL = logger.traceLogFileURL
        let traceArchiveURL = root.appendingPathComponent("AppPorts_Trace.1.txt")

        XCTAssertTrue(fileManager.fileExists(atPath: mainCurrentURL.path))
        XCTAssertTrue(fileManager.fileExists(atPath: mainArchiveURL.path))
        XCTAssertTrue(fileManager.fileExists(atPath: traceCurrentURL.path))
        XCTAssertTrue(fileManager.fileExists(atPath: traceArchiveURL.path))

        let mainCurrentText = try String(contentsOf: mainCurrentURL, encoding: .utf8)
        let traceCurrentText = try String(contentsOf: traceCurrentURL, encoding: .utf8)
        XCTAssertFalse(mainCurrentText.contains("TRACE-RECORD-"))
        XCTAssertFalse(traceCurrentText.contains("MAIN-RECORD-"))

        let exportRoot = root.appendingPathComponent("DualExport", isDirectory: true)
        try fileManager.createDirectory(at: exportRoot, withIntermediateDirectories: true)
        let package = try logger.buildDiagnosticPackage(in: exportRoot)

        let exportedMain = try String(contentsOf: package.appendingPathComponent("AppPorts_Log.share-safe.txt"), encoding: .utf8)
        let exportedTrace = try String(contentsOf: package.appendingPathComponent("AppPorts_Trace.share-safe.txt"), encoding: .utf8)
        XCTAssertTrue(exportedMain.contains("MAIN-RECORD-24"))
        XCTAssertTrue(exportedTrace.contains("TRACE-RECORD-24"))
        if let earlierMain = exportedMain.range(of: "MAIN-RECORD-20"),
           let laterMain = exportedMain.range(of: "MAIN-RECORD-24") {
            XCTAssertLessThan(earlierMain.lowerBound, laterMain.lowerBound)
        }

        logger.clearLog()
        XCTAssertFalse(fileManager.fileExists(atPath: mainArchiveURL.path))
        XCTAssertFalse(fileManager.fileExists(atPath: traceCurrentURL.path))
        XCTAssertFalse(fileManager.fileExists(atPath: traceArchiveURL.path))
    }

    func testOperationSummariesPersistAcrossLoggerRestart() throws {
        let suiteName = try XCTUnwrap(defaultsSuiteName)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))

        logger.logOperationSummary(
            category: "app_move",
            operationID: "persisted-op-1",
            result: "failed",
            errorCode: "TEST-PERSIST-ERR",
            details: [("volume", "Secret Disk")]
        )
        logger.flush()

        let restartedLogger = AppLogger(userDefaults: defaults)
        let summaries = restartedLogger.recentOperationSummariesSnapshot()
        XCTAssertEqual(summaries.last?.operationID, "persisted-op-1")
        XCTAssertEqual(summaries.last?.errorCode, "TEST-PERSIST-ERR")

        let exportRoot = try XCTUnwrap(tempRootURL).appendingPathComponent("RestartExport", isDirectory: true)
        try fileManager.createDirectory(at: exportRoot, withIntermediateDirectories: true)
        let package = try restartedLogger.buildDiagnosticPackage(in: exportRoot)
        let failuresText = try String(contentsOf: package.appendingPathComponent("recent-failures.json"), encoding: .utf8)
        XCTAssertTrue(failuresText.contains("persisted-op-1"))
        XCTAssertFalse(failuresText.contains("Secret Disk"))
    }

    func testAppInventorySnapshotExportedOnlyWhenIncluded() throws {
        let root = try XCTUnwrap(tempRootURL)
        logger.updateAppInventorySnapshot(scope: "local", entries: [
            AppLogger.AppInventoryEntry(
                scope: "local",
                name: "SecretTool.app",
                status: "本地",
                version: "1.2.3",
                containerKind: "standaloneApp",
                isSystemApp: false,
                isAppStoreApp: false,
                isRunning: true
            )
        ])
        logger.flush()

        let excludedRoot = root.appendingPathComponent("InventoryExcluded", isDirectory: true)
        try fileManager.createDirectory(at: excludedRoot, withIntermediateDirectories: true)
        let excludedPackage = try logger.buildDiagnosticPackage(in: excludedRoot, includeAppInventory: false)
        XCTAssertFalse(fileManager.fileExists(atPath: excludedPackage.appendingPathComponent("app-inventory.json").path))

        let includedRoot = root.appendingPathComponent("InventoryIncluded", isDirectory: true)
        try fileManager.createDirectory(at: includedRoot, withIntermediateDirectories: true)
        let includedPackage = try logger.buildDiagnosticPackage(in: includedRoot, includeAppInventory: true)
        let inventoryData = try Data(contentsOf: includedPackage.appendingPathComponent("app-inventory.json"))
        let entries = try JSONDecoder().decode([AppLogger.AppInventoryEntry].self, from: inventoryData)
        XCTAssertEqual(entries.first?.name, "SecretTool.app")
        XCTAssertEqual(entries.first?.scope, "local")
    }

    func testRedactedDiagnosticTextHandlesInlineDelimitersAndNetworkShareURLs() {
        let raw = """
        error: path="/Volumes/Alice Private Disk", code=EPERM; user='/Users/alice'
        remote=smb://alice:secret@nas.local/Media/AppPorts
        legacy=afp://192.168.1.50/TimeMachine
        """
        let redacted = logger.redactedDiagnosticText(from: raw)
        XCTAssertTrue(redacted.contains(#"path="/Volumes/<redacted-volume>", code=EPERM; user='/Users/<redacted-user>'"#))
        XCTAssertTrue(redacted.contains("remote=smb://<redacted-share>"))
        XCTAssertTrue(redacted.contains("legacy=afp://<redacted-share>"))
        XCTAssertFalse(redacted.contains("Alice Private Disk"))
        XCTAssertFalse(redacted.contains("nas.local"))
        XCTAssertFalse(redacted.contains("192.168.1.50"))
    }

    func testConcurrentMultiInstanceWritesShareLockWithoutInterleaving() throws {
        let suiteName = try XCTUnwrap(defaultsSuiteName)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let secondLogger = AppLogger(userDefaults: defaults)

        DispatchQueue.concurrentPerform(iterations: 60) { index in
            let activeLogger = index.isMultiple(of: 2) ? logger! : secondLogger
            activeLogger.logContext(
                "MULTI|\(index)",
                details: (0..<4).map { ("k_\($0)", "MOWNER|\(index)|\($0)") }
            )
        }
        logger.flush()
        secondLogger.flush()

        let contents = try String(contentsOf: logger.logFileURL, encoding: .utf8)
        var currentEvent = ""
        var events = Set<String>()
        var fields = Set<String>()
        var mismatches = 0
        for line in contents.split(separator: "\n") {
            if let marker = line.range(of: "MULTI|") {
                currentEvent = String(line[marker.upperBound...])
                events.insert(currentEvent)
            }
            if let marker = line.range(of: "MOWNER|") {
                let field = String(line[marker.upperBound...])
                fields.insert(field)
                if field.split(separator: "|").first.map(String.init) != currentEvent {
                    mismatches += 1
                }
            }
        }
        XCTAssertEqual(events.count, 60)
        XCTAssertEqual(fields.count, 240)
        XCTAssertEqual(mismatches, 0)
    }

    func testResetLogPathToDefaultClearsCustomOverride() throws {
        let suiteName = "AppLoggerTests.CustomPath.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        let customLogger = AppLogger(userDefaults: defaults, usesTestLogDirectory: false)
        let customURL = try XCTUnwrap(tempRootURL).appendingPathComponent("Custom/AppPorts_Log.txt")

        XCTAssertFalse(customLogger.isUsingCustomLogPath)
        customLogger.setLogPath(customURL)
        XCTAssertTrue(customLogger.isUsingCustomLogPath)
        XCTAssertEqual(customLogger.logFileURL.standardizedFileURL, customURL.standardizedFileURL)

        customLogger.resetLogPathToDefault()
        XCTAssertFalse(customLogger.isUsingCustomLogPath)
        XCTAssertEqual(customLogger.logFileURL.standardizedFileURL, customLogger.defaultLogFileURL.standardizedFileURL)
    }

    func testUnlimitedLogSizeDisablesRotationAndSurvivesMigration() throws {
        let suiteName = "AppLoggerTests.Unlimited.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        let root = try XCTUnwrap(tempRootURL).appendingPathComponent("UnlimitedRoot", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defaults.set(root.appendingPathComponent("AppPorts_Log.txt").path, forKey: "LogFilePath")
        defaults.set(true, forKey: "LogEnabled")
        defaults.set(Int(AppLogger.unlimitedMaxLogSizeBytes), forKey: "MaxLogSizeBytes")

        let unlimitedLogger = AppLogger(userDefaults: defaults)
        XCTAssertTrue(unlimitedLogger.isLogSizeUnlimited)
        XCTAssertEqual(unlimitedLogger.maxLogSize, AppLogger.unlimitedMaxLogSizeBytes)

        for index in 0..<40 {
            unlimitedLogger.log("UNLIMITED-MAIN-\(index) " + String(repeating: "u", count: 256), level: "INFO")
            unlimitedLogger.log("UNLIMITED-TRACE-\(index) " + String(repeating: "t", count: 256), level: "TRACE")
        }
        unlimitedLogger.flush()

        XCTAssertFalse(fileManager.fileExists(atPath: root.appendingPathComponent("AppPorts_Log.1.txt").path))
        XCTAssertFalse(fileManager.fileExists(atPath: root.appendingPathComponent("AppPorts_Trace.1.txt").path))
        let content = try String(contentsOf: unlimitedLogger.logFileURL, encoding: .utf8)
        XCTAssertTrue(content.contains("UNLIMITED-MAIN-0"))
        XCTAssertTrue(content.contains("UNLIMITED-MAIN-39"))

        let exportRoot = root.appendingPathComponent("Export", isDirectory: true)
        try fileManager.createDirectory(at: exportRoot, withIntermediateDirectories: true)
        let package = try unlimitedLogger.buildDiagnosticPackage(in: exportRoot)
        let metadataData = try Data(contentsOf: package.appendingPathComponent("diagnostic-summary.json"))
        let metadata = try JSONDecoder().decode([String: String].self, from: metadataData)
        XCTAssertEqual(metadata["max_log_size"], "unlimited")
    }

    func testDiagnosticExportHandlesInvalidUTF8BytesInLegacyLog() throws {
        let root = try XCTUnwrap(tempRootURL)
        var rawBytes = Data("[2026-03-12 20:00:00] [INFO] before-corrupt\n".utf8)
        rawBytes.append(contentsOf: [0xFF, 0xFE, 0x0A])
        rawBytes.append(contentsOf: "[2026-03-12 20:00:01] [ERROR] after-corrupt /Volumes/Alice Private Disk/App.app\n".utf8)
        try rawBytes.write(to: logger.logFileURL)

        let exportRoot = root.appendingPathComponent("CorruptUTF8Export", isDirectory: true)
        try fileManager.createDirectory(at: exportRoot, withIntermediateDirectories: true)
        let package = try logger.buildDiagnosticPackage(in: exportRoot)
        let exported = try String(contentsOf: package.appendingPathComponent("AppPorts_Log.share-safe.txt"), encoding: .utf8)
        XCTAssertTrue(exported.contains("before-corrupt"))
        XCTAssertTrue(exported.contains("after-corrupt /Volumes/<redacted-volume>/App.app"))
        XCTAssertFalse(exported.contains("Alice Private Disk"))
    }

    func testRedactedDiagnosticTextMasksMultilinePlistVolumeNameAndMountPoint() {
        let raw = """
        \t<key>VolumeName</key>
        \t<string>Alice Private Disk</string>
        \t<key>MountPoint</key>
        \t<string>/Volumes/Alice Private Disk</string>
        \t<key>Home</key>
        \t<string>/Users/alice</string>
        """
        let redacted = logger.redactedDiagnosticText(from: raw)
        XCTAssertTrue(redacted.contains("<key>VolumeName</key>\n\t<string><redacted-volume></string>"))
        XCTAssertTrue(redacted.contains("<key>MountPoint</key>\n\t<string>/Volumes/<redacted-volume></string>"))
        XCTAssertTrue(redacted.contains("<key>Home</key>\n\t<string>/Users/<redacted-user></string>"))
        XCTAssertFalse(redacted.contains("Alice Private Disk"))
        XCTAssertFalse(redacted.contains("/Users/alice"))
    }

    func testRealZipArchiveExportTruncatesOversizedLogWithoutModifyingLocalFile() throws {
        let root = try XCTUnwrap(tempRootURL)
        logger.maxLogSize = AppLogger.unlimitedMaxLogSizeBytes

        // Write a >16 MB log file to exercise tail-bounded export + real /usr/bin/ditto ZIP creation
        let header = Data("[2026-01-01 00:00:00] [INFO] VERY-OLD-ENTRY-SHOULD-BE-OUTSIDE-EXPORT-WINDOW\n".utf8)
        let fillerLine = Data(("[2026-06-01 12:00:00] [INFO] " + String(repeating: "x", count: 1000) + "\n").utf8)
        let tail = Data("""
        [2026-11-27 09:55:00] [ERROR] RECENT-TAIL-ENTRY /Volumes/Alice Private Disk/Apps/Demo.app
        \t<key>VolumeName</key>
        \t<string>Alice Private Disk</string>
        """.utf8)

        let logURL = logger.logFileURL
        fileManager.createFile(atPath: logURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: logURL)
        try handle.write(contentsOf: header)
        for _ in 0..<17_000 {
            try handle.write(contentsOf: fillerLine)
        }
        try handle.write(contentsOf: tail)
        try handle.close()

        let originalSize = try XCTUnwrap(fileManager.attributesOfItem(atPath: logURL.path)[.size] as? Int64)
        XCTAssertGreaterThan(originalSize, 16 * 1024 * 1024)

        let archiveURL = try logger.createDiagnosticArchive(includeAppInventory: false)
        defer { try? fileManager.removeItem(at: archiveURL.deletingLastPathComponent()) }

        // Local file must be completely untouched
        let afterSize = try XCTUnwrap(fileManager.attributesOfItem(atPath: logURL.path)[.size] as? Int64)
        XCTAssertEqual(afterSize, originalSize)

        let zipSize = try XCTUnwrap(fileManager.attributesOfItem(atPath: archiveURL.path)[.size] as? Int64)
        XCTAssertGreaterThan(zipSize, 0)
        XCTAssertLessThan(zipSize, 2 * 1024 * 1024)

        // Extract the real ZIP archive and verify contents + redaction
        let extractedRoot = root.appendingPathComponent("ExtractedZip", isDirectory: true)
        try fileManager.createDirectory(at: extractedRoot, withIntermediateDirectories: true)
        _ = try AppLogger.runDiagnosticCommand(
            executableURL: URL(fileURLWithPath: "/usr/bin/ditto"),
            arguments: ["-x", "-k", archiveURL.path, extractedRoot.path],
            timeout: 30
        )
        let extractedDirs = try fileManager.contentsOfDirectory(at: extractedRoot, includingPropertiesForKeys: nil)
        let packageDir = try XCTUnwrap(extractedDirs.first)

        let metadataData = try Data(contentsOf: packageDir.appendingPathComponent("diagnostic-summary.json"))
        let metadata = try JSONDecoder().decode([String: String].self, from: metadataData)
        XCTAssertEqual(metadata["main_log_export_truncated"], "true")
        XCTAssertEqual(metadata["max_log_size"], "unlimited")

        let exportedLog = try String(contentsOf: packageDir.appendingPathComponent("AppPorts_Log.share-safe.txt"), encoding: .utf8)
        XCTAssertTrue(exportedLog.contains("诊断包导出副本仅包含最近"))
        XCTAssertTrue(exportedLog.contains("RECENT-TAIL-ENTRY /Volumes/<redacted-volume>/Apps/Demo.app"))
        XCTAssertTrue(exportedLog.contains("<key>VolumeName</key>\n\t<string><redacted-volume></string>"))
        XCTAssertFalse(exportedLog.contains("VERY-OLD-ENTRY-SHOULD-BE-OUTSIDE-EXPORT-WINDOW"))
        XCTAssertFalse(exportedLog.contains("Alice Private Disk"))
    }

    func testClearLogMovesLogVolumesToTrashAndFallsBackOnError() throws {
        let root = try XCTUnwrap(tempRootURL)
        let suiteName = "AppLoggerTests.Trash.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        let trashDir = root.appendingPathComponent("MockTrash", isDirectory: true)
        try fileManager.createDirectory(at: trashDir, withIntermediateDirectories: true)
        let logDir = root.appendingPathComponent("TrashLogs", isDirectory: true)
        try fileManager.createDirectory(at: logDir, withIntermediateDirectories: true)
        defaults.set(logDir.appendingPathComponent("AppPorts_Log.txt").path, forKey: "LogFilePath")
        defaults.set(true, forKey: "LogEnabled")

        let lock = NSLock()
        nonisolated(unsafe) var trashedNames: [String] = []
        let trashLogger = AppLogger(userDefaults: defaults, trashItemHandler: { url in
            lock.lock()
            trashedNames.append(url.lastPathComponent)
            lock.unlock()
            try FileManager.default.moveItem(at: url, to: trashDir.appendingPathComponent(url.lastPathComponent))
        })

        // Seed all 4 log volumes
        for name in ["AppPorts_Log.txt", "AppPorts_Log.1.txt", "AppPorts_Trace.txt", "AppPorts_Trace.1.txt"] {
            try Data("sample-\(name)\n".utf8).write(to: logDir.appendingPathComponent(name))
        }
        trashLogger.clearLog()

        XCTAssertEqual(Set(trashedNames), ["AppPorts_Log.txt", "AppPorts_Log.1.txt", "AppPorts_Trace.txt", "AppPorts_Trace.1.txt"])
        XCTAssertTrue(fileManager.fileExists(atPath: trashDir.appendingPathComponent("AppPorts_Log.1.txt").path))
        XCTAssertFalse(fileManager.fileExists(atPath: logDir.appendingPathComponent("AppPorts_Log.1.txt").path))

        // Fallback to direct removeItem when trash fails (e.g. volume without Trash support)
        let fallbackLogger = AppLogger(userDefaults: defaults, trashItemHandler: { _ in
            throw CocoaError(.featureUnsupported)
        })
        try Data("archive\n".utf8).write(to: logDir.appendingPathComponent("AppPorts_Log.1.txt"))
        fallbackLogger.clearLog()
        XCTAssertFalse(fileManager.fileExists(atPath: logDir.appendingPathComponent("AppPorts_Log.1.txt").path))
    }

    private func stringValues(in value: Any) -> [String] {
        if let string = value as? String { return [string] }
        if let array = value as? [Any] { return array.flatMap(stringValues) }
        if let dictionary = value as? [String: Any] { return dictionary.values.flatMap(stringValues) }
        return []
    }
}
