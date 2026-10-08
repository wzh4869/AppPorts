# Mount-Migration: Containerdaten auf ein externes Laufwerk verschieben

{% hint style="success" %}
**Kurz erklärt**

Daten in `~/Library/Containers/` und `~/Library/Group Containers/`, etwa WeChat-Chats, QQ Music-Caches und Daten von App Store-Apps, lassen sich nicht über symbolische Links auslagern. Seit AppPorts 1.9.0 wird dafür ein eigenes APFS-Datenvolume auf dem externen Laufwerk erstellt. AppPorts kopiert die Daten hinein und **bindet das Volume im ursprünglichen Ordner ein**. Der sichtbare Pfad und die App-Signatur bleiben unverändert.

Drei Voraussetzungen: Das externe Laufwerk verwendet unverschlüsseltes APFS; beim ersten Öffnen der App erlaubst du den Zugriff; vor dem Öffnen schließt du das Laufwerk an.
{% endhint %}

## Wann wird diese Methode verwendet? <a href="#wann-wird-diese-methode-verwendet" id="wann-wird-diese-methode-verwendet"></a>

Wähle unter „Datenverzeichnisse“ → „App Data“ eine App. Bei Ordnern in den Gruppen `Containers` und `Group Containers` heißt die Schaltfläche „Mount-Migration“ statt „Migrate“. Andere Gruppen wie `Application Support` und Caches sowie Tool-Verzeichnisse und eigene Ordner verwenden weiterhin symbolische Links.

Warum Containerordner besonders sind und warum nicht nur die Sandbox-Eigenschaft der Haupt-App zählt, erklärt [Containerdaten, Sandbox und Signaturidentität](container-identity.md).

## Nach dem Klick auf „Mount-Migration“ <a href="#preflight" id="preflight"></a>

AppPorts prüft den externen Speicher zuerst nur lesend und verändert nichts. Das Ergebnis bestimmt den nächsten Schritt:

| Prüfergebnis | Anzeige | Möglichkeiten |
|---|---|---|
| Unverschlüsseltes APFS, genügend Platz | Erklärung der Migration: freigegebener lokaler Speicher, Zugriffsabfrage beim ersten Öffnen, Laufwerk im Alltag angeschlossen halten | Mit „Daten migrieren“ starten |
| exFAT, NTFS, HFS+ usw. | „Dieser externe Speicher verwendet exFAT“ | „So belassen“, „Anderen Ort auswählen“ oder „Vorbereitung ansehen“ |
| Verschlüsseltes APFS | „Dieser externe Speicher ist verschlüsselt“ | So belassen oder einen unverschlüsselten APFS-Ort wählen |
| Zu wenig Platz | Benötigter und verfügbarer Speicher | Platz schaffen und erneut prüfen oder einen anderen Ort wählen |
| Kein externer Speicher ausgewählt / nicht verbunden | Aufforderung zum Auswählen oder Anschließen | „Externen Speicher auswählen“, „Erneut prüfen“ |

**Wenn die Migration nicht möglich ist, musst du nichts ändern.** Apps, `Application Support`, Caches und Tool-Verzeichnisse lassen sich weiterhin auf dieses Laufwerk migrieren. Nur die Containerdaten bleiben lokal, und die App funktioniert wie gewohnt. Bei Bedarf kannst du später ein [APFS-Laufwerk vorbereiten](../why-apfs.md#prepare-apfs).

{% hint style="info" %}
**Warum verschlüsselte APFS-Laufwerke noch nicht unterstützt werden**

Das neue Datenvolume übernimmt das Passwort des ursprünglichen Volumes nicht. Lokal durch FileVault geschützte Chats würden sonst auf einem Volume ohne Passwort landen. Solange automatisches Entsperren und Passwortverwaltung nicht fertig sind, nimmt AppPorts diese unbemerkte Abschwächung nicht vor. Siehe [Verschlüsselte externe Laufwerke](../why-apfs.md#encrypted-drives).
{% endhint %}

## Vor der Migration <a href="#vor-der-migration" id="vor-der-migration"></a>

- **Verschiebe AppPorts zuerst in den Ordner „Programme“ und öffne es dort.** Der Anmeldeagent benötigt einen dauerhaft gültigen Programmpfad. Beim direkten Start aus Downloads oder einem DMG kann macOS einen temporären App Translocation-Pfad verwenden. Erkennt AppPorts diesen, blockiert es neue Mount-Migrationen und bittet um Installation. Öffne AppPorts nach dem Verschieben oder Aktualisieren einmal, damit der Agentenpfad angepasst wird. Bei unverändertem Pfad wird der Agent nicht neu geladen.
- **Beende die zu migrierende App vollständig.** AppPorts prüft dies und erlaubt keine Migration laufender Apps.
- **AppPorts benötigt Festplattenvollzugriff.** Das Einbinden an einem Containerpfad selbst wird vom System kontrolliert und schlägt ohne Berechtigung fehl.
- **Denke an ein Backup.** Sichere wichtige Daten wie bei jeder Migration vorher selbst. Anschließend liegen diese Daten extern. Time Machine sichert externe Laufwerke normalerweise nicht; prüfe bei Bedarf unter „Systemeinstellungen › Allgemein › Time Machine“ in den Optionen, ob das Laufwerk enthalten ist.

## Was während der Migration geschieht <a href="#was-wahrend-der-migration-geschieht" id="was-wahrend-der-migration-geschieht"></a>

1. Im APFS-Container des externen Laufwerks wird ein Volume erstellt, das nicht automatisch unter `/Volumes` eingebunden wird. Sein Name hat die Form `AppPorts-<Bundle ID>-<目录名>-xxxxxx`. Es teilt sich den freien Speicher mit anderen Volumes; eine Größe muss nicht angegeben werden.
2. Das Volume wird vorübergehend unter `~/Library/Application Support/AppPorts/mounts/` eingebunden. AppPorts kopiert den Ordnerinhalt hinein, schreibt `.appports-mount-metadata.plist` in die Volumewurzel und hängt das Volume wieder aus.
3. Der ursprüngliche Ordner wird als Sicherheitskopie auf demselben Volume umbenannt. Am alten Pfad wird ein leerer Ordner angelegt, das Volume dort eingebunden und seine Identität geprüft.
4. AppPorts schreibt den Datensatz in `~/Library/Application Support/AppPorts/container-mounts.plist`, installiert den Agenten zum erneuten Einbinden bei der Anmeldung und löscht zuletzt die Sicherheitskopie.

Bei zu wenig externem Speicher wird vor dem Erstellen des Volumes angehalten. Tritt vor Abschluss der Migration ein Fehler auf, versucht AppPorts, die Änderungen zurückzurollen. Ist das nicht sicher möglich, bleiben Kopien erhalten und AppPorts zeigt ihre Pfade an.

Ist die Migration abgeschlossen und schlägt nur das abschließende Entfernen der lokalen Sicherheitskopie fehl, bleiben die eingebundenen Daten nutzbar. AppPorts zeigt ausdrücklich den Pfad der noch nicht entfernten Sicherung an. Du musst die Migration nicht wiederholen.

Danach zeigt `mount` das Volume direkt am Containerpfad:

```
/dev/disk7s5 on /Users/<user>/Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files (apfs, local, nodev, nosuid, journaled, noowners, nobrowse)
```

## App nach der Migration erstmals öffnen <a href="#app-nach-der-migration-erstmals-offnen" id="app-nach-der-migration-erstmals-offnen"></a>

Das System fragt, ob die App auf Dateien auf Wechselmedien zugreifen darf. **Klicke auf „Erlauben“.** Das ist die normale macOS-Prüfung für extern gespeicherte Daten und erscheint nur einmal.

Wenn du ablehnst, behandelt die App den Ordner als datenlos und zeigt einen leeren Inhalt. Abhilfe: Öffne Systemeinstellungen → Datenschutz & Sicherheit → Dateien und Ordner (oder „Wechselmedien“) und aktiviere die App. Alternativ setzt `tccutil reset SystemPolicyRemovableVolumes <Bundle ID>` im Terminal die Abfrage zurück, damit sie beim nächsten Mal erneut erscheint.

System-Apps unter `/System/Applications` erhalten keine Abfrage; der Zugriff wird still verweigert. AppPorts migriert diese Apps ohnehin nicht.

## Alltag <a href="#alltag" id="alltag"></a>

**Schließe das externe Laufwerk an, bevor du die App öffnest.** Ohne Laufwerk ist der Mountpunkt nur ein gesperrter leerer Ordner mit Berechtigungen 000. Die App sieht leere Daten, meldet keinen Fehler und schreibt keine zweite lokale Kopie. Nach dem Anschließen bindet AppPorts das Volume automatisch wieder ein; die Daten sind wieder da.

**Diese Datenvolumes sind normalerweise im Finder unsichtbar.** AppPorts bindet sie mit `nobrowse` ein, sodass sie weder in der Seitenleiste noch auf dem Schreibtisch erscheinen. In den ersten ein bis zwei Sekunden nach dem Anschließen kann macOS sie unter `/Volumes` einbinden und kurz ein Symbol anzeigen. Nach dem erneuten Einbinden durch AppPorts verschwindet es. Ältere, noch sichtbare Volumes werden beim nächsten Start von AppPorts oder Anschließen des Laufwerks direkt ausgeblendet; Aushängen ist nicht nötig. Im Festplattendienstprogramm bleiben die Volumes namens `AppPorts-…` sichtbar. **Lösche oder entferne sie dort nicht**: Darauf liegen deine migrierten Daten.

**Beende vor dem Abziehen zuerst die App und wähle in AppPorts „Aushängen“ oder wirf das externe Laufwerk im Finder aus.** Direktes Abziehen kann die Schreibvorgänge der letzten Sekunden verlieren lassen; Datenbanken müssen möglicherweise repariert werden. Im Abziehtest verloren APFS-Volumes nur die letzten Transaktionen. Siehe [Versuchsprotokoll: Abziehtest](https://app.gitbook.com/s/XSPACE_EN/research/unplug-test).

**Wann automatisch wieder eingebunden wird:**

- Wenn AppPorts läuft: beim Start und jedes Mal, wenn ein Volume im System erscheint. Erreichbare, noch nicht eingebundene Datensätze werden eingebunden.
- Ohne geöffnetes AppPorts: Nach erfolgreicher Migration installiert AppPorts einen Anmeldeagenten. Er bindet die Volumes bei der Anmeldung und beim Anschließen eines externen Laufwerks still ein und beendet sich. Nach Wiederherstellung des letzten Datensatzes wird der Agent automatisch deinstalliert.
- Direkt nach dem Systemstart kann eine App noch etwas über zehn Sekunden einen leeren Ordner sehen, weil das System den Agenten nach den Anmeldeobjekten startet. Beende die App und öffne sie erneut. Der Mountpunkt bleibt als Absicherung leer: Selbst eine früher gestartete App liest nur den leeren Ordner und erzeugt keinen abweichenden lokalen Datenbestand. Sobald das Volume eingebunden ist, erholt sie sich von selbst; bei WeChat funktionierte das in allen drei Tests.

{% hint style="warning" %}
**Ältere Systeme wie macOS 12 benötigen das Administratorpasswort**

macOS 27 erlaubt normalen Nutzern, Volumes an Pfaden in ihrem eigenen Ordner einzubinden. Im Test erlaubt macOS 12 dies nicht. Bei diesem Fehler versucht AppPorts es mit dem systemeigenen Administratorpasswortdialog erneut; meist wird einmal pro Migration gefragt. Der Agent hat keine Oberfläche und kann diesen Dialog nicht zeigen. Auf solchen Systemen ist deshalb nach der Anmeldung kein automatisches Einbinden möglich. Öffne AppPorts, das nach dem Passwort fragt, oder klicke unter „App Data“ auf „Einbinden“. Ab welcher Version zwischen 13 und 26 diese Einschränkung entfällt, wurde noch nicht einzeln geprüft.
{% endhint %}

## Status und Aktionen <a href="#statuses" id="statuses"></a>

| Status | Bedeutung | Verfügbare Aktionen |
|------|------|----------|
| Eingebunden | Das Volume liegt am ursprünglichen Ordner; die App kann normal lesen und schreiben | Aushängen, Wiederherstellen |
| Einbindung ausstehend | Das Volume ist erreichbar, aber noch nicht eingebunden, etwa nach dem Anschließen oder manuellen Aushängen | Einbinden, Wiederherstellen |
| Laufwerk nicht verbunden | Das Datenvolume wurde nicht gefunden; meist fehlt das externe Laufwerk | Laufwerk anschließen; AppPorts bindet automatisch wieder ein. Bleibt der Status bestehen, siehe [Fehlersuche](#troubleshooting) |

**Wiederherstellen** kopiert die Daten zurück auf diesen Mac und entfernt anschließend Volume und Datensatz. Das externe Laufwerk muss angeschlossen bleiben:

- Vor Beginn wird der lokale freie Speicher geprüft. Reicht er nicht, wird angehalten; Volume und Datensatz bleiben unverändert.
- Nach dem Kopieren wandelt AppPorts zunächst den Mount-Datensatz in Angaben zur ausstehenden Bereinigung um, damit das Volume nicht automatisch erneut eingebunden wird. Erst dann erfolgt der Wechsel zurück zum lokalen Ordner. AppPorts entfernt nur den leeren Mountpunkt nach dem Aushängen und löscht keine Ordner rekursiv.
- Wird der Wechsel zum lokalen Ordner nicht abgeschlossen, bleiben die zwischengespeicherte lokale Kopie und das externe Volume erhalten. Die lokale Kopie liegt weiterhin im selben Verzeichnis in einem versteckten Ordner namens `.appports-restore-staging-…`. Beachte die von AppPorts angezeigten Pfade und Hinweise zur weiteren Behandlung.
- Ist der lokale Ordner wiederhergestellt und scheitert nur das Löschen des externen Volumes oder das Aktualisieren des Bereinigungsdatensatzes, meldet AppPorts ausdrücklich, dass die Wiederherstellung abgeschlossen ist, die Bereinigung aber noch aussteht. Du kannst die Bereinigung auf der Seite Datenverzeichnisse erneut versuchen. Wiederhole weder die Migration noch die Wiederherstellung.

Wenn du nicht feststellen kannst, ob eine Kopie noch vorhanden ist, kannst du „Nur Bereinigungseintrag entfernen“ wählen; dabei werden weder lokale Sicherungen noch externe Volumes gelöscht oder erneut eingebunden, und verbleibende Kopien musst du selbst bereinigen.

Enthält der Mountpunkt lokale Dateien, etwa weil eine App ohne Laufwerk doch etwas geschrieben hat, verweigert AppPorts das Einbinden, damit diese Daten nicht verdeckt werden. Verschiebe die Dateien zuerst an einen anderen Ort.

## Vor dem Entfernen oder Verschieben von AppPorts <a href="#vor-dem-entfernen-oder-verschieben-von-appports" id="vor-dem-entfernen-oder-verschieben-von-appports"></a>

Mount-Migration benötigt den AppPorts-Anmeldeagenten, um die Volumes nach jeder Anmeldung wieder einzubinden. **Stelle vor dem Löschen von AppPorts die per Mount-Migration migrierten Ordner unter „App Data“ mit „Wiederherstellen“ lokal wieder her.** Andernfalls bleiben die Daten zwar unbeschädigt auf dem externen Volume, werden bei der Anmeldung aber nicht mehr eingebunden. Die App sieht dann einen leeren Ordner. Installiere AppPorts erneut und öffne es einmal, um dies zu beheben.

Wenn du AppPorts nur aktualisierst oder verschiebst, genügt es, die neue Version einmal zu öffnen. Sie richtet den Agenten automatisch auf den neuen Programmpfad aus.

## Fehlersuche <a href="#troubleshooting" id="troubleshooting"></a>

| Symptom | Vorgehen |
|---|---|
| „Laufwerk nicht verbunden“, obwohl das Laufwerk angeschlossen ist | Prüfe im Festplattendienstprogramm, ob die `AppPorts-…`-Volumes noch existieren. Falls ja, aktualisiere über die AppPorts-Symbolleiste oder schließe das Laufwerk erneut an. Wurde das Volume gelöscht, sind diese Daten extern nicht mehr vorhanden und müssen aus einem Backup wiederhergestellt werden |
| Die App zeigt nach dem Öffnen keine Daten | Prüfe zuerst „Eingebunden“. Fehlt der Status, schließe das Laufwerk an oder wähle „Einbinden“. Ist es eingebunden und trotzdem leer, prüfe, ob du beim [ersten Öffnen](#app-nach-der-migration-erstmals-offnen) den Zugriff abgelehnt hast |
| „Einbinden“ meldet einen nicht leeren Mountpunkt | Der Mountpunkt enthält lokale Dateien. Prüfe und verschiebe sie, bevor du erneut einbindest |
| Migration oder Wiederherstellung meldet eine laufende Hintergrundverbindung zum Speicher | Der Anmeldeagent bindet gerade ein. Warte einige Sekunden und versuche es erneut |

## Warum keine Images? <a href="#warum-keine-images" id="warum-keine-images"></a>

Wegen der vielen exFAT-Nutzer haben wir ein APFS-Image (sparsebundle) auf exFAT ernsthaft getestet. Es benötigt keine Zugriffsabfrage, ist ähnlich schnell und lässt sich auf jedem Format speichern. Das wirkte zunächst besser.

Beim Abziehen des USB-Laufwerks während des Schreibens verlor das APFS-Volume nur die letzten Transaktionen, und die Datenbank ließ sich reparieren. Das Image ließ sich dagegen in beiden Durchläufen **überhaupt nicht mehr öffnen**; sämtliche enthaltenen Daten waren unzugänglich. Sein eigenes „Inhaltsverzeichnis“ wird alle paar Sekunden neu geschrieben. Ein Abziehen während dieses Schreibens hinterlässt Bruchstücke ohne Verzeichnis. Die vollständigen Daten stehen im [Versuchsprotokoll: Abziehtest](https://app.gitbook.com/s/XSPACE_EN/research/unplug-test), die Erklärung für Nutzer unter [Warum das externe Laufwerk APFS verwenden muss](../why-apfs.md).

Deshalb werden nur APFS-Volumes unterstützt.

## Technische Details <a href="#technical-details" id="technical-details"></a>

### Ablauf des automatischen erneuten Einbindens <a href="#ablauf-des-automatischen-erneuten-einbindens" id="ablauf-des-automatischen-erneuten-einbindens"></a>

- Der Agent liegt unter `~/Library/LaunchAgents/com.shimoko.AppPorts.container-mount.plist` und führt `AppPorts --mount-agent` aus. Er überwacht auch `/Volumes`: Sobald ein externes Laufwerk eingebunden wird, startet er erneut. Beim gemessenen Start am 2026-09-22 war die Reihenfolge: Anmeldung abgeschlossen → 4.6 Sekunden später Agent gestartet → nach 18 Sekunden beide Volumes wieder an den Containerpfaden. Das war etwa 19 Sekunden schneller als vorher, doch Anmelde-Apps starteten schon nach etwa 3 Sekunden. Zeitachse und Grenzen erklärt das [Versuchsprotokoll: Einbinden vor der Anmeldung](https://app.gitbook.com/s/XSPACE_EN/research/prelogin-mount).
- **Erscheint das Laufwerk spät, gibt der Agent nicht nach einem Versuch auf.** Er überwacht `/Volumes` im eigenen Prozess und wartet auf eine **echte Änderung**, statt in festen Abständen abzufragen. Beim Start ist das System beschäftigt; am 2026-09-23 wurde das Laufwerk erst nach 2 Minuten 33 Sekunden erkannt. Regelmäßige Abfragen würden entweder unnötig `diskutil` starten oder den App-Start verpassen. Ohne Ereignisse prüft er zur Absicherung alle 20 Sekunden erneut, insgesamt 180 Sekunden. Während des Wartens hält er keine Sperre. Gemessen dauerte es vom Erscheinen des Volumes bis zum Einbinden etwa 1 Sekunde.
- **Zuerst unter `/Volumes/<卷名>` nachsehen:** Beim Start und Anschließen bindet das System fast immer zuerst dort ein. `statfs` und das Lesen der Markierung in der Volumewurzel erkennen unser Volume in Mikrosekunden und sparen ein `diskutil info`. Diese Abfrage benötigte beim Start am 2026-09-23 **9 Sekunden** und war der teuerste Schritt. Erst wenn die Erkennung scheitert, etwa wegen eines geänderten Volumenamens oder einer fehlenden Markierung, wird `diskutil` abgefragt.
- **Nach dem Einbinden prüfen:** Ist ein Volume bereits vom System unter `/Volumes` eingebunden, hat `diskutil mount -mountPoint` eine Falle: Es **ignoriert den Mountpunkt, gibt trotzdem `mounted` aus und liefert 0 zurück**. Deshalb wird nach jedem Einbinden der tatsächliche Zielpfad geprüft. Stimmt er nicht, wird der aktuelle Ort erneut ermittelt, das Volume unter `/Volumes` ausgehängt und neu eingebunden, höchstens 3 Durchläufe. Am 2026-09-21 und 09-23 trat dies jeweils einmal auf. Damals wurde der Vorgang als fehlgeschlagen beendet, und WeChat sah anschließend einen leeren Ordner.
- **Nur eigene Volumes bearbeiten:** Vor Einbinden, Aushängen und Wiederherstellen wird die Volume UUID am Mountpunkt mit dem Datensatz verglichen. Liegt dort ein anderes Volume, wird angehalten; es wird weder ausgehängt noch überschrieben oder gelöscht.
- Agent und AppPorts teilen sich eine prozessübergreifende Sperre unter `~/Library/Application Support/AppPorts/operation.lock`. Während AppPorts migriert, aushängt oder wiederherstellt, wartet der Agent bis zu 120 Sekunden. Danach überspringt er den Durchlauf bis zum nächsten Anschließen oder Anmelden. Umgekehrt beginnt AppPorts ohne Sperre keinen Vorgang und bittet um einen späteren Versuch. Die Sperre gilt nur während eines Einbindedurchlaufs. Das minutenlange Warten auf ein Laufwerk blockiert keine AppPorts-Aktionen.
- Kann die Datei mit den Migrationsdatensätzen nicht gelesen werden, überschreibt AppPorts sie nicht als leere Liste, sondern bewahrt sie und verweigert neue oder gelöschte Datensätze.
- `/etc/fstab` wird nicht verwendet: Im Test funktionierte `UUID=` nicht, Gerätenummern ändern sich nach dem Anschließen, und auch das Einbinden durch root beim Start unterliegt der Zugriffskontrolle.

### Spotlight-Index auf dem Volume <a href="#spotlight-index-auf-dem-volume" id="spotlight-index-auf-dem-volume"></a>

Das System behandelt an Containerpfaden eingebundene Volumes wie normale externe Volumes und legt eigene Indizes an. Die `.Spotlight-V100`-Ordner zweier WeChat-Volumes belegten gemessen zusammen 110 MB und wurden nach dem Start weiter beschrieben. Diese App-Daten benötigen keinen Systemindex. Deshalb gilt:

- Nach dem Erstellen wird eine leere `.metadata_never_index` in die Volumewurzel geschrieben. mds überspringt dann das gesamte Volume. Eine bereits erzeugte `.Spotlight-V100` wird dabei entfernt.
- Die Markierung bleibt auf dem Volume; bei einem anderen Anschluss oder beim Wiederherstellen der Mount-Migration muss sie nicht neu gesetzt werden.
- Vor dieser Version migrierte Volumes erhalten die Markierung beim nächsten Einbinden automatisch.
- Sie wird nicht in den lokalen Ordner zurückkopiert: Beim Wiederherstellen wird `.metadata_never_index` wie `.fseventsd` und `.Spotlight-V100` übersprungen.

### Befehle zur eigenen Prüfung <a href="#befehle-zur-eigenen-prufung" id="befehle-zur-eigenen-prufung"></a>

```bash
# 挂载记录
plutil -p ~/Library/Application\ Support/AppPorts/container-mounts.plist

# 当前挂载
mount | grep Containers

# 登录代理
launchctl print gui/$(id -u)/com.shimoko.AppPorts.container-mount

# 卷根有没有防索引标记；系统的索引状态应为 Indexing disabled
ls -la "<挂载点路径>/.metadata_never_index"
mdutil -s "<挂载点路径>"

# 手动重挂（要在有完全磁盘访问权限的终端里执行；旧系统前面加 sudo）
diskutil mount nobrowse -mountPoint "<挂载点路径>" <Volume UUID>
```

## Weitere Dokumentation <a href="#weitere-dokumentation" id="weitere-dokumentation"></a>

- [Warum das externe Laufwerk APFS verwenden muss](../why-apfs.md)
- [Containerdaten, Sandbox und Signaturidentität](container-identity.md)
- [Hinweise zum Upgrade auf macOS 27](../macos-27.md): von der alten Methode umsteigen
- [Versuchsprotokoll: Mountpunkte](https://app.gitbook.com/s/XSPACE_EN/research/sandbox-mountpoint): die ursprünglichen Tests hinter dieser Funktion
