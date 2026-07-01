//
//  CustomDirScanner.swift
//  AppPorts
//
//  Created by Codex on 2026/6/26.
//

import Foundation

actor CustomDirScanner {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func scan(configs: [CustomDirConfig], calculateSizes: Bool = false) -> [CustomDirPair] {
        configs.map { scan(config: $0, calculateSizes: calculateSizes) }
    }

    private func scan(config: CustomDirConfig, calculateSizes: Bool) -> CustomDirPair {
        let localURL = config.localURL
        let externalURL = config.externalDestinationURL
        let localState = inspectLocal(localURL: localURL, expectedExternalURL: externalURL)
        let externalExists = fileManager.fileExists(atPath: externalURL.path)
        let externalStatus: String

        if externalExists {
            externalStatus = localState.status == CustomDirStatus.linked
                ? CustomDirStatus.linked
                : CustomDirStatus.pendingRelink
        } else {
            externalStatus = CustomDirStatus.missing
        }

        var localEntry = CustomDirEntry(
            config: config,
            kind: .local,
            url: localURL,
            status: localState.status,
            linkedDestination: localState.linkedDestination
        )
        var externalEntry = CustomDirEntry(
            config: config,
            kind: .external,
            url: externalURL,
            status: externalStatus,
            linkedDestination: localState.status == CustomDirStatus.linked ? localURL : nil
        )

        if calculateSizes {
            applySize(to: &localEntry)
            applySize(to: &externalEntry)
        }

        return CustomDirPair(config: config, local: localEntry, external: externalEntry)
    }

    private func inspectLocal(localURL: URL, expectedExternalURL: URL) -> (status: String, linkedDestination: URL?) {
        if isSymbolicLink(at: localURL) {
            guard let destination = resolveSymlinkDestination(of: localURL) else {
                return (CustomDirStatus.orphanedLink, nil)
            }

            if fileManager.fileExists(atPath: destination.path) {
                let status = destination.standardizedFileURL == expectedExternalURL.standardizedFileURL
                    ? CustomDirStatus.linked
                    : CustomDirStatus.destinationConflict
                return (status, destination.standardizedFileURL)
            }

            return (CustomDirStatus.orphanedLink, destination.standardizedFileURL)
        }

        if fileManager.fileExists(atPath: localURL.path) {
            return (CustomDirStatus.local, nil)
        }

        return (CustomDirStatus.missing, nil)
    }

    private func applySize(to entry: inout CustomDirEntry) {
        guard fileManager.fileExists(atPath: entry.url.path) else { return }
        let sizeBytes = fastDirectorySize(at: entry.url, fileManager: fileManager)
        entry.sizeBytes = sizeBytes
        entry.size = LocalizedByteCountFormatter.string(fromByteCount: sizeBytes)
    }

    private func isSymbolicLink(at url: URL) -> Bool {
        guard let attrs = try? fileManager.attributesOfItem(atPath: url.path),
              let fileType = attrs[.type] as? FileAttributeType else {
            return false
        }
        return fileType == .typeSymbolicLink
    }

    private func resolveSymlinkDestination(of url: URL) -> URL? {
        guard let destinationPath = try? fileManager.destinationOfSymbolicLink(atPath: url.path) else {
            return nil
        }

        if destinationPath.hasPrefix("/") {
            return URL(fileURLWithPath: destinationPath).standardizedFileURL
        }

        return url
            .deletingLastPathComponent()
            .appendingPathComponent(destinationPath)
            .standardizedFileURL
    }
}
