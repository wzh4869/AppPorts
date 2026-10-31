import CryptoKit
import Darwin
import Foundation

/// One synchronous worker owns this scratch storage. No file contents or
/// verification result survive a digest call; only buffer capacity is reused.
final class FileContentHasher {
    typealias Read = (Int32, UnsafeMutableRawPointer, Int, off_t) -> Int
    private let read: Read
    private var buffer: [UInt8] = []
    private static let maximumBufferSize = 1_048_576

    init(read: @escaping Read = { pread($0, $1, $2, $3) }) {
        self.read = read
    }

    /// The caller must verify descriptor identity and stat stability around
    /// this complete read. A short EOF never establishes a valid digest.
    func digest(fd: Int32, byteCount: Int64, path: String,
                checkpoint: () throws -> Void,
                didRead: (Int64) -> Void) throws -> Data {
        guard byteCount >= 0 else { throw TreeCopyError.sourceChanged(path) }
        try checkpoint()
        let wantedCapacity = max(1, min(Self.maximumBufferSize, Int(clamping: byteCount)))
        if buffer.count < wantedCapacity {
            buffer = [UInt8](repeating: 0, count: wantedCapacity)
        }
        var hasher = SHA256()
        var offset: Int64 = 0
        try buffer.withUnsafeMutableBytes { bytes in
            while offset < byteCount {
                try checkpoint()
                let wanted = Int(min(Int64(bytes.count), byteCount - offset))
                let count = read(fd, bytes.baseAddress!, wanted, off_t(offset))
                if count < 0 {
                    if errno == EINTR { continue }
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                        userInfo: [NSFilePathErrorKey: path])
                }
                guard count > 0, count <= wanted else { throw TreeCopyError.sourceChanged(path) }
                hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: bytes.prefix(count)))
                offset += Int64(count)
                didRead(Int64(count))
            }
        }
        try checkpoint()
        return Data(hasher.finalize())
    }
}
