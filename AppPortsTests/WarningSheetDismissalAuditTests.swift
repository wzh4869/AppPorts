import XCTest
@testable import AppPorts

/// 警示弹窗「关得掉」的审计。
///
/// `.sheet(item:)` 不会因为点了弹窗内部的按钮就自动关闭 —— item 必须显式置回 nil。
/// 漏掉这一步的症状是「按钮点了没反应」：动作其实执行了，但弹窗留在屏幕上，
/// 再点一次又会撞上 `AppOperationState` 的忙碌判断被静默忽略，整个弹窗看上去是死的。
///
/// 修法是把「关闭」收进 `WarningSheet` 自己（`onResolve`）并用 `.warningSheet(_:)` 展示。
/// 这个测试守住那条规则，防止以后有人再手写 `.sheet { WarningSheet(...) }`。
final class WarningSheetDismissalAuditTests: XCTestCase {

    func testWarningSheetsAreAlwaysPresentedThroughTheDismissingModifier() throws {
        let sourceFiles = try swiftSourceFiles(
            in: try repositoryRootURL().appendingPathComponent("AppPorts")
        )

        var findings: [String] = []

        for fileURL in sourceFiles.sorted(by: { $0.path < $1.path }) {
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            let relativePath = try relativeSourcePath(for: fileURL)

            for block in sheetPresentationBlocks(in: content) {
                guard block.text.contains("WarningSheet(") else { continue }
                findings.append(
                    "\(relativePath):\(block.line) 手写的 .sheet 直接构造了 WarningSheet，"
                        + "没有绑定 onResolve，弹窗点按钮后关不掉。改用 .warningSheet($绑定)。"
                )
            }
        }

        XCTAssertTrue(findings.isEmpty, findings.joined(separator: "\n"))

    }

    func testEveryWarningRequestStateHasANonNilAssignmentInItsFile() throws {
        // 静态检查仅证明本文件有非 nil 赋值表达式，不证明运行时一定触发弹窗。
        let sourceFiles = try swiftSourceFiles(
            in: try repositoryRootURL().appendingPathComponent("AppPorts")
        )

        var findings: [String] = []
        let declarationPattern = try NSRegularExpression(
            pattern: #"@State private var (\w+): WarningSheetRequest\?"#
        )
        let contents = try sourceFiles.map { (url: $0, content: try String(contentsOf: $0, encoding: .utf8)) }

        for (fileURL, content) in contents {
            let relativePath = try relativeSourcePath(for: fileURL)
            let range = NSRange(content.startIndex..<content.endIndex, in: content)
            for match in declarationPattern.matches(in: content, range: range) {
                guard let nameRange = Range(match.range(at: 1), in: content) else { continue }
                let name = String(content[nameRange])
                if try !hasNonNilAssignment(to: name, in: content) {
                    findings.append("\(relativePath): \(name) 在声明所在文件没有非 nil 赋值表达式")
                }
            }
        }

        XCTAssertTrue(findings.isEmpty, findings.joined(separator: "\n"))
    }

    func testAssignmentAuditRejectsDismissalOnlyAndComparison() throws {
        for source in ["request = nil", "request =\n nil", "request == candidate",
                       "otherRequest = candidate", "// request = candidate"] {
            XCTAssertFalse(try hasNonNilAssignment(to: "request", in: source), source)
        }
        for source in ["request = WarningSheetRequest()", "self.request = candidate",
                       "request =\n makeRequest()"] {
            XCTAssertTrue(try hasNonNilAssignment(to: "request", in: source), source)
        }
    }

    func testStorageLimitationConfirmationSkipsCapabilityRecheck() throws {
        let contentViewURL = try repositoryRootURL()
            .appendingPathComponent("AppPorts/ContentView.swift")
        let content = try String(contentsOf: contentViewURL, encoding: .utf8)

        guard let methodRange = content.range(of: "private func makeStorageLimitationRequest(") else {
            XCTFail("未找到 ContentView.makeStorageLimitationRequest")
            return
        }
        let tail = String(content[methodRange.lowerBound...])
        let methodBody = tail.components(separatedBy: "\n    private func ").first ?? tail

        XCTAssertTrue(
            methodBody.contains("skipStorageLimitationCheck: true"),
            "makeStorageLimitationRequest 的「仍要迁移」回调在关闭弹窗（storageLimitationRequest = nil）后"
                + "调用 proceedWithMigration 时必须传入 skipStorageLimitationCheck: true，否则会再次触发存储能力弹窗死循环"
        )
    }

    private func hasNonNilAssignment(to name: String, in source: String) throws -> Bool {
        // This is a source audit, not a Swift parser or a reachability proof.
        let code = source.components(separatedBy: .newlines)
            .map { String($0.components(separatedBy: "//")[0]) }.joined(separator: "\n")
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let pattern = try NSRegularExpression(pattern: "\\b" + escaped + #"\s*=(?!=)\s*(?!nil\b)(?=\S)"#)
        return pattern.firstMatch(in: code, range: NSRange(code.startIndex..<code.endIndex, in: code)) != nil
    }

    // MARK: - 源码扫描辅助

    private struct SheetBlock {
        let line: Int
        let text: String
    }

    /// 抓出每个 `.sheet(item:)` / `.sheet(isPresented:)` 从起始行到配对大括号的全部文本。
    private func sheetPresentationBlocks(in content: String) -> [SheetBlock] {
        let lines = content.components(separatedBy: .newlines)
        var blocks: [SheetBlock] = []
        var index = 0

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(".sheet(item:") || trimmed.hasPrefix(".sheet(isPresented:") else {
                index += 1
                continue
            }

            let indent = line.prefix { $0 == " " }.count
            // 单行写法：开括号和闭括号在同一行
            if let openIndex = line.lastIndex(of: "{"), line[line.index(after: openIndex)...].contains("}") {
                blocks.append(SheetBlock(line: index + 1, text: line))
                index += 1
                continue
            }

            var buffer = [line]
            var cursor = index + 1
            while cursor < lines.count {
                let candidate = lines[cursor]
                let candidateIndent = candidate.prefix { $0 == " " }.count
                if candidate.trimmingCharacters(in: .whitespaces) == "}", candidateIndent <= indent {
                    break
                }
                buffer.append(candidate)
                cursor += 1
            }
            blocks.append(SheetBlock(line: index + 1, text: buffer.joined(separator: "\n")))
            index = cursor + 1
        }

        return blocks
    }

    private func repositoryRootURL() throws -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func relativeSourcePath(for fileURL: URL) throws -> String {
        let sourceRootPath = try repositoryRootURL()
            .appendingPathComponent("AppPorts")
            .standardizedFileURL.path + "/"
        return fileURL.standardizedFileURL.path.replacingOccurrences(of: sourceRootPath, with: "")
    }

    private func swiftSourceFiles(in rootURL: URL) throws -> [URL] {
        let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        var result: [URL] = []
        while let item = enumerator?.nextObject() as? URL {
            guard item.pathExtension == "swift" else { continue }
            result.append(item)
        }
        return result
    }
}
