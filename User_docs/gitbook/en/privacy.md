---
layout:
  outline:
    visible: false
  pagination:
    visible: false
---

# AppPorts Privacy Policy

- **Last updated:** September 17, 2026
- **Effective date:** September 17, 2026
- **Applies to:** AppPorts 1.8.1 and later

AppPorts (the “Software”) is an application migration tool for macOS. This Privacy Policy (the “Policy”) explains how we collect, use, share, and protect your personal information, and the rights you have in that regard.

This Policy applies to the Software and to our official website (appports.shimoko.com) and documentation site (docs-appports.shimoko.com). In addition to this Policy, for each feature that needs to read your information we also explain that feature’s information-handling rules in the relevant interface.

Please read this Policy in full and make sure you understand it before using the Software or visiting those sites. By using the Software or visiting those sites, you confirm that you have read, understood, and accepted this Policy. This Policy does not govern how third parties define or use your personal information; we recommend reading their privacy policies before interacting with them.

## 1. Definitions <a href="#_1-definitions" id="_1-definitions"></a>

For the purposes of this Policy:

1. “Personal information” means any information relating to an identified or identifiable natural person that is recorded electronically or otherwise. It includes information that identifies you directly, such as your name, and information that does not identify you directly but can reasonably be inferred to do so, such as a device serial number. It excludes anonymised information.
2. “Aggregate data” means data that, after statistical processing, cannot identify a specific natural person. For the purposes of this Policy, aggregate data is not personal information.
3. “Processing” means any operation performed on personal information, including collection, storage, use, adaptation, transmission, provision, disclosure, and deletion.
4. “You” means the end user of the Software and a visitor to the sites described above.
5. “We” means the developer and operator of the Software.

## 2. Scope <a href="#_2-scope" id="_2-scope"></a>

This Policy applies to your interactions with us through the Software, the official website, and the documentation site. Both sites are static and have no user accounts and no user-generated content features.

This Policy does not apply to third-party services linked from those sites; such services are governed by their own privacy policies.

## 3. Our Commitment <a href="#_3-our-commitment" id="_3-our-commitment"></a>

We believe in and respect fundamental privacy rights, and we believe those rights should not depend on the country or region in which you live.

Consistent with that principle, we do not build features at the expense of your privacy. The Software’s core functions run entirely on your device: there is no account system, no usage tracking, and no personalised recommendations. Where a feature genuinely needs to read your information, we state its scope and purpose in this Policy or in the relevant interface.

## 4. Personal Information We Collect and Use <a href="#_4-personal-information-we-collect-and-use" id="_4-personal-information-we-collect-and-use"></a>

We do not collect, use, or disclose any of your personal information, and we retain no data about you on any server. Specifically:

1. The Software has no account system, offers no registration or sign-in, and collects no identifiers such as phone numbers, email addresses, or names;
2. The Software includes no analytics, behavioural tracking, A/B testing, or crash-reporting SDK;
3. The Software includes no advertising or push-notification SDK and serves no personalised advertising;
4. The Software neither generates nor reads any device identifier (such as IDFA, IDFV, hardware serial number, or hardware UUID);
5. The Software requests no access to contacts, calendars, reminders, photos, microphone, camera, location, Bluetooth, or health data;
6. The Software does not access the system keychain;
7. The Software sets and reads no cookies for analytics or advertising purposes.

## 5. Information Read Locally <a href="#_5-information-read-locally" id="_5-information-read-locally"></a>

To provide its core function — migrating applications and their data to external storage — the Software reads the following information on your device. All of this reading takes place locally and does not constitute disclosure to any third party:

1. Application bundles, icons, and code-signing information in application directories such as /Applications;
2. Application-related data directories under \~/Library, used to identify migratable data and measure its size;
3. Custom scan paths that you add yourself;
4. The external storage path you select, used as the migration target and to verify link status;
5. The list of currently running applications, used to confirm that a target application is not running before migration so that data is not corrupted;
6. Basic device information, including the macOS version, processor core count, physical memory, and external drive read/write speed, used only to produce local logs and migration performance reports.

## 6. Network Access and Recipients <a href="#_6-network-access-and-recipients" id="_6-network-access-and-recipients"></a>

The Software makes network requests only in the following cases, and those requests contain none of your personal information, nor any account identifier, device identifier, file path, or file name:

1. Version checks: the Software performs one silent version check at launch, or when you initiate a check. It requests appports.shimoko.com/latest.json and also queries version information on GitHub (api.github.com), falling back to the releases.atom feed if that interface is unavailable.
2. Displayed information: when you open the “About AppPorts” window, the Software requests the list of contributors from GitHub and the list of sponsors from the documentation site (docs-appports.shimoko.com/sponsors.json).

These requests carry only a fixed User-Agent string (AppPorts or AppPorts-UpdateChecker). As an inherent property of HTTP, the receiving server can obtain your IP address and the time of the request. Those recipients are the servers of GitHub and of this project’s documentation site, and each handles personal information under its own privacy policy.

The following are not performed by the Software itself but handed to your default browser: downloading a new version; opening external links such as the official website, documentation, code repository, and sponsor page.

## 7. Local Storage <a href="#_7-local-storage" id="_7-local-storage"></a>

The Software stores the following files and settings locally on your device. None of this involves disclosing personal information to any third party:

1. \~/Library/Application Support/AppPorts/AppPorts\_Log.txt: operation logs and diagnostic information;
2. \~/Library/Application Support/AppPorts/contributors-cache.json: a cached contributor list, used to reduce repeated network requests;
3. \~/Library/Application Support/AppPorts/sponsors-cache.json: a cached sponsor list, used so it can be shown offline;
4. Preference files under \~/Library/Preferences: interface language, external storage path, custom scan paths, and feature toggles.

You may delete these files and the Software itself at any time to erase all local data.

## 8. Diagnostic Package <a href="#_8-diagnostic-package" id="_8-diagnostic-package"></a>

The “export diagnostic package” function runs only when you click it, and:

1. you choose the destination file location in the system save panel;
2. before export, the Software replaces usernames in the logs with \~, replaces /Users/&lt;username&gt; with /Users/&lt;redacted-user&gt;, and redacts the names of your external storage volumes;
3. the Software never uploads that file automatically and never provides it to any third party. Whether to share it with us is entirely your decision.

## 9. System Permissions <a href="#_9-system-permissions" id="_9-system-permissions"></a>

To provide the functions described above, the Software may involve the following system permissions:

1. Full Disk Access: used to read and write /Applications and the relevant directories under \~/Library. You enable it yourself in System Settings → Privacy &amp; Security. The Software cannot request this permission on its own and cannot work around that restriction.
2. Automation (Apple Events): when migrating App Store applications, the Software uses Finder to perform the move or deletion. macOS asks for your consent; you may decline, and you may turn the permission off at any time in System Settings → Privacy &amp; Security → Automation.
3. Administrator privileges: triggered only when you re-sign or repair the ownership of an application installed under the root user. The administrator password you enter is submitted by the macOS system dialog directly to the operating system; the Software does not read, record, or store it.

The Software requests no access to contacts, calendars, photos, microphone, camera, location, or Bluetooth, and does not access the system keychain.

The Software does not run in the App Sandbox (it requires cross-volume access to application and data directories) but does enable the Hardened Runtime. Release builds are not notarised by Apple, so the first launch may require your approval in System Settings → Privacy &amp; Security.

## 10. Cookies and Similar Technologies <a href="#_10-cookies-and-similar-technologies" id="_10-cookies-and-similar-technologies"></a>

Our official website (appports.shimoko.com) and documentation site (docs-appports.shimoko.com) are static sites. They use no cookies for analytics, contain no third-party advertising or social plugins, and set no cross-site tracking pixels.

Both sites use the open source analytics tool Umami to count page views so that we can understand how each page is used and improve it. Its handling rules are as follows:

1. no cookies, no personally identifiable information, and no cross-site tracking;
2. your raw IP address is not stored — it is used only at the time of the request to determine an approximate region and to de-duplicate visits;
3. only aggregate data is recorded, such as page views, referring site, browser and operating system type, and approximate region;
4. you can block the script at any time with a content blocker or network filter, which does not affect your ability to visit or read the pages.

If the law of your country or region treats IP addresses or similar identifiers as personal information, we treat such identifiers to the same standard.

The hosting provider may retain standard access logs for operations and security purposes.

## 11. Publication of Sponsor Information <a href="#_11-publication-of-sponsor-information" id="_11-publication-of-sponsor-information"></a>

If you support the project through the sponsor QR code and leave a nickname in the payment note, it will be published on the sponsor page of the documentation site and in the sponsor section of the “About AppPorts” window. A personal link is optional; without one, only the nickname is shown. Sponsorship amounts are displayed only on the website sponsor page.

This is the only case in this project in which personal information is made public, and it depends on your voluntary provision. If you would rather not have your nickname or link published, simply leave it out when sponsoring, or request correction or removal in the manner set out in clause 18.

## 12. Third-Party Platforms <a href="#_12-third-party-platforms" id="_12-third-party-platforms"></a>

In the following cases, the relevant information is handled independently by third-party platforms under their own privacy policies, and we are not responsible for their information-handling practices:

1. when you file an issue or pull request on GitHub, the relevant information is handled by GitHub;
2. when you sponsor the project through platforms such as Bilibili, WeChat, or Alipay, payment information is handled by those platforms, and we never have access to your payment account details;
3. when you open a third-party link from the Software or from those sites, that third party may collect information about you on its own.

## 13. Cross-Border Transfers <a href="#_13-cross-border-transfers" id="_13-cross-border-transfers"></a>

The Software collects and stores no personal information on any server, so no transfer of personal information abroad is initiated by us.

When you interact with us through platforms such as GitHub or Bilibili, the relevant information may be transferred to servers in the country or region where those platforms operate. Such transfers and processing are carried out independently by those platforms under their own privacy policies.

## 14. Minors <a href="#_14-minors" id="_14-minors"></a>

The Software is not designed for minors and does not actively collect their personal information. If you are a minor, please read this Policy with your guardian and use the Software only with your guardian’s consent.

## 15. Information Security <a href="#_15-information-security" id="_15-information-security"></a>

Because the Software collects and stores no personal information on any server, there is no risk of your personal information being exposed through a server-side data breach. The security of the files the Software reads and writes on your device depends on the safeguards of your device and operating system themselves; we recommend that you keep your device secure and your system up to date.

## 16. Your Privacy Rights <a href="#_16-your-privacy-rights" id="_16-your-privacy-rights"></a>

We respect your ability to know about, access, correct, transfer, restrict the processing of, and delete your personal information. Because we do not collect or store your personal information, we hold no personal information that could be accessed, corrected, or deleted; we do, however, guarantee your right to communicate with us about this Policy, and we undertake not to treat you differently for exercising those rights.

If we ever rely on your consent as the legal basis for processing personal information, you may withdraw that consent at any time, without affecting the lawfulness of processing carried out on the basis of your consent before its withdrawal.

You may exercise your rights as follows:

1. delete the Software, together with the caches and logs under \~/Library/Application Support/AppPorts/, to erase all local data;
2. request correction or removal of published sponsor information at any time, in the manner set out in clause 18;
3. if you believe our handling of personal information has harmed your lawful rights and interests, you have the right to complain to the relevant supervisory authority.

## 17. Changes to This Policy <a href="#_17-changes-to-this-policy" id="_17-changes-to-this-policy"></a>

We may revise this Policy from time to time. When we do, the “Last updated” and “Effective date” at the top of this page will be revised accordingly. For material revisions that substantially change your rights, we will give notice in the changelog and the GitHub release notes.

The Simplified Chinese version of this Policy prevails; translations are provided for reference only.

## 18. Contact <a href="#_18-contact" id="_18-contact"></a>

For any question, comment, or complaint about this Policy or about the protection of personal information, you may contact us as follows:

We will respond to your request within fifteen business days of receipt.

**Email:** [a@shimoko.com](<mailto:a@shimoko.com>)
