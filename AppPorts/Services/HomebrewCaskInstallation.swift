import Foundation

/// Homebrew's installed receipt, staging link and configuration. Read only installed
/// metadata; evaluating tap Ruby or using the current online definition can select a different app.
struct HomebrewCaskInstallation {
    let directory: URL
    let source: URL
    let targetName: String
    let configURL: URL
    let config: [String: Any]
    let configData: Data
    let receiptData: Data

    var explicitDirectory: String? { (config["explicit"] as? [String: Any])?["appdir"] as? String }

    var installedTarget: URL? {
        guard let path = effectiveDirectory(explicit: explicitDirectory), path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path).appendingPathComponent(targetName)
    }

    func effectiveDirectory(explicit: String?) -> String? {
        explicit ?? (config["env"] as? [String: Any])?["appdir"] as? String
            ?? (config["default"] as? [String: Any])?["appdir"] as? String
    }

    static func component(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.contains("\0")
    }

    static func realDirectory(_ url: URL) -> Bool {
        url.standardizedFileURL.path == url.resolvingSymlinksInPath().path
            && (try? SignatureSnapshot.info(at: url).st_mode & S_IFMT) == S_IFDIR
    }

    static func regularData(_ url: URL) throws -> Data {
        guard realDirectory(url.deletingLastPathComponent()),
              try SignatureSnapshot.info(at: url).st_mode & S_IFMT == S_IFREG else { throw CocoaError(.fileReadInvalidFileName) }
        return try Data(contentsOf: url)
    }

    static func load(_ directory: URL) throws -> Self? {
        let metadata = directory.appendingPathComponent(".metadata")
        guard realDirectory(metadata) else { return nil }
        let receiptURL = metadata.appendingPathComponent("INSTALL_RECEIPT.json")
        guard try AppTransferStore.exists(receiptURL) else { return nil }
        let receiptData = try regularData(receiptURL)
        guard let receipt = try JSONSerialization.jsonObject(with: receiptData) as? [String: Any],
              let source = receipt["source"] as? [String: Any], let version = source["version"] as? String,
              component(version), receipt["uninstall_flight_blocks"] as? Bool != true,
              let artifacts = receipt["uninstall_artifacts"] as? [[String: Any]],
              let app = singleApp(artifacts) else { return nil }
        let stage = directory.appendingPathComponent(version)
        let versionMetadata = metadata.appendingPathComponent(version)
        guard realDirectory(stage), realDirectory(versionMetadata) else { return nil }
        let timestamps = try FileManager.default.contentsOfDirectory(at: versionMetadata, includingPropertiesForKeys: nil,
                                                                      options: [.skipsHiddenFiles])
        guard timestamps.count == 1, let timestamp = timestamps.first else { return nil }
        let definition = timestamp.appendingPathComponent("Casks").appendingPathComponent(directory.lastPathComponent + ".json")
        guard try AppTransferStore.exists(definition),
              let installed = try JSONSerialization.jsonObject(with: regularData(definition)) as? [String: Any],
              (installed["url_specs"] as? [String: Any])?["only_path"] == nil else { return nil }
        if let full = installed["artifacts"] {
            guard let list = full as? [[String: Any]], let definitionApp = singleApp(list),
                  definitionApp == app else { return nil }
        }
        let configURL = metadata.appendingPathComponent("config.json")
        let configData = try regularData(configURL)
        guard let config = try JSONSerialization.jsonObject(with: configData) as? [String: Any],
              let explicit = config["explicit"] as? [String: Any],
              explicit["appdir"] == nil || explicit["appdir"] is String else { return nil }
        return .init(directory: directory, source: stage.appendingPathComponent(app.source),
                     targetName: app.target, configURL: configURL, config: config, configData: configData, receiptData: receiptData)
    }

    private static func singleApp(_ artifacts: [[String: Any]]) -> (source: String, target: String)? {
        guard artifacts.allSatisfy({ $0.count == 1 && ["app", "uninstall", "zap"].contains($0.keys.first ?? "") }) else { return nil }
        let apps = artifacts.compactMap { $0["app"] as? [Any] }
        guard apps.count == 1, let args = apps.first, let source = args.first as? String,
              component(source), source.hasSuffix(".app") else { return nil }
        if args.count == 1 { return (source, source) }
        guard args.count == 2, let options = args[1] as? [String: String], let target = options["target"],
              options.count == 1, component(target), target.hasSuffix(".app") else { return nil }
        return (source, target)
    }

    /// A stopped registration may have published either half. Any third value belongs to another writer.
    func redirect(original: URL, routed: URL, originalExplicit: String?, restoring: Bool, previousRoute: URL? = nil) throws {
        let oldDir = original.deletingLastPathComponent().path
        let newDir = routed.deletingLastPathComponent().path
        let target = restoring ? original : routed
        let destinationSetting = restoring ? originalExplicit : newDir
        let routedDirectories = [newDir, previousRoute?.deletingLastPathComponent().path].compactMap { $0 }
        let knownLinks = [original.path, routed.path, previousRoute?.path].compactMap { $0 }
        let hasRoutedDirectory = explicitDirectory.map(routedDirectories.contains) ?? false
        guard targetName == original.lastPathComponent,
              effectiveDirectory(explicit: originalExplicit) == oldDir,
              explicitDirectory == originalExplicit || hasRoutedDirectory else { throw CocoaError(.fileWriteFileExists) }
        let fm = FileManager.default
        let current = try AppTransferStore.exists(source) ? fm.destinationOfSymbolicLink(atPath: source.path) : nil
        // A failed offline brew upgrade may remove its dangling staging link.
        guard current.map(knownLinks.contains) ?? hasRoutedDirectory
        else { throw CocoaError(.fileWriteFileExists) }
        guard current != target.path || explicitDirectory != destinationSetting else { return }
        let receipt = configURL.deletingLastPathComponent().appendingPathComponent("INSTALL_RECEIPT.json")
        guard try Self.regularData(receipt) == receiptData, try Self.regularData(configURL) == configData else {
            throw CocoaError(.fileWriteFileExists)
        }
        if current == nil {
            // An exclusive symlink creation preserves anything Homebrew just published.
            try fm.createSymbolicLink(atPath: source.path, withDestinationPath: target.path)
            try DurableFileIO.syncDirectory(at: source.deletingLastPathComponent())
        } else if current != target.path {
            let temp = source.deletingLastPathComponent().appendingPathComponent(".appports-link-" + UUID().uuidString)
            try fm.createSymbolicLink(atPath: temp.path, withDestinationPath: target.path)
            defer { _ = unlink(temp.path) }
            guard try fm.destinationOfSymbolicLink(atPath: source.path) == current else { throw CocoaError(.fileWriteFileExists) }
            guard rename(temp.path, source.path) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            try DurableFileIO.syncDirectory(at: source.deletingLastPathComponent())
        }
        if explicitDirectory != destinationSetting {
            var updated = config
            var options = config["explicit"] as? [String: Any] ?? [:]
            options["appdir"] = destinationSetting
            updated["explicit"] = options
            guard try Self.regularData(configURL) == configData,
                  try Self.regularData(receipt) == receiptData,
                  try fm.destinationOfSymbolicLink(atPath: source.path) == target.path else { throw CocoaError(.fileWriteFileExists) }
            try JSONSerialization.data(withJSONObject: updated, options: [.sortedKeys]).write(to: configURL, options: .atomic)
            try DurableFileIO.syncDirectory(at: configURL.deletingLastPathComponent())
        }
    }
}
