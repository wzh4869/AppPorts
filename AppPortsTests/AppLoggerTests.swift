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

    private func stringValues(in value: Any) -> [String] {
        if let string = value as? String { return [string] }
        if let array = value as? [Any] { return array.flatMap(stringValues) }
        if let dictionary = value as? [String: Any] { return dictionary.values.flatMap(stringValues) }
        return []
    }
}
