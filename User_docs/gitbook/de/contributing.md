# Mitwirken

Vielen Dank für Ihr Interesse an AppPorts! Wir begrüßen es, wenn Community-Mitglieder beitragen, sei es bei der Fehlerbehebung, Dokumentationsverbesserung oder dem Hinzufügen neuer Funktionen.

## Bevor Sie beginnen <a href="#bevor-sie-beginnen" id="bevor-sie-beginnen"></a>

1. Durchsuchen Sie vorhandene [Issues](https://github.com/wzh4869/AppPorts/issues), um sicherzustellen, dass keine Duplikate vorhanden sind
2. Forken Sie das Projekt und klonen Sie es lokal
3. Erstellen Sie einen Feature-Branch (`feat/your-feature`) oder Fix-Branch (`fix/your-fix`) basierend auf dem `develop`-Branch

## Entwicklungsansatz <a href="#entwicklungsansatz" id="entwicklungsansatz"></a>

### Über Vibe Coding <a href="#uber-vibe-coding" id="uber-vibe-coding"></a>

Das AppPorts-Projekt akzeptiert Vibe-Code-Entwicklung mit KI-gestützten Tools (z. B. Cursor, GitHub Copilot, Claude). Wir verstehen, dass KI-Tools die Entwicklungseffizienz erheblich steigern können, **aber die Qualität und Korrektheit des eingereichten Codes liegt in der Verantwortung des Contributors**.

Bei der Verwendung von Vibe Coding:

- **KI-Assistenten müssen die `CLAUDE.md` im Projektstammverzeichnis befolgen**, die Codierungsrichtlinien, Architekturkonventionen, Build-Befehle und Entwicklungsworkflow definiert. Wenn der KI-Assistent diese Datei nicht automatisch liest, fordern Sie ihn in Ihren Prompts explizit auf, zuerst `CLAUDE.md` zu lesen
- Erwägen Sie eine Kreuzvalidierung der generierten Codequalität und Sicherheit mit mehreren KI-Modellen, um blinde Flecken eines einzelnen Modells zu vermeiden
- Vom KI generierter Code kann nicht dem vorhandenen Stil des Projekts entsprechen; bitte manuell vor der Einreichung überprüfen
- KI kann das Verständnis des macOS-Systemverhaltens nicht ersetzen; bitte verifizieren Sie Logik, die Dateisystemoperationen, Code-Signierung und Berechtigungsverwaltung betrifft, manuell
- Änderungen an **Kernfunktionalität** (z. B. Migrationsstrategien, Datenverzeichnismigration, Code-Signierung) müssen zuerst über Issue diskutiert werden, bevor mit der Entwicklung begonnen wird

### Codekonventionen <a href="#codekonventionen" id="codekonventionen"></a>

- Befolgen Sie Swift-Codekonventionen und den vorhandenen Stil des Projekts
- Schreiben Sie klare Swift-Dokumentationskommentare für komplexe Logik
- SwiftUI-Zeichenkettenliterale verwenden die `LocalizedStringKey`-API; AppKit/API-Zeichenketten verwenden `.localized`

## Testanforderungen <a href="#testanforderungen" id="testanforderungen"></a>

{% hint style="warning" %}
**⚠️ Alle PRs müssen Tests bestehen**

Unabhängig von der Entwicklungsmethode müssen die folgenden Tests vor dem Einreichen eines PR abgeschlossen werden. CI führt automatisch Kompilierungs-Smoke-Checks aus; nicht bestandene PRs werden am Merging gehindert.
{% endhint %}

### Erforderlich: Kompilierungs-Smoke-Check <a href="#erforderlich-kompilierungs-smoke-check" id="erforderlich-kompilierungs-smoke-check"></a>

Alle PRs müssen die Xcode Release-Kompilierung bestehen — dies ist eine harte Anforderung für das Merging:

```bash
xcodebuild clean build \
  -scheme "AppPorts" \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath build \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_ENTITLEMENTS="" \
  CODE_SIGNING_ALLOWED=NO
```

### Auf Anfrage: Spezialisierte Tests <a href="#auf-anfrage-spezialisierte-tests" id="auf-anfrage-spezialisierte-tests"></a>

Wenn ein PR die entsprechenden Module betrifft, wird empfohlen, proaktiv die folgenden spezialisierten Tests auszuführen. CI führt diese auch im Advisory-Modus in PRs aus; Ergebnisse blockieren das Merging nicht, geben aber Feedback.

#### Datenverzeichnis-Tests <a href="#datenverzeichnis-tests" id="datenverzeichnis-tests"></a>

Ausführen, wenn PR `DataDirMover`, `DataDirScanner` oder Datenverzeichnismigration-Logik betrifft:

```bash
xcodebuild test \
  -scheme "AppPorts" \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath build \
  -only-testing:"AppPortsTests/DataDirMoverTests" \
  -only-testing:"AppPortsTests/DataDirScannerTests" \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_ENTITLEMENTS="" \
  CODE_SIGNING_ALLOWED=NO
```

#### App-Migrations-Tests <a href="#app-migrations-tests" id="app-migrations-tests"></a>

Ausführen, wenn PR `AppMigrationService`, `AppScanner` oder App-Migrations-Logik betrifft:

```bash
xcodebuild test \
  -scheme "AppPorts" \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath build \
  -only-testing:"AppPortsTests/AppMigrationServiceTests" \
  -only-testing:"AppPortsTests/AppScannerTests" \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_ENTITLEMENTS="" \
  CODE_SIGNING_ALLOWED=NO
```

#### Protokollierungs-Tests <a href="#protokollierungs-tests" id="protokollierungs-tests"></a>

Ausführen, wenn PR `AppLogger` oder Diagnosefunktionalität betrifft:

```bash
xcodebuild test \
  -scheme "AppPorts" \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath build \
  -only-testing:"AppPortsTests/AppLoggerTests" \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_ENTITLEMENTS="" \
  CODE_SIGNING_ALLOWED=NO
```

#### Lokalisierungsprüfung <a href="#lokalisierungsprufung" id="lokalisierungsprufung"></a>

Ausführen, wenn PR benutzersichtbaren Text, Menüs, Popups, Einstellungen oder Fehlermeldungen betrifft:

```bash
xcodebuild test \
  -scheme "AppPorts" \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath build \
  -only-testing:"AppPortsTests/LocalizationAuditTests" \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_ENTITLEMENTS="" \
  CODE_SIGNING_ALLOWED=NO
```

### Testübersicht <a href="#testubersicht" id="testubersicht"></a>

| Testsuite | Module | Wann ausführen |
|-----------|--------|----------------|
| Kompilierungs-Smoke-Check | Gesamtes Projekt | **Erforderlich** (CI erzwungen) |
| `DataDirMoverTests` | Datenverzeichnismigration | Bei Beteiligung von `DataDirMover` |
| `DataDirScannerTests` | Datenverzeichnisscanning | Bei Beteiligung von `DataDirScanner` |
| `AppMigrationServiceTests` | App-Migration | Bei Beteiligung von `AppMigrationService` |
| `AppScannerTests` | App-Scanning | Bei Beteiligung von `AppScanner` |
| `AppLoggerTests` | Protokollierung & Diagnose | Bei Beteiligung von `AppLogger` |
| `LocalizationAuditTests` | Lokalisierung | Bei benutzersichtbarem Text |

## Lokalisierung <a href="#lokalisierung" id="lokalisierung"></a>

- Lokalisierungsanpassung wird empfohlen, ist aber für externe Contributor-PRs nicht obligatorisch
- Wenn ein PR benutzersichtbaren Text hinzufügt, ändert oder löscht, können Sie gerne `Localizable.xcstrings` im selben PR aktualisieren
- Wenn Sie es dieses Mal nicht bearbeiten, erklären Sie bitte kurz den Grund oder Zukunftsplan in der PR-Beschreibung
- SwiftUI-Zeichenkettenliterale verwenden die `LocalizedStringKey`-API; AppKit/API-Zeichenketten verwenden `.localized`
- Dynamischer Text sollte formatierte Schlüssel verwenden, z. B. `String(format: "Sort: %@".localized, value)`
- Die Sprachliste wird in `AppLanguageCatalog` gepflegt; nicht auf mehreren Seiten duplizieren
- Wenn ein PR Menüs, Popups, Einstellungen, Protokollexporte, Fehlermeldungen, Statustext oder Onboarding-Text ändert, wird empfohlen, mindestens die `zh-Hans` und `en` Anzeigeergebnisse zu prüfen

Weitere Regeln siehe: [LOCALIZATION.md](https://github.com/wzh4869/AppPorts/blob/main/LOCALIZATION.md)

## Commit-Konventionen <a href="#commit-konventionen" id="commit-konventionen"></a>

- **Issue zuerst**: Wichtige Funktionsänderungen sollten zuerst über Issue diskutiert werden
- **Atomar halten**: Jeder PR sollte idealerweise nur ein Problem behandeln oder eine Funktion hinzufügen
- **Commit-Nachricht-Vorschläge**:
  - `feat: ...` — Neue Funktion
  - `fix: ...` — Fehlerbehebung
  - `docs: ...` — Dokumentationsupdate
  - `refactor: ...` — Refactoring
  - `test: ...` — Test-bezogen

## PR einreichen <a href="#pr-einreichen" id="pr-einreichen"></a>

1. Stellen Sie sicher, dass Ihr Branch auf dem neuesten `develop`-Branch basiert
2. Pushen Sie in Ihr Fork-Repository
3. Reichen Sie einen Pull Request an AppPorts' `develop`-Branch ein
4. Füllen Sie die erforderlichen Punkte in der PR-Vorlage aus
5. Warten Sie auf bestandene CI-Checks und Code Review

{% hint style="success" %}
**💡 Merge-Effizienz verbessern**

- Halten Sie jeden PR fokussiert auf ein einzelnes Problem oder eine Funktion
- Füllen Sie die Testsituation in der PR-Vorlage ehrlich aus
- Fügen Sie Screenshots für UI-Änderungen bei
{% endhint %}

## Willkommene Beitragsbereiche <a href="#willkommene-beitragsbereiche" id="willkommene-beitragsbereiche"></a>

- Stabilitäts- und Leistungsverbesserungen für Kernlogik wie `AppScanner`
- UI/UX-Optimierung, besonders Verbesserungen, die sich nativ für macOS anfühlen
- Synchronisierung und Verbesserung der chinesischen und englischen Dokumentation
