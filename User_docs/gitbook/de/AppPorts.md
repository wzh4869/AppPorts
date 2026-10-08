# AppPorts Benutzerhandbuch

Dieses Handbuch beschreibt die Kernfunktionen, Designprinzipien und technische Umsetzung von AppPorts. Weitere technische Details finden Sie im [DeepWiki](https://deepwiki.com/wzh4869/AppPorts). Verbesserungsvorschläge können Sie in den [Issues](https://github.com/wzh4869/AppPorts/issues) des Projekts einreichen.

## Überblick <a href="#uberblick" id="uberblick"></a>

AppPorts ist ein Werkzeug für [macOS](https://www.apple.com.cn/os/macos/), mit dem Sie Apps auf externe Speichergeräte migrieren und lokal verknüpfen können. Große Apps lassen sich so auslagern, während das Verhalten von Finder, Launchpad, App-Menüs und Systemupdates möglichst unverändert bleibt.

### Die Philosophie von AppPorts <a href="#die-philosophie-von-appports" id="die-philosophie-von-appports"></a>

| Prinzip | Beschreibung |
|------|------|
| **Vertraute Nutzung** | Migrierte Apps sollen sich für Benutzer und Betriebssystem möglichst wie lokale Apps verhalten |
| **Stabile Verfahren** | Erprobte Verfahren mit höherer Migrationsstabilität haben Vorrang |
| **Geringe Systemlast** | Keine Abhängigkeit von Daemons, um eine dauerhafte Belegung von Systemressourcen zu vermeiden |
| **Breite Internationalisierung** | Möglichst viele Sprachen unterstützen und die Übersetzungsqualität laufend verbessern |
| **Barrierefreiheit** | Möglichst umfassende Unterstützung für Bedienungshilfen bieten |

## Kernfunktionen <a href="#kernfunktionen" id="kernfunktionen"></a>

- **Migration ohne Verknüpfungspfeil**: Große Apps mit einem Klick auf externen Speicher migrieren. Lokal bleibt nur eine schlanke Launcher-Hülle. Finder zeigt keinen Verknüpfungspfeil an; Launchpad und die macOS-App-Menüs zeigen die App weiterhin normal an.
- **Schutz vor automatischen Updates**: Erkennt Apps mit eigenen Updatern wie Sparkle, Electron und Chrome und bietet „Gesperrte Migration“ an, damit Updater die externe App-Kopie nicht löschen oder überschreiben.
- **Hinweis auf neuere lokale Versionen**: Ist die echte lokale App neuer als ihre externe Kopie, zeigt AppPorts „Ausstehende Auslagerung“ an. Sie können die neuere lokale Version migrieren und damit die ältere externe Kopie ersetzen.
- **Versionsabgleich für Stub Portal**: Aktualisiert der App Store eine App auf dem externen Laufwerk, werden die Versionsinformationen des lokalen Stub Portals automatisch angepasst. Das Menü „Öffnen mit“ zeigt damit stets die richtige Version.
- **Eigene Scan-Verzeichnisse**: Zusätzliche lokale App-Verzeichnisse, etwa von JetBrains Toolbox oder Steam, können hinzugefügt werden. AppPorts speichert sie und überwacht Änderungen automatisch.
- **Verwaltung von Codesignaturen**: Wird die App nach der Migration ihres Programmpakets als beschädigt gemeldet, können Sie sie über das Kontextmenü neu signieren. Das Sichern und Wiederherstellen der Originalsignatur wird unterstützt. Sandbox-Apps werden grundsätzlich nicht neu signiert.
- **App Store-Unterstützung ab macOS 15.1**: App Store-Apps lassen sich direkt auf externen Speicher installieren und dort aktualisieren, ohne sie auf den Mac zurückzuholen.
- **Wiederherstellung mit einem Klick**: Apps auf den Mac zurückholen und ihre Verknüpfungen automatisch entfernen. Unterbrochene Migrationen können automatisch wiederhergestellt werden.
- **Verwaltung von Datenverzeichnissen**: App-Datenverzeichnisse wie Unterverzeichnisse von `~/Library/` oder `~/.npm` auf externen Speicher migrieren. Baumansicht, Suche und Sortierung erleichtern die Verwaltung; AppPorts-Metadaten dienen der strengen Prüfung von Wiederherstellungszielen.
- **Mount-Migration von Containerdaten**: Sandbox-Containerdaten wie WeChat-Chatverläufe werden in ein eigenes Volume auf einem externen APFS-Laufwerk migriert, das am ursprünglichen Verzeichnis eingebunden wird. Die App-Signatur bleibt unverändert.
- **Verzeichnismigration**: Beliebige echte Ordner im Benutzerordner auf externen Speicher migrieren, etwa große Projekte, Modelle, Mediensammlungen und Tool-Caches. Erneutes Verlinken, Wiederherstellung und Prüfungen auf überlappende Pfade werden unterstützt.

## Migrationsstrategien <a href="#migrationsstrategien" id="migrationsstrategien"></a>

### Deep Contents Wrapper (Migration des Contents-Verzeichnisses) <a href="#deep-contents-wrapper-migration-des-contents-verzeichnisses" id="deep-contents-wrapper-migration-des-contents-verzeichnisses"></a>

Ein macOS-App-Paket hat normalerweise diese Dateistruktur:

```text
/Applications/Safari.app/
├── Contents/
│   ├── MacOS/
│   ├── Resources/
│   ├── Frameworks/
│   └── Info.plist
└── ...
```

Deep Contents Wrapper migriert den gesamten Inhalt der App auf externen Speicher und erstellt lokal ein leeres `.app`-Verzeichnis mit demselben Namen. Darin liegt lediglich ein symbolischer Link auf das externe `Contents`-Verzeichnis. Da macOS ein vollständiges `.app`-Paket erkennt, zeigt Finder keinen Verknüpfungspfeil an. Symbol, Launchpad und App-Menüs funktionieren normal.

{% hint style="warning" %}
**Dieses Verfahren wird in der aktuellen Version nicht mehr verwendet**

Der Hauptnachteil von Deep Contents Wrapper: Automatische Updater können dem symbolischen Link folgen und Dateien auf dem externen Laufwerk direkt verändern. Dadurch kann die eigentliche App beschädigt werden.
{% endhint %}

### Stub Portal (Launcher-Hülle) <a href="#stub-portal-launcher-hulle" id="stub-portal-launcher-hulle"></a>

Stub Portal erstellt lokal eine minimale `.app`-Hülle, die nur diese vier Bestandteile enthält:

| Bestandteil | Beschreibung |
|------|------|
| `Contents/MacOS/launcher` | Launcher, der `open "/Volumes/External/SomeApp.app"` ausführt |
| `Contents/Resources/` | Von der externen App kopierte Symboldateien |
| `Contents/Info.plist` | Aus der externen `Info.plist` vereinfacht erzeugt: `CFBundleExecutable` wird auf `launcher` gesetzt, `LSUIElement=true` hinzugefügt, damit kein Dock-Symbol erscheint, und alle Update-Konfigurationsschlüssel werden entfernt |
| `Contents/PkgInfo` | Standard-Kennungsdatei mit 4 Byte |

Beim Öffnen der Hülle führt macOS `launcher` aus. Dieser startet mit `open` die echte App auf dem externen Speicher. Lokal gibt es keine symbolischen Links, denen ein Updater bis zur externen App folgen könnte.

### iOS Stub Portal (Launcher-Hülle für iOS) <a href="#ios-stub-portal-launcher-hulle-fur-ios" id="ios-stub-portal-launcher-hulle-fur-ios"></a>

Das Grundprinzip entspricht Stub Portal; nur die Verarbeitung der Symbole unterscheidet sich. iOS-Apps geben ihre Symbole nicht in `Info.plist` an, sondern speichern mehrere `AppIcon.png`-Dateien unter `Wrapper/` oder `WrappedBundle/`. Der Ablauf:

1. Die `AppIcon.png`-Datei mit der höchsten Auflösung suchen.
2. Mit `sips` auf 256×256 Pixel skalieren.
3. Mit `sips` in das Format `.icns` konvertieren.
4. Aus `iTunesMetadata.plist` eine `Info.plist` erzeugen, da iOS-Apps keine standardmäßige `Info.plist` enthalten.

### Whole Symlink (symbolischer Link auf das gesamte Paket) <a href="#whole-symlink-symbolischer-link-auf-das-gesamte-paket" id="whole-symlink-symbolischer-link-auf-das-gesamte-paket"></a>

Das gesamte `.app`-Verzeichnis wird als symbolischer Link auf den externen Speicher angelegt:

```text
/Applications/SomeApp.app → /Volumes/External/SomeApp.app
```

Lokal bleibt nur ein symbolischer Link ohne eigentliche App-Dateien. macOS kann die App normalerweise öffnen, doch Finder zeigt einen Verknüpfungspfeil am Symbol an, und bei Launchpad können Kompatibilitätsprobleme auftreten. Auch automatische Updater können dem Link folgen und externe App-Dateien verändern. AppPorts verwendet dieses Verfahren daher hauptsächlich als Rückfallstrategie.
