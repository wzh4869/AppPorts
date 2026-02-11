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
    
    /// 目录的文件描述符
    private var fileDescriptor: CInt = -1
    
    /// GCD 文件系统监控源
    private var dispatchSource: DispatchSourceFileSystemObject?
    
    /// 监控事件的调度队列（并发队列）
    private let queue = DispatchQueue(label: "com.shimoko.AppPorts.folderMonitor", attributes: .concurrent)
    
    /// 文件夹变化时的回调闭包
    private var onChange: (() -> Void)?
    
    // MARK: - 初始化
    
    /// 创建文件夹监控器
    /// - Parameter url: 要监控的目录 URL
    init(url: URL) {
        self.url = url
    }
    
    // MARK: - 监控 API
    
    /// 开始监控文件夹变化
    ///
    /// - Parameter onChange: 当文件夹内容变化时的回调
    ///
    /// - Note: 如果目录不存在，监控不会启动
    /// - Note: 回调在后台队列执行，需要在主线程更新 UI
    func startMonitoring(onChange: @escaping () -> Void) {
        self.onChange = onChange
        
        // 确保文件夹存在
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        
        // 打开目录获取文件描述符（只读模式）
        fileDescriptor = open(url.path, O_EVTONLY)
        guard fileDescriptor != -1 else { return }
        
        // 创建文件系统监控源（监听写操作事件）
        dispatchSource = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fileDescriptor, eventMask: .write, queue: queue)
        
        // 设置事件处理器
        dispatchSource?.setEventHandler { [weak self] in
            self?.onChange?()
        }
        
        // 设置取消处理器（清理资源）
        dispatchSource?.setCancelHandler { [weak self] in
            guard let self = self else { return }
            close(self.fileDescriptor)
            self.fileDescriptor = -1
            self.dispatchSource = nil
        }
        
        // 启动监控
        dispatchSource?.resume()
    }
    
    /// 停止监控文件夹变化
    ///
    /// - Note: 会触发取消处理器，自动关闭文件描述符
    func stopMonitoring() {
        dispatchSource?.cancel()
        // 取消处理器会关闭文件描述符
    }
    
    // MARK: - 生命周期
    
    /// 析构函数，确保监控器停止
    deinit {
        stopMonitoring()
    }
}
