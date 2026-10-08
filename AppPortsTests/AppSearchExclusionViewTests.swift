import AppKit
import SwiftUI
import XCTest
@testable import AppPorts

final class AppSearchExclusionViewTests: XCTestCase {
    func testWarningsSkippedAppsAndFailuresRemainIncomplete() {
        let report = AppSearchExclusionReport(entries: [
            entry("A", .completed, "Different language"),
            entry("B", .unsupported, "已成功"),
            entry("C", .failed, "成功"),
            entry("D", .dockWarning, "Storage excluded; Dock still needs attention"),
            entry("E", .pending, "Not processed yet")
        ])
        XCTAssertEqual(report.completed.map(\.name), ["A.app"])
        XCTAssertEqual(report.incomplete.map(\.name), ["B.app", "C.app", "D.app", "E.app"])
        XCTAssertEqual(report.incomplete[2].message, "Storage excluded; Dock still needs attention")
    }

    @MainActor
    func testOpeningAndReopeningLoadsWithoutStartingAnOperation() async throws {
        var loads = 0
        var operations = 0
        for attempt in 1...2 {
            let loaded = expectation(description: "Opening \(attempt) reads current state")
            let report = AppSearchExclusionReport(entries: [entry("Already excluded", .completed, ""),
                entry("Waiting", .pending, "点击「自动处理」开始。".localized)])
            let view = AppSearchExclusionView(load: {
                loads += 1
                loaded.fulfill()
                return report
            }, process: {
                operations += 1
                XCTFail("Opening the sheet must never start an application operation")
                return .init()
            })
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 640),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: view)
            window.contentView = host
            window.orderFront(nil)
            defer { window.close() }
            await fulfillment(of: [loaded], timeout: 5)
            // Give SwiftUI a turn to publish the loaded report, then capture the actual live view.
            try await Task.sleep(nanoseconds: 200_000_000)
            host.layoutSubtreeIfNeeded()
            if let path = ProcessInfo.processInfo.environment["APPPORTS_RENDER_UI_OUTPUT"] {
                let output = URL(fileURLWithPath: path)
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: output.appendingPathComponent("board-auto-open-\(attempt).png"))
            }
        }
        XCTAssertEqual(loads, 2)
        XCTAssertEqual(operations, 0)
    }

    func testSameNamedAppsKeepSeparateIdentitiesAndDisplayNames() {
        let first = entry("Example", .completed, "")
        let second = AppSearchExclusionReport.Entry(id: "/another/Example.app", name: "Example.app",
            iconURL: Bundle.main.bundleURL, outcome: .failed, message: "Conflict")
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(first.displayName, "Example")
        XCTAssertEqual(second.displayName, "Example")
        XCTAssertEqual(entry("A.app tools", .failed, "").displayName, "A.app tools")
    }

    @MainActor
    func testRenderExclusionBoardStatesInChineseAndEnglish() async throws {
        guard let path = ProcessInfo.processInfo.environment["APPPORTS_RENDER_UI_OUTPUT"] else {
            throw XCTSkip("Set APPPORTS_RENDER_UI_OUTPUT for visual review")
        }
        let output = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let oldLanguage = LanguageManager.shared.language
        defer { LanguageManager.shared.language = oldLanguage }
        for language in ["zh-Hans", "en"] {
            LanguageManager.shared.language = language
            let success = ["Antigravity IDE", "Bitwarden", "Claude", "CrossOver Preview", "Cyberpunk2077", "Long Application Name — Professional Edition 2026"]
                .map { entry($0, .completed, "应用存储位置已排除索引。".localized) }
            let unfinished = [
                entry("Adobe Premiere Pro 2026", .unsupported, "套件目录可能包含文档，暂不自动排除。".localized),
                entry("BaiduNetdisk", .unsupported, "App Store 和 iOS 应用保留原安装路径，暂不自动排除。".localized),
                entry("Long Application Name — Professional Edition 2026", .failed, "应用存储路径存在冲突或已改变，未执行操作。".localized),
                entry("Example", .dockWarning, "应用存储位置已排除索引，Dock 快捷方式同步失败。".localized),
                entry("Waiting", .pending, "点击「自动处理」开始。".localized)
            ]
            let scenarios: [(String, AppSearchExclusionReport?, Bool)] = [
                ("loading", nil, false),
                ("processing", .init(entries: success + unfinished), true),
                ("mixed", .init(entries: success + unfinished), false),
                ("completed", .init(entries: Array(success.prefix(2))), false),
                ("incomplete", .init(entries: unfinished), false),
                ("empty", .init(), false),
                ("blocked", .init(operationError: "正在执行其他应用操作，请稍后重试。".localized), false)
            ]
            for (scenario, report, processing) in scenarios {
                for dark in [false, true] {
                    let view = AppSearchExclusionPanel(report: report, isProcessing: processing, isLoading: scenario == "loading",
                        close: { XCTFail("Rendering must not close the sheet") },
                        process: { XCTFail("Rendering must not relocate applications") })
                        .environment(\.locale, Locale(identifier: language))
                        .preferredColorScheme(dark ? .dark : .light)
                        .background(dark ? Color(nsColor: .windowBackgroundColor) : Color.white)
                    let host = NSHostingView(rootView: view)
                    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 640),
                                          styleMask: [.borderless], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    window.contentView = host
                    host.frame = NSRect(x: 0, y: 0, width: 820, height: 640)
                    host.layoutSubtreeIfNeeded()
                    try await Task.sleep(nanoseconds: 200_000_000)
                    host.layoutSubtreeIfNeeded()
                    host.displayIfNeeded()
                    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    try png.write(to: output.appendingPathComponent("board-\(scenario)-\(language)-\(dark ? "dark" : "light").png"))
                    window.close()
                }
            }
        }
    }

    private func entry(_ name: String, _ outcome: AppSearchExclusionReport.Outcome, _ message: String) -> AppSearchExclusionReport.Entry {
        .init(id: "/fixture/\(outcome)/\(name).app", name: name + ".app", iconURL: Bundle.main.bundleURL,
              outcome: outcome, message: message)
    }
}
