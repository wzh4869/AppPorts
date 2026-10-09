---
icon: "sliders"
layout:
  width: "default"
  outline:
    visible: true
---

# Einstellungen

Die Einstellungen von AppPorts öffnen Sie über das Zahnradsymbol oben rechts im Hauptfenster.

## App Store- und iOS-Einstellungen <a href="#app-store-und-ios-einstellungen" id="app-store-und-ios-einstellungen"></a>

| Einstellung | Beschreibung | Standard |
|--------|------|--------|
| Migration von Mac App Store-Apps erlauben | Erlaubt die Migration von App Store-Apps. Unter macOS vor 15.1 müssen Sie diese Option für solche Apps manuell aktivieren | Aus |
| Migration von nicht-nativen Apps erlauben | Erlaubt die Migration von iOS-/iPadOS-Apps für Mac | Aus |

{% hint style="success" %}
**Ab macOS 15.1**

macOS 15.1 und neuer unterstützen die native Installation von App Store-Apps auf externem Speicher. Aktivieren Sie vorzugsweise in den App Store-Einstellungen „Große Apps auf eine separate Festplatte laden und installieren“, statt den Schalter für die manuelle Migration in AppPorts zu verwenden.
{% endhint %}

## Signatureinstellungen <a href="#signatureinstellungen" id="signatureinstellungen"></a>

| Einstellung | Position | Beschreibung | Standard |
|--------|------|------|--------|
| Nach Migration neu signieren | Symbolleiste der Datenverzeichnisse; **nur im klassischen Modus sichtbar** | Führt nach einer Migration per symbolischem Link eine Ad-hoc-Signierung der zugehörigen App durch | Aus |
| Automatische Neuzeichnung bei Anmeldung | Einstellungen | Signiert bei der Anmeldung Apps erneut, deren Signatursicherung bereits eine Ad-hoc-Signatur enthält, um nach einem Neustart ungültig gewordene Signaturen zu behandeln. Sandbox-Apps werden übersprungen, außer im klassischen Modus | Bei Neuinstallationen aus; bei Benutzern mit bereits installiertem Anmeldeagenten bleibt die Option aktiviert |

Außerhalb des klassischen Modus werden Sandbox-Apps über keinen Einstiegspunkt neu signiert: Nach einer erneuten Signierung lassen sie sich unter macOS 27 möglicherweise nicht mehr öffnen. Für Containerdaten wird stattdessen die [Mount-Migration](datamigrae/mount-migration.md) verwendet, die keine Änderung der Signatur erfordert.

Neue Einträge mit einer vollständigen Sicherung der Original-App werden vom Anmeldeskript nicht erneut signiert. AppPorts prüft Signaturvorgänge und ersetzt die App auf sichere Weise. Beim Start wird ein bereits installiertes Skript aktualisiert.

„Automatische Neuzeichnung bei Anmeldung“ installiert den LaunchAgent `com.shimoko.AppPorts.re-sign`; seine Protokolle werden in die Standardprotokolldatei von AppPorts geschrieben. Signierung und Sicherung betreffen die echte App auf dem externen Laufwerk, nicht die lokale Launcher-Hülle. Siehe [Erneutes Signieren und Schutz vor Abstürzen](datamigrae/resign.md).

## Klassischer Datenmigrationsmodus (nicht empfohlen) <a href="#classic-data-migration-mode" id="classic-data-migration-mode"></a>

Dieser Schalter am Ende der Einstellungen ist standardmäßig ausgeschaltet. Er ist nur für Benutzer vorgesehen, die noch vom bisherigen Verfahren aus 1.8.1 abhängig sind und vorerst nicht umsteigen können. Wenn das externe Laufwerk kein APFS verwendet, wird empfohlen, den aktuellen Zustand beizubehalten und Containerdaten auf dem Mac zu lassen. Aktivieren Sie den klassischen Modus nicht, um die APFS-Anforderung zu umgehen; siehe [Warum muss das externe Laufwerk APFS verwenden?](why-apfs.md#what-to-do). Vor dem Aktivieren müssen Sie im Bestätigungsdialog „Ich verstehe diese Risiken“ auswählen. Unter macOS 27 weist ein Hinweis neben dem Schalter darauf hin, dass neu signierte Sandbox-Apps möglicherweise nicht mehr geöffnet werden können. Nach dem Aktivieren gelten folgende Unterschiede:

| Element | Aus (Standard) | Ein |
|------|--------------|------|
| Schaltflächen für Containerverzeichnisse | Nur „Mount-Migration“ | „Migrate“ für symbolische Links neben „Mount-Migration“ |
| Dialog zum erneuten Signieren vor einer Containermigration | Wird nicht angezeigt | Wird angezeigt; Standard ist „Nicht zustimmen, nur migrieren“ |
| Erneutes Signieren von Sandbox-Apps | An allen Einstiegspunkten verweigert | Erlaubt; jedes Mal ist eine weitere Bestätigung mit Erläuterung der Folgen nötig |
| Schalter „Nach Migration neu signieren“ | Unsichtbar | In der Symbolleiste der Datenverzeichnisse sichtbar |
| „Normalisieren“, „Erneut verlinken“ und „Linkdetails“ für Containerverzeichnisse | Deaktiviert; Hinweis auf Wiederherstellung mit anschließender Mount-Migration | Verfügbar |

Der klassische Modus stellt das bisherige Verfahren einschließlich seiner Risiken vollständig wieder her. Neu signierte Sandbox-Apps lassen sich unter macOS 27 möglicherweise nicht öffnen; dann müssen die Daten wiederhergestellt und die Apps neu installiert werden. AppPorts kennzeichnet diese Apps mit „Signatur ersetzt“ und erinnert beim Start daran. Siehe [Upgrade auf macOS 27](macos-27.md). Das Ausschalten des klassischen Modus verändert bestehende Migrationen per symbolischem Link nicht; „Wiederherstellen“ bleibt verfügbar.

## Einstellungen zur Mount-Migration <a href="#einstellungen-zur-mount-migration" id="einstellungen-zur-mount-migration"></a>

Die Mount-Migration hat keinen eigenen Schalter. „Bereitschaft“ in den Einstellungen prüft den Festplattenvollzugriff, den Installationsort von AppPorts und das Format des externen Speichers und erklärt, welche Punkte Aufmerksamkeit erfordern. Nach der ersten erfolgreichen Mount-Migration installiert AppPorts den Anmeldeagenten `com.shimoko.AppPorts.container-mount`. Dieser bindet verfügbare Volumes nach der Anmeldung automatisch wieder an ihren Containerverzeichnissen ein. Nach der Wiederherstellung des letzten Mount-Eintrags wird der Agent automatisch entfernt. Auf älteren Systemen wie macOS 12 kann der Agent keinen Dialog für das Administratorpasswort anzeigen; öffnen Sie nach der Anmeldung AppPorts, um das erneute Einbinden abzuschließen.

## Protokolleinstellungen <a href="#protokolleinstellungen" id="protokolleinstellungen"></a>

| Einstellung | Beschreibung | Standard |
|--------|------|--------|
| Protokollierung aktivieren | Laufzeitprotokolle in eine Datei schreiben | Ein |
| Max. Protokollgröße | Bei Überschreitung des Limits wird die ältere Hälfte der Protokolldatei abgeschnitten | 2 MB |
| Protokollspeicherort | Speicherpfad der Protokolldatei | `~/Library/Application Support/AppPorts/AppPorts_Log.txt` |

### Protokollaktionen <a href="#protokollaktionen" id="protokollaktionen"></a>

| Aktion | Beschreibung |
|------|------|
| Im Finder anzeigen | Den Ordner mit der Protokolldatei öffnen |
| Diagnosepaket exportieren | Eine ZIP-Datei mit Protokollen, Vorgangsaufzeichnungen und Systeminformationen erstellen |
| Protokoll löschen | Den Inhalt der aktuellen Protokolldatei löschen |

Weitere Informationen finden Sie unter [Protokollierung und Diagnose](logging.md).

Vor einer manuellen Sicherung, erneuten Signierung oder Wiederherstellung beendet AppPorts den Hintergrund-Signaturvorgang der aktuellen Anmeldung und wartet auf dessen Unterprozesse. So wird eine gerade wiederhergestellte Signatur nicht im Hintergrund überschrieben. Die Konfiguration des Anmeldeagenten bleibt erhalten; bei der nächsten Anmeldung richtet sich sein Verhalten weiter nach dem Schalter. Kann AppPorts nicht bestätigen, dass der Hintergrundvorgang beendet ist, wird die manuelle Aktion abgebrochen.
