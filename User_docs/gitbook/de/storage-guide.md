# Leitfaden für externen Speicher

Die Zuverlässigkeit des externen Speichers wirkt sich direkt auf den Start migrierter Apps, den Zugriff auf Datenverzeichnisse und spätere Updates aus. Eine externe SSD mit stabiler Leistung und ausreichend Kapazität wird empfohlen.

## Empfohlene Ausstattung <a href="#empfohlene-ausstattung" id="empfohlene-ausstattung"></a>

| Merkmal | Empfehlung | Beschreibung |
|--------|--------|------|
| Kapazität | 256 GB oder mehr | Der tatsächliche Bedarf hängt von Anzahl und Größe der migrierten Apps und Datenverzeichnisse ab |
| Schnittstelle | USB 3.0 oder neuer / Thunderbolt | USB 2.0 ist langsam; die Migration großer Apps dauert entsprechend länger |
| Dateisystem | APFS | Das einzige unterstützte Format für Containerdaten; bietet außerdem Klone, Snapshots und gemeinsame Speichernutzung bei bester Leistung |

## Schnittstellen im Vergleich <a href="#schnittstellen-im-vergleich" id="schnittstellen-im-vergleich"></a>

| Schnittstelle | Theoretische Geschwindigkeit | Tatsächliche Migrationsgeschwindigkeit | Einsatz |
|------|----------|-------------|----------|
| USB 2.0 | 480 Mbps | ~30 MB/s | Nicht empfohlen; die Migration großer Apps dauert lange |
| USB 3.0 (USB-A) | 5 Gbps | ~350 MB/s | Für grundlegende Anforderungen ausreichend |
| USB 3.1 Gen 2 (USB-C) | 10 Gbps | ~700 MB/s | Empfohlen |
| Thunderbolt 3/4 | 40 Gbps | ~2500 MB/s | Beste Leistung |
| NVMe (Thunderbolt) | 40 Gbps | ~2800 MB/s | Beste Leistung |

## Empfehlungen zum Dateisystem <a href="#empfehlungen-zum-dateisystem" id="empfehlungen-zum-dateisystem"></a>

### APFS (empfohlen) <a href="#apfs-empfohlen" id="apfs-empfohlen"></a>

- Unterstützt Klone, Snapshots und gemeinsame Speichernutzung.
- Beste Leistung, besonders auf SSDs.
- Native macOS-Unterstützung.
- **Die Migration von Containerdaten aus `~/Library/Containers/`, etwa WeChat-Chatverläufen, unterstützt ausschließlich externe APFS-Laufwerke.** Gründe und Versuche finden Sie unter [Warum muss das externe Laufwerk APFS verwenden?](why-apfs.md).

### HFS+ <a href="#hfs" id="hfs"></a>

- Gute Kompatibilität, geeignet für ältere Macs.
- Keine Unterstützung für Klone oder Snapshots.
- Geeignet für mechanische Festplatten.

### exFAT <a href="#exfat" id="exfat"></a>

- Gute plattformübergreifende Kompatibilität für die gemeinsame Nutzung mit macOS und Windows.
- Keine Unterstützung für Hardlinks oder Klone.
- Vergleichsweise geringere Leistung.
- Geeignet für den Dateiaustausch zwischen mehreren Systemen.
- Containerdaten können nicht migriert werden. Wenn Sie auch Windows verwenden, können Sie AppPorts eine separate APFS-Partition bereitstellen. Belegt exFAT das gesamte Laufwerk, können die Systemwerkzeuge es nicht direkt verkleinern: Sichern Sie die Daten und partitionieren Sie das Laufwerk anschließend neu. Siehe [Voraussetzungen und Vorgehen bei der Partitionierung](why-apfs.md#prepare-apfs).

## Speicherbedarf planen <a href="#speicherbedarf-planen" id="speicherbedarf-planen"></a>

Wie viel externen Speicher AppPorts nach der Migration belegt, hängt von der Größe der Apps und Datenverzeichnisse ab. Einige typische Größen zur Orientierung:

| App-Typ | Größe |
|----------|------|
| Chrome | ~500 MB |
| Microsoft Office | ~5 GB |
| Adobe Creative Cloud | ~20-50 GB |
| Xcode | ~15 GB |
| Final Cut Pro | ~5 GB |
| Lokale große Sprachmodelle (Ollama) | ~4-30 GB |

{% hint style="success" %}
**Empfohlene Kapazität**

- Leichte Nutzung (5-10 Apps): 128 GB.
- Mittlere Nutzung (10-20 Apps): 256 GB.
- Intensive Nutzung (20+ Apps und Datenverzeichnisse): 512 GB oder mehr.
{% endhint %}

## Hinweise <a href="#hinweise" id="hinweise"></a>

- Der externe Speicher muss angeschlossen bleiben. Ohne Verbindung sind migrierte Apps und Datenverzeichnisse nicht verfügbar.
- Sichern Sie wichtige externe Daten regelmäßig.
- Trennen Sie den externen Speicher während der Migration nicht, damit Kopiervorgänge nicht unterbrochen werden und der Zustand konsistent bleibt.
- Beenden Sie vor dem Trennen Apps, die externe Daten verwenden. Für per Mount-Migration verschobene Verzeichnisse sollten Sie zunächst in AppPorts „Aushängen“ wählen.
- Belegen Sie die Zielpfade externer AppPorts-Datenverzeichnisse nicht manuell mit gewöhnlichen Dateien. AppPorts verlinkt oder normalisiert nur echte Verzeichnisse.
- Wenn der externe Speicher eine Störung hat, können Sie nach Wiederherstellung der Verbindung versuchen, die Apps mit AppPorts auf den Mac zurückzuholen.
