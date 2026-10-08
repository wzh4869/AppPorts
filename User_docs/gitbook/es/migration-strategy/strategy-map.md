# Tipos de Apps y Estrategias

| Tipo de App | Clasificación de Contenedor | Estrategia de Migración | Protección de Bloqueo | Notas |
|-------------|----------------------------|------------------------|----------------------|-------|
| App macOS nativa (sin auto-actualización) | `standaloneApp` | macOS Stub Portal | No | ej., Safari, Finder |
| App con auto-actualización Sparkle | `standaloneApp` | macOS Stub Portal | **Sí** | ej., algunas apps de desarrolladores independientes |
| App Electron (sin `app-update.yml`) | `standaloneApp` | macOS Stub Portal | No | ej., VS Code |
| App Electron (con `app-update.yml`) | `standaloneApp` | macOS Stub Portal | **Sí** | ej., Slack, Discord |
| App híbrida Electron + Sparkle | `standaloneApp` | macOS Stub Portal | **Sí** | Ambas banderas detectadas independientemente |
| Apps con actualizador personalizado (Chrome, Edge) | `standaloneApp` | macOS Stub Portal | No | Identificadas vía `LaunchServices`, `KSProductID`, etc. |
| App iOS (versión Mac) | `standaloneApp` | iOS Stub Portal | No | Iconos extraídos de `WrappedBundle`; sin firmado |
| App de Mac App Store | `standaloneApp` | macOS Stub Portal | No | Protección SIP; no se puede re-firmar |
| Directorio de contenedor de app única | `singleAppContainer` | Whole App Symlink | No | Directorio con solo 1 `.app`; symlink completo |
| Directorio de suite de apps (ej., Office) | `appSuiteFolder` | Whole App Symlink | Depende de apps internas | Directorio con 2+ `.app`; symlink completo |
| Ruta no `.app` | — | Whole App Symlink | — | Ruta con extensión distinta a `.app` |

{% hint style="warning" %}
**⚠️ Sobre la Protección de Bloqueo**

Cuando una app está marcada como que necesita bloqueo (`needsLock = true`), AppPorts ejecuta `chflags -R uchg` en la app del almacenamiento externo después de completar la migración, estableciendo la bandera inmutable. Esto evita que los actualizadores automáticos eliminen o modifiquen la copia externa, pero también significa que la app no puede auto-actualizarse. Los usuarios necesitan desbloquear manualmente en AppPorts antes de actualizar.
{% endhint %}

{% hint style="success" %}
**💡 Por Qué las Apps con Actualizador Personalizado No Se Bloquean**

Las apps que usan actualizadores personalizados como Chrome y Edge no se bloquean. Los actualizadores de estas apps típicamente descargan e instalan nuevas versiones en el almacenamiento interno local. Debido a las características de aislamiento de enlace de macOS Stub Portal, esto no daña los archivos de la app en el almacenamiento externo.

Cuando AppPorts detecta que la versión de la app en el almacenamiento interno local es superior a la del almacenamiento externo, etiqueta automáticamente la app como "Pendiente de mover fuera", indicando al usuario que re-migre para sincronizar la última versión.
{% endhint %}
