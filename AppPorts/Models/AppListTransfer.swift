import Foundation

/// 已成功完成的迁移事实，用于立即更新列表；完整扫描随后补齐磁盘元数据。
/// 只能在文件操作成功后应用，不能用于预测尚未完成的操作。
enum AppListTransfer {
    case movedOut(AppItem, destination: URL, isMASExternal: Bool)
    case linkedIn(AppItem, localDestination: URL)
    case movedBack(AppItem, localDestination: URL, externalSourceRemains: Bool, retiredLocalURLs: [URL] = [])

    @discardableResult
    func apply(localApps: inout [AppItem], externalApps: inout [AppItem]) -> Set<String> {
        switch self {
        case let .movedOut(app, destination, isMASExternal):
            var portal = app
            portal.status = AppStatus.linked
            portal.isMASExternal = false
            portal.size = nil
            portal.sizeBytes = 0
            var external = Self.relocated(app, to: destination)
            external.status = AppStatus.linked
            external.isMASExternal = isMASExternal
            Self.upsert(portal, into: &localApps)
            Self.upsert(external, into: &externalApps)
            return [portal.id, external.id]

        case let .linkedIn(app, destination):
            var external = app
            external.status = AppStatus.linked
            var portal = Self.relocated(app, to: destination)
            portal.status = AppStatus.linked
            portal.isMASExternal = false
            portal.size = nil
            portal.sizeBytes = 0
            Self.upsert(portal, into: &localApps)
            Self.upsert(external, into: &externalApps)
            return [portal.id, external.id]

        case let .movedBack(app, destination, sourceRemains, retiredLocalURLs):
            let retiredIDs = Set(retiredLocalURLs.map { $0.standardizedFileURL.path })
            localApps.removeAll { retiredIDs.contains($0.id) }
            var local = Self.relocated(app, to: destination)
            local.status = AppStatus.local
            local.isMASExternal = false
            Self.upsert(local, into: &localApps)
            let sourceComponents = app.path.standardizedFileURL.pathComponents
            let childIDs = Set(externalApps.filter {
                $0.id != app.id && $0.path.standardizedFileURL.pathComponents.starts(with: sourceComponents)
            }.map(\.id))
            let changedIDs = retiredIDs.union(childIDs).union([local.id, app.id])
            // 旧版展开入口已被收回：无论外部清理是否成功，都由套件整行代表剩余内容。
            externalApps.removeAll { childIDs.contains($0.id) }
            if sourceRemains {
                // 还原允许“本地复制成功、外部清理失败”；不能把仍存在的副本藏起来。
                var external = app
                external.status = AppStatus.unlinked
                Self.upsert(external, into: &externalApps)
            } else {
                externalApps.removeAll { $0.id == app.id }
            }
            return changedIDs
        }
    }

    private static func upsert(_ app: AppItem, into apps: inout [AppItem]) {
        if let index = apps.firstIndex(where: { $0.id == app.id }) {
            apps[index] = app
        } else {
            apps.append(app)
        }
    }

    private static func relocated(_ app: AppItem, to destination: URL) -> AppItem {
        var result = app
        result.path = destination
        result.name = destination.lastPathComponent
        if let bundle = app.bundleURL {
            let sourceComponents = app.path.standardizedFileURL.pathComponents
            let bundleComponents = bundle.standardizedFileURL.pathComponents
            if bundleComponents.starts(with: sourceComponents) {
                result.bundleURL = bundleComponents.dropFirst(sourceComponents.count)
                    .reduce(destination) { $0.appendingPathComponent($1) }
            } else {
                result.bundleURL = nil
            }
        }
        return result
    }
}
