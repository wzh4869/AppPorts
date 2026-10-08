# Containerdaten, Sandbox und Signaturidentität

{% hint style="success" %}
**Kurz erklärt**

Daten in `~/Library/Containers/` und `~/Library/Group Containers/` gehören zu **Sandbox-Apps**. Werden sie über „Verknüpfungen“ (symbolische Links) extern ausgelagert, kann die App sie nicht lesen. AppPorts umging dies früher durch erneutes Signieren. Dadurch können Apps unter macOS 27 nicht mehr öffnen und Anmeldesitzungen verloren gehen.

Seit 1.9.0 verwenden Containerdaten [Mount-Migration](mount-migration.md), ohne ein Byte der Signatur zu ändern. Bereits neu signierte Apps müssen neu installiert werden. Siehe [Hinweise zum Upgrade auf macOS 27](../macos-27.md).
{% endhint %}

Diese Seite erklärt die Hintergründe. Öffnet sich deine App bereits nicht mehr, gehe direkt zu den Reparaturschritten in den [Hinweisen zum Upgrade auf macOS 27](../macos-27.md).

## Was ist ein Container? <a href="#was-ist-ein-container" id="was-ist-ein-container"></a>

Die meisten macOS-Apps laufen in einer Sandbox. Das System gibt jeder App einen eigenen Ordner unter `~/Library/Containers/<Bundle ID>/`, in dem sie lesen und schreiben darf. Für App Store-Apps ist dies vorgeschrieben; auch direkt heruntergeladene Apps wie WeChat und QQ Music verwenden meist eine Sandbox. Gemeinsam genutzte Daten mehrerer Apps liegen in `~/Library/Group Containers/`.

Ob eine App eine Sandbox verwendet, zeigt der Eintrag `com.apple.security.app-sandbox` in ihren Berechtigungen:

```bash
codesign -d --entitlements - --xml /Applications/WeChat.app 2>/dev/null | grep -c app-sandbox
# 输出 1 就是沙盒应用
```

Leicht übersehen wird: **Eine Haupt-App ohne Sandbox bedeutet nicht, dass ihre Container beliebig verändert werden dürfen.** Die Hauptprogramme von Chrome und Edge laufen nicht in einer Sandbox, ihre Widgets und Erweiterungen haben aber eigene Container, die Sandbox-Prozessen gehören. AppPorts behandelt deshalb alle Ordner unter `Containers` gleich und richtet sich nicht nach der Haupt-App.

## Drei Wege zum Auslagern von Containerdaten <a href="#drei-wege-zum-auslagern-von-containerdaten" id="drei-wege-zum-auslagern-von-containerdaten"></a>

| Vorgehen | Ergebnis | Grund |
|------|------|------|
| Extern kopieren und am ursprünglichen Ort einen symbolischen Link hinterlassen | Die App öffnet sich, liest aber keine Daten; WeChat meldet einen nicht verwendbaren Speicherort | Die Sandbox prüft das **Ziel** des Links und verweigert Ziele außerhalb des Containers. Externes Laufwerk und Schreibtisch machen keinen Unterschied |
| Symbolischer Link plus Ad-hoc-Neusignierung | Unter macOS 26 und älter nutzbar; unter 27 kann die App direkt nach dem Doppelklick schließen. Für WeChat bestätigt, QQ Music öffnet sich noch | Erst die entfernte Sandbox-Identität macht den Link nutzbar. Gleichzeitig geht die Zuordnung zwischen App und Container verloren, die das System ab 27 prüft |
| Ein externes APFS-Volume am ursprünglichen Ordner einbinden | Funktioniert, Signatur bleibt unverändert | Der Pfad bleibt im Container, also erlaubt die Sandbox den Zugriff. Für die externen Daten erscheint einmal eine Systemabfrage, die du erlauben musst |

Alle drei Wege wurden unter macOS 27 getestet. Die Originalprotokolle stehen in den [Versuchen mit symbolischen Links](https://app.gitbook.com/s/OOJEV4rd6jhAZxZO5wvY/guide/research/sandbox-symlink) und [Mountpunkten](https://app.gitbook.com/s/OOJEV4rd6jhAZxZO5wvY/guide/research/sandbox-mountpoint).

## Was ändert erneutes Signieren genau? <a href="#was-andert-erneutes-signieren-genau" id="was-andert-erneutes-signieren-genau"></a>

Ad-hoc-Neusignierung mit `codesign --force --deep --sign -` entfernt aus der App:

| Verlorener Inhalt | Folge |
|------------|------|
| `com.apple.security.app-sandbox` | Die App läuft nicht mehr mit einer Sandbox-Identität |
| `com.apple.security.application-groups` | Gemeinsame Daten in `Group Containers` sind nicht mehr lesbar |
| `keychain-access-groups` | Anmeldedaten und Datenbankschlüssel im Schlüsselbund sind nicht mehr zugänglich |
| Team ID | Die Systemprüfung, ob dieser Container der App gehört, stimmt nicht mehr |

Die App fällt nicht sofort aus. Als normaler Prozess kann sie unter macOS 26 und älter ihren Container lesen. Unter 27 wird sie bei bereits gespeicherten Zugriffsregeln für ihre alte Signatur wegen nicht übereinstimmender Code-Anforderungen abgewiesen:

```
sandboxd rejected approval request from WeChat for kTCCServiceSystemPolicyAppData
  (/Users/<user>/Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files): denied
runningboardd: termination reported by launchd (0, 0, 65280)
```

Dasselbe neu signierte WeChat auf demselben Rechner:

| System | Verhalten |
|------|------|
| macOS 26.6.2 | Zweieinhalb Tage durchgehend normal genutzt |
| macOS 27.0 | Beendet sich bei jedem Start nach etwa 0.4 Sekunden |

{% hint style="warning" %}
**„Bisher ging es immer“ belegt keine Sicherheit**

Nach der Neusignierung kann die App wochen- oder monatelang normal funktionieren und erst beim nächsten großen Systemupgrade ausfallen, ohne vorherige oder nachträgliche Warnung. Das Zertifikat des ursprünglichen Entwicklers liegt zudem nicht auf deinem Mac. Die entfernten Berechtigungen lassen sich nicht einfach zurücksignieren; die App muss neu installiert werden.
{% endhint %}

## Warum öffnet sich die App aus dem Terminal? <a href="#warum-offnet-sich-die-app-aus-dem-terminal" id="warum-offnet-sich-die-app-aus-dem-terminal"></a>

Das kann bei der Fehlersuche täuschen. Das System rechnet Berechtigungen einem „verantwortlichen Prozess“ zu. Beim Doppelklick im Finder oder Dock ist die App selbst verantwortlich und wird mit ihrer eigenen Identität abgewiesen. Beim Start aus Terminal oder einer App mit Festplattenvollzugriff gilt der übergeordnete Prozess als verantwortlich. Die App nutzt damit dessen Berechtigungen mit.

Ein erfolgreicher Terminalstart ist deshalb keine Reparatur. Entscheidend ist der Doppelklick im Finder oder Dock.

## Selbst prüfen <a href="#selbst-prufen" id="selbst-prufen"></a>

Ersetze `/Applications/WeChat.app` durch die zu prüfende App:

```bash
# 1. 签名身份
codesign -dv --verbose=4 /Applications/WeChat.app 2>&1 | grep -E "Authority|TeamIdentifier|Signature"

# 2. 授权（正常输出一段 XML；只有 Executable= 一行说明已被抹掉）
codesign -d --entitlements - /Applications/WeChat.app

# 3. 容器里有没有指向外置盘的符号链接
find ~/Library/Containers/<Bundle ID> -maxdepth 6 -type l -exec readlink {} \; 2>/dev/null

# 4. 复现一次，看系统有没有拒绝
open -a /Applications/WeChat.app; sleep 3
log show --last 1m --style compact 2>/dev/null | grep -iE "rejected approval request|deny\(1\) file-read-data"
```

| Beobachtung | Bedeutung |
|----------|------|
| `Signature=adhoc` und `TeamIdentifier=not set` | Neu signiert; öffnet sich die App nicht, muss sie neu installiert werden |
| Schritt 3 liefert Ziele unter `/Volumes/...` | Im Container liegen noch alte symbolische Links; zuerst wiederherstellen |
| `kTCCServiceSystemPolicyAppData ... denied` im Protokoll | Zugriff auf den eigenen Container wird wegen der Neusignierung verweigert |
| `deny(1) file-read-data /Volumes/...` im Protokoll | Die Sandbox verweigert das Folgen des symbolischen Links zu externen Daten |

Beide Meldungen können gleichzeitig auftreten. Sie betreffen zwei unabhängige Probleme, die getrennt behoben werden müssen.

## Reparatur <a href="#reparatur" id="reparatur"></a>

Halte die Reihenfolge ein. Sonst sieht auch die neu installierte App noch symbolische Links, und die Neuinstallation scheint wirkungslos:

1. **Containerdaten wiederherstellen:** Unter „App Data“ in AppPorts alle mit „Verknüpft“ markierten Containerordner der App einzeln mit „Wiederherstellen“ lokal zurückholen.
2. **App neu installieren:** Aus offizieller Quelle darüberinstallieren, um Originalsignatur und Sandbox zurückzubringen. Die Containerdaten werden dabei nicht gelöscht.
3. **Bei Bedarf Mount-Migration verwenden:** Danach zeigen Containerordner „Mount-Migration“. Nutze dies, wenn die Daten weiterhin extern liegen sollen.

„Originalsignatur wiederherstellen“ kann in der neuen AppPorts-Version die ursprüngliche App aus einer vollständigen Sicherung zurückholen, ohne den privaten Entwicklerschlüssel. Alte Datensätze mit nur einem Identitätsnamen benötigen eine offizielle Original-App derselben Version oder eine Neuinstallation aus offizieller Quelle. Siehe [Signatur sichern und wiederherstellen](resign.md#signatur-sichern-und-wiederherstellen). Stelle vor der Signatur weiterhin zuerst die im klassischen Modus migrierten Containerordner wieder her.

Die ausführliche Anleitung und den Umgang mit bereits extern gespeicherten Apps findest du unter [Hinweise zum Upgrade auf macOS 27](../macos-27.md#reparatur).

## Ein realer Fall <a href="#ein-realer-fall" id="ein-realer-fall"></a>

Der vollständige Ablauf auf einem echten Rechner im September 2026:

| Zeitpunkt | Ereignis |
|------|------|
| 9/15 04:46 | AppPorts migriert den WeChat-Chatordner extern und hinterlässt einen symbolischen Link |
| 9/15 04:47 | AppPorts signiert WeChat mit Ad-hoc neu |
| 9/16 bis 9/18 | WeChat funktioniert unter macOS 26.6.2 zweieinhalb Tage normal |
| 9/18 04:46 | Upgrade auf macOS 27.0 |
| Ab 9/18 | Jeder Start endet nach etwa 0.4 Sekunden |
| 9/18 05:04 | Nutzer stellt Daten wieder her und signiert erneut; Problem bleibt |
| 9/18 | Daten wiederhergestellt und WeChat von der offiziellen Website neu installiert; normale Funktion, vollständige Chats |

Die Daten waren zu keinem Zeitpunkt beschädigt. Die eigentliche Ursache war die Neusignierung, die vor dem Upgrade keine Symptome zeigte.

## Weitere Dokumentation <a href="#weitere-dokumentation" id="weitere-dokumentation"></a>

- [Hinweise zum Upgrade auf macOS 27](../macos-27.md): Prüfung vor dem Upgrade und Reparatur
- [Mount-Migration](mount-migration.md): die neue Methode verwenden
- [Warum das externe Laufwerk APFS verwenden muss](../why-apfs.md)
- [Neusignierung und Schutz vor Abstürzen](resign.md): heutige Grenzen der Signaturfunktion
