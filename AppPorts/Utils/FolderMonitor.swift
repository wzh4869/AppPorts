//
//  FolderMonitor.swift
//  AppPorts
//
//  Created by shimoko.com on 2026/2/6.
//

import Foundation

// MARK: - 文件夹监控器

/// 文件夹内容变化监控工具
///
/// 使用 macOS 的 DispatchSource 机制监控指定目录的文件系统事件。
/// 当目录内容发生变化（文件创建、删除、修改）时触发回调。
///
/// ## 使用示例
/// ```swift
/// let monitor = FolderMonitor(url: URL(fileURLWithPath: "/Applications"))
/// monitor.startMonitoring {
///     print("应用目录发生变化")
///     // 重新扫描应用列表
/// }
/// ```
///
/// ## 注意事项
/// - 监控器在对象销毁时自动停止
/// - 回调在后台队列执行，更新 UI 需要切换到主线程
/// - 监控的是目录级别的变化，不包括子目录递归监控
///
/// - Note: 底层使用 `kqueue` 机制，性能优异且资源占用少
class FolderMonitor {
    // MARK: - 属性

    /// 被监控的目录 URL
    private let url: URL

    /// 状态互斥锁（防止并发启动/停止/析构竞争）
    private let stateLock = NSLock()

    /// GCD 文件系统监控源
    private var dispatchSource: DispatchSourceFileSystemObject?

    /// 监控事件的串行调度队列
    private let queue = DispatchQueue(label: "com.shimoko.AppPorts.folderMonitor")

    /// 文件夹变化时的回调闭包
    private var onChange: (() -> Void)?

    /// 防抖计时器
    private var debounceTimer: DispatchWorkItem?

    /// 测试钩子：观察每次描述符关闭结果 (fd, closeReturnCode)
    private let onDescriptorClosed: (@Sendable (Int32, Int32) -> Void)?
    
    // MARK: - 初始化
    
    /// 创建文件夹监控器
    /// - Parameter url: 要监控的目录 URL
    init(url: URL, onDescriptorClosed: (@Sendable (Int32, Int32) -> Void)? = nil) {
        self.url = url
        self.onDescriptorClosed = onDescriptorClosed
    }
    
    // MARK: - 监控 API
    
    /// 开始监控文件夹变化
    ///
    /// - Parameter onChange: 当文件夹内容变化时的回调
    ///
    /// - Note: 如果目录不存在，监控不会启动
    /// - Note: 回调在后台队列执行，需要在主线程更新 UI
    func startMonitoring(onChange: @escaping () -> Void) {
        stopMonitoring()
        AppLogger.shared.logContext("FolderMonitor 开始监控请求", details: [("path", url.path)], level: "TRACE")
        
        // 确保文件夹存在
        guard FileManager.default.fileExists(atPath: url.path) else {
            AppLogger.shared.logError(
                "FolderMonitor 启动失败：目录不存在",
                context: [("path", url.path)],
                relatedURLs: [("path", url)]
            )
            return
        }
        
        // 打开目录获取文件描述符（只读事件模式，禁止子进程继承描述符）
        let descriptor = open(url.path, O_EVTONLY | O_CLOEXEC)
        guard descriptor != -1 else {
            let error = NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errno))])
            AppLogger.shared.logError(
                "FolderMonitor 启动失败：无法打开目录",
                error: error,
                context: [("path", url.path)],
                relatedURLs: [("path", url)]
            )
            return
        }
        
        // 创建文件系统监控源（监听写操作事件）
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: queue)
        
        // 设置事件处理器（1 秒防抖，避免迁移期间扫描风暴）
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source, !source.isCancelled else { return }
            let work = DispatchWorkItem { [weak self, weak source] in
                let callback: (() -> Void)? = {
                    guard let self, let source, !source.isCancelled else { return nil }
                    self.stateLock.lock()
                    defer { self.stateLock.unlock() }
                    guard self.dispatchSource === source else { return nil }
                    return self.onChange
                }()
                guard let callback else { return }
                AppLogger.shared.logContext("FolderMonitor 检测到目录变化", details: [("path", self?.url.path)], level: "TRACE")
                callback()
            }
            self.stateLock.lock()
            let isCurrent = self.dispatchSource === source
            if isCurrent {
                self.debounceTimer?.cancel()
                self.debounceTimer = work
            }
            self.stateLock.unlock()
            if isCurrent {
                self.queue.asyncAfter(deadline: .now() + 1.0, execute: work)
            }
        }
        
        // 取消处理器直接关闭本次独立捕获的描述符，不依赖 self 存活，避免析构/切换泄漏外置盘 FD
        let closedObserver = self.onDescriptorClosed
        source.setCancelHandler {
            let rc = close(descriptor)
            closedObserver?(descriptor, rc)
        }
        
        stateLock.lock()
        self.onChange = onChange
        self.dispatchSource = source
        stateLock.unlock()

        // 启动监控
        source.resume()
        AppLogger.shared.logContext("FolderMonitor 已启动", details: [("path", url.path)], level: "TRACE")
    }
    
    /// 停止监控文件夹变化
    ///
    /// - Note: 会触发取消处理器，自动关闭文件描述符
    func stopMonitoring() {
        stateLock.lock()
        let timer = debounceTimer
        let source = dispatchSource
        debounceTimer = nil
        dispatchSource = nil
        onChange = nil
        stateLock.unlock()

        timer?.cancel()
        if let source {
            AppLogger.shared.logContext("FolderMonitor 停止监控", details: [("path", url.path)], level: "TRACE")
            source.cancel()
        }
    }
    
    // MARK: - 生命周期
    
    /// 析构函数，确保监控器停止
    deinit {
        stopMonitoring()
    }
}
