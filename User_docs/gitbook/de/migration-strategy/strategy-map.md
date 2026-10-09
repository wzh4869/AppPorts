---
icon: "table-list"
description: "Die passende Migrationsstrategie für jeden App-Typ finden."
layout:
  width: "default"
  outline:
    visible: true
---

# App-Typen & Strategien

| App-Typ | Container-Klassifizierung | Migrationsstrategie | Sperrschutz | Hinweise |
|---------|---------------------------|-------------------|-------------|----------|
| Native macOS-App (ohne Selbstupdate) | `standaloneApp` | macOS Stub Portal | Nein | z. B. Safari, Finder |
| Sparkle-Selbstupdate-App | `standaloneApp` | macOS Stub Portal | **Ja** | z. B. einige Indie-Entwickler-Apps |
| Electron-App (ohne `app-update.yml`) | `standaloneApp` | macOS Stub Portal | Nein | z. B. VS Code |
| Electron-App (mit `app-update.yml`) | `standaloneApp` | macOS Stub Portal | **Ja** | z. B. Slack, Discord |
| Electron + Sparkle Hybrid-App | `standaloneApp` | macOS Stub Portal | **Ja** | Beide Flags unabhängig erkannt |
| Custom-Updater-Apps (Chrome, Edge) | `standaloneApp` | macOS Stub Portal | Nein | Identifiziert über `LaunchServices`, `KSProductID` usw. |
| iOS-App (Mac-Version) | `standaloneApp` | iOS Stub Portal | Nein | Icons aus `WrappedBundle` extrahiert; keine Signierung |
| Mac App Store-App | `standaloneApp` | macOS Stub Portal | Nein | SIP-Schutz; kann nicht neu signiert werden |
| Einzelner App-Container-Ordner | `singleAppContainer` | Whole App Symlink | Nein | Verzeichnis mit nur 1 `.app`; Whole Symlink |
| App-Suite-Verzeichnis (z. B. Office) | `appSuiteFolder` | Whole App Symlink | Abhängig von internen Apps | Verzeichnis mit 2+ `.app`; Whole Symlink |
| Nicht-`.app`-Pfad | — | Whole App Symlink | — | Pfad mit Erweiterung außer `.app` |

{% hint style="warning" %}
**⚠️ Über Sperrschutz**

Wenn eine App als Sperrung benötigend markiert ist (`needsLock = true`), führt AppPorts nach Abschluss der Migration `chflags -R uchg` auf der externen Speicher-App aus und setzt das immutable Flag. Dies verhindert, dass Selbst-Updater die externe Kopie löschen oder ändern, bedeutet aber auch, dass die App sich nicht selbst aktualisieren kann. Benutzer müssen die App vor einem Update manuell in AppPorts entsperren.
{% endhint %}

{% hint style="success" %}
**💡 Warum Custom-Updater-Apps nicht gesperrt werden**

Apps, die Custom-Updater wie Chrome und Edge verwenden, werden nicht gesperrt. Diese Apps' Updater installieren neue Versionen typischerweise in den lokalen internen Speicher. Aufgrund der Link-Isolations-Eigenschaften von macOS Stub Portal werden App-Dateien auf dem externen Speicher nicht beschädigt.

Wenn AppPorts erkennt, dass die App-Version auf dem lokalen internen Speicher höher ist als auf dem externen Speicher, markiert es die App automatisch mit „Ausstehendes Herausverschieben" und fordert den Benutzer auf, die neueste Version erneut zu migrieren.
{% endhint %}
