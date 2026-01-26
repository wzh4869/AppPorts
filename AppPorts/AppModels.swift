
import Foundation

// MARK: - 数据模型
struct AppItem: Identifiable, Equatable, Sendable {
    let id = UUID()
    var name: String
    var path: URL
    var status: String
    var isSystemApp: Bool = false
    var isRunning: Bool = false
    var size: String? = nil
    var sizeBytes: Int64 = 0 // For sorting

    static func == (lhs: AppItem, rhs: AppItem) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name && lhs.status == rhs.status && lhs.isRunning == rhs.isRunning && lhs.size == rhs.size && lhs.sizeBytes == rhs.sizeBytes
    }
}

enum AppMoverError: LocalizedError {
    case permissionDenied(Error)
    case generalError(Error)
    case appIsRunning
    
    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "权限不足。请前往“系统设置 > 隐私与安全性 > 完全磁盘访问权限”，允许 AppPorts 访问磁盘，然后重启应用。"
        case .generalError(let innerError):
            return innerError.localizedDescription
        case .appIsRunning:
            return "该应用正在运行。请先退出应用，然后再试。"
        }
    }
}
