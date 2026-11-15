import Foundation
import Darwin

enum AppManagementPermission {
    enum State: Equatable, Sendable {
        case granted
        case denied
        case unknown
    }

    static func state(query: () -> Int32? = SystemQuery.read) -> State {
        switch query() {
        case 0: return .granted
        case 1: return .denied
        default: return .unknown
        }
    }

    private enum SystemQuery {
        typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int32

        // 动态加载让不提供该私有接口的系统仍能启动，并返回无法确认。
        static let preflight: Preflight? = {
            guard let framework = dlopen("/System/Library/PrivateFrameworks/TCC.framework/TCC", RTLD_LAZY | RTLD_LOCAL) else {
                return nil
            }
            guard let symbol = dlsym(framework, "TCCAccessPreflight") else {
                dlclose(framework)
                return nil
            }
            return unsafeBitCast(symbol, to: Preflight.self)
        }()

        static func read() -> Int32? {
            // 不传其他进程的 token；由 TCC 检查当前运行应用，不请求授权。
            preflight?("kTCCServiceSystemPolicyAppBundles" as CFString, nil)
        }
    }
}
