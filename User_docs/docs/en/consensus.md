# Boundaries & Shared Understanding of AppPorts

AppPorts changes a default assumption built into macOS and many apps—while preserving original signatures and sandbox boundaries whenever possible, it relocates apps and data that normally live on your internal drive to your chosen external storage via Stub Portals, symbolic links, or APFS volume mounts.

::: warning Shared Understanding

Remember: **AppPorts is not magic—it is a precision scalpel.**

:::

## An inexhaustible ecosystem {#ecosystem}

The macOS ecosystem includes tens of thousands of apps, each handling hardcoded paths, sandbox and privacy checks (Sandbox / TCC), file ownership, code signing, self-updaters, and background daemons differently. We cannot test every app or guarantee full compatibility with every program on your Mac.

## Freedom comes with risk {#risk-and-freedom}

Stepping outside the default internal-drive assumptions of macOS and apps carries real uncertainty. Minor issues include crashes, reset preferences, failed updates, or broken permissions; severe cases—such as sudden drive disconnects, diverged offline writes, or operator mistakes—can make data invisible, corrupted, or permanently lost.

## Treat your data with care {#respect-data}

Before migrating, restoring, unlinking, re-signing, or cleaning up retained copies, carefully review the current status and prompts. Check these guides beforehand—such as [Quick start](/docs/faststart), [Move applications](/docs/core), [Move data](/docs/datamigrae/operation), and [External drives and daily use](/docs/storage-guide). You can also copy the Markdown of a documentation page from the top-right actions and share it with an AI assistant to quickly understand how it works and assess risks for a specific app. Always ensure your external drive connection is stable; **back up your data before making changes, and note that Time Machine backs up your Mac’s internal drive by default—keep a separate backup of important data moved to an external drive**.

## Feedback and collaboration {#feedback}

AppPorts’ safeguards were refined through real-world testing and hard-won lessons. If you encounter errors, compatibility issues, or have ideas for improvement, please report them via [GitHub Issues](https://github.com/wzh4869/AppPorts/issues) (for bugs, attaching diagnostics from Logs → Export Diagnostic Package helps greatly) or our community channels.

**AppPorts gives you the freedom to control your storage, but the ultimate safety of your data is always in your hands.**

Continue with [Quick start](/docs/faststart), [Move applications](/docs/core), [Move data](/docs/datamigrae/operation) or [External drives and daily use](/docs/storage-guide).
