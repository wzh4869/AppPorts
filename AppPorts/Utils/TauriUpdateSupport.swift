import Foundation
import Darwin

/// Shared by the scanner and the standalone portal. A Tauri app can ship without the updater.
enum TauriUpdateSupport {
    enum Mode: Int { case sameVolumeTemporaryDirectory = 1, native }
    static let portalKey = "AppPortsTauriLaunchSupport"
    private static let cache: NSCache<NSString, NSNumber> = {
        let cache = NSCache<NSString, NSNumber>()
        cache.countLimit = 128
        return cache
    }()

    static func mode(at application: URL) -> Mode? {
        guard let info = NSDictionary(contentsOf: application.appendingPathComponent("Contents/Info.plist")) as? [String: Any] else { return nil }
        return mode(at: application, info: info)
    }

    static func mode(at application: URL, info: [String: Any]) -> Mode? {
        guard info["CSResourcesFileMapped"] as? Bool == true,
              info["LSRequiresCarbon"] as? Bool == true,
              info["CFBundleIdentifier"] as? String != "io.github.clash-verge-rev.clash-verge-rev",
              let name = info["CFBundleExecutable"] as? String, !name.isEmpty,
              name == (name as NSString).lastPathComponent, name != ".", name != ".." else { return nil }
        let executable = application.appendingPathComponent("Contents/MacOS").appendingPathComponent(name)
        let real = executable.resolvingSymlinksInPath()
        var file = stat()
        guard real.path.hasPrefix(application.resolvingSymlinksInPath().path + "/"),
              stat(real.path, &file) == 0, file.st_mode & S_IFMT == S_IFREG, file.st_mode & 0o111 != 0 else { return nil }
        let key = "\(file.st_dev):\(file.st_ino):\(file.st_size):\(file.st_ctimespec.tv_sec):\(file.st_ctimespec.tv_nsec)" as NSString
        if let saved = cache.object(forKey: key) { return Mode(rawValue: saved.intValue) }
        guard CFBundleCopyExecutableArchitecturesForURL(real as CFURL) != nil,
              let binary = try? Data(contentsOf: real, options: .alwaysMapped) else { return nil }
        let mode = pluginMode(in: binary)
        cache.setObject(NSNumber(value: mode?.rawValue ?? 0), forKey: key)
        return mode
    }

    private static let marker = Data("/tauri-plugin-updater-".utf8)
    private static let source = Data("/src/updater.rs".utf8)

    static func pluginMode(in binary: Data) -> Mode? {
        // Rust embeds dependency source locations in the release executable. Universal builds
        // can contain multiple copies. Ambiguous or unrecognized versions keep the default launch.
        var offset = 0
        var result: Mode?
        while let match = binary.range(of: marker, in: offset..<binary.count) {
            offset = match.upperBound
            let limit = min(offset + 48, binary.count)
            guard let slash = binary[offset..<limit].firstIndex(of: 47),
                  binary[slash...].starts(with: source) else { continue }
            let raw = binary[offset..<slash]
            guard raw.count <= 18, raw.allSatisfy({ $0 == 46 || (48...57).contains($0) }) else { return nil }
            let parts = String(decoding: raw, as: UTF8.self).split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 3, parts[0] == "2", let minor = Int(parts[1]), let patch = Int(parts[2]) else { return nil }
            let mode: Mode
            if (10...12).contains(minor) || (minor == 13 && patch < 2) {
                mode = .sameVolumeTemporaryDirectory
            } else if minor > 13 || (minor == 13 && patch >= 2) {
                mode = .native
            } else {
                return nil
            }
            if let result, result != mode { return nil }
            result = mode
            offset = slash + source.count
        }
        return result
    }

    static func requiresExternalTemporaryDirectory(at app: URL, info: [String: Any]) -> Bool {
        let app = app.resolvingSymlinksInPath()
        var target = stat()
        return stat(app.path, &target) == 0 && target.st_flags & UInt32(UF_IMMUTABLE) == 0
            && sharesSystemTemporaryVolume(app) == false
            && mode(at: app, info: info) == .sameVolumeTemporaryDirectory
    }

    static func sharesSystemTemporaryVolume(_ app: URL) -> Bool? {
        var target = stat(), temporary = stat()
        guard stat(app.path, &target) == 0, stat(FileManager.default.temporaryDirectory.path, &temporary) == 0 else { return nil }
        return target.st_dev == temporary.st_dev
    }

    /// Only AppPorts creates the directory, while it already has access for migration or maintenance.
    /// The independently signed launcher only checks the existing directory's metadata.
    static func temporaryDirectory(for app: URL, identifier id: String, create: Bool) -> URL? {
        guard !id.isEmpty, id.utf8.count <= 180,
              id.utf8.allSatisfy({ $0 == 45 || $0 == 46 || (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }) else { return nil }
        let app = app.resolvingSymlinksInPath()
        var target = stat()
        guard stat(app.path, &target) == 0, target.st_flags & UInt32(UF_IMMUTABLE) == 0 else { return nil }
        let directory = app.deletingLastPathComponent().appendingPathComponent(".appports-tmp-\(getuid())-\(id)", isDirectory: true)
        if create && mkdir(directory.path, 0o700) != 0 && errno != EEXIST { return nil }
        var status = stat()
        guard lstat(directory.path, &status) == 0, status.st_mode & S_IFMT == S_IFDIR,
              status.st_mode & 0o777 == 0o700, status.st_uid == getuid(), status.st_dev == target.st_dev else { return nil }
        return directory
    }

    static func preparePortal(for app: URL, info: [String: Any]) -> Bool {
        guard requiresExternalTemporaryDirectory(at: app, info: info), let id = info["CFBundleIdentifier"] as? String else { return false }
        return temporaryDirectory(for: app, identifier: id, create: true) != nil
    }
}
