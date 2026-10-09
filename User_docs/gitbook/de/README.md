---
description: "Der macOS-Leitfaden für Installation, Migration und den Alltag mit AppPorts."
layout:
  width: "wide"
  outline:
    visible: false
  pagination:
    visible: false
  metadata:
    visible: false
icon: "book-open"
---

# AppPorts

## Externe Laufwerke retten die Welt <a href="#externe-laufwerke-retten-die-welt" id="externe-laufwerke-retten-die-welt"></a>

<a href="faststart.md" class="button primary">Schnellstart</a> <a href="AppPorts.md" class="button secondary">Einführung</a>

**Hier beginnen**

<table data-view="cards">
<thead><tr><th width="48"></th><th></th><th></th><th data-hidden data-card-target data-type="content-ref"></th></tr></thead>
<tbody>
<tr><td><i class="fa-rocket"></i></td><td><strong>Schnellstart</strong></td><td>AppPorts herunterladen, installieren und die nötigen Berechtigungen für den ersten Start erteilen.</td><td><a href="faststart.md">faststart.md</a></td></tr>
<tr><td><i class="fa-hard-drive"></i></td><td><strong>Leitfaden für externen Speicher</strong></td><td>Auswahl, Formatierung und Anforderungen an externe Laufwerke verstehen.</td><td><a href="storage-guide.md">storage-guide.md</a></td></tr>
<tr><td><i class="fa-wrench"></i></td><td><strong>Fehlerbehebung</strong></td><td>Passende Prüfungen und Lösungen für Berechtigungen, Migrationszustände und typische Probleme finden.</td><td><a href="troubleshooting.md">troubleshooting.md</a></td></tr>
</tbody>
</table>

**Die Kernfunktionen entdecken**

<table data-view="cards">
<thead><tr><th width="48"></th><th></th><th></th><th data-hidden data-card-target data-type="content-ref"></th></tr></thead>
<tbody>
<tr><td><i class="fa-layer-group"></i></td><td><strong>Migration ohne Verknüpfungspfeil</strong></td><td>Große Apps mit einem Klick auf externen Speicher migrieren. Lokal bleibt eine schlanke Launcher-Hülle, Finder zeigt keinen Verknüpfungspfeil an, und Launchpad sowie App-Menüs zeigen die App normal an.</td><td><a href="core.md">core.md</a></td></tr>
<tr><td><i class="fa-arrows-rotate"></i></td><td><strong>Schutz vor automatischen Updates</strong></td><td>Erkennt Apps mit eigenen Updatern wie Sparkle und Electron und bietet „Gesperrte Migration“ an. Ist die lokale App neuer als die externe Kopie, erscheint „Ausstehende Auslagerung“.</td><td><a href="migration-strategy/updater-detection.md">migration-strategy/updater-detection.md</a></td></tr>
<tr><td><i class="fa-database"></i></td><td><strong>Verwaltung von Datenverzeichnissen</strong></td><td>Unterverzeichnisse von ~/Library/, ~/.npm und weitere Datenverzeichnisse auf externen Speicher migrieren. Sandbox-Containerdaten wie WeChat-Chatverläufe werden per Mount-Migration auf ein externes APFS-Laufwerk verschoben; die Signatur bleibt unverändert.</td><td><a href="datamigrae/README.md">datamigrae/README.md</a></td></tr>
</tbody>
</table>
