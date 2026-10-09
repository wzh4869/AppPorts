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
  title:
    visible: false
  description:
    visible: false
  cover:
    visible: true
    size: "background"
icon: "book-open"
cover: ".gitbook/assets/home-cover.svg"
coverY: 0
---

# AppPorts

## Externe Laufwerke retten die Welt <a href="#externe-laufwerke-retten-die-welt" id="externe-laufwerke-retten-die-welt"></a>

Der macOS-Leitfaden für Installation, Migration und den Alltag mit AppPorts.

<button type="button" class="button primary" data-action="ask" data-icon="gitbook-assistant">Was möchten Sie über AppPorts wissen?</button>

<a href="faststart.md" class="button primary">Schnellstart</a> <a href="AppPorts.md" class="button secondary">Einführung</a>

<h3 align="center">Hier beginnen <a href="#hier-beginnen" id="hier-beginnen"></a></h3>

<p align="center">Wählen Sie einen Leitfaden für den Einstieg, die App-Migration oder die Datenmigration.</p>

<table data-view="cards">
<thead><tr><th width="48"></th><th></th><th></th><th></th><th></th><th></th></tr></thead>
<tbody>
<tr><td><i class="fa-rocket"></i></td><td><h4>Erste Schritte <a href="#start-1" id="start-1"></a></h4></td><td>AppPorts, Installation, Berechtigungen und Grundeinstellungen kennenlernen.</td><td><a data-mention href="faststart.md">Schnellstart</a></td><td><a data-mention href="AppPorts.md">Einführung</a></td><td><a data-mention href="settings.md">Einstellungen</a></td></tr>
<tr><td><i class="fa-layer-group"></i></td><td><h4>Apps migrieren <a href="#start-2" id="start-2"></a></h4></td><td>Apps verschieben oder zurückholen und die Strategien nach App-Typ verstehen.</td><td><a data-mention href="core.md">Kernfunktionen</a></td><td><a data-mention href="migration-strategy/portal.md">Migrationsstrategien</a></td><td><a data-mention href="migration-strategy/strategy-map.md">App-Typen und Strategien</a></td></tr>
<tr><td><i class="fa-database"></i></td><td><h4>Daten migrieren <a href="#start-3" id="start-3"></a></h4></td><td>Anleitungen zu Datenverzeichnissen, Tool-Daten und der Mount-Migration von Containerdaten lesen.</td><td><a data-mention href="datamigrae/operation.md">Migrationsanleitung</a></td><td><a data-mention href="datamigrae/tools.md">Tool-Verzeichniserkennung</a></td><td><a data-mention href="datamigrae/mount-migration.md">Mount-Migration</a></td></tr>
</tbody>
</table>

***

<h3 align="center">Speicher und Wartung <a href="#storage-and-maintenance" id="storage-and-maintenance"></a></h3>

<p align="center">Anforderungen an externe Laufwerke, Updates und Anleitungen zur Fehlerbehebung nachlesen.</p>

<table data-view="cards">
<thead><tr><th width="48"></th><th></th><th></th><th></th><th></th><th></th></tr></thead>
<tbody>
<tr><td><i class="fa-hard-drive"></i></td><td><h4>Externer Speicher <a href="#maintain-1" id="maintain-1"></a></h4></td><td>Laufwerke auswählen und prüfen, wann APFS nötig ist und welche Kompatibilitätsgrenzen gelten.</td><td><a data-mention href="storage-guide.md">Leitfaden für externen Speicher</a></td><td><a data-mention href="why-apfs.md">APFS-Anforderungen</a></td><td><a data-mention href="limitations.md">Kompatibilität und Grenzen</a></td></tr>
<tr><td><i class="fa-arrows-rotate"></i></td><td><h4>Updates und Wartung <a href="#maintain-2" id="maintain-2"></a></h4></td><td>App-Updates, Änderungen in macOS 27 und den Bezug zwischen Containerdaten und Signaturidentität verstehen.</td><td><a data-mention href="migration-strategy/updater-detection.md">Auto-Update-Erkennung</a></td><td><a data-mention href="macos-27.md">Upgrade auf macOS 27</a></td><td><a data-mention href="datamigrae/container-identity.md">Containerdaten und Signierung</a></td></tr>
<tr><td><i class="fa-life-ring"></i></td><td><h4>Fehlerbehebung <a href="#maintain-3" id="maintain-3"></a></h4></td><td>Prüfschritte nach Symptomen, Antworten auf häufige Fragen und Hinweise zu Logs finden.</td><td><a data-mention href="troubleshooting.md">Fehlerbehebung</a></td><td><a data-mention href="faq.md">Häufige Fragen</a></td><td><a data-mention href="logging.md">Protokollierung und Diagnose</a></td></tr>
</tbody>
</table>

***

<h3 align="center">Die Kernfunktionen entdecken <a href="#die-kernfunktionen-entdecken" id="die-kernfunktionen-entdecken"></a></h3>

<p align="center">Die drei Kernfunktionen von AppPorts kennenlernen.</p>

<table data-view="cards">
<thead><tr><th width="48"></th><th></th><th></th><th data-hidden data-card-target data-type="content-ref"></th></tr></thead>
<tbody>
<tr><td><i class="fa-layer-group"></i></td><td><strong>Migration ohne Verknüpfungspfeil</strong></td><td>Große Apps mit einem Klick auf externen Speicher migrieren. Lokal bleibt eine schlanke Launcher-Hülle, Finder zeigt keinen Verknüpfungspfeil an, und Launchpad sowie App-Menüs zeigen die App normal an.</td><td><a href="core.md">core.md</a></td></tr>
<tr><td><i class="fa-arrows-rotate"></i></td><td><strong>Schutz vor automatischen Updates</strong></td><td>Erkennt Apps mit eigenen Updatern wie Sparkle und Electron und bietet „Gesperrte Migration“ an. Ist die lokale App neuer als die externe Kopie, erscheint „Ausstehende Auslagerung“.</td><td><a href="migration-strategy/updater-detection.md">migration-strategy/updater-detection.md</a></td></tr>
<tr><td><i class="fa-database"></i></td><td><strong>Verwaltung von Datenverzeichnissen</strong></td><td>Unterverzeichnisse von ~/Library/, ~/.npm und weitere Datenverzeichnisse auf externen Speicher migrieren. Sandbox-Containerdaten wie WeChat-Chatverläufe werden per Mount-Migration auf ein externes APFS-Laufwerk verschoben; die Signatur bleibt unverändert.</td><td><a href="datamigrae/README.md">datamigrae/README.md</a></td></tr>
</tbody>
</table>

***

<h3 align="center">Mehr entdecken <a href="#keep-exploring" id="keep-exploring"></a></h3>

<table data-view="cards">
<thead><tr><th width="48"></th><th></th><th></th><th data-hidden data-card-target data-type="content-ref"></th></tr></thead>
<tbody>
<tr><td><i class="fa-clock-rotate-left"></i></td><td><h4>Änderungsprotokoll <a href="#explore-1" id="explore-1"></a></h4></td><td>Änderungen und Fehlerbehebungen nach Version nachlesen.</td><td><a href="changelog.md">changelog.md</a></td></tr>
<tr><td><i class="fa-flask"></i></td><td><h4>Versuchsprotokolle <a href="#explore-2" id="explore-2"></a></h4></td><td>Versuche zu Sandbox, Mountpunkten, dem Abziehen von Laufwerken und dem Systemstart nachlesen.</td><td><a href="research/README.md">research/README.md</a></td></tr>
<tr><td><i class="fa-code-pull-request"></i></td><td><h4>Mitwirken <a href="#explore-3" id="explore-3"></a></h4></td><td>Erfahren, wie Beiträge zu Entwicklung, Tests und Dokumentation möglich sind.</td><td><a href="contributing.md">contributing.md</a></td></tr>
</tbody>
</table>
