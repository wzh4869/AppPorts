import Foundation

/// A content and metadata manifest. Paths are relative to the selected root.
/// Source identities support checking a retained original after a rename.
struct TreeCopySnapshot: Codable, Equatable, Sendable {
    struct Identity: Codable, Equatable, Hashable, Sendable {
        let device: Int32
        let inode: UInt64
    }

    struct Timestamp: Codable, Equatable, Sendable {
        let seconds: Int64
        let nanoseconds: Int64
    }

    struct Entry: Codable, Equatable, Sendable {
        enum Kind: String, Codable, Sendable { case directory, file, symbolicLink }
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
        let acl: String?
        let size: Int64
        let digest: Data?
        let linkTarget: String?
        let hardlinkGroup: String?
    }

    let entries: [Entry]
    let excludedRootEntries: Set<String>
    var logicalBytes: Int64 { entries.filter { $0.kind == .file }.reduce(0) { $0 + $1.size } }
}
