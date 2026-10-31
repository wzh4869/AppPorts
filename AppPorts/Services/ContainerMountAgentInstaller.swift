//
//  ContainerMountAgentInstaller.swift
//  AppPorts
//

import Foundation
import Security

/// 管理「登录后自动重挂载容器卷」LaunchAgent 的安装与卸载。
///
/// 挂载到容器路径需要 Full Disk Access，普通脚本做不到；代理直接运行 AppPorts 自身的
/// 可执行文件并带 `--mount-agent` 参数，沿用主应用的 TCC 授权。挂载或恢复任务存在时安装，
/// 最后一项还原和清理完成后自动卸载。
enum ContainerMountAgentInstaller {

    static let label = "com.shimoko.AppPorts.container-mount"
    static let launchArgument = "--mount-agent"

    private static var agentPlistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: agentPlistURL.path)
    }

    /// 当前进程是否以后台挂载代理身份启动。
    static var isRunningAsAgent: Bool {
        CommandLine.arguments.dropFirst().contains(launchArgument)
    }

    /// AppPorts 每次启动时校准一次代理定义。
    ///
    /// 代理记录的程序路径原本只在迁移、还原时才更新：应用被移动或删除之后，代理会指向一个
    /// 不存在的程序，登录后没人挂卷，打开应用只能看到空目录（数据不会丢，挂载点是锁住的空目录）。
    /// 这里按 `agentExecutablePath` 的规则重写定义，没有变化时什么都不做。
    /// 启动时不卸载代理：没有挂载记录就保持原状，卸载只跟随最后一次还原。
    static func refreshAtLaunch(store: ContainerMountStore = .shared) async {
        // 测试宿主也会走到这里；不能让跑测试改写开发机上真实的登录代理。
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
              (try? requiresAgent(store: store)) == true else { return }
        // 定义有变化时要先 bootout 正在运行的代理；拿锁，免得在它挂到一半时把它停掉。
        let lock = OperationLock()
        guard await lock.acquire(timeout: OperationLock.appWaitTimeout) else {
            AppLogger.shared.log("启动时校准自动挂载代理：代理正在挂载，本次跳过", level: "TRACE")
            return
        }
        defer { lock.release() }
        // 等锁期间最后一条记录可能已被还原；此时不要重新安装刚卸载的代理。
        guard (try? requiresAgent(store: store)) == true else { return }
        do {
            try install()
        } catch {
            AppLogger.shared.logError(
                "启动时校准自动挂载代理失败",
                error: error,
                errorCode: "CONTAINER-MOUNT-AGENT-REFRESH-FAILED"
            )
        }
    }

    /// A restore temporarily removes its mount record before switching. Its
    /// transaction must keep the restart/reconnect worker installed throughout.
    static func requiresAgent(store: ContainerMountStore) throws -> Bool {
        if try !store.recordsStrict().isEmpty { return true }
        return try store.transfers().contains { $0.mode == .mount }
    }

    /// Keep an existing agent when the index is unreadable; absence must be proven.
    static func installIfNeeded(store: ContainerMountStore = .shared) {
        // The agent reconciles once the whole attempt has finished. bootout
        // or rebootstrap here would terminate recovery halfway through its loop.
        guard !isRunningAsAgent else { return }
        do {
            guard try requiresAgent(store: store) else {
                uninstall()
                return
            }
            try install()
        } catch {
            AppLogger.shared.logError(
                "安装容器卷自动挂载代理失败",
                error: error,
                errorCode: "CONTAINER-MOUNT-AGENT-INSTALL-FAILED"
            )
        }
    }

    /// 代理的 LaunchAgent 定义。
    ///
    /// `WatchPaths` 是关键：只靠 `RunAtLoad`，代理要等到登录后约 55 秒才跑，
    /// 而登录项里的微信在登录后约 43 秒就被拉起 —— 挂载永远慢一步，
    /// 微信只能读到空的容器路径。加上 `/Volumes` 监听后，系统把外置卷挂上
    /// （实测登录后约 17 秒）就会立刻再跑一次代理，比微信早约 20 秒完成。
    ///
    /// 代理自己跑起来之后还会在进程内等 `/Volumes` 的变化（`VolumeChangeMonitor`），
    /// 所以插盘的第一时间就能重试；这里的 `WatchPaths` 负责的是"代理没在跑的时候"：
    /// 用户开机十分钟后才插上盘，也得有人把代理叫起来。
    ///
    /// `KeepAlive` 里的 `SuccessfulExit: false` 是为了绕开登录时的排队：登录后一段时间
    /// 用户域处于 on-demand-only 模式，`RunAtLoad` 这种"闲着可以等"的任务会被 launchd
    /// 排到 20 秒后才 spawn（实测 `pending spawn, domain in on-demand-only mode` →
    /// 17.6 秒后 `Successfully spawned … because speculative`），而登录项里的应用 3 秒就起来了。
    /// 声明"失败才重启"让这个任务始终算"需要运行"，域一起来就会被拉起；代理正常退出
    /// （exit 0）不会被反复重启。原来的 `ProcessType: Background` 也去掉了：它等于主动
    /// 告诉 launchd "我不急"，与这里的意图相反。
    /// 抽成纯函数是为了能被测试守住，避免哪天被改回去。
    static func launchAgentPayload(executablePath: String, signatureIdentity: String? = nil) -> [String: Any] {
        var payload: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executablePath, launchArgument],
            // Attribute the legacy agent to the app in System Settings.
            "AssociatedBundleIdentifiers": ["com.shimoko.AppPorts"],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "LimitLoadToSessionType": ["Aqua"],
            "WatchPaths": ["/Volumes"]
        ]
        // Rebootstrap after an in-place update too. launchd binds its managed
        // launch constraint to the signing identity seen at registration.
        if let signatureIdentity { payload["AppPortsSignatureIdentity"] = signatureIdentity }
        return payload
    }

    private static func executableSignatureIdentity(at path: String) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess,
              let code else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let values = information as? [String: Any], let hash = values[kSecCodeInfoUnique as String] as? Data else { return nil }
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 代理运行哪一份 AppPorts

    /// 路径是否在 Gatekeeper「App 转移」的临时目录里。
    ///
    /// 从下载文件夹或磁盘映像里直接打开的应用，macOS 可能把它挪到
    /// `/private/var/folders/…/AppTranslocation/<UUID>/d/` 下运行，这个路径不会持久保留。
    /// 登录代理指向这种路径，下次登录 launchd 就找不到程序，容器卷没人挂。
    static func isTranslocated(_ url: URL) -> Bool {
        url.standardizedFileURL.pathComponents.contains { $0.lowercased() == "apptranslocation" }
    }

    /// 这些位置中的程序可能在重启、清理缓存或下次构建时消失，不能用作登录代理。
    /// 同时检查原路径与符号链接目标，避免「应用程序」里的链接掩盖临时构建。
    static func isTemporaryLocation(
        _ url: URL,
        resolveSymlinks: (URL) -> URL = { $0.resolvingSymlinksInPath() }
    ) -> Bool {
        let standardized = url.standardizedFileURL
        return [standardized, resolveSymlinks(standardized).standardizedFileURL].contains { candidate in
            let path = candidate.path.lowercased()
            let temporaryRoots = [
                "/tmp", "/private/tmp", "/var/tmp", "/private/var/tmp",
                "/var/folders", "/private/var/folders"
            ]
            if temporaryRoots.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
                return true
            }

            let components = candidate.pathComponents.map { $0.lowercased() }
            if isTranslocated(candidate) || components.contains("deriveddata") || components.contains(".build") {
                return true
            }
            // Xcode 可把构建目录放在任意位置。只认明确的产品布局，不把 build-tools 等普通目录误判为临时目录。
            return zip(components, components.dropFirst()).contains { parent, child in
                parent == "build" && (
                    child == "products" || child == "debug" || child == "release"
                        || child.hasPrefix("debug-") || child.hasPrefix("release-")
                )
            }
        }
    }

    /// 当前这份 AppPorts 是否从临时目录或构建输出目录运行，与代理候选路径使用同一套规则。
    static var isRunningFromTemporaryLocation: Bool {
        isTemporaryLocation(Bundle.main.executableURL ?? Bundle.main.bundleURL)
    }

    /// 是否装在「应用程序」文件夹（`/Applications` 或 `~/Applications`）里。
    static func isInApplicationsFolder(_ url: URL, homeDirectory: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let userApplications = homeDirectory.appendingPathComponent("Applications").standardizedFileURL.path
        return path.hasPrefix("/Applications/") || path.hasPrefix(userApplications + "/")
    }

    /// 选出登录代理应当运行的 AppPorts 可执行文件。
    ///
    /// 不能「谁最后启动就用谁」：从 Xcode 或临时目录跑起来的调试构建会把代理抢走，
    /// 而那些构建重启后可能就不在了，也未必有完全磁盘访问授权。规则：
    /// 1. 运行路径和旧记录都必须是非临时且仍可执行的本地路径，否则不作为候选。
    /// 2. 只有一个有效候选时采用它；没有有效候选时提示先安装到稳定位置。
    /// 3. 当前这份装在「应用程序」文件夹、记录的那份不在：采用当前这份（用户装好了正式版）。
    /// 4. 其余情况保留记录的那份。
    /// - Returns: nil 表示没有可用的稳定路径。
    static func agentExecutablePath(
        running: URL,
        recorded: String?,
        fileExists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        resolveSymlinks: (URL) -> URL = { $0.resolvingSymlinksInPath() }
    ) -> String? {
        func usablePath(_ url: URL) -> String? {
            guard url.isFileURL, !isTemporaryLocation(url, resolveSymlinks: resolveSymlinks) else { return nil }
            let path = url.standardizedFileURL.path
            return fileExists(path) ? path : nil
        }

        let usableRecorded = recorded.flatMap { path -> String? in
            guard path.hasPrefix("/") else { return nil }
            return usablePath(URL(fileURLWithPath: path))
        }
        guard let usableRunning = usablePath(running) else { return usableRecorded }
        guard let usableRecorded else { return usableRunning }
        if isInApplicationsFolder(URL(fileURLWithPath: usableRunning), homeDirectory: homeDirectory),
           !isInApplicationsFolder(URL(fileURLWithPath: usableRecorded), homeDirectory: homeDirectory) {
            return usableRunning
        }
        return usableRecorded
    }

    /// 已安装的代理定义里记录的可执行文件路径。
    static func recordedExecutablePath(inAgentPlist data: Data) -> String? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let arguments = plist["ProgramArguments"] as? [String] else { return nil }
        return arguments.first
    }

    static func install() throws {
        let runningExecutable = Bundle.main.executableURL
            ?? Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/AppPorts")
        let existing = try? Data(contentsOf: agentPlistURL)
        let recordedExecutable = existing.flatMap(recordedExecutablePath(inAgentPlist:))
        guard let executablePath = agentExecutablePath(running: runningExecutable, recorded: recordedExecutable) else {
            throw InstallError.temporaryLocation
        }
        let plist = launchAgentPayload(executablePath: executablePath,
                                      signatureIdentity: executableSignatureIdentity(at: executablePath))
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)

        let changed = try configureAgent(definitionMatches: existing == data, writeDefinition: {
            let launchAgentsDir = agentPlistURL.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: launchAgentsDir.path) {
                try FileManager.default.createDirectory(at: launchAgentsDir, withIntermediateDirectories: true)
            }
            try data.write(to: agentPlistURL, options: .atomic)
        }, run: runLaunchctl)
        guard changed else { return }
        AppLogger.shared.logContext(
            "容器卷自动挂载代理已安装",
            details: [
                ("plist", agentPlistURL.path),
                ("executable", executablePath),
                ("previous_executable", recordedExecutable ?? "none")
            ]
        )
    }

    /// A successful legacy `load` does not prove the service was registered.
    /// Keep this sequence injectable so tests never change real login services.
    @discardableResult
    static func configureAgent(
        definitionMatches: Bool,
        writeDefinition: () throws -> Void,
        run: ([String]) -> Int32
    ) throws -> Bool {
        let domain = "gui/\(getuid())"
        let service = "\(domain)/\(label)"
        // Disabled overrides survive plist replacement and bootstrap. Enable
        // before the fast path; on failure leave the existing definition alone.
        guard run(["enable", service]) == 0 else { throw InstallError.launchAgentLoadFailed }
        if definitionMatches, run(["print", service]) == 0 { return false }
        _ = run(["bootout", service])
        try writeDefinition()
        guard run(["bootstrap", domain, agentPlistURL.path]) == 0
                || run(["load", agentPlistURL.path]) == 0 else {
            throw InstallError.launchAgentLoadFailed
        }
        guard run(["print", service]) == 0 else { throw InstallError.launchAgentLoadFailed }
        return true
    }

    static func uninstall() {
        guard isInstalled else { return }
        runLaunchctl(["bootout", "gui/\(getuid())/\(label)"])
        runLaunchctl(["unload", agentPlistURL.path])
        try? FileManager.default.removeItem(at: agentPlistURL)
        AppLogger.shared.log("容器卷自动挂载代理已卸载")
    }

    /// 代理入口：重挂载所有在线的记录；没就位就等 `/Volumes` 的真实变化再试，
    /// 直到全部就位、或用完等待窗口（`ContainerRemountLoop.Policy.window`）。
    static func runAgentAndExit() -> Never {
        // 启动行：既是排障锚点，也是「开机时序」自查脚本判定代理何时被 launchd 拉起的依据，
        // 所以无论这一轮有没有活干都要留下（pid 行里的 `[pid:…]` 已经有进程号了）。
        AppLogger.shared.log("容器卷自动挂载代理启动")
        // 先把监听打开、再跑第一轮：第一轮跑的期间盘才插上，那次变化也不会漏掉。
        let monitor = VolumeChangeMonitor()
        if !monitor.start() {
            AppLogger.shared.logContext(
                "目录变化监听不可用，重试退化为兜底复查",
                details: [("path", "/Volumes"), ("backstop_seconds", "20")],
                level: "WARN"
            )
        }
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            // 后台代理没有界面，不能弹管理员授权框；旧系统上会以 privilegeRequired 失败并留给 AppPorts 启动时处理。
            let migrator = ContainerVolumeMigrator(disk: DiskUtility(administratorRunner: nil))
            var attemptIndex = 0
            let result = await ContainerRemountLoop.run(
                attempt: {
                    defer { attemptIndex += 1 }
                    // 第一轮可能碰上主应用正在做挂载迁移，值得等满；之后的轮次只象征性等一下，
                    // 免得代理和主应用互相让路谁都不动。
                    let timeout = attemptIndex == 0 ? OperationLock.agentWaitTimeout : Self.retryLockTimeout
                    return await remountAttempt(migrator: migrator, lockTimeout: timeout)
                },
                waitForChange: { await monitor.waitForNextChange(timeout: $0) }
            )
            reportAgentResult(result)
            semaphore.signal()
        }
        // Each disk command and idle reconnect loop is bounded. A valid large
        // copy/verification must finish before this process can exit.
        semaphore.wait()
        AppLogger.shared.log("容器卷自动挂载代理退出")
        exit(0)
    }

    /// 重试轮次里拿锁的等待时长。
    private static let retryLockTimeout: TimeInterval = 10

    /// 一轮尝试：拿锁 → 重挂载 → 放锁。
    ///
    /// 锁只在这一轮里持有：等卷（可能好几分钟）的时候不占锁，
    /// 用户在 AppPorts 里做迁移/还原不会被代理卡住。
    private static func remountAttempt(
        migrator: ContainerVolumeMigrator,
        lockTimeout: TimeInterval
    ) async -> ContainerRemountLoop.Attempt {
        let lock = OperationLock()
        // 插盘本身就会触发 `/Volumes` 变化，如果这时用户正在 AppPorts 里做挂载迁移或还原，
        // 两边会去抢同一个挂载点。让路：等主应用做完再上，等不到就跳过这一轮。
        guard await lock.acquire(timeout: lockTimeout) else {
            AppLogger.shared.logContext(
                "自动挂载代理让路",
                details: [("reason", "AppPorts 正在执行容器操作"), ("waited_seconds", String(Int(lockTimeout)))]
            )
            return .deferred
        }
        defer { lock.release() }
        await migrator.performAutomaticMaintenance()
        let outcomes = await migrator.remountAvailableRecords()
        if (try? requiresAgent(store: .shared)) == false {
            // All filesystem work and journal writes are complete. Remove the
            // persisted definition before bootout can terminate this process.
            try? FileManager.default.removeItem(at: agentPlistURL)
            runLaunchctl(["bootout", "gui/\(getuid())/\(label)"])
        }
        return .results(outcomes)
    }

    /// 代理一轮运行的收尾日志。空跑只留一行，逐条详单只在真的动过盘子（或读不到卷）时才写。
    private static func reportAgentResult(_ result: ContainerRemountLoop.Result) {
        let outcomes = result.outcomes
        if outcomes.isEmpty {
            switch result.reason {
            case .noRecords:
                AppLogger.shared.log("容器卷自动挂载代理结束：没有挂载记录")
            case .alwaysDeferred:
                AppLogger.shared.log("容器卷自动挂载代理结束：让路给 AppPorts，未执行")
            default:
                AppLogger.shared.logContext(
                    "容器卷自动挂载代理结束：没有跑成",
                    details: [("cycles", String(result.cycles)), ("reason", String(describing: result.reason))]
                )
            }
            return
        }
        if outcomes.allSatisfy({ $0.state == .alreadyMounted }) {
            AppLogger.shared.log(
                "容器卷自动挂载代理结束：\(outcomes.count) 个挂载点都已在位，无操作",
                level: "TRACE"
            )
            return
        }
        for outcome in outcomes {
            AppLogger.shared.logContext(
                "自动挂载代理结果",
                details: [
                    ("mount_point", outcome.record.mountPointPath),
                    ("volume", outcome.record.volumeName),
                    ("state", String(describing: outcome.state))
                ]
            )
        }
        let pending = ContainerRemountLoop.pendingRecords(in: outcomes)
        if result.waited || !pending.isEmpty {
            AppLogger.shared.logContext(
                "自动挂载代理重试统计",
                details: [
                    ("cycles", String(result.cycles)),
                    ("waited_for_volume", result.waited ? "true" : "false"),
                    ("still_pending", String(pending.count)),
                    ("reason", String(describing: result.reason))
                ]
            )
        }
    }

    @discardableResult
    private static func runLaunchctl(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return -1
        }
        process.waitUntilExit()
        return process.terminationStatus
    }

    enum InstallError: LocalizedError {
        case launchAgentLoadFailed
        case temporaryLocation

        var errorDescription: String? {
            switch self {
            case .launchAgentLoadFailed:
                return "LaunchAgent 加载失败".localized
            case .temporaryLocation:
                return "AppPorts 当前从临时位置运行，无法设置登录后自动挂载。请把 AppPorts 拖到「应用程序」文件夹，再从那里打开。".localized
            }
        }
    }
}
