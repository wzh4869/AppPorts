# Archived: mount experiments not adopted

::: warning Experiments, not current features
These methods were explored in September 2026 on macOS 27.0 (26A428). Their results and reasons for rejection remain here for reference. They are not installation instructions and do not imply that AppPorts ever released corresponding switches.
:::

## Storing data inside disk images {#images}

One option was to place an APFS disk image on external storage and attach its internal volume at the app directory. Encapsulating the required filesystem in a file appeared to offer support for more external drive formats.

In two unexpected-disconnection rounds on the tested USB device, sparsebundle images could not be mounted after reconnection. A native APFS volume also suffered database corruption. The ASIF attempt stopped before a valid unplug test, so there was no success or failure conclusion. See the [unexpected-disconnection experiment](/docs/blog/why-mount-and-apfs#unplug-experiment) for procedures and counts.

Container migration therefore does not offer per-directory disk images as a workaround for the external APFS requirement. This does not establish that every image fails in every environment, and the small sample is not a failure-rate estimate. Note: the [app library image](/docs/storage-guide#app-library-image) introduced in 2.2.0 hosts an external application library (for example on an SMB share or non-APFS drive) and differs from this earlier per-container data image experiment.

## Fixing a location in the system mount table {#fstab}

Experiments compared volume UUIDs and device identifiers in the system mount table, fstab. In the tested setup, the UUID form failed to mount, while a direct device identifier worked. Device identifiers can change after a restart or reconnection.

A fixed entry also does not handle locked user data, container authorization, or drives that become available late. It was not adopted as the user configuration method. Failure in this setup does not mean macOS can never mount by UUID.

## Mounting earlier with a system daemon {#daemon}

A system process was tested for mounting before login or immediately after unlock. With FileVault enabled, the user's target data path was unavailable before unlock. After unlock, administrator identity still could not replace the authorization required for container access.

Another attempt used the system process only to start an already authorized user task. It worked when the user session existed and failed before the session was established. This also introduced system-level installation, retries, and maintenance. The current approach uses a user task to remount data and does not require this experimental daemon.

## Trusting command success without checking the location {#verification}

The investigation found that when macOS had already mounted a volume elsewhere, a command specifying a mount point could return success without attaching the volume at the original directory. The current implementation verifies the actual location and retries where needed. Neither “process started” nor “success returned” proves remounting is complete.

Startup configuration improved waiting times in some samples, but apps could still launch first. See [restart and automatic remounting](/docs/blog/why-mount-and-apfs#startup-method) for timing results and limitations.

The conditions and failures remain documented so the same ideas are not later mistaken for proven features. Current instructions are in [migrate data](/docs/datamigrae/operation) and [settings and permissions](/docs/settings#mount-agent).
