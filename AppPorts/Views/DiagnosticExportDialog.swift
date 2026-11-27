import AppKit
import UniformTypeIdentifiers

@MainActor
enum DiagnosticExportDialog {
    struct Options {
        let destinationURL: URL
        let includeAppInventory: Bool
    }

    static func run(defaultFileName: String) -> Options? {
        let layoutDirection: NSUserInterfaceLayoutDirection =
            LanguageManager.shared.layoutDirection == .rightToLeft ? .rightToLeft : .leftToRight
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 260),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "导出诊断包".localized
        panel.isReleasedWhenClosed = false
        let optionsView = DiagnosticExportOptionsView(defaultFileName: defaultFileName)
        optionsView.userInterfaceLayoutDirection = layoutDirection
        panel.contentView = optionsView
        panel.delegate = optionsView
        panel.defaultButtonCell = optionsView.exportButton.cell as? NSButtonCell
        optionsView.layoutSubtreeIfNeeded()
        panel.setContentSize(NSSize(width: 480, height: optionsView.fittingSize.height))
        panel.center()
        defer { panel.orderOut(nil) }
        guard NSApp.runModal(for: panel) == .OK,
              let destinationURL = optionsView.destinationURL else { return nil }
        return Options(destinationURL: destinationURL, includeAppInventory: optionsView.includeAppInventory)
    }
}

@MainActor
private final class DiagnosticExportOptionsView: NSView, NSWindowDelegate {
    private(set) var destinationURL: URL?
    private let pathField = NSTextField(labelWithString: "请选择保存路径".localized)
    private let inventoryCheckbox = NSButton(frame: .zero)
    let exportButton = NSButton(title: "导出".localized, target: nil, action: nil)
    private let defaultFileName: String

    private(set) var includeAppInventory = false

    init(defaultFileName: String) {
        self.defaultFileName = defaultFileName
        super.init(frame: NSRect(x: 0, y: 0, width: 480, height: 260))

        let explanation = NSTextField(wrappingLabelWithString: "诊断包包含运行日志、系统信息和最近操作记录，用于排查问题。默认不包含本机应用列表，并会隐藏用户名和外置盘名称。".localized)
        explanation.font = .systemFont(ofSize: NSFont.systemFontSize)
        explanation.preferredMaxLayoutWidth = 440
        let saveLabel = NSTextField(labelWithString: "保存路径".localized)
        saveLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        pathField.maximumNumberOfLines = 1
        pathField.lineBreakMode = .byTruncatingMiddle
        pathField.isEditable = false
        pathField.isSelectable = false
        pathField.focusRingType = .none
        pathField.textColor = .secondaryLabelColor
        pathField.isBezeled = false
        pathField.isBordered = false
        pathField.drawsBackground = false
        pathField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pathField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        pathField.setAccessibilityLabel("保存路径".localized)
        let underline = NSBox()
        underline.boxType = .separator
        let chooseButton = NSButton(title: "选择路径…".localized, target: self, action: #selector(chooseDestination))
        chooseButton.bezelStyle = .rounded
        chooseButton.setContentHuggingPriority(.required, for: .horizontal)
        chooseButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        inventoryCheckbox.setButtonType(.switch)
        inventoryCheckbox.title = "允许包含本机应用列表".localized
        inventoryCheckbox.font = .systemFont(ofSize: NSFont.systemFontSize)
        inventoryCheckbox.alignment = .natural
        inventoryCheckbox.imagePosition = .imageLeading
        inventoryCheckbox.target = self
        inventoryCheckbox.action = #selector(toggleAppInventory(_:))
        inventoryCheckbox.isTransparent = false
        inventoryCheckbox.isHidden = false
        inventoryCheckbox.isEnabled = true
        inventoryCheckbox.allowsMixedState = false
        inventoryCheckbox.state = .off
        inventoryCheckbox.setContentCompressionResistancePriority(.required, for: .vertical)
        let cancelButton = NSButton(title: "取消".localized, target: self, action: #selector(cancelExport))
        cancelButton.keyEquivalent = "\u{1b}"
        exportButton.target = self
        exportButton.action = #selector(confirmExport)
        exportButton.keyEquivalent = "\r"
        if let defaultDestination = Self.defaultDestinationURL(fileName: defaultFileName) {
            destinationURL = defaultDestination
            pathField.stringValue = defaultDestination.path
            pathField.textColor = .labelColor
            pathField.toolTip = defaultDestination.path
            exportButton.isEnabled = true
        } else {
            exportButton.isEnabled = false
        }
        for button in [cancelButton, exportButton] { button.bezelStyle = .rounded }
        let controls: [NSView] = [explanation, saveLabel, pathField, underline, chooseButton, inventoryCheckbox, cancelButton, exportButton]
        for view in controls {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 480),
            explanation.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            explanation.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            explanation.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            saveLabel.leadingAnchor.constraint(equalTo: explanation.leadingAnchor),
            saveLabel.centerYAnchor.constraint(equalTo: chooseButton.centerYAnchor),
            pathField.leadingAnchor.constraint(equalTo: saveLabel.trailingAnchor, constant: 12),
            pathField.trailingAnchor.constraint(equalTo: chooseButton.leadingAnchor, constant: -12),
            pathField.centerYAnchor.constraint(equalTo: chooseButton.centerYAnchor),
            pathField.widthAnchor.constraint(greaterThanOrEqualToConstant: 100),
            underline.leadingAnchor.constraint(equalTo: pathField.leadingAnchor),
            underline.trailingAnchor.constraint(equalTo: pathField.trailingAnchor),
            underline.topAnchor.constraint(equalTo: pathField.bottomAnchor, constant: 2),
            underline.heightAnchor.constraint(equalToConstant: 1),
            chooseButton.trailingAnchor.constraint(equalTo: explanation.trailingAnchor),
            chooseButton.topAnchor.constraint(equalTo: explanation.bottomAnchor, constant: 16),
            inventoryCheckbox.leadingAnchor.constraint(equalTo: explanation.leadingAnchor),
            inventoryCheckbox.trailingAnchor.constraint(equalTo: explanation.trailingAnchor),
            inventoryCheckbox.heightAnchor.constraint(equalToConstant: 24),
            inventoryCheckbox.topAnchor.constraint(equalTo: chooseButton.bottomAnchor, constant: 16),
            exportButton.topAnchor.constraint(equalTo: inventoryCheckbox.bottomAnchor, constant: 20),
            exportButton.trailingAnchor.constraint(equalTo: explanation.trailingAnchor),
            exportButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -20),
            exportButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 80),
            cancelButton.trailingAnchor.constraint(equalTo: exportButton.leadingAnchor, constant: -8),
            cancelButton.centerYAnchor.constraint(equalTo: exportButton.centerYAnchor),
            cancelButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 80)
        ])
    }

    required init?(coder: NSCoder) { return nil }

    @objc private func toggleAppInventory(_ sender: NSButton) {
        includeAppInventory = sender.state == .on
    }

    @objc private func chooseDestination() {
        let panel = NSSavePanel()
        panel.title = "选择诊断包保存路径".localized
        panel.prompt = "选择".localized
        panel.allowedContentTypes = [UTType.zip]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = destinationURL?.lastPathComponent ?? defaultFileName
        panel.directoryURL = destinationURL?.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        destinationURL = url
        pathField.stringValue = url.path
        pathField.textColor = .labelColor
        pathField.toolTip = url.path
        exportButton.isEnabled = true
    }

    @objc private func confirmExport() {
        guard destinationURL != nil else { return }
        NSApp.stopModal(withCode: .OK)
    }

    @objc private func cancelExport() { NSApp.stopModal(withCode: .cancel) }

    private static func defaultDestinationURL(fileName: String) -> URL? {
        let fileManager = FileManager.default
        let candidates = [
            fileManager.urls(for: .desktopDirectory, in: .userDomainMask).first,
            fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first,
            fileManager.homeDirectoryForCurrentUser
        ].compactMap { $0 }
        for directory in candidates where fileManager.isWritableFile(atPath: directory.path) {
            return directory.appendingPathComponent(fileName)
        }
        return nil
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        NSApp.stopModal(withCode: .cancel)
        return true
    }
}
