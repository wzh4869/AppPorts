---
outline: deep
---

# Einstellungen

Die Einstellungsseite von AppPorts ist über das Zahnradsymbol in der oberen rechten Ecke des Hauptfensters erreichbar.

## App Store & iOS Einstellungen

| Einstellung | Beschreibung | Standard |
|-------------|--------------|---------|
| App Store-App-Migration | Ermöglicht die Migration von App Store-Apps. Muss auf macOS-Versionen unter 15.1 manuell aktiviert werden | Aus |
| iOS-App-Migration | Ermöglicht die Migration von iOS/iPadOS-Apps (Mac-Version) | Aus |

::: tip 💡 macOS 15.1+ Benutzer
macOS 15.1 und neuer unterstützt die native App Store-App-Installation auf externe Laufwerke. Es wird empfohlen, „Große Apps auf ein externes Laufwerk herunterladen und installieren" in den App Store-Einstellungen zu aktivieren, anstatt den Migrations-Schalter von AppPorts zu verwenden.
:::

## Signierungs-Einstellungen

| Einstellung | Beschreibung | Standard |
|-------------|--------------|---------|
| Automatisch neu signieren | Führt automatisch Ad-hoc-Neuzeichnung bei assoziierten Apps nach der Datenverzeichnismigration aus | Aus |
| Automatisch neu signieren bei Anmeldung | Signiert migrierte Apps mit abgelaufenen Signaturen bei jeder Benutzeranmeldung automatisch neu | Ein |

Wenn aktiviert, sichert jede Datenverzeichnismigration automatisch die ursprüngliche Signatur und führt die Neuzeichnung aus, um „Beschädigt"-Meldungen nach der Migration zu vermeiden.

Wenn „Automatisch neu signieren bei Anmeldung" aktiviert ist, wird ein LaunchAgent (`com.shimoko.AppPorts.re-sign`) installiert, der bei jeder Benutzeranmeldung die Signatursicherungsdatensätze durchsucht und Apps, deren Ad-hoc-Signaturen abgelaufen sind, automatisch neu signiert. Neuzeichnungsprotokolle werden in die Standardprotokolldatei von AppPorts geschrieben.

::: tip 💡 Automatische Neuzeichnung für verknüpfte Apps
Für verknüpfte Apps (Status: „Verknüpft") löst die automatische Neuzeichnung automatisch den **realen externen App-Pfad** hinter der Stub-Portal-Shell oder dem symbolischen Link auf und stellt sicher, dass Signaturänderungen auf das tatsächliche Anwendungspaket angewendet werden. Sicherung und Neuzeichnung werden anhand der Bundle ID der realen App identifiziert.
:::

## Protokollierungs-Einstellungen

| Einstellung | Beschreibung | Standard |
|-------------|--------------|---------|
| Protokollierung aktivieren | Schreibt Laufzeitprotokolle in Datei | Ein |
| Maximale Protokollgröße | Schneidet automatisch die ältere Hälfte ab, wenn die Protokolldatei diese Größe überschreitet | 2 MB |
| Protokollort | Speicherpfad der Protokolldatei | `~/Library/Application Support/AppPorts/AppPorts_Log.txt` |

### Protokolloperationen

| Operation | Beschreibung |
|-----------|--------------|
| Im Finder anzeigen | Öffnet das Verzeichnis mit der Protokolldatei |
| Diagnosepaket exportieren | Erzeugt eine ZIP-Datei mit Protokollen, Aufzeichnungen und Systeminformationen |
| Protokoll löschen | Löscht den aktuellen Inhalt der Protokolldatei |

Für detaillierte Protokollbeschreibungen siehe [Protokollierung & Diagnose](/de/logging).
