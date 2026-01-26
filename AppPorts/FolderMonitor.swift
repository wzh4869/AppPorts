
import Foundation

class FolderMonitor {
    // MARK: - Properties
    
    private let url: URL
    private var fileDescriptor: CInt = -1
    private var dispatchSource: DispatchSourceFileSystemObject?
    private let queue = DispatchQueue(label: "com.shimoko.AppPorts.folderMonitor", attributes: .concurrent)
    private var onChange: (() -> Void)?
    
    // MARK: - Initializer
    
    init(url: URL) {
        self.url = url
    }
    
    // MARK: - Monitoring API
    
    func startMonitoring(onChange: @escaping () -> Void) {
        self.onChange = onChange
        
        // Ensure folder exists (though we usually monitor existing folders)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        
        // Open the directory
        fileDescriptor = open(url.path, O_EVTONLY)
        guard fileDescriptor != -1 else { return }
        
        // Create the dispatch source
        dispatchSource = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fileDescriptor, eventMask: .write, queue: queue)
        
        dispatchSource?.setEventHandler { [weak self] in
            self?.onChange?()
        }
        
        dispatchSource?.setCancelHandler { [weak self] in
            guard let self = self else { return }
            close(self.fileDescriptor)
            self.fileDescriptor = -1
            self.dispatchSource = nil
        }
        
        // Start monitoring
        dispatchSource?.resume()
    }
    
    func stopMonitoring() {
        dispatchSource?.cancel()
        // Cancellation handler closes the descriptor
    }
    
    deinit {
        stopMonitoring()
    }
}
