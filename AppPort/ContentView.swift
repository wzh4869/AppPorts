import SwiftUI

// --- AppItem 和 AppMoverError 结构体保持不变 ---
struct AppItem: Identifiable {
    let id = UUID()
    var name: String
    var path: URL
    var status: String
}

enum AppMoverError: Error {
    case permissionDenied(Error)
    case generalError(Error)
}
// ----------------------------------------------


struct ContentView: View {

    @State private var localApps: [AppItem] = []
    @State private var externalApps: [AppItem] = []
    
    private let localAppsURL = URL(fileURLWithPath: "/Applications")
    @State private var externalDriveURL: URL?

    @State private var selectedLocalApp: UUID?
    @State private var selectedExternalApp: UUID?
    
    @State private var showAlert = false
    @State private var alertTitle = ""
    @State private var alertMessage = ""

    private let fileManager = FileManager.default

    var body: some View {
        VStack(spacing: 15) {
            
            // --- 上半部分 GroupBox (不变) ---
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    List(localApps, selection: $selectedLocalApp) { app in
                        HStack {
                            Text(app.name)
                            Spacer()
                            Text(app.status)
                                .font(.caption)
                                .foregroundColor(app.status == "已链接" ? .blue : .gray)
                        }
                        .tag(app.id)
                    }
                    .frame(minHeight: 200)
                    
                    HStack {
                        Button(action: scanLocalApps) {
                            Image(systemName: "arrow.clockwise")
                        }
                        .help("刷新本地列表")
                        
                        Spacer()
                        
                        Button("迁移到外部 ➔") {
                            performMoveOut()
                        }
                        .disabled(selectedLocalApp == nil || externalDriveURL == nil)
                    }
                }
                .padding(5)
                
            } label: {
                HStack {
                    Image(systemName: "laptopcomputer")
                    Text("Mac 本地应用 (/Applications)")
                }
                .font(.headline)
            }
            .padding(.horizontal)
            .padding(.top)
            
            // --- 下半部分 GroupBox (不变) ---
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Image(systemName: "folder")
                        Text(externalDriveURL?.path ?? "(未选择路径)")
                            .font(.callout)
                            .foregroundColor(.gray)
                        Spacer()
                        Button("选择文件夹...") {
                            openPanelForExternalDrive()
                        }
                    }
                    
                    List(externalApps, selection: $selectedExternalApp) { app in
                        HStack {
                            Text(app.name)
                            Spacer()
                            Text(app.status)
                                .font(.caption)
                                .foregroundColor(.gray)
                        }
                        .tag(app.id)
                    }
                    .frame(minHeight: 200)
                    
                    HStack {
                        Button(action: scanExternalApps) {
                            Image(systemName: "arrow.clockwise")
                        }
                        .help("刷新外部列表")
                        
                        Spacer()
                        
                        Button("链接回本地 ↩") {
                            performLinkIn()
                        }
                        .disabled(selectedExternalApp == nil)
                    }
                }
                .padding(5)
                
            } label: {
                HStack {
                    Image(systemName: "externaldrive.fill")
                    Text("外部应用文件夹")
                }
                .font(.headline)
            }
            .padding(.horizontal)
            .padding(.bottom)

        }
        .frame(width: 550, height: 650)
        
        // 【已修复】
        // 使用新的 onAppear 语法
        .onAppear {
            scanLocalApps()
        }
        // 【已修复】
        // 使用新的 onChange 语法
        .onChange(of: externalDriveURL) {
            scanExternalApps()
        }
        .alert(alertTitle, isPresented: $showAlert, actions: {
            Button("好的", role: .cancel) { }
        }, message: {
            Text(alertMessage)
        })
    }
    
    //
    // =======================================================
    //   核心功能函数 (这部分没有改动)
    // =======================================================
    //
    
    func scanLocalApps() {
        self.localApps = scanApps(at: localAppsURL, baseStatus: "本地")
    }
    
    func scanExternalApps() {
        guard let dir = externalDriveURL else {
            self.externalApps = []
            return
        }
        self.externalApps = scanApps(at: dir, baseStatus: "外部")
    }
    
    func scanApps(at dir: URL, baseStatus: String) -> [AppItem] {
        var foundApps: [AppItem] = []
        do {
            let items = try fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isSymbolicLinkKey], options: .skipsHiddenFiles)
            for itemURL in items {
                if itemURL.pathExtension == "app" {
                    var appStatus = baseStatus
                    let resourceValues = try itemURL.resourceValues(forKeys: [.isSymbolicLinkKey])
                    if resourceValues.isSymbolicLink == true {
                        appStatus = "已链接"
                    }
                    foundApps.append(AppItem(name: itemURL.lastPathComponent, path: itemURL, status: appStatus))
                }
            }
        } catch {
            if let nsError = error as NSError?, nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoPermissionError {
                showError(title: "扫描失败", message: "无法读取 /Applications 目录。\n\n请前往 '系统设置 > 隐私与安全性 > 完全磁盘访问'，将本应用添加进去并重启。")
            } else {
                showError(title: "扫描失败", message: error.localizedDescription)
            }
        }
        return foundApps.sorted { $0.name < $1.name }
    }
    
    func openPanelForExternalDrive() {
        let openPanel = NSOpenPanel()
        openPanel.prompt = "选择文件夹"
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = true
        openPanel.canChooseFiles = false
        if openPanel.runModal() == .OK {
            self.externalDriveURL = openPanel.urls.first
        }
    }
    
    func showError(title: String, message: String) {
        print("错误: \(title) - \(message)")
        self.alertTitle = title
        self.alertMessage = message
        self.showAlert = true
    }

    func moveAndLink(appToMove: AppItem, destinationURL: URL) throws {
        do {
            try fileManager.moveItem(at: appToMove.path, to: destinationURL)
            try fileManager.createSymbolicLink(at: appToMove.path, withDestinationURL: destinationURL)
        } catch {
            if let nsError = error as NSError?, nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileWriteNoPermissionError {
                throw AppMoverError.permissionDenied(error)
            } else {
                throw AppMoverError.generalError(error)
            }
        }
    }

    func linkApp(appToLink: AppItem, destinationURL: URL) throws {
        if fileManager.fileExists(atPath: destinationURL.path) {
            throw AppMoverError.generalError(NSError(domain: "", code: 0, userInfo: [NSLocalizedDescriptionKey: "本地 /Applications 文件夹已存在同名文件，请先移除。"]))
        }
        do {
            try fileManager.createSymbolicLink(at: destinationURL, withDestinationURL: appToLink.path)
        } catch {
            if let nsError = error as NSError?, nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileWriteNoPermissionError {
                throw AppMoverError.permissionDenied(error)
            } else {
                throw AppMoverError.generalError(error)
            }
        }
    }
    
    func performMoveOut() {
        guard let selectedId = selectedLocalApp,
              let appToMove = localApps.first(where: { $0.id == selectedId })
        else { return }
        
        guard let destDir = externalDriveURL else {
            showError(title: "操作失败", message: "尚未选择外部目标文件夹")
            return
        }
        
        let destinationURL = destDir.appendingPathComponent(appToMove.name)
        
        do {
            try moveAndLink(appToMove: appToMove, destinationURL: destinationURL)
            print("操作成功！")
            scanLocalApps()
            scanExternalApps()
        } catch AppMoverError.permissionDenied {
            showError(title: "权限不足", message: "应用没有权限修改 /Applications 文件夹。\n\n请前往 '系统设置 > 隐私与安全性 > 完全磁盘访问'，将本应用添加进去并重启。")
        } catch {
            showError(title: "迁移失败", message: error.localizedDescription)
        }
    }
    
    func performLinkIn() {
        guard let selectedId = selectedExternalApp,
              let appToLink = externalApps.first(where: { $0.id == selectedId })
        else { return }
        
        let destinationURL = localAppsURL.appendingPathComponent(appToLink.name)
        
        do {
            try linkApp(appToLink: appToLink, destinationURL: destinationURL)
            print("链接成功！")
            scanLocalApps()
        } catch AppMoverError.permissionDenied {
            showError(title: "权限不足", message: "应用没有权限在 /Applications 文件夹中创建链接。\n\n请前往 '系统设置 > 隐私与安全性 > 完全磁盘访问'，将本应用添加进去并重启。")
        } catch {
            showError(title: "链接失败", message: error.localizedDescription)
        }
    }
}
