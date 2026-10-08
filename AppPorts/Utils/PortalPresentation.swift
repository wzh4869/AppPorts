import Foundation

/// Produces only the display metadata of a macOS portal. Call on a private staging
/// bundle, then sign and install the bundle before registering it with the system.
enum PortalPresentation {
    static let formatVersion = 1
    static let versionKey = "AppPortsPortalFormatVersion"

    static func needsRefresh(local: [String: Any], external: [String: Any]) -> Bool {
        (local[versionKey] as? Int) != formatVersion ||
        (local["CFBundleVersion"] as? String) != (external["CFBundleVersion"] as? String) ||
        (local["CFBundleShortVersionString"] as? String) != (external["CFBundleShortVersionString"] as? String)
    }

    /// Source and destination are the respective Contents directories. Returns
    /// recoverable presentation warnings; an invalid plist or write failure throws.
    static func write(from externalContents: URL, to stagedContents: URL) throws -> [String] {
        let fm = FileManager.default
        let data = try Data(contentsOf: externalContents.appendingPathComponent("Info.plist"))
        guard var plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        let source = externalContents.appendingPathComponent("Resources").resolvingSymlinksInPath()
        let destination = stagedContents.appendingPathComponent("Resources")
        // Never write through a mirrored Resources directory into the real app.
        guard (try? stagedContents.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
              (try? destination.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        var warnings: [String] = []
        var copiedResources: Set<String> = []

        // Refresh starts with a copy of the old portal. Remove only previous
        // presentation resources so removed translations cannot override new names.
        let oldInfo = stagedContents.appendingPathComponent("Info.plist")
        if let oldData = try? Data(contentsOf: oldInfo),
           let old = try? PropertyListSerialization.propertyList(from: oldData, format: nil) as? [String: Any] {
            var obsolete = old["AppPortsPresentationResources"] as? [String] ?? []
            if let icon = old["CFBundleIconFile"] as? String {
                obsolete.append((icon as NSString).pathExtension.isEmpty ? icon + ".icns" : icon)
            }
            for name in Set(obsolete) where safeRelativeName(name) && name != "real_app_path.txt" {
                let target = destination.appendingPathComponent(name)
                guard isContained(target.deletingLastPathComponent().resolvingSymlinksInPath(), in: destination.resolvingSymlinksInPath()) else { continue }
                if (try? fm.attributesOfItem(atPath: target.path)) != nil { try fm.removeItem(at: target) }
            }
        }
        for locale in (try? fm.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil)) ?? [] where locale.pathExtension == "lproj" {
            if (try? locale.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                try fm.removeItem(at: locale)
            } else {
                for name in ["InfoPlist.strings", "InfoPlist.stringsdict"] {
                    let target = locale.appendingPathComponent(name)
                    if (try? fm.attributesOfItem(atPath: target.path)) != nil { try fm.removeItem(at: target) }
                }
            }
        }

        func copyResource(_ name: String, regularFileOnly: Bool = false) throws -> Bool {
            guard safeRelativeName(name), name != "real_app_path.txt" else { return false }
            let origin = source.appendingPathComponent(name)
            guard fm.fileExists(atPath: origin.path), isContained(origin.resolvingSymlinksInPath(), in: source) else { return false }
            if regularFileOnly, (try? origin.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) != true { return false }
            // Preflight the whole tree before replacing a resource. Symlinks are
            // materialized only when their resolved targets remain inside Resources.
            guard treeIsSafe(origin, root: source, ancestors: []) else { return false }
            let target = destination.appendingPathComponent(name)
            let parent = target.deletingLastPathComponent()
            guard isContained(parent.resolvingSymlinksInPath(), in: destination.resolvingSymlinksInPath()) else { return false }
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
            if (try? fm.attributesOfItem(atPath: target.path)) != nil { try fm.removeItem(at: target) }
            try copyRealTree(origin, to: target)
            copiedResources.insert(name)
            return true
        }

        if let icon = plist["CFBundleIconFile"] as? String {
            let file = (icon as NSString).pathExtension.isEmpty ? icon + ".icns" : icon
            if try !copyResource(file, regularFileOnly: true) {
                plist.removeValue(forKey: "CFBundleIconFile")
                warnings.append("Traditional icon resource is missing or unsafe: \(icon)")
            }
        }
        let hasModernReference = plist["CFBundleIconName"] != nil || plist["CFBundleIcons"] != nil || plist["CFBundleIcons~ipad"] != nil
        if hasModernReference {
            let copiedAssets = try copyResource("Assets.car", regularFileOnly: true)
            var copiedNamedResource = false
            if let name = plist["CFBundleIconName"] as? String, safeRelativeName(name) {
                let modernName = name.hasSuffix(".icon") ? name : name + ".icon"
                copiedNamedResource = try copyResource(modernName)
                // An .icns file is a traditional fallback, not evidence that the
                // asset-catalog name can resolve. Give it an explicit file key.
                if plist["CFBundleIconFile"] == nil {
                    let fallbackName = name.hasSuffix(".icns") ? name : name + ".icns"
                    if try copyResource(fallbackName, regularFileOnly: true) {
                        plist["CFBundleIconFile"] = fallbackName
                    }
                }
            }
            if !copiedAssets && !copiedNamedResource {
                for key in ["CFBundleIconName", "CFBundleIcons", "CFBundleIcons~ipad"] { plist.removeValue(forKey: key) }
                warnings.append("Modern icon resources unavailable; using the traditional icon when present")
            }
        }
        // Document icons otherwise inherit references to resources absent in a stub.
        if var documents = plist["CFBundleDocumentTypes"] as? [[String: Any]] {
            for index in documents.indices {
                if let icon = documents[index]["CFBundleTypeIconFile"] as? String {
                    let file = (icon as NSString).pathExtension.isEmpty ? icon + ".icns" : icon
                    if try !copyResource(file, regularFileOnly: true) { documents[index].removeValue(forKey: "CFBundleTypeIconFile") }
                }
            }
            plist["CFBundleDocumentTypes"] = documents
        }

        // Only localized display names belong in a launcher. Copying all localized
        // plist keys could override its executable or inject unrelated permissions.
        let displayKeys: Set<String> = ["CFBundleName", "CFBundleDisplayName", "CFBundleSpokenName"]
        let locales = (try? fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)) ?? []
        for locale in locales where locale.pathExtension == "lproj" {
            for file in ["InfoPlist.strings", "InfoPlist.stringsdict"] {
                let origin = locale.appendingPathComponent(file)
                guard isContained(origin.resolvingSymlinksInPath(), in: source),
                      let bytes = try? Data(contentsOf: origin),
                      let values = try? PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any] else { continue }
                let filtered = values.filter { displayKeys.contains($0.key) }
                guard !filtered.isEmpty else { continue }
                let targetDirectory = destination.appendingPathComponent(locale.lastPathComponent)
                // A hybrid portal can contain a mirrored locale; replace the link
                // itself, never a file reached through it.
                if let attributes = try? fm.attributesOfItem(atPath: targetDirectory.path),
                   attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                    try fm.removeItem(at: targetDirectory)
                }
                try fm.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
                let target = targetDirectory.appendingPathComponent(file)
                if (try? fm.attributesOfItem(atPath: target.path)) != nil { try fm.removeItem(at: target) }
                let output = try PropertyListSerialization.data(fromPropertyList: filtered, format: .xml, options: 0)
                try output.write(to: target, options: .atomic)
            }
        }
        plist["AppPortsTargetBundleIdentifier"] = plist["CFBundleIdentifier"]
        if let uuid = try? externalContents.deletingLastPathComponent().resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString {
            plist["AppPortsTargetVolumeUUID"] = uuid
        }
        plist["CFBundleExecutable"] = "launcher"
        plist["LSUIElement"] = true
        if let identifier = plist["CFBundleIdentifier"] as? String { plist["CFBundleIdentifier"] = identifier + ".appports.stub" }
        for key in ["SUFeedURL", "SUPublicDSAKeyFile", "SUPublicEDKey", "SUScheduledCheckInterval", "SUAllowsAutomaticUpdates", "ElectronDefaultApp", "electron"] {
            plist.removeValue(forKey: key)
        }
        plist[versionKey] = formatVersion
        plist["AppPortsPresentationResources"] = copiedResources.sorted()
        let output = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let target = stagedContents.appendingPathComponent("Info.plist")
        if (try? fm.attributesOfItem(atPath: target.path)) != nil { try fm.removeItem(at: target) }
        try output.write(to: target, options: .atomic)
        return warnings
    }

    private static func safeRelativeName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix("/") && !name.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == ".." || $0 == "." || $0.isEmpty })
    }

    private static func isContained(_ url: URL, in root: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let base = root.standardizedFileURL.path
        return path == base || path.hasPrefix(base + "/")
    }

    private static func treeIsSafe(_ url: URL, root: URL, ancestors: Set<String>) -> Bool {
        let resolved = url.resolvingSymlinksInPath()
        guard isContained(resolved, in: root), !ancestors.contains(resolved.path),
              let values = try? resolved.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey]) else { return false }
        if values.isRegularFile == true { return true }
        guard values.isDirectory == true,
              let children = try? FileManager.default.contentsOfDirectory(at: resolved, includingPropertiesForKeys: nil) else { return false }
        return children.allSatisfy { treeIsSafe($0, root: root, ancestors: ancestors.union([resolved.path])) }
    }

    private static func copyRealTree(_ source: URL, to destination: URL) throws {
        let resolved = source.resolvingSymlinksInPath()
        let values = try resolved.resourceValues(forKeys: [.isDirectoryKey])
        if values.isDirectory == true {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            for child in try FileManager.default.contentsOfDirectory(at: resolved, includingPropertiesForKeys: nil) {
                try copyRealTree(child, to: destination.appendingPathComponent(child.lastPathComponent))
            }
        } else {
            try Data(contentsOf: resolved).write(to: destination, options: .atomic)
        }
    }
}
