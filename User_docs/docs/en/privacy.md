# AppPorts Privacy Policy

Updated: November 18, 2026

Effective: November 18, 2026

Applies to: AppPorts 1.8.1 and later

AppPorts (“the Software”) is an application migration tool for macOS. This Privacy Policy (“the Policy”) explains how we collect, use, share, and protect personal information and the rights you have in relation to it.

The Policy applies to the Software, our official website (appports.shimoko.com), and our documentation site (docs-appports.shimoko.com). Features that need to read information also explain their processing rules through relevant interface notices.

Read and understand the entire Policy before using the Software or visiting these sites. Beginning to use them indicates that you have read, understood, and agreed to this Policy. It does not govern how third parties define or use personal information; review their policies before interacting with them.

## Article 1. Definitions {#section-1}

- Personal information: information recorded electronically or otherwise relating to an identified or identifiable natural person. This includes direct identifiers such as names and indirect identifiers reasonably capable of identifying someone, such as device serial numbers. Anonymized information is excluded.
- Aggregate data: statistically processed data that cannot identify a particular person. Under this Policy, it is not personal information.
- Processing: collection, storage, use, processing, transmission, provision, disclosure, deletion, and similar handling of personal information.
- You: end users of the Software and visitors to the sites above.
- We: the developer and operator of the Software.

## Article 2. Scope {#section-2}

This Policy covers your interactions with us through the Software, official website, and documentation site. Both sites are static, with no user accounts or user-generated-content features.

Third-party services linked from these sites are governed by their own policies and are outside this Policy's scope.

## Article 3. Our commitments {#section-3}

We believe in and respect fundamental privacy rights, regardless of your country or region.

We do not design features at the expense of privacy. Core functionality runs entirely on your device. There are no accounts, behavioral collection, or personalized recommendations. If a feature needs to read information, its scope and purpose are stated in this Policy or the feature's interface.

## Article 4. Personal information we collect and use {#section-4}

We do not collect, use, or disclose your personal information, or retain data about you on our servers. Specifically:

- The Software has no account registration or login and does not collect phone numbers, email addresses, names, or similar identity information.
- It includes no analytics, behavioral tracking, A/B testing, or crash-collection SDKs.
- It includes no advertising or push-notification SDKs and serves no personalized advertising.
- It does not generate or read device identifiers such as IDFA, IDFV, hardware serial numbers, or hardware UUIDs.
- It requests no Contacts, Calendar, Reminders, Photos, microphone, camera, location, Bluetooth, Health, or similar permissions.
- It accesses only its encrypted data-volume password items in the local login Keychain when you choose to save them; it does not read other apps’ passwords.
- It does not set or read cookies for analytics or advertising.

## Article 5. Information read locally {#section-5}

To migrate applications and their data to external storage, the Software reads the following locally. These reads occur on your device and do not provide personal information to third parties:

- Application bundles, icons, and code-signature information in app directories such as /Applications.
- App-related directories under ~/Library, to identify migratable data and calculate sizes.
- Custom scan paths you add.
- External-storage paths you select, for destinations and link-state checks.
- Connected volumes' identifiers, connection types, writability, and free space, to verify locations and select a suitable external drive when saving signature originals.
- Running applications, to check that a target is not running before migration and reduce the risk of data damage.
- System App Store external-installation preferences (`PreferredVolume` in `com.apple.appstored`, read-only to check whether it matches the selected external drive) and local ShipIt update status and logs produced by migrated applications (used only when Application update guardian is enabled to identify explicitly failed updates and perform recovery or clean up retry state).
- Basic operational information: macOS version, processor core count, physical memory, and external-storage read/write speed, used only in local logs and migration performance reports.

## Article 6. Network requests and recipients {#section-6}

The Software makes network requests only in these circumstances. Request contents exclude personal information, account or device identifiers, and file paths or names:

- Version checks: one silent check at launch or a check you initiate requests `docs-appports.shimoko.com/latest.json` (and corresponding official release metadata), and queries GitHub version information at `api.github.com` when needed. If the API is unavailable, it falls back to `github.com`'s `releases.atom` feed.
- In-app update downloads: when you explicitly choose Update via China mirror or Update via GitHub in an update prompt, the Software downloads the release package from the official download mirror (`file.shimoko.com`) or the corresponding GitHub Release asset URL and verifies its hash and code signature locally.
- Information display: opening “About AppPorts” requests GitHub contributors and the documentation site's sponsor list at `docs-appports.shimoko.com/sponsors.json`.

These requests use a fixed User-Agent: `AppPorts`, `AppPorts-UpdateChecker`, or `AppPorts-Updater`. HTTP inherently allows recipient servers to see your IP address and request time. Recipients include GitHub and the servers of this project's official website, download mirror, and documentation site; their information processing follows their respective privacy policies.

Opening the website, documentation, repository, sponsor page, or other external links, or manually downloading releases through web links, is handled by your default browser rather than performed independently by the Software.

## Article 7. Local storage {#section-7}

The Software stores these files and settings on your local devices without providing their contents externally:

- ~/Library/Application Support/AppPorts/AppPorts_Log.txt: operations and diagnostics.
- Local login Keychain: passwords for encrypted data volumes only when you choose to save them, without syncing; passwords are not written to logs or migration records and otherwise remain temporary process credentials;
- App and tool-directory size caches and application search-location records: used to display sizes and cache times and maintain app libraries and local entries; file inventories are not uploaded;
- `migration-task-history.json`: task names, categories, associated paths, times and display results; this is display history, not a queue that automatically repeats operations;
- `disk-ejection-pauses.plist` and `launch-locks`: local mounting-pause information after an explicit physical-disk eject, app library image unmount, or individual data-volume unmount, and lock files used by local processes to coordinate launch protection during migration; these are not uploaded;
- ~/Library/Application Support/AppPorts/contributors-cache.json: contributor cache to reduce repeated requests.
- ~/Library/Application Support/AppPorts/sponsors-cache.json: sponsor cache for offline display.
- Migration, mount, signing, and recovery records under ~/Library/Application Support/AppPorts/ (including update recovery receipts, rollback intents, and per-request task status files under `shipit-recovery/`): app identity, paths, volume identifiers, and operation states needed for reconnection, signature restoration, background update-guardian status synchronization, and unfinished operations.
- `~/Library/LaunchAgents/com.shimoko.AppPorts.container-mount.plist` and `~/Library/LaunchAgents/com.shimoko.AppPorts.update-guardian.plist`: user LaunchAgent definitions written only when you enable the corresponding background agent (automatic container/image mounting or Application update guardian) to run local recovery at login or when external storage mounts; disabling an agent in Settings removes it.
- AppPorts Backups at a suitable external drive's root: since 1.9.1 build 31, verified official originals are saved automatically before manual re-signing, with README.txt. They restore app contents and signatures; they are not backups of chats, documents, or other personal data.
- Preference files under ~/Library/Preferences: interface language, external and custom scan paths, app library image location records (SMB share URL without credentials, or backing volume and internal APFS volume identifiers), background-agent switches, guidance dismissal state, and feature switches.

Signing also creates a temporary working copy beside the real app. Useful older internal originals move externally after the required conditions and copy verification pass. Originals, indexes, and operation records stay on local storage and are not uploaded through saving or automatic maintenance.

You may delete caches, logs, and preferences. Before deleting migration or recovery records, complete relevant restoration and finalization through the Software so information needed to reconnect data or restore signatures is not lost. Uninstalling does not restore migrated data or delete external apps, data, or signature originals. See [signature-original cleanup](/docs/settings#signature-backup-cleanup) and [before uninstalling](/docs/faq#uninstall).

## Article 8. Diagnostic packages {#section-8}

“Export Diagnostics” runs only when you choose it:

- You select the destination in the system save panel.
- Before export, the Software replaces usernames in logs with ~, replaces /Users/＜username＞ with /Users/＜redacted-user＞, and redacts external-storage names.
- It does not upload or provide the file to any third party automatically. Sharing it with us is entirely your decision.

[![Diagnostics export dialog. Including this Mac’s app list is unchecked by default. You choose the save location.](https://file.shimoko.com/d/openlist/openlist/%E7%BD%91%E7%AB%99%E5%AA%92%E4%BD%93%E6%96%87%E4%BB%B6/appports-guide-diagnostics-en-c1e3fed21079e128.png?sign=3bUYvlhGHcCYG7lsuVQlhVFPtnevKDD_0XHB5rXQZo8%3D%3A0)](https://file.shimoko.com/d/openlist/openlist/%E7%BD%91%E7%AB%99%E5%AA%92%E4%BD%93%E6%96%87%E4%BB%B6/appports-guide-diagnostics-en-c1e3fed21079e128.png?sign=3bUYvlhGHcCYG7lsuVQlhVFPtnevKDD_0XHB5rXQZo8%3D%3A0)

*Diagnostics export dialog. Including this Mac’s app list is unchecked by default. You choose the save location.*

## Article 9. System permissions {#section-9}

The Software may use these permissions:

- Full Disk Access to read and write relevant /Applications and ~/Library directories. You must enable this manually in System Settings → Privacy & Security. The Software cannot grant it to itself or bypass it.
- App Management permission, prompted by macOS when updating or modifying protected application bundles during migration, portal creation, restoration, or cleanup of old app copies. You can manage this in System Settings → Privacy & Security → App Management.
- Automation (Apple Events) when operations use Finder to move or delete App Store apps or request disk ejection. macOS asks for consent. You may refuse or revoke it in System Settings → Privacy & Security → Automation.
- Administrator privileges when moving, restoring, re-signing, or repairing ownership of root-owned app installations, cleaning up root-owned retained old data copies during manual retry, or when macOS requires administrator authorization for specific volume mount or unmount operations. Your password goes directly to macOS through its system dialog; the Software does not read, record, or store it.

The Software requests no Contacts, Calendar, Photos, microphone, camera, location, Bluetooth, or similar permissions and uses only its local login Keychain items when you choose to save encrypted data-volume passwords.

App Sandbox is disabled because the Software must read and write apps and data across drives. Hardened Runtime is enabled. Releases are not notarized by Apple; on first launch, you may need to allow the app in System Settings → Privacy & Security.

## Article 10. Cookies and similar technologies {#section-10}

The official website (appports.shimoko.com) and documentation site (docs-appports.shimoko.com) are static sites. They use no cookies for analytics, contain no third-party advertising or social plugins, and set no cross-site tracking pixels.

The documentation site uses Umami Cloud to count page views and improve its content. It excludes query parameters and section anchors from the page URLs reported for analytics. These rules apply to the documentation site and to the official website when it uses similar analytics:

- No cookies, personally identifying collection, or cross-site tracking.
- Raw IP addresses are not stored. They are used at request time only to infer an approximate region and deduplicate visits.
- Recorded aggregate information includes page views, referring sites, browser and OS types, and approximate regions.
- You may block the script with a content-blocking extension or network filter without affecting normal reading or access.

Where local law treats IP addresses or similar identifiers as personal information, we apply the same standard to them.

Hosting providers may retain ordinary access logs for operations and security.

## Article 11. Public sponsor information {#section-11}

If you donate through the project's QR code and provide a nickname in the message, it is displayed on the documentation sponsor page and in “About AppPorts.” Personal links are optional; without one, only the nickname appears. Donation amounts appear only on the website's sponsor page.

This is the project's only personal-information publication scenario and depends on voluntary submission. Leave these fields blank if you do not want publication, or request correction or deletion using Article 18.

## Article 12. Third-party platforms {#section-12}

These platforms process information independently under their own policies. We are not responsible for their processing:

- GitHub processes information in Issues and Pull Requests you submit.
- Bilibili, WeChat, Alipay, and other donation platforms process payment information. We do not access your payment-account information.
- Third-party sites opened through the Software or our sites may collect information themselves.

## Article 13. Cross-border transfers {#section-13}

The Software does not collect or store your personal information on servers, so we do not initiate outbound transfers of such information.

Interactions through GitHub, Bilibili, or other platforms may be transmitted to servers in their countries or regions. Those platforms independently handle transfers and processing under their policies.

## Article 14. Minors {#section-14}

The Software is not designed for minors and does not actively collect their personal information. Minors should read this Policy with a guardian and obtain consent before use.

## Article 15. Information security {#section-15}

Because the Software does not collect or store personal information on servers, there is no risk of that information being exposed through a breach of such server storage. Locally read and written files depend on your device's and OS's security protections. Keep your device secure and your system updated.

## Article 16. Your privacy rights {#section-16}

We respect your ability to know about, access, correct, transfer, restrict processing of, and delete personal information. Because we do not collect or store it, we hold no such records for lookup, correction, or deletion. You may nevertheless contact us about this Policy without discriminatory treatment for exercising these rights.

Where consent is required as a legal basis, you may withdraw it at any time without affecting processing lawfully performed before withdrawal.

You can exercise rights by:

- Managing or deleting local caches, logs, settings, and recovery material under Article 7, after resolving managed migrations. Uninstalling does not establish that external data has been deleted.
- Requesting correction or deletion of published sponsor information using Article 18.
- Complaining or reporting to the relevant regulator if you believe our processing infringes your lawful rights.

## Article 17. Policy updates {#section-17}

We may revise this Policy. Updated and effective dates at the top will change accordingly. Material changes to your rights will be highlighted in the changelog and GitHub release notes.

The Simplified Chinese version governs. Translations are provided for reference.

## Article 18. Contact {#section-18}

For questions, comments, or complaints about this Policy or personal-information protection, email [a@shimoko.com](mailto:a@shimoko.com).

We will respond within 15 working days of receiving your request.
