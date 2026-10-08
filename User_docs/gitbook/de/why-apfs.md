# Warum das externe Laufwerk APFS verwenden muss

{% hint style="success" %}
**Kurz erklärt**

Seit 1.9.0 erstellt AppPorts beim Migrieren von `~/Library/Containers/` (App-Containerdaten, etwa WeChat-Chats) ein neues Volume im APFS-Container des externen Laufwerks und bindet es direkt am ursprünglichen Ordner ein. Das funktioniert nur mit APFS. Für exFAT / NTFS haben wir auch den Umweg über ein Image getestet. Das Ergebnis: **Nach dem Abziehen war das gesamte Image unbrauchbar.** Deshalb bieten wir diesen Weg nicht an.

**Wenn dein Laufwerk kein APFS verwendet, musst du es nicht sofort ändern.** Apps und normale Datenordner lassen sich weiterhin migrieren. Nur die Containerdaten bleiben vorerst auf diesem Mac; die Apps funktionieren wie gewohnt. Möchtest du sie später migrieren, folge [APFS-Laufwerk vorbereiten](#prepare-apfs). Freier Speicher innerhalb einer exFAT-Partition bedeutet nicht, dass sich daraus direkt eine neue Partition erstellen lässt.
{% endhint %}

## Für welche Vorgänge gilt die Anforderung? <a href="#fur-welche-vorgange-gilt-die-anforderung" id="fur-welche-vorgange-gilt-die-anforderung"></a>

| Vorhaben | Benötigtes Format des externen Laufwerks |
|---|---|
| Die App selbst migrieren (`.app` auf das externe Laufwerk verschieben) | Keine Vorgabe; exFAT funktioniert ebenfalls |
| Normale Datenordner migrieren (`Application Support`, Caches, Tool-Verzeichnisse wie `~/.npm`, eigene Ordner) | Keine Vorgabe |
| **Containerdaten** migrieren (`~/Library/Containers/`, `~/Library/Group Containers/`; hier liegen Daten von WeChat, QQ Music und App Store-Apps) | **APFS erforderlich** |

Nur die dritte Kategorie ist betroffen. Dazu gehören allerdings oft die größten Datenbestände, die man besonders gern auslagern möchte.

## Warum sind Containerdaten besonders? <a href="#warum-sind-containerdaten-besonders" id="warum-sind-containerdaten-besonders"></a>

Die meisten Mac-Apps sind Sandbox-Apps: Das System weist jeder App einen eigenen Ordner unter `~/Library/Containers/` zu, in dem sie lesen und schreiben darf. Das gehört zum Sicherheitskonzept von macOS und ist für Apps im App Store vorgeschrieben.

Früher kopierte AppPorts einen Datenordner auf das externe Laufwerk und hinterließ am ursprünglichen Ort eine „Verknüpfung“ (einen symbolischen Link). Bei normalen Datenordnern funktioniert das gut. Bei Sandbox-Apps hat es **nie wirklich funktioniert**:

- Das System prüft nicht den Ort der Verknüpfung, sondern **ihr Ziel**. Liegt das Ziel auf dem externen Laufwerk, verlässt die App ihren eigenen Ordner, und der Zugriff wird verweigert.
- Es schien nur zu funktionieren, weil bei der Migration zusätzlich neu signiert und damit die Sandbox-Identität entfernt wurde. Ohne Sandbox unterlag die App dieser Beschränkung nicht mehr.
- Unter macOS 27 zeigen sich die Folgen: Wenn das System prüft, ob diese App auf diesen Ordner zugreifen darf, stimmt die entfernte Identität möglicherweise nicht mehr. Die App beendet sich dann eine Sekunde nach dem Doppelklick. Für WeChat ist das bestätigt; QQ Music öffnet sich derzeit noch. Zur Reparatur muss die App neu installiert werden. Die Hintergründe stehen in den [Hinweisen zum Upgrade auf macOS 27](macos-27.md).

Die neue Lösung muss deshalb eine Bedingung erfüllen: **Die Daten müssen auf dem externen Laufwerk liegen, ohne den eigenen Ordner zu „verlassen“.**

## Wie erreicht die neue Lösung das? <a href="#wie-erreicht-die-neue-losung-das" id="wie-erreicht-die-neue-losung-das"></a>

Statt einer Verknüpfung wird ein Speicherbereich auf dem externen Laufwerk **direkt im ursprünglichen Ordner eingebunden**. Stell dir vor, der Ordner bleibt am selben Ort, aber sein „Boden“ wird durch das externe Laufwerk ersetzt.

- Der Pfad, den die App sieht, bleibt unverändert. Die Systemprüfung funktioniert weiterhin.
- Kein Byte der App-Signatur wird verändert. Erneutes Signieren ist unnötig; spätere Systemupgrades verursachen dadurch keine Probleme.
- Ohne das externe Laufwerk ist der Ordner leer. Die App behandelt ihn als datenlos und schreibt keine neuen lokalen Daten, die eine zweite Kopie erzeugen würden.

Damit sich ein Speicherbereich in einem Ordner einbinden lässt, muss er ein eigenständiges **Volume** sein. APFS kann **mehrere Volumes im selben APFS-Container anlegen, die sich dessen freien Speicher teilen**. Dafür sind weder feste Volumegrößen noch eine neue Partitionierung nötig. AppPorts erstellt so für jeden migrierten Ordner ein eigenes Volume. Ein Volume hinzuzufügen ist etwas anderes, als auf dem physischen Laufwerk eine neue Partition anzulegen.

Innerhalb einer exFAT- oder NTFS-Partition lassen sich so keine APFS-Volumes hinzufügen. Soll APFS auf demselben Laufwerk daneben bestehen, benötigt es eine eigene Partition: Nutze bereits nicht zugewiesenen Speicher oder verkleinere die vorhandene Partition mit einem Werkzeug, das ihr Dateisystem unterstützt. Geht das nicht, musst du zuerst sichern und dann neu partitionieren. AppPorts verändert die Partitionierung nicht für dich.

## Der getestete Umweg hat nicht funktioniert <a href="#der-getestete-umweg-hat-nicht-funktioniert" id="der-getestete-umweg-hat-nicht-funktioniert"></a>

Viele Nutzer haben exFAT-Laufwerke. Deshalb haben wir einen Umweg eingehend geprüft: ein Image (sparsebundle, wie bei Time Machine-Backups auf Netzlaufwerken) auf exFAT, darin APFS, und dieses Image am Ordner einbinden.

Zunächst sah das vielversprechend aus. Tests im September 2026 unter macOS 27 zeigten:

- Ein APFS-Laufwerk ist nicht nötig; das Image lässt sich auf jedem Format speichern.
- Beim ersten Zugriff erscheint keine Abfrage zum Zugriff auf Wechselmedien. Beim APFS-Volume erscheint sie einmal.
- Die Lese- und Schreibgeschwindigkeit ist ähnlich wie bei einem APFS-Volume.
- Sogar mitgelieferte Plattform-Apps wie Notizzettel können darauf zugreifen; mit dem APFS-Volume funktioniert das für Plattform-Apps nicht.

Dann testeten wir einen realistischen Fall: **das Laufwerk während des Schreibens direkt abziehen**. Auf einem als APFS formatierten 64 GB-USB-Stick legten wir ein APFS-Volume und ein Image an und banden beide in je einem Ordner ein. Zwei Programme schrieben fortlaufend Datenbanken hinein, ähnlich wie WeChat oder QQ Music Chats und Wiedergabelisten speichern. Nach etwas mehr als zehn Sekunden zogen wir den Stick ab und prüften nach dem erneuten Anschließen, was übrig war.

| | Vor dem Abziehen geschrieben | Nach dem erneuten Anschließen |
|---|---|---|
| APFS-Volume, Durchlauf 1 (normales Schreiben) | 7177 Datensätze | Die Datenbank meldete einmal einen Schaden; ein Reparaturbefehl stellte alle 7172 Datensätze wieder her. Das Dateisystem war intakt |
| APFS-Volume, Durchlauf 2 (App erzwingt das Schreiben auf den Datenträger) | 1906 Datensätze | 1905 intakt; nur der letzte fehlte |
| Image, Durchlauf 1 (normales Schreiben) | 25574 Datensätze | **Das Image ließ sich nicht mehr öffnen**; sein gesamter Inhalt war unzugänglich |
| Image, Durchlauf 2 (App erzwingt das Schreiben auf den Datenträger) | 373 Datensätze | **Das Image ließ sich wieder nicht öffnen** |

Der Unterschied war nicht „mehr oder weniger Verlust“, sondern „ein paar Datensätze fehlen“ gegenüber „alles ist unzugänglich“.

Der Grund ist überschaubar: Ein Image besteht aus vielen 8 MB großen Dateien auf dem externen Laufwerk. Sein eigenes „Inhaltsverzeichnis“ liegt in der ersten Datei und wird alle paar Sekunden neu geschrieben. Beim Abziehen gewährleistet das Laufwerk nur die Integrität der Dateien selbst, nicht die Vollständigkeit eines gerade geschriebenen Inhalts darin. Wird das Inhaltsverzeichnis mitten im Schreiben unterbrochen, besteht das ganze Image nur noch aus Bruchstücken ohne Verzeichnis. Auch erzwungenes Schreiben durch die App hilft nicht: Diese Ebene gehört zum Image und liegt außerhalb der Kontrolle der App.

Wer Time Machine auf einem Netzlaufwerk verwendet, kennt vielleicht die Meldung, das Backup sei beschädigt und müsse neu erstellt werden. Das ist dasselbe Problem. Ein Backup lässt sich neu anlegen, ein verlorener Chatverlauf nicht.

Nach diesem Test haben wir den Image-Ansatz verworfen. Ein Werkzeug zur Datenmigration darf keine Option anbieten, bei der einmaliges Abziehen alles unzugänglich machen kann, auch wenn sie sonst bequemer wäre.

## Was du jetzt tun kannst <a href="#what-to-do" id="what-to-do"></a>

Zuerst: **Möchtest du Containerdaten migrieren?** Falls nicht, musst du nichts ändern. Falls doch, wähle nach dem Zustand deines Laufwerks:

| Deine Situation | Empfehlung |
|---|---|
| Das Laufwerk verwendet bereits unverschlüsseltes APFS | Unter „App Data“ direkt „Mount-Migration“ wählen |
| Das Laufwerk verwendet exFAT / NTFS und soll unverändert bleiben | **So belassen**: Containerdaten bleiben auf diesem Mac; alles andere lässt sich weiter migrieren. Das ist eine ganz normale Nutzung |
| Du hast ein weiteres APFS-Laufwerk oder möchtest eines vorbereiten | Dieses Laufwerk in AppPorts als externen Speicher auswählen und dann die Containerdaten migrieren |
| Du möchtest auf diesem Laufwerk Platz für APFS schaffen | Zuerst sichern und dann [APFS-Laufwerk vorbereiten](#prepare-apfs) befolgen |
| Das Laufwerk verwendet verschlüsseltes APFS | Noch nicht unterstützt; siehe [Verschlüsselte externe Laufwerke](#encrypted-drives) |

Wenn du unsicher bist, klicke in AppPorts auf „Mount-Migration“. Zuerst wird der externe Speicher nur lesend geprüft. AppPorts erklärt die Situation, ohne etwas zu verändern.

**Das Format prüfen:** Wähle das externe Laufwerk im Finder aus, drücke `⌘ I` und lies das Feld „Format“. „APFS“ ist geeignet; „ExFAT“, „NTFS“ und „Mac OS Extended“ (HFS+) fallen in die zweite Tabellenzeile.

## APFS-Laufwerk vorbereiten <a href="#prepare-apfs" id="prepare-apfs"></a>

{% hint style="warning" %}
**Vor Änderungen am Laufwerk**

Sichere bei jeder der folgenden Vorgehensweisen zuerst die Daten auf dem Laufwerk. AppPorts löscht und partitioniert es nicht für dich.
{% endhint %}

**Keine wichtigen Daten auf dem Laufwerk:** Öffne das Festplattendienstprogramm, wähle das Laufwerk und klicke auf „Löschen“. Wähle „APFS“ als Format und „GUID-Partitionstabelle“ als Schema. Dadurch wird das gesamte Laufwerk geleert.

**Daten und vorhandene Partition erhalten:** Prüfe zuerst, ob das Laufwerk die GUID-Partitionstabelle verwendet, und unterscheide dann die folgenden Fälle. „Verfügbar“ im Finder meint freien Speicher innerhalb des Dateisystems, **nicht nicht zugewiesenen Speicher außerhalb der Partition**.

| Aktueller Zustand | APFS-Speicher vorbereiten |
|---|---|
| Ein APFS-Container ist vorhanden | Wähle eines seiner Volumes in AppPorts. AppPorts fügt die APFS-Volumes für die Migration automatisch hinzu; keine neue Partitionierung nötig |
| Genügend nicht zugewiesener Speicher für eine neue Partition ist vorhanden | Darin kann eine APFS-Partition erstellt werden, ohne die bestehende Partition zu löschen. Prüfe vorher den im Festplattendienstprogramm angezeigten Änderungsumfang |
| exFAT belegt das gesamte Laufwerk, ohne nicht zugewiesenen Speicher | Weder das Festplattendienstprogramm noch die Windows-Datenträgerverwaltung können exFAT verkleinern. Mit Systemwerkzeugen musst du zuerst sichern, dann löschen und neu partitionieren und zuletzt die Dateien zurückkopieren |
| NTFS-Partition ohne nicht zugewiesenen Speicher | macOS kann NTFS nicht verlustfrei verkleinern. Verkleinere NTFS gegebenenfalls zuerst in der Windows-Datenträgerverwaltung. Erstelle nach erfolgreicher Freigabe von nicht zugewiesenem Speicher unter macOS eine APFS-Partition. Wie stark verkleinert werden kann, hängt unter anderem von der Dateianordnung ab |
| Mac OS Extended (Journaled HFS+)-Partition oder APFS-Container | macOS unterstützt verlustfreie Größenänderungen. Wenn freier Speicher und Partitionsanordnung es erlauben, kannst du verkleinern und eine APFS-Partition erstellen. Sichere trotzdem vorher |

Bei einem anderen Schema als GUID solltest du die obigen Schritte zum Hinzufügen einer Partition nicht direkt anwenden. Sichere zuerst und partitioniere dann mit GUID neu. Richte anschließend den externen Speicherpfad in AppPorts auf das APFS-Volume.

Grundlage: Laut lokalem `man diskutil` benötigt `resizeVolume` **journaled HFS+**; APFS verwendet `apfs resizeContainer`. [Microsofts Anleitung zum Verkleinern eines Basisvolumes](https://learn.microsoft.com/en-us/windows-server/storage/disk-management/shrink-a-basic-volume) nennt ausdrücklich NTFS oder Volumes ohne Dateisystem, nicht exFAT. Ob ein Drittanbieterwerkzeug exFAT verlustfrei verkleinern kann, muss gesondert geprüft werden. Es ist keine eingebaute Systemfunktion.

**Das Laufwerk auch unter Windows nutzen:** Windows kann APFS standardmäßig weder lesen noch schreiben. Du kannst zwei Partitionen verwenden: exFAT für Windows und APFS für AppPorts. Belegt exFAT bereits das ganze Laufwerk, können die Systemwerkzeuge nicht direkt eine APFS-Partition daraus abzweigen. Sichere zuerst und partitioniere neu.

## Verschlüsselte externe Laufwerke <a href="#encrypted-drives" id="encrypted-drives"></a>

Mount-Migration erstellt im APFS-Container des externen Laufwerks ein neues Datenvolume. Dieses **übernimmt das Passwort des ursprünglichen Volumes nicht**. Bei einer normalen Migration würden lokal durch FileVault geschützte Chats auf einem Volume landen, das jeder nach dem Anschließen lesen kann. Solange automatisches Entsperren bei der Anmeldung und Passwortverwaltung nicht fertig sind, bietet AppPorts auf verschlüsselten APFS-Laufwerken keine Mount-Migration an. Es erstellt auch nicht unbemerkt ein unverschlüsseltes Volume.

Deine Möglichkeiten:

- **So belassen:** Die Containerdaten bleiben auf diesem Mac und werden weiterhin von FileVault geschützt.
- **Ein unverschlüsseltes APFS-Laufwerk oder eine entsprechende Partition verwenden:** Migriere nur in dem Bewusstsein, dass diese Daten extern unverschlüsselt liegen.

## Klassischer Datenmigrationsmodus <a href="#klassischer-datenmigrationsmodus" id="klassischer-datenmigrationsmodus"></a>

Der klassische Datenmigrationsmodus in den Einstellungen stellt die Methode aus 1.8.1 wieder her: symbolische Links und erneutes Signieren. Er benötigt kein APFS, bringt aber alle früheren Risiken mit: Sandbox-Apps können unter macOS 27 nicht mehr öffnen, und Anmeldesitzungen können verloren gehen. Er bleibt nur für Nutzer erhalten, die bereits von der alten Lösung abhängen. **Aktiviere ihn nicht, nur um die APFS-Anforderung zu umgehen.** Siehe [Einstellungen](settings.md#classic-data-migration-mode).

## Häufige Fragen <a href="#haufige-fragen" id="haufige-fragen"></a>

### Was ist mit Containerdaten, die früher auf exFAT migriert wurden? <a href="#was-ist-mit-containerdaten-die-fruher-auf-exfat-migriert-wurden" id="was-ist-mit-containerdaten-die-fruher-auf-exfat-migriert-wurden"></a>

Die frühere Migration verwendete Verknüpfungen und erneutes Signieren, unabhängig vom Format. Ihr Problem ist das Signieren, nicht das Format. Die Lösung steht in den [Hinweisen zum Upgrade auf macOS 27](macos-27.md). Wenn die Containerdaten danach weiterhin extern liegen sollen, folge [APFS-Laufwerk vorbereiten](#prepare-apfs).

### Warum gibt es für exFAT keine Option „Ich kenne das Risiko“? <a href="#warum-gibt-es-fur-exfat-keine-option-„ich-kenne-das-risiko" id="warum-gibt-es-fur-exfat-keine-option-„ich-kenne-das-risiko"></a>

Weil das Risiko nicht gelegentlich ein paar Daten betrifft, sondern beim einmaligen Abziehen alles unzugänglich machen kann. Abziehen gehört zum normalen Gebrauch mobiler Laufwerke. Nach dem Verlust eines Chatverlaufs hilft der Hinweis, man habe vorher gewarnt, niemandem.

### Verändert APFS die Lese- und Schreibgeschwindigkeit? <a href="#verandert-apfs-die-lese-und-schreibgeschwindigkeit" id="verandert-apfs-die-lese-und-schreibgeschwindigkeit"></a>

Nein. APFS ist das native Format von macOS und auf SSDs meist schneller als exFAT. In unseren Tests waren Datenbankschreibvorgänge auf einem APFS-Volume desselben USB-Sticks ungefähr zehnmal schneller als direkte Schreibvorgänge auf exFAT.

### Geht HFS+ (Mac OS Extended) auch? <a href="#geht-hfs-mac-os-extended-auch" id="geht-hfs-mac-os-extended-auch"></a>

Nicht direkt für Mount-Migration. HFS+ kann nicht wie APFS den Speicher zwischen mehreren Volumes teilen. Journaled HFS+ lässt sich mit macOS-Werkzeugen aber verlustfrei verkleinern, um bei passenden Voraussetzungen eine APFS-Partition anzulegen. Das unterscheidet es von exFAT. Sichere trotzdem vorher. Siehe [APFS-Laufwerk vorbereiten](#prepare-apfs).

## Weitere Dokumentation <a href="#weitere-dokumentation" id="weitere-dokumentation"></a>

- [Mount-Migration](datamigrae/mount-migration.md): die neue Methode verwenden
- [Versuchsprotokoll: Abziehtest](https://app.gitbook.com/s/XSPACE_EN/research/unplug-test): Originaldaten des Tests
- [Hinweise zum Upgrade auf macOS 27](macos-27.md): warum die alte Methode unter 27 scheitern kann
- [Leitfaden für externen Speicher](storage-guide.md): allgemeine Empfehlungen zu Anschlüssen, Kapazität und Dateisystemen
