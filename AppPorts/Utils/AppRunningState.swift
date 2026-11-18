import Foundation

/// 用运行应用的快照匹配真实应用；不依赖 UI 扫描时缓存的 isRunning。
enum AppRunningState {
    struct RunningApplication: Sendable {
        let bundleURL: URL?
        let bundleIdentifier: String?
    }

    struct Snapshot: Sendable {
        let normalizedPaths: Set<String>
        let identifiers: Set<String>
        var isEmpty: Bool { normalizedPaths.isEmpty && identifiers.isEmpty }

        init(applications: [RunningApplication]) {
            var paths: Set<String> = []
            var ids: Set<String> = []
            paths.reserveCapacity(applications.count * 2)
            ids.reserveCapacity(applications.count)
            for application in applications {
                if let rawID = AppRunningState.nonemptyIdentifier(application.bundleIdentifier) {
                    if rawID.lowercased().hasSuffix(".appports.stub") { continue }
                    ids.insert(rawID)
                }
                if let bundleURL = application.bundleURL {
                    paths.insert(bundleURL.standardizedFileURL.path)
                    paths.insert(AppRunningState.normalizedPath(bundleURL))
                }
            }
            self.normalizedPaths = paths
            self.identifiers = ids
        }

        func matches(appURL: URL, bundleIdentifier: String?) -> Bool {
            if normalizedPaths.contains(appURL.standardizedFileURL.path)
                || normalizedPaths.contains(AppRunningState.normalizedPath(appURL)) {
                return true
            }
            guard let expectedID = AppRunningState.nonemptyIdentifier(bundleIdentifier) else {
                return false
            }
            return identifiers.contains(expectedID)
        }
    }

    nonisolated static func isRunning(appURL: URL, applications: [RunningApplication]) -> Bool {
        isRunning(appURL: appURL, snapshot: Snapshot(applications: applications))
    }

    nonisolated static func applyingRunningState(
        to apps: [AppItem],
        applications: [RunningApplication]
    ) -> [AppItem] {
        let snapshot = Snapshot(applications: applications)
        return apps.map { app in
            var updated = app
            if app.isFolder {
                updated.isRunning = folderAppBundles(at: app.path).contains { child in
                    isRunning(appURL: child, snapshot: snapshot)
                        || isRunning(appURL: app.path.appendingPathComponent(child.lastPathComponent), snapshot: snapshot)
                }
            } else {
                updated.isRunning = isRunning(appURL: app.displayURL, snapshot: snapshot)
                    || (app.displayURL != app.path && isRunning(appURL: app.path, snapshot: snapshot))
            }
            return updated
        }
    }

    nonisolated static func isRunning(appURL: URL, snapshot: Snapshot) -> Bool {
        let resolvedIdentity: ResolvedAppIdentity?
        if case .success(let identity) = AppIdentityResolver.resolve(at: appURL) {
            resolvedIdentity = identity
        } else {
            resolvedIdentity = nil
        }

        let onlineRealURL = resolvedIdentity?.realAppURL ?? (try? CodeSigner.resolveAppURL(at: appURL))
        let offlineTarget = offlinePortalTarget(at: appURL)
        var candidateURLs: [URL] = []
        if let onlineRealURL {
            candidateURLs.append(onlineRealURL)
        }
        if let identityBundleURL = resolvedIdentity?.identityBundleURL,
           normalizedPath(identityBundleURL) != onlineRealURL.map(normalizedPath) {
            candidateURLs.append(identityBundleURL)
        }
        if let offlineURL = offlineTarget.targetURL {
            candidateURLs.append(offlineURL)
        }
        if candidateURLs.isEmpty && !isStubPortalBundle(at: appURL) {
            candidateURLs.append(appURL)
        }

        let identifier = resolvedIdentity?.bundleIdentifier
            ?? CodeSigner.bundleIdentifier(at: onlineRealURL ?? appURL).flatMap {
                $0.lowercased().hasSuffix(".appports.stub") ? nil : $0
            }
            ?? offlineTarget.targetBundleIdentifier

        if candidateURLs.isEmpty {
            guard let expectedID = nonemptyIdentifier(identifier) else { return false }
            return snapshot.identifiers.contains(expectedID)
        }
        return candidateURLs.contains { candidate in
            snapshot.matches(appURL: candidate, bundleIdentifier: identifier)
        }
    }

    nonisolated private static func folderAppBundles(at folderURL: URL) -> [URL] {
        let fm = FileManager.default
        let inspectURL: URL
        if let linkDestination = try? fm.destinationOfSymbolicLink(atPath: folderURL.path) {
            inspectURL = URL(fileURLWithPath: linkDestination, relativeTo: folderURL.deletingLastPathComponent()).standardizedFileURL
        } else {
            inspectURL = folderURL
        }
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: inspectURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return []
        }
        let items = (try? fm.contentsOfDirectory(at: inspectURL, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        return items.filter { $0.pathExtension == "app" }
    }

    nonisolated static func isStubPortalBundle(at appURL: URL) -> Bool {
        let plistURL = appURL.appendingPathComponent("Contents/Info.plist")
        if let id = CodeSigner.bundleIdentifier(at: appURL),
           id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasSuffix(".appports.stub") {
            return true
        }
        let fm = FileManager.default
        if (try? fm.attributesOfItem(atPath: appURL.appendingPathComponent("Contents/Resources/real_app_path.txt").path)) != nil {
            return true
        }
        if (try? Data(contentsOf: plistURL)) != nil,
           let launcher = try? String(contentsOf: appURL.appendingPathComponent("Contents/MacOS/launcher"), encoding: .utf8),
           launcher.contains("REAL_APP=") {
            return true
        }
        return false
    }

    /// 断盘或目标暂不可达时，仅根据入口记录提取原始外部路径与包身份（绝不把 `.appports.stub` 当作运行目标）。
    nonisolated private static func offlinePortalTarget(at appURL: URL) -> (targetURL: URL?, targetBundleIdentifier: String?) {
        let fm = FileManager.default
        var candidate = appURL.standardizedFileURL
        var visited = Set<String>()
        var extractedURL: URL?
        var extractedIdentifier: String?

        while visited.insert(candidate.path).inserted {
            if let plistData = try? Data(contentsOf: candidate.appendingPathComponent("Contents/Info.plist")),
               let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any] {
                if let targetID = nonemptyIdentifier(plist["AppPortsTargetBundleIdentifier"] as? String),
                   !targetID.lowercased().hasSuffix(".appports.stub") {
                    extractedIdentifier = extractedIdentifier ?? targetID
                } else if let rawID = nonemptyIdentifier(plist["CFBundleIdentifier"] as? String),
                          rawID.lowercased().hasSuffix(".appports.stub") {
                    let stripped = String(rawID.dropLast(".appports.stub".count))
                    if !stripped.isEmpty {
                        extractedIdentifier = extractedIdentifier ?? stripped
                    }
                }
            }

            if let dest = try? fm.destinationOfSymbolicLink(atPath: candidate.path) {
                let target = URL(fileURLWithPath: dest, relativeTo: candidate.deletingLastPathComponent()).standardizedFileURL
                extractedURL = target
                candidate = target
                continue
            }

            let pathFile = candidate.appendingPathComponent("Contents/Resources/real_app_path.txt")
            if let raw = try? String(contentsOf: pathFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
               raw.hasPrefix("/") {
                let target = URL(fileURLWithPath: raw).standardizedFileURL
                extractedURL = target
                candidate = target
                continue
            }

            let launcher = candidate.appendingPathComponent("Contents/MacOS/launcher")
            if let script = try? String(contentsOf: launcher, encoding: .utf8),
               let assignment = script.components(separatedBy: .newlines)
                .map({ $0.trimmingCharacters(in: .whitespaces) })
                .first(where: { $0.hasPrefix("REAL_APP=") }),
               assignment.hasPrefix("REAL_APP='"), assignment.hasSuffix("'") {
                let raw = String(assignment.dropFirst("REAL_APP='".count).dropLast())
                    .replacingOccurrences(of: "'\\''", with: "'")
                if raw.hasPrefix("/") {
                    let target = URL(fileURLWithPath: raw).standardizedFileURL
                    extractedURL = target
                    candidate = target
                    continue
                }
            }

            if let hybrid = AppMigrationService.hybridPortalExternalURL(at: candidate) {
                let target = hybrid.standardizedFileURL
                extractedURL = target
                candidate = target
                continue
            }

            let contents = candidate.appendingPathComponent("Contents")
            if let dest = try? fm.destinationOfSymbolicLink(atPath: contents.path) {
                let resolvedContents = URL(fileURLWithPath: dest, relativeTo: candidate).standardizedFileURL
                let target = resolvedContents.deletingLastPathComponent()
                extractedURL = target
                candidate = target
                continue
            }

            break
        }

        return (extractedURL, extractedIdentifier)
    }

    /// 路径匹配覆盖无 Bundle ID 的进程；身份匹配覆盖由其它位置启动的同一应用。
    nonisolated static func matches(
        appURL: URL,
        bundleIdentifier: String?,
        application: RunningApplication
    ) -> Bool {
        if let runningURL = application.bundleURL,
           normalizedPath(runningURL) == normalizedPath(appURL) {
            return true
        }

        // nil == nil 或空字符串相等不代表同一应用。
        guard let expectedID = nonemptyIdentifier(bundleIdentifier),
              let runningID = nonemptyIdentifier(application.bundleIdentifier) else {
            return false
        }
        return expectedID == runningID
    }

    nonisolated private static func normalizedPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    nonisolated private static func nonemptyIdentifier(_ identifier: String?) -> String? {
        guard let identifier = identifier?.trimmingCharacters(in: .whitespacesAndNewlines),
              !identifier.isEmpty else { return nil }
        return identifier
    }
}
