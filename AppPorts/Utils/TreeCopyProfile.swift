import Foundation

/// How much proof a tree copy has to produce before the caller may switch.
///
/// Data directories and application bundles have different failure costs, so
/// they must not share one contract:
///
/// - A data directory has no publisher-supplied manifest. Losing a committed
///   write is unrecoverable, so the copier has to build its own content proof
///   (per-file SHA-256) and keep it strict across every later verification.
/// - An application bundle is a replaceable product, and a signed bundle
///   already carries a cryptographic content manifest. `SecStaticCodeCheckValidity`
///   proves the destination matches the bytes the developer signed, which is a
///   stronger statement than "matches what we read five minutes ago" and costs
///   seconds instead of hours.
///
/// The profile only decides which proof is required. Structural safety —
/// no-follow traversal, anchored descriptors, mount-boundary refusal, atomic
/// rename switching, retained original until verified — is identical for both.
enum TreeCopyProfile: Sendable {
    /// Content-addressed proof: hash every file, compare timestamps strictly,
    /// and flush the device cache for every directory.
    case strictData
    /// Product-integrity proof: no per-file digest (the caller verifies the
    /// code signature), timestamps may drift while size and kind still match,
    /// and only the root gets a device-cache barrier.
    case appBundle

    /// Whether the manifest carries per-file SHA-256 digests.
    var recordsContentDigests: Bool {
        switch self {
        case .strictData: return true
        case .appBundle: return false
        }
    }

    /// Whether a timestamp change alone fails verification. Size, kind, mode,
    /// ownership, ACLs and extended attributes are compared in both profiles.
    var requiresStableTimestamps: Bool {
        switch self {
        case .strictData: return true
        case .appBundle: return false
        }
    }

    /// Whether a destination filesystem that cannot carry extended ACLs may
    /// still receive the copy. An application runs without them; a data
    /// directory's ownership/ACL contract cannot be proven without them.
    var toleratesUnsupportedACL: Bool {
        switch self {
        case .strictData: return false
        case .appBundle: return true
        }
    }

    /// Whether a destination filesystem that cannot share inodes may still
    /// receive the copy. Separate copies of the same bytes keep the
    /// application usable; a data directory would lose its hardlink topology.
    var toleratesUnsupportedHardlink: Bool {
        switch self {
        case .strictData: return false
        case .appBundle: return true
        }
    }

    /// Whether a destination filesystem without resource-fork support may
    /// still receive the copy. An application's data fork is what runs; the
    /// fork is metadata that some bundles use for icons and legacy resources.
    var toleratesUnsupportedResourceFork: Bool {
        switch self {
        case .strictData: return false
        case .appBundle: return true
        }
    }

    /// Whether a destination filesystem that ignores POSIX permission bits
    /// (ExFAT, FAT) may still receive the copy. The application still runs;
    /// its mode bits become the filesystem's fixed default.
    var toleratesUnsupportedPermissions: Bool {
        switch self {
        case .strictData: return false
        case .appBundle: return true
        }
    }

    var syncBarrier: TreeSyncBarrier {
        switch self {
        case .strictData: return .full
        case .appBundle: return .contentDurable
        }
    }
}

/// How deeply a copy flushes data to the storage device.
enum TreeSyncBarrier: Sendable {
    /// Flush every file and every directory, and ask the device to empty its
    /// own write cache at each directory. Survives power loss.
    case full
    /// Flush every file and directory, but issue the device-cache barrier only
    /// once at the root. Survives a process crash; a power cut during the copy
    /// leaves a destination the caller re-copies instead of switching to.
    case contentDurable
}
