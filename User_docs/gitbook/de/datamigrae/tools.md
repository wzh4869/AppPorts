# Tool-Verzeichnis-Erkennung

![](https://pic.cdn.shimoko.com/tools.png)

AppPorts kann automatisch Datenverzeichnisse (Dot-Folders) erkennen, die von gängigen Entwicklungstools, KI-Tools und Editoren im Home-Verzeichnis des Benutzers erstellt wurden, und unterstützt deren Migration in den externen Speicher. Weitere Tool-Migrationsanforderungen bitte über die Projekt-[Issues](https://github.com/wzh4869/AppPorts/issues) einreichen.

## Prioritätsstufen <a href="#prioritatsstufen" id="prioritatsstufen"></a>

| Priorität | Bedeutung |
|-----------|-----------|
| `critical` | Muss nach der Migration funktionieren; beeinflusst die Kernfunktionalität der Anwendung |
| `recommended` | Große Speicherersparnis; hoher Migrationsnutzen |
| `optional` | Kleine Größe oder wiederherstellbar |

## Entwicklungstools / Paketmanager <a href="#entwicklungstools-paketmanager" id="entwicklungstools-paketmanager"></a>

| Tool | Pfad | Priorität | Beschreibung |
|------|------|-----------|--------------|
| npm | `~/.npm` | recommended | Node.js Paketmanager lokaler Cache |
| Maven | `~/.m2` | recommended | Java Maven Abhängigkeitsrepository |
| Gradle | `~/.gradle` | recommended | Gradle-Build-Cache, Wrapper und Abhängigkeitsdaten |
| Android-Entwicklungsdaten | `~/.android` | recommended | Android-, ADB- und Emulator-Konfiguration und Cache-Daten |
| Flutter/Dart Pub | `~/.pub-cache` | recommended | Dart- und Flutter-Pub-Paketcache |
| Bun | `~/.bun` | recommended | Bun JavaScript-Laufzeitumgebung und Cache |
| Conda | `~/.conda` | recommended | Anaconda/Miniconda Umgebungsdaten |
| Composer | `~/.composer` | optional | PHP Composer globale Pakete |
| Nexus | `~/.nexus` | optional | Nexus Proxy-Cache |

## KI / Machine-Learning-Tools <a href="#ki-machine-learning-tools" id="ki-machine-learning-tools"></a>

| Tool | Pfad | Priorität | Beschreibung |
|------|------|-----------|--------------|
| Ollama | `~/.ollama` | recommended | Lokale Large-Language-Model-Speicherung |
| PyTorch | `~/.cache/torch` | recommended | Vortrainierte Modellgewichte-Cache |
| Whisper | `~/.cache/whisper` | recommended | OpenAI Spracherkennungsmodelle |
| Keras | `~/.keras` | optional | Keras Modelle und Datensätze |
| NLTK | `~/nltk_data` | optional | Natürliche Sprachverarbeitung Korpora |

## KI-Coding-Assistenten <a href="#ki-coding-assistenten" id="ki-coding-assistenten"></a>

| Tool | Pfad | Priorität | Beschreibung |
|------|------|-----------|--------------|
| Lingma | `~/.lingma` | optional | Alibaba Cloud KI-Coding-Assistent |
| Trae IDE | `~/.trae` | optional | ByteDance Trae IDE |
| Trae CN | `~/.trae-cn` | optional | Trae IDE Inlandsversion |
| Trae AICC | `~/.trae-aicc` | optional | Trae AICC |
| MarsCode | `~/.marscode` | optional | ByteDance MarsCode IDE |
| CodeBuddy | `~/.codebuddy` | optional | Tencent KI-Assistent |
| CodeBuddy CN | `~/.codebuddycn` | optional | Tencent CodeBuddy Inlandsversion |
| Qwen | `~/.qwen` | optional | Alibaba Tongyi Qianwen |
| ClawBOT | `~/.clawdbot` | optional | ClawdBOT KI-Tool |

## Editoren / IDEs <a href="#editoren-ides" id="editoren-ides"></a>

| Tool | Pfad | Priorität | Beschreibung |
|------|------|-----------|--------------|
| VS Code | `~/.vscode` | optional | Erweiterungen und Konfiguration |
| Cursor | `~/.cursor` | optional | Cursor KI-Editor |
| Spring Tool Suite 4 | `~/.sts4` | optional | STS4-Daten |

## Browser / Testautomatisierung <a href="#browser-testautomatisierung" id="browser-testautomatisierung"></a>

| Tool | Pfad | Priorität | Beschreibung |
|------|------|-----------|--------------|
| Selenium | `~/.cache/selenium` | optional | Automatisch heruntergeladene Browser-Treiber |
| Chromium | `~/.chromium-browser-snapshots` | optional | Browser-Snapshots von Playwright/Selenium |
| WDM | `~/.wdm` | optional | WebDriver Manager Treiberprogramme |

## Laufzeitumgebungen <a href="#laufzeitumgebungen" id="laufzeitumgebungen"></a>

| Tool | Pfad | Priorität | Beschreibung |
|------|------|-----------|--------------|
| Docker | `~/.docker` | optional | Docker Desktop CLI-Konfiguration und Kontext |
| OpenClaw | `~/.openclaw` | optional | OpenClaw Tool-Daten |

## Nicht-migrierbare Systemverzeichnisse <a href="#nicht-migrierbare-systemverzeichnisse" id="nicht-migrierbare-systemverzeichnisse"></a>

Die folgenden Verzeichnisse enthalten absolute Pfadreferenzen oder ausführbare Dateien; deren Migration kann Tool-Fehler verursachen. **Migration wird nicht unterstützt**:

| Pfad | Grund |
|------|-------|
| `~/.local` | Enthält ausführbare Pfadreferenzen; Befehlszeilentools können nach der Migration fehlschlagen |
| `~/.config` | Enthält absolute Pfadkonfigurationen; Tool-Konfigurationen können nach der Migration fehlschlagen |

## Conda-Distribution Spezialbehandlung <a href="#conda-distribution-spezialbehandlung" id="conda-distribution-spezialbehandlung"></a>

Wenn die Bundle ID oder der Name einer App `anaconda`, `conda` oder `miniconda` enthält, scannt AppPorts zusätzlich die folgenden Pfade, um die Conda-Installationswurzel zu identifizieren:

- `/opt/anaconda3`
- `/opt/miniconda3`
- `/usr/local/anaconda3`
- `/usr/local/miniconda3`
- `~/anaconda3`
- `~/miniconda3`
