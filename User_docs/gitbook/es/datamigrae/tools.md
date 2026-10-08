# Detección de Directorios de Herramientas

![](https://pic.cdn.shimoko.com/tools.png)

AppPorts puede detectar automáticamente directorios de datos (dot-folders) creados por herramientas de desarrollo comunes, herramientas de IA y editores en el directorio home del usuario, y admite migrarlos al almacenamiento externo. Para más requisitos de migración de herramientas, envíelos a los [Issues](https://github.com/wzh4869/AppPorts/issues) del proyecto.

## Niveles de Prioridad <a href="#niveles-de-prioridad" id="niveles-de-prioridad"></a>

| Prioridad | Significado |
|-----------|-------------|
| `critical` | Debe funcionar después de la migración; afecta la funcionalidad principal de la aplicación |
| `recommended` | Gran ahorro de espacio; alto beneficio de migración |
| `optional` | Tamaño pequeño o reconstruible |

## Herramientas de Desarrollo / Gestores de Paquetes <a href="#herramientas-de-desarrollo-gestores-de-paquetes" id="herramientas-de-desarrollo-gestores-de-paquetes"></a>

| Herramienta | Ruta | Prioridad | Descripción |
|-------------|------|-----------|-------------|
| npm | `~/.npm` | recommended | Caché local del gestor de paquetes Node.js |
| Maven | `~/.m2` | recommended | Repositorio de dependencias Java Maven |
| Gradle | `~/.gradle` | recommended | Caché de compilación, Wrapper y datos de dependencias de Gradle |
| Datos de desarrollo Android | `~/.android` | recommended | Configuración y cachés de Android, ADB y emuladores |
| Flutter/Dart Pub | `~/.pub-cache` | recommended | Caché de paquetes Pub para Dart y Flutter |
| Bun | `~/.bun` | recommended | Tiempo de ejecución JavaScript y caché de Bun |
| Conda | `~/.conda` | recommended | Datos de entorno Anaconda/Miniconda |
| Composer | `~/.composer` | optional | Paquetes globales PHP Composer |
| Nexus | `~/.nexus` | optional | Caché proxy de Nexus |

## Herramientas de IA / Aprendizaje Automático <a href="#herramientas-de-ia-aprendizaje-automatico" id="herramientas-de-ia-aprendizaje-automatico"></a>

| Herramienta | Ruta | Prioridad | Descripción |
|-------------|------|-----------|-------------|
| Ollama | `~/.ollama` | recommended | Almacenamiento de modelos de lenguaje grandes locales |
| PyTorch | `~/.cache/torch` | recommended | Caché de pesos de modelos preentrenados |
| Whisper | `~/.cache/whisper` | recommended | Modelos de reconocimiento de voz de OpenAI |
| Keras | `~/.keras` | optional | Modelos y conjuntos de datos de Keras |
| NLTK | `~/nltk_data` | optional | Corpus de procesamiento de lenguaje natural |

## Asistentes de Codificación con IA <a href="#asistentes-de-codificacion-con-ia" id="asistentes-de-codificacion-con-ia"></a>

| Herramienta | Ruta | Prioridad | Descripción |
|-------------|------|-----------|-------------|
| Lingma | `~/.lingma` | optional | Asistente de codificación con IA de Alibaba Cloud |
| Trae IDE | `~/.trae` | optional | Trae IDE de ByteDance |
| Trae CN | `~/.trae-cn` | optional | Versión doméstica de Trae IDE |
| Trae AICC | `~/.trae-aicc` | optional | Trae AICC |
| MarsCode | `~/.marscode` | optional | MarsCode IDE de ByteDance |
| CodeBuddy | `~/.codebuddy` | optional | Asistente de IA de Tencent |
| CodeBuddy CN | `~/.codebuddycn` | optional | Versión doméstica de CodeBuddy de Tencent |
| Qwen | `~/.qwen` | optional | Tongyi Qianwen de Alibaba |
| ClawBOT | `~/.clawdbot` | optional | Herramienta de IA ClawdBOT |

## Editores / IDEs <a href="#editores-ides" id="editores-ides"></a>

| Herramienta | Ruta | Prioridad | Descripción |
|-------------|------|-----------|-------------|
| VS Code | `~/.vscode` | optional | Extensiones y configuración |
| Cursor | `~/.cursor` | optional | Editor de IA Cursor |
| Spring Tool Suite 4 | `~/.sts4` | optional | Datos de STS4 |

## Navegadores / Automatización de Pruebas <a href="#navegadores-automatizacion-de-pruebas" id="navegadores-automatizacion-de-pruebas"></a>

| Herramienta | Ruta | Prioridad | Descripción |
|-------------|------|-----------|-------------|
| Selenium | `~/.cache/selenium` | optional | Controladores de navegador descargados automáticamente |
| Chromium | `~/.chromium-browser-snapshots` | optional | Capturas de navegador usadas por Playwright/Selenium |
| WDM | `~/.wdm` | optional | Programas de controladores de WebDriver Manager |

## Entornos de Ejecución <a href="#entornos-de-ejecucion" id="entornos-de-ejecucion"></a>

| Herramienta | Ruta | Prioridad | Descripción |
|-------------|------|-----------|-------------|
| Docker | `~/.docker` | optional | Configuración CLI y contexto de Docker Desktop |
| OpenClaw | `~/.openclaw` | optional | Datos de herramientas de OpenClaw |

## Directorios del Sistema No Migrables <a href="#directorios-del-sistema-no-migrables" id="directorios-del-sistema-no-migrables"></a>

Los siguientes directorios contienen referencias de rutas absolutas o archivos ejecutables; migrarlos puede causar fallos en las herramientas. **La migración no está soportada**:

| Ruta | Razón |
|------|-------|
| `~/.local` | Contiene referencias de rutas ejecutables; las herramientas de línea de comandos pueden fallar después de la migración |
| `~/.config` | Contiene configuraciones de rutas absolutas; las configuraciones de herramientas pueden fallar después de la migración |

## Manejo Especial de Distribuciones Conda <a href="#manejo-especial-de-distribuciones-conda" id="manejo-especial-de-distribuciones-conda"></a>

Cuando el Bundle ID o el nombre de una aplicación contiene `anaconda`, `conda` o `miniconda`, AppPorts escanea adicionalmente las siguientes rutas para identificar la raíz de instalación de Conda:

- `/opt/anaconda3`
- `/opt/miniconda3`
- `/usr/local/anaconda3`
- `/usr/local/miniconda3`
- `~/anaconda3`
- `~/miniconda3`
