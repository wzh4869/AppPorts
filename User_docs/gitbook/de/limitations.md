---
icon: "triangle-exclamation"
layout:
  width: "default"
  outline:
    visible: true
---

# Kompatibilität und Einschränkungen

## Systemanforderungen <a href="#systemanforderungen" id="systemanforderungen"></a>

| Anforderung | Beschreibung |
|------|------|
| Mindestversion | macOS 12.0 (Monterey) |
| Architektur | Intel x86_64 / Apple Silicon (arm64) |
| Berechtigungen | Festplattenvollzugriff |
| Externer Speicher | Mindestens ein externes Speichergerät erforderlich |

## Funktionskompatibilität <a href="#funktionskompatibilitat" id="funktionskompatibilitat"></a>

### Nach macOS-Version <a href="#nach-macos-version" id="nach-macos-version"></a>

| Funktion | macOS 12.0 - 15.0 | macOS 15.1+ |
|------|:---:|:---:|
| App-Migration (Stub Portal) | ✓ | ✓ |
| Datenverzeichnismigration (symbolische Links) | ✓ | ✓ |
| Mount-Migration von Containerdaten | ✓ (Administratorpasswort zum Einbinden erforderlich) | ✓ (unter 27 ohne Passwort getestet; 13 bis 26 nicht einzeln geprüft) |
| Verzeichnismigration (eigene Ordner) | ✓ | ✓ |
| Verwaltung von Codesignaturen | ✓ | ✓ |
| Migration von App Store-Apps auf externen Speicher | ✗ | ✓ |
| Updates von App Store-Apps direkt auf externem Speicher | ✗ | ✓ |
| Migration von iOS-Apps | ✓ | ✓ |

{% hint style="warning" %}
**App Store-Apps unter macOS vor 15.1**

Vor macOS 15.1 (Sequoia) unterstützt das System die native Installation von App Store-Apps auf externem Speicher nicht. Wenn eine Migration erforderlich ist, müssen Sie in AppPorts „Migration von Mac App Store-Apps erlauben“ manuell aktivieren. Nach einem App-Update müssen Sie die App erneut manuell migrieren, um die externe Kopie zu ersetzen.
{% endhint %}

### Nach App-Typ <a href="#nach-app-typ" id="nach-app-typ"></a>

| App-Typ | Migration | Wiederherstellung | Automatische Updates | Hinweise |
|----------|:---:|:---:|:---:|------|
| Native macOS-Apps | ✓ | ✓ | ✓ | Beste Kompatibilität |
| Sparkle-Apps | ✓ | ✓ | Sperre erforderlich | Die Sperre verhindert Updates innerhalb der App; zum Aktualisieren auf den Mac zurückholen |
| Electron-Apps | ✓ | ✓ | Sperre erforderlich | Wie bei Sparkle-Apps |
| Chrome / Edge (eigene Updater) | ✓ | ✓ | ✓ | Updater installieren lokal und beschädigen die externe Kopie nicht |
| App Store-Apps (macOS 15.1+) | ✓ | ✓ | ✓ | Native externe Installation; der App Store kann direkt aktualisieren |
| App Store-Apps (macOS <15.1) | ✓ | ✓ | Manuell | Nach dem Update erneut migrieren |
| iOS-Apps für Mac | ✓ | ✓ | ✓ | Verwenden iOS Stub Portal |
| System-Apps | ✗ | — | — | Durch SIP geschützt, nicht migrierbar |

{% hint style="warning" %}
**Geschützte Apps migrieren**

Bei App Store-Apps oder Apps im Besitz von root verhindern macOS-Berechtigungen möglicherweise, dass AppPorts die lokale Kopie automatisch löscht oder ersetzt. Wenn ein Hinweis auf eine geschützte App erscheint, verschieben Sie sie zunächst manuell im Finder auf externen Speicher und erstellen Sie anschließend in AppPorts die lokale Verknüpfung.
{% endhint %}

{% hint style="success" %}
**Verknüpfungspfeile im Finder**

Ältere Versionen von AppPorts haben möglicherweise symbolische Links auf das gesamte App-Paket erstellt; Finder zeigt dafür einen Verknüpfungspfeil an. Die aktuelle Version verwendet für normale `.app`-Pakete standardmäßig Stub Portal. Der lokale Zugang zeigt deshalb gewöhnlich keinen Pfeil. Falls weiterhin ein Pfeil sichtbar ist, holen Sie die App auf den Mac zurück und migrieren Sie sie erneut.
{% endhint %}

{% hint style="success" %}
**Zum Status „Ausstehende Auslagerung“**

„Ausstehende Auslagerung“ erfordert vergleichbare App-Versionen und eine zuverlässige Zuordnung derselben App. AppPorts gleicht lokale und externe Apps zuerst anhand der Bundle ID ab und verwendet bei Bedarf den normalisierten App-Namen. Fehlen Versionsnummern, lassen sich ihre Formate nicht vergleichen oder unterscheiden sich die Bundle IDs gleichnamiger Apps, wird dieser Status nicht angezeigt.
{% endhint %}

### Nach Datenverzeichnistyp <a href="#nach-datenverzeichnistyp" id="nach-datenverzeichnistyp"></a>

| Datenverzeichnistyp | Migrationsverfahren | Risiko |
|-------------|:---:|------|
| `~/Library/Application Support/` | Symbolischer Link | Mittel — Apps können Dateisperren oder SQLite-WAL-Protokolle verwenden |
| `~/Library/Preferences/` | Symbolischer Link | Niedrig bis mittel — der Cache von `cfprefsd` kann zum Lesen veralteter Einstellungen führen |
| `~/Library/Containers/` | Einbinden | Mittel — unverschlüsseltes externes APFS-Laufwerk erforderlich; beim ersten Öffnen der App Zugriff erlauben; Laufwerk vor dem Öffnen anschließen |
| `~/Library/Group Containers/` | Einbinden | Mittel — wie oben; gemeinsame Daten betreffen auch andere Apps desselben Teams |
| `~/Library/Caches/` | Symbolischer Link | Niedrig — Caches lassen sich neu erstellen |
| `~/Library/Logs/` | Symbolischer Link | Niedrig — nur Protokolldateien |
| `~/Library/WebKit/` | Symbolischer Link | Mittel — lokaler WebKit-Speicher |
| `~/Library/HTTPStorages/` | Symbolischer Link | Niedrig — Speicher für Netzwerksitzungen |
| `~/Library/Application Scripts/` | Symbolischer Link | Niedrig — Erweiterungsskripte |
| `~/Library/Saved Application State/` | Symbolischer Link | Niedrig — Wiederherstellung des Fensterzustands |
| Dot-Ordner wie `~/.npm` und `~/.m2` | Symbolischer Link | Niedrig — Caches von Entwicklungswerkzeugen |
| Eigene Ordner im Benutzerordner | Symbolischer Link | Abhängig vom Inhalt — schreibende Apps oder Werkzeuge vor der Migration schließen |

{% hint style="warning" %}
**Verzeichnisse mit wichtigen Daten**

WeChat-Chatverläufe, VM-Abbilder, Spielebibliotheken, Datenbanken und Modell-Caches sind häufig groß, werden oft beschrieben und reagieren empfindlich auf Pfade oder Dateisperren. Erstellen Sie vor der Migration eine unabhängige Sicherung. Meldet eine App danach Datenprobleme, stellen Sie die Daten zunächst lokal wieder her und untersuchen Sie dann die Ursache.
{% endhint %}

{% hint style="warning" %}
**Containerdaten nur per Mount-Migration verschieben**

Werden Daten aus `~/Library/Containers/` oder `~/Library/Group Containers/` per symbolischem Link verschoben, können Sandbox-Apps sie nicht lesen. Ältere Versionen umgingen dies durch erneutes Signieren; dadurch lassen sich die Apps unter macOS 27 möglicherweise nicht mehr öffnen. Seit 1.9.0 wird für diese beiden Verzeichnistypen nur die [Mount-Migration](datamigrae/mount-migration.md) angeboten, und das erneute Signieren von Sandbox-Apps wird grundsätzlich verweigert. Hintergründe: [Containerdaten, Sandbox und Signaturidentität](datamigrae/container-identity.md).
{% endhint %}

{% hint style="warning" %}
**Zulässige eigene Verzeichnisse**

Die Verzeichnismigration ist für echte Ordner im Benutzerordner vorgesehen. Dateien, symbolische Links, Pfade innerhalb des externen Ziels, Systemverzeichnisse und Pfade, die verwaltete Einträge enthalten oder in ihnen liegen, können nicht ausgewählt werden.
{% endhint %}

{% hint style="warning" %}
**Konflikte mit Zielverzeichnissen**

AppPorts übernimmt ein externes Verzeichnis nicht allein deshalb, weil seine Größe ähnlich ist. Eine automatische Wiederherstellung erfolgt nur, wenn die AppPorts-Metadaten im externen Verzeichnis vollständig zur aktuellen Aufgabe passen. Andernfalls wird das Verzeichnis als echter Zielkonflikt behandelt und der Vorgang gestoppt.
{% endhint %}

## Nicht migrierbare Inhalte <a href="#nicht-migrierbare-inhalte" id="nicht-migrierbare-inhalte"></a>

### Durch SIP geschützt <a href="#durch-sip-geschutzt" id="durch-sip-geschutzt"></a>

| Pfad | Grund |
|------|------|
| macOS-System-Apps wie Safari und Finder | Systemintegritätsschutz |
| Das übergeordnete Verzeichnis `~/Library/Containers/` | macOS-Systemschutz |

### Enthaltene Pfadverweise <a href="#enthaltene-pfadverweise" id="enthaltene-pfadverweise"></a>

| Pfad | Grund |
|------|------|
| `~/.local` | Enthält Verweise auf ausführbare Dateien; Befehlszeilenwerkzeuge funktionieren nach der Migration möglicherweise nicht mehr |
| `~/.config` | Enthält Konfigurationen mit absoluten Pfaden; Werkzeugeinstellungen funktionieren nach der Migration möglicherweise nicht mehr |

## Anforderungen an externen Speicher <a href="#anforderungen-an-externen-speicher" id="anforderungen-an-externen-speicher"></a>

| Anforderung | Beschreibung |
|------|------|
| Dateisystem | App-Pakete und normale Datenverzeichnisse: APFS, HFS+ oder exFAT. **Containerdaten: nur APFS** |
| Mindestplatz | Abhängig von der Größe der zu migrierenden Apps |
| Schnittstelle | USB, Thunderbolt und NVMe werden unterstützt |
| Verbindung | Der externe Speicher muss nach der Migration angeschlossen bleiben; sonst lassen sich die betroffenen Apps nicht starten |

{% hint style="success" %}
**Empfehlungen zum Dateisystem**

- **APFS**: Empfohlen. Das einzige Format für die Mount-Migration von Containerdaten und zugleich die beste Leistung.
- **HFS+**: Kompatibel mit älteren Macs; keine Migration von Containerdaten.
- **exFAT**: Plattformübergreifend, aber keine Migration von Containerdaten. Für die gemeinsame Nutzung mit Windows können Sie eine separate APFS-Partition verwenden. Belegt exFAT das gesamte Laufwerk, lässt es sich mit den Systemwerkzeugen nicht direkt verkleinern: zuerst sichern und dann neu partitionieren. Gibt es bereits nicht zugewiesenen Speicherplatz, können Sie entsprechend den [Voraussetzungen für die Partitionierung](why-apfs.md#prepare-apfs) eine APFS-Partition erstellen.

Warum Containerdaten APFS benötigen und welche Alternativen wir geprüft haben, erfahren Sie unter [Warum muss das externe Laufwerk APFS verwenden?](why-apfs.md).
{% endhint %}

### Netzlaufwerke <a href="#netzlaufwerke" id="netzlaufwerke"></a>

NAS, SMB, rclone, SFTP und andere eingebundene Netzlaufwerke gehören nicht zu den hauptsächlich geprüften Einsatzbereichen von AppPorts. Sie können funktionieren, erfordern aber eine eigene Prüfung der Mount-Stabilität, konsistenter Pfade, Berechtigungen, erweiterter Attribute und des Verhaltens symbolischer Links. Für Datenverzeichnisse mit fortlaufenden Schreibzugriffen werden Netzlaufwerke nicht als erste Wahl empfohlen.
