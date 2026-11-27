# Introduction

AppPorts is a free, open-source macOS tool for moving applications and data. It helps you put large apps, application data and your own folders on external storage, while managing local entries, reconnection and restoration. Keep the things you need and make room on your Mac's internal drive.

Apps and data can move independently. You can move a large app alone, or keep the app installed locally and move only its eligible data directories. Different content has different limits; AppPorts offers actions appropriate to the selected item.

## How to use these docs {#reading}

These guides are for everyday AppPorts users. They cover preparation, migration, restoration and troubleshooting.

- **First time here:** follow [Quick start](/docs/faststart) to install AppPorts and complete a migration.
- **Know what to move:** go to [Move applications](/docs/core) or [Move data](/docs/datamigrae/operation).
- **Need files back or an entry repaired:** see [Restore, reconnect and unlink](/docs/restore).
- **Interested in the design:** read “How it works”; for experiments and tradeoffs, explore the [blog](/docs/blog/overview).
- **Unfamiliar term or warning:** consult the [glossary](/docs/glossary), [badges and states](/docs/badges), or [troubleshooting](/docs/faq).

These docs describe the current interface and behavior, including development changes not yet included in a public release. See the [changelog](/docs/changelog) for released versions, and check version notes when using an older build.

You can also consult [AppPorts on DeepWiki](https://deepwiki.com/wzh4869/AppPorts). The [author's blog post](https://www.shimoko.com/p/appports/) explains how AppPorts began.

The [blog](/docs/blog/overview) follows the experiments and failed approaches that shaped AppPorts' migration methods.

## AppPorts' product philosophy {#philosophy}

| Principle | What it means in use |
| --- | --- |
| Familiar experience | Preserve familiar ways of opening apps, with a local entry after moving the real app externally. |
| Stable strategies | Prefer validated methods and explain uncertain data, permissions or conflicting destinations. |
| Low system overhead | Avoid unnecessary background work; disk maintenance and the application update guardian run from events and actual state, and can be disabled in settings. |
| International access | Make AppPorts usable in more languages and keep improving translations. |
| Accessibility | Support accessible controls, status information and assistive technologies. |

These principles also preserve choice. Moving an app does not require studying container data first. When mount requirements are not met, data can stay local. Moved content still depends on the external drive, and important data still needs a backup.

## Before you start {#before-start}

Decide whether you are moving the application itself or its data, then check storage and permissions. AppPorts cannot make an unsupported directory eligible or guarantee that every app works on every storage device.

[![Choose a sidebar section according to what you want to move. Directory Migration is selected here, with the add-folder button on the right (Simplified Chinese interface).](https://file.shimoko.com/d/openlist/openlist/%E7%BD%91%E7%AB%99%E5%AA%92%E4%BD%93%E6%96%87%E4%BB%B6/appports-guide-navigation-e9d2f12c105517f2.png?sign=YXYXzqUxWXjfroVApwggGfQ0rJu9H2ScYHnjNVr6iMc%3D%3A0)](https://file.shimoko.com/d/openlist/openlist/%E7%BD%91%E7%AB%99%E5%AA%92%E4%BD%93%E6%96%87%E4%BB%B6/appports-guide-navigation-e9d2f12c105517f2.png?sign=YXYXzqUxWXjfroVApwggGfQ0rJu9H2ScYHnjNVr6iMc%3D%3A0)

*Choose a sidebar section according to what you want to move. Directory Migration is selected here, with the add-folder button on the right (Simplified Chinese interface).*

Continue with [Boundaries & Consensus](/docs/consensus), [Quick start](/docs/faststart), [external drives](/docs/storage-guide), the [privacy policy](/docs/privacy) or [licenses](/docs/licenses).
