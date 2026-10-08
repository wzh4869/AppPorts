# Detección de Auto-Actualizadores

## Detección de Aplicaciones Electron <a href="#deteccion-de-aplicaciones-electron" id="deteccion-de-aplicaciones-electron"></a>

AppPorts identifica las aplicaciones Electron mediante las siguientes tres condiciones de detección (verificadas en orden de prioridad, evaluación de cortocircuito):

| # | Elemento de Detección | Ruta / Patrón |
|---|----------------------|----------------|
| 1 | Framework Electron | El directorio `Contents/Frameworks/Electron Framework.framework` existe |
| 2 | Variantes de Electron Helper | Existen entradas que contienen `Electron Helper` en el nombre bajo `Contents/Frameworks/` |
| 3 | Claves de identificador en Info.plist | Existen las claves `ElectronDefaultApp` o `electron` en `Contents/Info.plist` |

### Detección de Auto-Actualización de Electron <a href="#deteccion-de-auto-actualizacion-de-electron" id="deteccion-de-auto-actualizacion-de-electron"></a>

Adicionalmente verifica la existencia del archivo `Contents/Resources/app-update.yml` (archivo de configuración para `electron-updater`). Si está presente, la app Electron se marca como con capacidad de auto-actualización.

## Detección de Aplicaciones Sparkle <a href="#deteccion-de-aplicaciones-sparkle" id="deteccion-de-aplicaciones-sparkle"></a>

AppPorts identifica las aplicaciones Sparkle mediante las siguientes tres condiciones de detección:

| # | Elemento de Detección | Ruta / Patrón |
|---|----------------------|----------------|
| 1 | Framework Sparkle | Existe `Contents/Frameworks/Sparkle.framework` o `Contents/Frameworks/Squirrel.framework` |
| 2 | Archivos binarios del actualizador | Existen archivos que coinciden con `shipit`, `autoupdate`, `updater`, `update` bajo `Contents/MacOS/` o `Contents/Frameworks/` |
| 3 | Claves Sparkle en Info.plist | Existen cualquiera de las siguientes claves en `Contents/Info.plist`: `SUFeedURL`, `SUPublicDSAKeyFile`, `SUPublicEDKey`, `SUScheduledCheckInterval`, `SUAllowsAutomaticUpdates` |

{% hint style="warning" %}
**⚠️ Manejo Especial para Apps Electron**

Cuando una app ha sido identificada como Electron, la condición de detección #2 (archivos binarios del actualizador) se omite para evitar falsos positivos del binario `updater` de `electron-updater` siendo detectado como Sparkle.
{% endhint %}

## Apps Híbridas Electron + Sparkle <a href="#apps-hibridas-electron-sparkle" id="apps-hibridas-electron-sparkle"></a>

Algunas apps contienen tanto el framework Electron como el actualizador Sparkle. AppPorts detecta ambas banderas independientemente, permitiendo que `isElectron` e `isSparkle` sean ambos `true`.

### Lógica de Detección <a href="#logica-de-deteccion" id="logica-de-deteccion"></a>

```text
isElectron = satisface cualquiera de las tres condiciones de detección de Electron
isSparkle  = satisface cualquiera de las tres condiciones de detección de Sparkle (las apps Electron omiten la condición #2)
```

Las dos banderas son independientes y pueden ser ambas verdaderas simultáneamente.

### Comportamiento Post-Migración <a href="#comportamiento-post-migracion" id="comportamiento-post-migracion"></a>

| Atributo | Condición de Determinación |
|----------|---------------------------|
| `hasSelfUpdater` | `isSparkle` o (`isElectron` y existe `app-update.yml`) o existe actualizador personalizado |
| `needsLock` | `isSparkle` o (`isElectron` y existe `app-update.yml`) |

Cuando `needsLock` es `true`, AppPorts ejecuta `chflags -R uchg` (estableciendo bandera inmutable) en la app del almacenamiento externo después de completar la migración, evitando que los actualizadores automáticos eliminen o modifiquen la copia externa.

## Detección de Actualizadores Personalizados <a href="#deteccion-de-actualizadores-personalizados" id="deteccion-de-actualizadores-personalizados"></a>

Para aplicaciones nativas con auto-actualización que no son ni Sparkle ni Electron (ej., Chrome, Edge, Parallels), AppPorts las identifica mediante los siguientes patrones:

| Ruta de Detección | Patrón de Coincidencia | Apps Típicas |
|-------------------|----------------------|-------------|
| `Contents/Library/LaunchServices/` | El nombre de archivo contiene `update` | Chrome, Edge, Thunderbird |
| `Contents/MacOS/` | El nombre del binario contiene `update` o `upgrade` (excluyendo `electron`) | Parallels, Thunderbird |
| `Contents/SharedSupport/` | El nombre de archivo contiene `update` | WPS Office |
| `Contents/Info.plist` | Existe la clave `KSProductID` | Google Keystone (Chrome) |

## Identificación de Estrategias Heredadas <a href="#identificacion-de-estrategias-heredadas" id="identificacion-de-estrategias-heredadas"></a>

Al restaurar o desvincular, AppPorts necesita identificar entradas heredadas creadas por versiones anteriores:

| Característica de la Estructura Local | Identificado Como |
|--------------------------------------|-------------------|
| La ruta raíz es un enlace simbólico | `wholeAppSymlink` |
| `Contents/` es un enlace simbólico | `deepContentsWrapper` |
| `Contents/Info.plist` es un enlace simbólico | `wholeAppSymlink` (esquema híbrido Sparkle heredado) |
| `Contents/Frameworks/` es un enlace simbólico | `wholeAppSymlink` (esquema híbrido Electron heredado) |
| Existe `Contents/MacOS/launcher` | `stubPortal` |
| Ninguna de las anteriores coincide | No gestionado por AppPorts |
