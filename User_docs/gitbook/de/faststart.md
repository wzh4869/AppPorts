---
icon: "rocket"
description: "AppPorts herunterladen, installieren und die nötigen Berechtigungen für den ersten Start erteilen."
layout:
  width: "default"
  outline:
    visible: true
---

# Erste Schritte

## AppPorts installieren <a href="#appports-installieren" id="appports-installieren"></a>

Die Installation von AppPorts erfordert die folgenden zwei Voraussetzungen:
1. Ein stabiles externes Speichergerät (z. B. eine externe Festplatte)
2. Betriebssystem mindestens macOS 12.0 (Monterey) oder neuer

{% stepper %}
{% step %}

### Herunterladen <a href="#herunterladen" id="herunterladen"></a>

Besuchen Sie die [Github Releases](https://github.com/wzh4869/AppPorts/releases)-Seite, um den neuesten .dmg-Installer herunterzuladen.

{% hint style="success" %}

Wenn der obige Link nicht geöffnet werden kann, besuchen Sie diesen Link, um den Installer zu erhalten: [Direkt-Download](https://file.shimoko.com/AppPorts)
{% endhint %}

![](https://file.shimoko.com/d/openlist/openlist/%E7%BD%91%E7%AB%99%E5%AA%92%E4%BD%93%E6%96%87%E4%BB%B6/download.gif?sign=Xb9FOEqPxR8Q7WLixKzg5NCYcjVzmzq2eh0634xGdG0=:0)


{% endstep %}

{% step %}

### Installieren und starten <a href="#installieren-und-starten" id="installieren-und-starten"></a>
1. Öffnen Sie den .dmg-Installer
2. Ziehen Sie die Anwendung in den Programme-Ordner
3. Starten Sie die Anwendung

![](https://file.shimoko.com/d/openlist/openlist/%E7%BD%91%E7%AB%99%E5%AA%92%E4%BD%93%E6%96%87%E4%BB%B6/install.gif?sign=dg-gU67tz19m6DGdI3NywEAcuqKnyTpWGas0YhZeGfM=:0)


{% endstep %}

{% step %}

### Erforderliche Berechtigungen <a href="#erforderliche-berechtigungen" id="erforderliche-berechtigungen"></a>

Beim ersten Start benötigt AppPorts die „Vollständiger Festplattenzugriff"-Berechtigung, um das /Applications-Verzeichnis zu lesen und zu ändern.
1. Öffnen Sie Systemeinstellungen → Datenschutz & Sicherheit.
Wählen Sie „Vollständiger Festplattenzugriff".
2. Klicken Sie auf die +-Schaltfläche, fügen Sie AppPorts hinzu und schalten Sie den Schalter ein.
3. Starten Sie AppPorts neu.

![](https://file.shimoko.com/d/openlist/openlist/%E7%BD%91%E7%AB%99%E5%AA%92%E4%BD%93%E6%96%87%E4%BB%B6/outh.gif?sign=fTXqbKCR_tZBKDb6p1DziuJYjD9NZAJk-Zsw7c4oOJM=:0)

{% endstep %}
{% endstepper %}

#### App Store App-Selbstupdate-Berechtigung <a href="#app-store-app-selbstupdate-berechtigung" id="app-store-app-selbstupdate-berechtigung"></a>

Benutzer mit macOS 15.1 (Sequoia) oder neuer müssen „Große Apps auf ein externes Laufwerk herunterladen und installieren" im App Store aktivieren, damit AppPorts einen externen Speicher-`/Applications`-Ordner erstellen kann, um automatische Updates für App Store-Apps zu unterstützen.
{% hint style="warning" %}
**⚠️ Systeme vor macOS 15.1 (Sequoia) unterstützen diese Funktion aufgrund von OS-Einschränkungen nicht**

Sie müssen die Einstellung „Migration von App Store-Apps erlauben" in den AppPorts-Einstellungen aktivieren. Nachfolgende App-Updates erfordern eine manuelle Re-Migration zum Überschreiben.
{% endhint %}

1. Öffnen Sie den App Store
2. Klicken Sie in der Statusleiste auf Einstellungen und aktivieren Sie „Große Apps auf ein externes Laufwerk herunterladen und installieren", wobei dasselbe externe Speichergerät wie die AppPorts-externe Speicherbibliothek ausgewählt wird

![](https://file.shimoko.com/d/openlist/openlist/%E7%BD%91%E7%AB%99%E5%AA%92%E4%BD%93%E6%96%87%E4%BB%B6/appstore.gif?sign=JwDPVgjgPb3AulPjZq6Y2KgubkHxmGNqaUawCBRhCEM=:0)
