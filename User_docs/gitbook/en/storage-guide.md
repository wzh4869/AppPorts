# External Storage Guide

## Recommended Configuration <a href="#recommended-configuration" id="recommended-configuration"></a>

| Configuration | Recommended Value | Description |
|---------------|-------------------|-------------|
| Capacity | 256 GB or above | Depends on the number of apps and data directories to migrate |
| Interface | USB 3.0 or above / Thunderbolt | USB 2.0 is slow; large app migration takes longer |
| File System | APFS | The only supported format for migrating container data; also supports clones, snapshots, and space sharing, with the best performance |

## Interface Performance Comparison <a href="#interface-performance-comparison" id="interface-performance-comparison"></a>

| Interface | Theoretical Speed | Actual Migration Speed | Use Case |
|-----------|-------------------|----------------------|----------|
| USB 2.0 | 480 Mbps | ~30 MB/s | Not recommended; too slow |
| USB 3.0 (USB-A) | 5 Gbps | ~350 MB/s | Basically sufficient |
| USB 3.1 Gen 2 (USB-C) | 10 Gbps | ~700 MB/s | Recommended |
| Thunderbolt 3/4 | 40 Gbps | ~2500 MB/s | Best performance |
| NVMe (Thunderbolt) | 40 Gbps | ~2800 MB/s | Best performance |

## File System Recommendations <a href="#file-system-recommendations" id="file-system-recommendations"></a>

### APFS (Recommended) <a href="#apfs-recommended" id="apfs-recommended"></a>

- Supports clones, snapshots, space sharing
- Best performance, especially for SSDs
- Native macOS support
- **Migrating container data (`~/Library/Containers/`, such as WeChat chat history) requires an APFS external drive.** See the explanation and experiments in [Why External Drives Must Use APFS](why-apfs.md).

### HFS+ <a href="#hfs" id="hfs"></a>

- Good compatibility; suitable for older Macs
- Does not support clones and snapshots
- Suitable for mechanical hard drives

### exFAT <a href="#exfat" id="exfat"></a>

- Cross-platform compatible (macOS + Windows)
- Does not support hard links and clones
- Relatively lower performance
- Suitable for scenarios requiring use across multiple systems
- Cannot be used for container data migration. If you also need Windows compatibility, use a separate APFS partition for AppPorts. If exFAT occupies the whole drive, the built-in tools cannot shrink it directly; back it up before repartitioning. See [Partition requirements and preparation](why-apfs.md#prepare-apfs).

## Capacity Planning <a href="#capacity-planning" id="capacity-planning"></a>

AppPorts' external storage usage after migration depends on the size of migrated apps and data directories. Below are reference sizes for common apps:

| App Type | Size |
|----------|------|
| Chrome | ~500 MB |
| Microsoft Office | ~5 GB |
| Adobe Creative Cloud | ~20-50 GB |
| Xcode | ~15 GB |
| Final Cut Pro | ~5 GB |
| Local large language models (Ollama) | ~4-30 GB |

{% hint style="success" %}
**💡 Capacity Recommendations**

- Light use (5-10 apps): 128 GB
- Medium use (10-20 apps): 256 GB
- Heavy use (20+ apps + data directories): 512 GB or above
{% endhint %}

## Notes <a href="#notes" id="notes"></a>

- External storage must remain connected; migrated apps and data directories cannot be used offline
- Regularly back up data on external storage
- Avoid unplugging external storage during migration
- Quit apps that use external data before unplugging the drive. For mount-migrated directories, click "Unmount" in AppPorts first.
- Do not manually place regular files at AppPorts external data-directory target paths; AppPorts only relinks or normalizes real directories
- If external storage fails, try moving apps back to this Mac with AppPorts after restoring the connection
