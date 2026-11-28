# 安全政策 | Security Policy

[简体中文](#安全政策) | [English](#security-policy)

---

# 安全政策

## 支持的版本

目前仅对最新的主要版本系列提供安全修复与更新支持，建议始终升级到最新版本（可在 AppPorts 的「设置 → 检查更新」或 [GitHub Releases](https://github.com/wzh4869/AppPorts/releases) 获取）。

| 版本 | 支持状态 |
| --- | --- |
| 2.4.x（当前最新） | ✅ 支持安全更新 |
| 2.3.x 及更早版本 | ❌ 不再维护 |

## 如何报告安全漏洞

**请勿在公开的 GitHub Issue、Pull Request 或 Discussions 中直接披露尚未修复的安全漏洞或利用方式。**

如果您发现了安全隐患，请通过以下任一私密渠道联系我们：

1. **GitHub 私密漏洞报告（推荐）**：前往本仓库的 **Security → Advisories**，点击 **Report a vulnerability** 私密提交。
2. **电子邮件**：发送邮件至 **a@shimoko.com**，建议在邮件主题中注明 `[SECURITY]`。

为便于快速定位与复现，请在报告中尽量提供以下信息：

- 受影响的 AppPorts 版本（含 Build 号）与 macOS 版本
- 漏洞类型与潜在影响（例如路径与软链边界逃逸、权限或签名校验绕过、后台代理提权风险、日志或诊断导出泄露敏感信息等）
- 最小复现步骤或概念验证（PoC）说明（请勿包含他人隐私或无关的个人数据）

AppPorts 由个人在业余时间维护，收到报告后我们会尽快确认并评估修复方案。在修复版本发布之前，请配合暂不公开披露漏洞细节；发布后如有需要，我们很乐意在更新说明中向报告者致谢。

## 反馈范围区分

- **安全漏洞与隐私泄露风险**：请使用上方的私密渠道。
- **普通功能缺陷、应用更新兼容或使用问题**：请通过 [GitHub Issues](https://github.com/wzh4869/AppPorts/issues) 提交。

---

# Security Policy

## Supported Versions

Security fixes are only provided for the latest release series. We recommend always keeping AppPorts up to date via **Settings → Check for Updates** or [GitHub Releases](https://github.com/wzh4869/AppPorts/releases).

| Version | Supported |
| --- | --- |
| 2.4.x (current) | ✅ Yes |
| 2.3.x and earlier | ❌ No |

## Reporting a Vulnerability

**Please do not disclose unpatched security vulnerabilities or exploit details in public GitHub Issues, Pull Requests, or Discussions.**

Instead, please report security issues privately through one of the following channels:

1. **GitHub Private Vulnerability Reporting (Recommended)**: Open **Security → Advisories** in this repository and click **Report a vulnerability**.
2. **Email**: Send details to **a@shimoko.com** with `[SECURITY]` in the subject line.

To help us reproduce and assess the issue efficiently, please include:

- Affected AppPorts version (and build number) and macOS version
- Type of issue and potential impact (for example: path or symlink boundary escape, permission or code-signing bypass, background agent privilege issue, or sensitive data exposure in logs/diagnostic exports)
- Minimal steps to reproduce or a proof of concept (without unrelated personal data)

AppPorts is maintained by an individual in spare time; we will review reports as promptly as possible and coordinate a fix before public disclosure. With your permission, we are happy to credit you in the release notes once a fix is published.

## Scope

- **Security vulnerabilities and privacy exposure**: Use the private channels above.
- **General bugs, app-update compatibility, or usage questions**: Please use [GitHub Issues](https://github.com/wzh4869/AppPorts/issues).
