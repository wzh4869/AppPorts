import Foundation
import Testing
@testable import AppPorts

struct WelcomeLaunchPolicyTests {
    private func makeIsolatedDefaults() -> (defaults: UserDefaults, suiteName: String) {
        let suite = "WelcomeLaunchPolicyTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        return (defaults, suite)
    }

    @Test("全新用户进入完整三步欢迎引导")
    func freshUserGetsFullOnboarding() {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(WelcomeLaunchPolicy.presentationMode(defaults: defaults) == .fullOnboarding)
    }

    @Test("完成旧版欢迎页的升级老用户仅展示一次单屏边界共识")
    func upgradingExistingUserGetsBoundaryConsensusOnly() {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(true, forKey: WelcomeLaunchPolicy.welcomeCompletedDefaultsKey)

        #expect(WelcomeLaunchPolicy.presentationMode(defaults: defaults) == .boundaryConsensusOnly)
    }

    @Test("老用户确认边界共识后不再重复弹出，且保留 welcomeCompleted 语义")
    func acknowledgingBoundaryConsensusKeepsWelcomeCompletedAndStopsReprompting() {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(true, forKey: WelcomeLaunchPolicy.welcomeCompletedDefaultsKey)
        WelcomeLaunchPolicy.recordBoundaryConsensusAcknowledged(defaults: defaults)

        #expect(defaults.bool(forKey: WelcomeView.completionDefaultsKey) == true)
        #expect(
            defaults.integer(forKey: WelcomeLaunchPolicy.boundaryConsensusVersionDefaultsKey)
                == WelcomeLaunchPolicy.currentBoundaryConsensusVersion
        )
        #expect(WelcomeLaunchPolicy.presentationMode(defaults: defaults) == nil)
    }

    @Test("新用户走完完整欢迎引导后同时记录欢迎与边界共识确认")
    func completingFullOnboardingRecordsBothFlags() {
        let (defaults, suite) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        WelcomeLaunchPolicy.recordFullOnboardingCompleted(defaults: defaults)

        #expect(defaults.bool(forKey: WelcomeView.completionDefaultsKey) == true)
        #expect(
            defaults.integer(forKey: WelcomeLaunchPolicy.boundaryConsensusVersionDefaultsKey)
                == WelcomeLaunchPolicy.currentBoundaryConsensusVersion
        )
        #expect(WelcomeLaunchPolicy.presentationMode(defaults: defaults) == nil)
    }

    @Test("富文本格式化支持按位置占位符重排并保留链接属性")
    func editorialRichTextSupportsPositionalPlaceholdersAndLinks() {
        let docsURL = URL(string: "https://docs-appports.shimoko.com/")!
        let docsSegment = EditorialRichText.link("文档", destination: docsURL)
        let backupSegment = EditorialRichText.emphasis("备份提醒")

        let rendered = EditorialRichText.format(
            "先看 %2$@，再读 %1$@。",
            segments: [docsSegment, backupSegment]
        )

        #expect(String(rendered.characters) == "先看 备份提醒，再读 文档 ↗。")
        let links = rendered.runs.compactMap(\.link)
        #expect(links == [docsURL])
    }

    @Test("富文本格式化支持顺序占位符并保留链接属性")
    func editorialRichTextSupportsSequentialPlaceholder() {
        let issuesURL = BoundaryConsensusStyle.githubIssuesURL
        let rendered = EditorialRichText.format(
            "欢迎前往 %@ 反馈。",
            segments: [EditorialRichText.link("GitHub Issues", destination: issuesURL)]
        )

        #expect(String(rendered.characters) == "欢迎前往 GitHub Issues ↗ 反馈。")
        let links = rendered.runs.compactMap(\.link)
        #expect(links == [issuesURL])
    }
}
