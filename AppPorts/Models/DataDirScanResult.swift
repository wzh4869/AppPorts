import Foundation
import Darwin

struct DataDirReadIssue: Equatable, Sendable {
    let url: URL
    let isPermissionDenied: Bool
    let errorDescription: String
    let isExpectedMountPause: Bool

    var requiresAttention: Bool { !isExpectedMountPause }

    init(url: URL, error: Error, pausedMountDirectories: Set<URL> = [],
         isMountPoint: (URL) -> Bool = { DiskUtility.isMountPoint($0) }) {
        self.url = url.standardizedFileURL
        let errors = Self.errorChain(error)
        errorDescription = errors.map { "\($0.localizedDescription) (\($0.domain):\($0.code))" }.joined(separator: "\n")
        isPermissionDenied = errors.contains {
            ($0.domain == NSCocoaErrorDomain && $0.code == CocoaError.fileReadNoPermission.rawValue)
                || ($0.domain == NSPOSIXErrorDomain
                    && [Int(POSIXErrorCode.EACCES.rawValue), Int(POSIXErrorCode.EPERM.rawValue)].contains($0.code))
        }
        // Match only the recorded entry itself; a denied parent or sibling still
        // needs attention. Never follow a replacement symlink or hide a mounted error.
        var info = stat()
        isExpectedMountPause = (isPermissionDenied || error is ManualMountPauseError)
            && pausedMountDirectories.contains(self.url)
            && lstat(self.url.path, &info) == 0
            && info.st_mode & S_IFMT == S_IFDIR
            && MountPointLease.isProtectedMode(info.st_mode & 0o7777)
            && !isMountPoint(self.url)
    }

    static func pausedMountIssue(at url: URL, pausedMountDirectories: Set<URL>,
                                 isMountPoint: (URL) -> Bool) -> DataDirReadIssue? {
        guard pausedMountDirectories.contains(url.standardizedFileURL) else { return nil }
        let issue = DataDirReadIssue(url: url, error: ManualMountPauseError.paused,
                                    pausedMountDirectories: pausedMountDirectories, isMountPoint: isMountPoint)
        return issue.isExpectedMountPause ? issue : nil
    }

    static func isMissingFile(_ error: Error) -> Bool {
        errorChain(error).contains {
            ($0.domain == NSCocoaErrorDomain
                && [CocoaError.fileNoSuchFile.rawValue, CocoaError.fileReadNoSuchFile.rawValue].contains($0.code))
                || ($0.domain == NSPOSIXErrorDomain && $0.code == Int(POSIXErrorCode.ENOENT.rawValue))
        }
    }

    private static func errorChain(_ error: Error) -> [NSError] {
        var chain = [error as NSError]
        while chain.count < 8, let underlying = chain.last?.userInfo[NSUnderlyingErrorKey] as? NSError {
            chain.append(underlying)
        }
        return chain
    }
}

struct DataDirScanResult: Sendable {
    let items: [DataDirItem]
    let readIssues: [DataDirReadIssue]
    var identityIssue: AppIdentityIssue? = nil
    var pausedMountDirectories: Set<URL> = []
}

struct DirectorySizeResult: Sendable {
    var bytes: Int64 = 0
    var readIssues: [DataDirReadIssue] = []

    var isComplete: Bool { readIssues.isEmpty }

    var formattedSize: String {
        let formattedBytes = LocalizedByteCountFormatter.string(fromByteCount: bytes)
        if isComplete { return formattedBytes }
        if bytes == 0, !readIssues.isEmpty, readIssues.allSatisfy(\.isExpectedMountPause) { return "—" }
        return bytes > 0
            ? String(format: "至少 %@".localized, formattedBytes)
            : "无法读取".localized
    }
}
