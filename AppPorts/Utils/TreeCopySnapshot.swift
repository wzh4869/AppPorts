import Foundation

/// A content and metadata manifest. Paths are relative to the selected root.
/// Source identities support checking a retained original after a rename.
struct TreeCopySnapshot: Codable, Equatable, Sendable {
    struct Ownership: Codable, Equatable, Sendable {
        let uid: UInt32
        let gid: UInt32
    }

    /// `noowners` reports an effective owner, not the stored UID/GID. Keep the
    /// source and destination contracts separate so a compatible destination
    /// never weakens verification of an ownership-aware retained original.
    struct OwnershipCompatibility: Codable, Equatable, Sendable {
        let sourceIgnoresOwnership: Bool
        var destinationIgnoresOwnership: Bool
        /// A source with projected ownership is copied as the current user.
        /// Store that choice instead of interpreting its observed UID as real.
        let projectedSourceOwner: Ownership?
    }

    struct Identity: Codable, Equatable, Hashable, Sendable {
        let device: Int32
        let inode: UInt64
    }

    struct Timestamp: Codable, Equatable, Sendable {
        let seconds: Int64
        let nanoseconds: Int64
    }

    struct ResourceFork: Codable, Equatable, Sendable {
        let size: Int64
        let digest: Data
    }

    struct Entry: Codable, Equatable, Sendable {
        enum Kind: String, Codable, Sendable { case directory, file, symbolicLink, namedPipe }
        let path: String
        let kind: Kind
        let identity: Identity
        let mode: UInt16
        let uid: UInt32
        let gid: UInt32
        let flags: UInt32
        let birthTime: Timestamp
        let modificationTime: Timestamp
        let extendedAttributes: [String: Data]
        /// Absent in older records, which stored the entire fork as an xattr.
        var resourceFork: ResourceFork? = nil
        let acl: String?
        let size: Int64
        let digest: Data?
        let linkTarget: String?
        let hardlinkGroup: String?

        var logicalBytes: Int64 { (kind == .file ? size : 0) + (resourceFork?.size ?? Int64(extendedAttributes[ResourceForkStream.attributeName]?.count ?? 0)) }

        private enum CodingKeys: String, CodingKey {
            case path, kind, identity, mode, uid, gid, flags, birthTime, modificationTime
            case extendedAttributes, resourceFork, acl, size, digest, linkTarget, hardlinkGroup
        }
    }

    /// Only legacy mount restores may preserve the formerly projected root owner.
    /// entries always retain the actual source ownership for unchanged/cleanup checks.
    var restoredRootOwnership: Ownership? = nil

    /// Absent in historical manifests: both sides require real ownership.
    /// Entries remain observations of the source, including projected IDs.
    var ownershipCompatibility: OwnershipCompatibility? = nil

    /// Source-only counts, keyed by the first selected path for each inode.
    /// A destination must reproduce the selected links and have no outside links.
    var externalFileHardlinks: [String: Int]? = nil

    func destinationEntry(_ entry: Entry) -> Entry {
        let owner = entry.path.isEmpty ? restoredRootOwnership ?? ownershipCompatibility?.projectedSourceOwner
                                      : ownershipCompatibility?.projectedSourceOwner
        guard let owner else { return entry }
        return Entry(path: entry.path, kind: entry.kind, identity: entry.identity, mode: entry.mode,
                     uid: owner.uid, gid: owner.gid, flags: entry.flags, birthTime: entry.birthTime,
                     modificationTime: entry.modificationTime, extendedAttributes: entry.extendedAttributes,
                     resourceFork: entry.resourceFork,
                     acl: entry.acl, size: entry.size, digest: entry.digest, linkTarget: entry.linkTarget,
                     hardlinkGroup: entry.hardlinkGroup)
    }

    let entries: [Entry]
    let excludedRootEntries: Set<String>
    var logicalBytes: Int64 { entries.reduce(0) { $0 + $1.logicalBytes } }
}

extension TreeCopySnapshot.Entry {
    /// Decode old raw-xattr records once, then retain only the fork's compact
    /// summary. A hybrid record must agree on both representations.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        path = try values.decode(String.self, forKey: .path)
        kind = try values.decode(Kind.self, forKey: .kind)
        identity = try values.decode(TreeCopySnapshot.Identity.self, forKey: .identity)
        mode = try values.decode(UInt16.self, forKey: .mode)
        uid = try values.decode(UInt32.self, forKey: .uid)
        gid = try values.decode(UInt32.self, forKey: .gid)
        flags = try values.decode(UInt32.self, forKey: .flags)
        birthTime = try values.decode(TreeCopySnapshot.Timestamp.self, forKey: .birthTime)
        modificationTime = try values.decode(TreeCopySnapshot.Timestamp.self, forKey: .modificationTime)
        var attributes = try values.decode([String: Data].self, forKey: .extendedAttributes)
        resourceFork = try values.decodeIfPresent(TreeCopySnapshot.ResourceFork.self, forKey: .resourceFork)
        if let rawFork = attributes.removeValue(forKey: ResourceForkStream.attributeName) {
            let legacy = TreeCopySnapshot.ResourceFork(size: Int64(rawFork.count), digest: try ResourceForkStream.digest(of: rawFork))
            if let resourceFork, resourceFork != legacy {
                throw DecodingError.dataCorruptedError(forKey: .resourceFork, in: values,
                    debugDescription: "Resource fork summary disagrees with the historical raw value")
            }
            resourceFork = legacy
        }
        if let resourceFork, resourceFork.size < 0 || resourceFork.digest.count != 32 {
            throw DecodingError.dataCorruptedError(forKey: .resourceFork, in: values,
                debugDescription: "Invalid resource fork summary")
        }
        extendedAttributes = attributes
        acl = try values.decodeIfPresent(String.self, forKey: .acl)
        size = try values.decode(Int64.self, forKey: .size)
        digest = try values.decodeIfPresent(Data.self, forKey: .digest)
        linkTarget = try values.decodeIfPresent(String.self, forKey: .linkTarget)
        hardlinkGroup = try values.decodeIfPresent(String.self, forKey: .hardlinkGroup)
    }
}
