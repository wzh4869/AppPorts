# Status-Badges

AppPorts zeigt den Status von Apps und Datenverzeichnissen mit farbigen, kapselförmigen Badges an. Einige Badges lassen sich anklicken, um weitere Erklärungen oder Handlungsempfehlungen zu öffnen.

## App-Status <a href="#app-status" id="app-status"></a>

### Verknüpfungsstatus <a href="#verknupfungsstatus" id="verknupfungsstatus"></a>

| Badge | Symbol | Farbe | Bedeutung |
|------|------|------|------|
| Verknüpft | `link` | Grün | Die App wurde auf externen Speicher migriert und ein lokaler Zugang erstellt |
| Gesperrte Migration | `lock.fill` | Grün | Die App ist verknüpft und mit `uchg` gesperrt, damit eigene Updater die externe Kopie nicht beschädigen |
| Ungesperrte Migration | `lock.open` | Orange | Die App ist verknüpft, aber nicht gesperrt. Updates innerhalb der App können die externe Kopie löschen oder überschreiben |
| Teilweise verknüpft | `link.badge.plus` | Gelb | Nur einige Bestandteile sind verknüpft, etwa einzelne `.app`-Pakete in einem Verzeichnis |
| Verwaister Link | `link.badge.exclamationmark` | Rot | Die App auf dem externen Speicher fehlt, doch der lokale Zugang existiert noch |
| Nicht verknüpft | `externaldrive.badge.xmark` | Orange | Die App liegt auf externem Speicher und ist noch nicht lokal verknüpft |
| Extern | `externaldrive` | Orange | Die App liegt auf externem Speicher und hat keinen lokalen Zugang |
| Ausstehende Auslagerung | `arrow.up.right.circle` | Cyan | Die echte lokale App ist neuer als die gleichnamige externe Kopie und kann diese durch eine erneute Migration ersetzen |
| Lokal | `macmini` | Sekundärfarbe | Normale lokale, nicht migrierte App. Wird angezeigt, wenn keine anderen Badges zutreffen |

{% hint style="success" %}
**Wann erscheint „Ausstehende Auslagerung“?**

AppPorts gleicht lokale und externe Apps zuerst anhand der Bundle ID ab und verwendet bei Bedarf den normalisierten App-Namen als Rückfallmethode. „Ausstehende Auslagerung“ erscheint nur, wenn beide Versionsnummern vergleichbar sind und die lokale Version neuer ist. Fehlen Versionsangaben, sind ihre Formate nicht vergleichbar oder unterscheiden sich die Bundle IDs gleichnamiger Apps, bleibt der normale lokale Status bestehen. So wird ein versehentliches Überschreiben der externen App vermieden.
{% endhint %}

### Framework-Badges <a href="#framework-badges" id="framework-badges"></a>

| Badge | Symbol | Farbe | Bedeutung | Erklärung beim Anklicken |
|------|------|------|------|----------|
| Sparkle | `arrow.triangle.2.circlepath` | Cyan | Verwendet Sparkle für automatische Updates | Nach der Migration können Updates innerhalb der App zum Verlust der externen Kopie führen. „Gesperrte Migration“ wird empfohlen |
| Electron | `atom` | Indigo | Basiert auf Electron und unterstützt möglicherweise automatische Updates | Nach der Migration können Updates innerhalb der App zum Verlust der externen Kopie führen. „Gesperrte Migration“ wird empfohlen |

### App-Typen <a href="#app-typen" id="app-typen"></a>

| Badge | Symbol | Farbe | Bedeutung |
|------|------|------|------|
| Läuft | `play.fill` | Violett | Die App läuft gerade |
| System | `lock.fill` | Grau | macOS-System-App |
| Nicht-nativ | `iphone` | Rosa | iOS-/iPadOS-App, die auf Apple Silicon ausgeführt wird |
| Store | `applelogo` | Blau | App aus dem Mac App Store |

### Besondere Badges <a href="#besondere-badges" id="besondere-badges"></a>

| Badge | Symbol | Farbe | Bedeutung |
|------|------|------|------|
| Neu signiert | `seal.fill` | Cyan | Die App hat derzeit eine Ad-hoc-Signatur, und AppPorts besitzt eine Signatursicherung |
| Signatur ersetzt | `exclamationmark.shield.fill` | Rot | AppPorts hat die Entwicklersignatur durch eine Ad-hoc-Signatur ersetzt. Unter macOS 27 lässt sich die App möglicherweise nicht öffnen. Anklicken zeigt weitere Informationen; „Reparaturschritte anzeigen“ im Kontextmenü öffnet die Reparaturansicht. Siehe [Upgrade auf macOS 27](macos-27.md) |

{% hint style="success" %}
**Unterschied zwischen „Neu signiert“ und „Signatur ersetzt“**

Beide bedeuten, dass die App derzeit eine Ad-hoc-Signatur hat. Der Unterschied ist die **ursprüngliche Signatur**. Bei „Neu signiert“ hatte die App bereits vorher keine Entwicklersignatur, oder diese lässt sich nicht mehr feststellen. Das erneute Signieren ermöglicht ihr normales Öffnen. Bei „Signatur ersetzt“ wurde eine vorhandene Entwicklersignatur durch eine Ad-hoc-Signatur ersetzt. Sandbox-Apps lassen sich deshalb unter macOS 27 möglicherweise nicht öffnen. AppPorts kennzeichnet sie rot und bietet eine Reparatur an.
{% endhint %}

{% hint style="success" %}
**Besonderheit des Badges „Store“**

Wenn die folgenden Bedingungen erfüllt sind, lässt sich „Store“ anklicken und zeigt Informationen zur nativen Installation auf externem Speicher ab macOS 15.1:

- Die App liegt im Verzeichnis `/Volumes/{drive}/Applications/` des externen Speichers.
- macOS verwaltet die App nativ, und der App Store kann in diesem Verzeichnis direkt inkrementelle Updates ausführen.
{% endhint %}

## Status von Datenverzeichnissen <a href="#status-von-datenverzeichnissen" id="status-von-datenverzeichnissen"></a>

| Status | Farbe | Bedeutung |
|------|------|------|
| Lokal | Sekundärfarbe | Das Verzeichnis liegt lokal und wurde nicht migriert. Ein Schild neben einem Containerverzeichnis weist auf die Mount-Migration hin |
| Verknüpft | Grün | Migration per symbolischem Link abgeschlossen; der lokale Link verweist auf das externe Laufwerk |
| Eingebunden | Violett | Mount-Migration abgeschlossen; das externe Volume ist am ursprünglichen Verzeichnis eingebunden |
| Einbindung ausstehend | Orange | Das Volume der Mount-Migration ist verfügbar, aber nicht eingebunden. Klicken Sie auf „Einbinden“ |
| Laufwerk nicht verbunden | Rot | Das Datenvolume der Mount-Migration wurde nicht gefunden. Meist ist das externe Laufwerk nicht angeschlossen; nach dem Anschließen bindet AppPorts es automatisch wieder ein |
| Normalisierung nötig | Gelb | Ein von AppPorts verwalteter Link verweist auf einen nicht standardmäßigen externen Pfad. „Normalisieren“ kann ihn korrigieren |
| Wartet auf erneute Verknüpfung | Orange | Die externen Daten sind noch vorhanden, aber der lokale Link fehlt. Verwenden Sie „Erneut verlinken“ |
| Vorhandener Symlink | Blau | Der symbolische Link wurde nicht von AppPorts erstellt und kann in die Verwaltung übernommen werden |

## Beispiele für kombinierte App-Badges <a href="#beispiele-fur-kombinierte-app-badges" id="beispiele-fur-kombinierte-app-badges"></a>

Eine App kann mehrere Badges gleichzeitig anzeigen:

```text
[已链接] [Sparkle] [运行中]
```

Bedeutung: Die App wurde auf externen Speicher migriert, verwendet Sparkle für automatische Updates und läuft gerade.

```text
[外部] [商店] [非原生]
```

Bedeutung: Eine über den App Store installierte iOS-App für Mac liegt auf externem Speicher.

```text
[孤立链接]
```

Bedeutung: Die externe App fehlt oder wurde entfernt, während der lokale Zugang noch besteht. Die Verknüpfung muss manuell entfernt werden.

```text
[待迁出]
```

Bedeutung: Lokal liegt die neuere echte App, extern noch eine ältere Kopie. Eine erneute Migration kann die lokale Version auslagern und die ältere externe Kopie ersetzen.
