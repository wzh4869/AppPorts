---
description: "Your macOS guide to installing AppPorts, moving apps and data, and everyday maintenance."
layout:
  width: "wide"
  outline:
    visible: false
  pagination:
    visible: false
  metadata:
    visible: false
  title:
    visible: false
  description:
    visible: false
  cover:
    visible: true
    size: "background"
icon: "book-open"
cover: ".gitbook/assets/home-cover.svg"
coverY: 0
---

# AppPorts

## App Migration Tool <a href="#app-migration-tool" id="app-migration-tool"></a>

Your macOS guide to installing AppPorts, moving apps and data, and everyday maintenance.

<button type="button" class="button primary" data-action="ask" data-icon="gitbook-assistant">What would you like to know about AppPorts?</button>

<a href="faststart.md" class="button primary">Get Started</a> <a href="AppPorts.md" class="button secondary">Introduction</a>

<h3 align="center">Start here <a href="#start-here" id="start-here"></a></h3>

<p align="center">Choose a guide for getting started, moving apps, or migrating data.</p>

<table data-view="cards">
<thead><tr><th width="48"></th><th></th><th></th><th></th><th></th><th></th></tr></thead>
<tbody>
<tr><td><i class="fa-rocket"></i></td><td><h4>Getting started <a href="#start-1" id="start-1"></a></h4></td><td>Learn about AppPorts, installation, permissions, and basic settings.</td><td><a data-mention href="faststart.md">Quick start</a></td><td><a data-mention href="AppPorts.md">Introduction</a></td><td><a data-mention href="settings.md">Settings</a></td></tr>
<tr><td><i class="fa-layer-group"></i></td><td><h4>App migration <a href="#start-2" id="start-2"></a></h4></td><td>Review app migration, restoration, and strategies for different app types.</td><td><a data-mention href="core.md">Core features</a></td><td><a data-mention href="migration-strategy/portal.md">Migration strategies</a></td><td><a data-mention href="migration-strategy/strategy-map.md">App types &amp; strategies</a></td></tr>
<tr><td><i class="fa-database"></i></td><td><h4>Data migration <a href="#start-3" id="start-3"></a></h4></td><td>Find guides for data directories, tool data, and container mount migration.</td><td><a data-mention href="datamigrae/operation.md">Data migration guide</a></td><td><a data-mention href="datamigrae/tools.md">Tool directory detection</a></td><td><a data-mention href="datamigrae/mount-migration.md">Container mount migration</a></td></tr>
</tbody>
</table>

***

<h3 align="center">Storage and maintenance <a href="#storage-and-maintenance" id="storage-and-maintenance"></a></h3>

<p align="center">Review external drive requirements, updates, and troubleshooting guides.</p>

<table data-view="cards">
<thead><tr><th width="48"></th><th></th><th></th><th></th><th></th><th></th></tr></thead>
<tbody>
<tr><td><i class="fa-hard-drive"></i></td><td><h4>External storage <a href="#maintain-1" id="maintain-1"></a></h4></td><td>Review drive selection, when APFS is required, and compatibility limits.</td><td><a data-mention href="storage-guide.md">Storage guide</a></td><td><a data-mention href="why-apfs.md">APFS requirements</a></td><td><a data-mention href="limitations.md">Compatibility &amp; limits</a></td></tr>
<tr><td><i class="fa-arrows-rotate"></i></td><td><h4>Updates and maintenance <a href="#maintain-2" id="maintain-2"></a></h4></td><td>Explore app updates, macOS 27 changes, and how container data relates to signing identity.</td><td><a data-mention href="migration-strategy/updater-detection.md">Self-updater detection</a></td><td><a data-mention href="macos-27.md">Upgrading to macOS 27</a></td><td><a data-mention href="datamigrae/container-identity.md">Container data &amp; signing</a></td></tr>
<tr><td><i class="fa-life-ring"></i></td><td><h4>Troubleshooting <a href="#maintain-3" id="maintain-3"></a></h4></td><td>Find checks for specific symptoms, answers to common questions, and logging guidance.</td><td><a data-mention href="troubleshooting.md">Troubleshooting</a></td><td><a data-mention href="faq.md">FAQ</a></td><td><a data-mention href="logging.md">Logs &amp; diagnostics</a></td></tr>
</tbody>
</table>

***

<h3 align="center">Explore the core features <a href="#explore-the-core-features" id="explore-the-core-features"></a></h3>

<p align="center">Explore the three core features of AppPorts.</p>

<table data-view="cards">
<thead><tr><th width="48"></th><th></th><th></th><th data-hidden data-card-target data-type="content-ref"></th></tr></thead>
<tbody>
<tr><td><i class="fa-layer-group"></i></td><td><strong>Badge-free Migration</strong></td><td>One-click migration of large apps to external drives. No shortcut arrows in Finder; Launchpad and app menu work normally.</td><td><a href="core.md">core.md</a></td></tr>
<tr><td><i class="fa-arrows-rotate"></i></td><td><strong>Auto-Update Protection</strong></td><td>Automatically detects self-updating apps such as Sparkle and Electron apps and offers Locked Migration. A newer local app is marked Pending Move Out when the external copy is older.</td><td><a href="migration-strategy/updater-detection.md">migration-strategy/updater-detection.md</a></td></tr>
<tr><td><i class="fa-database"></i></td><td><strong>Data Directory Management</strong></td><td>Move ~/Library/ subdirectories, ~/.npm and other data directories to external storage. Sandbox container data, such as WeChat chat history, uses mount migration to an APFS external drive, leaving the signature unchanged.</td><td><a href="datamigrae/README.md">datamigrae/README.md</a></td></tr>
</tbody>
</table>

***

<h3 align="center">Keep exploring <a href="#keep-exploring" id="keep-exploring"></a></h3>

<table data-view="cards">
<thead><tr><th width="48"></th><th></th><th></th><th data-hidden data-card-target data-type="content-ref"></th></tr></thead>
<tbody>
<tr><td><i class="fa-clock-rotate-left"></i></td><td><h4>Changelog <a href="#explore-1" id="explore-1"></a></h4></td><td>Review changes and fixes by version.</td><td><a href="changelog.md">changelog.md</a></td></tr>
<tr><td><i class="fa-flask"></i></td><td><h4>Experiment logs <a href="#explore-2" id="explore-2"></a></h4></td><td>Read experiments on sandboxes, mounts, drive removal, and startup.</td><td><a href="research/README.md">research/README.md</a></td></tr>
<tr><td><i class="fa-code-pull-request"></i></td><td><h4>Contributing <a href="#explore-3" id="explore-3"></a></h4></td><td>Learn how to contribute through development, testing, and documentation.</td><td><a href="contributing.md">contributing.md</a></td></tr>
</tbody>
</table>
