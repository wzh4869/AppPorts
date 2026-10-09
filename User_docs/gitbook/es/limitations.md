---
icon: "triangle-exclamation"
layout:
  width: "default"
  outline:
    visible: true
---

# Compatibilidad y limitaciones

## Requisitos del sistema <a href="#requisitos-del-sistema" id="requisitos-del-sistema"></a>

| Requisito | Descripción |
|------|------|
| Sistema mínimo | macOS 12.0 (Monterey) |
| Arquitectura | Intel x86_64 / Apple Silicon (arm64) |
| Permiso | Acceso total al disco |
| Almacenamiento externo | Al menos un dispositivo externo |

## Compatibilidad de funciones <a href="#compatibilidad-de-funciones" id="compatibilidad-de-funciones"></a>

### Según la versión de macOS <a href="#segun-la-version-de-macos" id="segun-la-version-de-macos"></a>

| Función | macOS 12.0 - 15.0 | macOS 15.1+ |
|------|:---:|:---:|
| Migración de apps con Stub Portal | ✓ | ✓ |
| Migración de datos por enlace simbólico | ✓ | ✓ |
| Migración por montaje de contenedores | ✓, exige contraseña de administrador para montar | ✓, las pruebas en 27 no requieren contraseña; de 13 a 26 no se han verificado individualmente |
| Migración de carpetas personalizadas | ✓ | ✓ |
| Gestión de firmas de código | ✓ | ✓ |
| Migración externa de apps de App Store | ✗ | ✓ |
| Actualización de App Store directamente en almacenamiento externo | ✗ | ✓ |
| Migración de apps de iOS | ✓ | ✓ |

{% hint style="warning" %}
**Apps de App Store antes de macOS 15.1**

Antes de macOS 15.1 (Sequoia) no se admite la instalación externa nativa de apps de App Store. Si necesita migrarlas, active manualmente esa opción en AppPorts. Después de actualizar una app debe volver a migrarla para sustituir la copia externa.
{% endhint %}

### Según el tipo de app <a href="#segun-el-tipo-de-app" id="segun-el-tipo-de-app"></a>

| Tipo | Migración | Restauración | Actualización automática | Descripción |
|------|:---:|:---:|:---:|------|
| App nativa de macOS | ✓ | ✓ | ✓ | Máxima compatibilidad |
| Sparkle | ✓ | ✓ | Requiere bloqueo | El bloqueo impide actualizar desde la app; devuélvala al Mac antes de actualizar |
| Electron | ✓ | ✓ | Requiere bloqueo | Igual que Sparkle |
| Chrome / Edge, actualizador personalizado | ✓ | ✓ | ✓ | Instala la actualización localmente sin dañar la copia externa |
| App Store, macOS 15.1+ | ✓ | ✓ | ✓ | Instalación externa nativa y actualización directa desde App Store |
| App Store, macOS <15.1 | ✓ | ✓ | Manual | Hay que volver a migrar después de actualizar |
| iOS para Mac | ✓ | ✓ | ✓ | Usa iOS Stub Portal |
| App del sistema | ✗ | — | — | Protegida por SIP; no se puede migrar |

{% hint style="warning" %}
**Migración de apps protegidas**

Los permisos de macOS pueden impedir que AppPorts elimine o sustituya automáticamente la copia local de apps de App Store o propiedad de root. Si aparece el aviso, muévala primero con Finder al disco externo y después cree el enlace local desde AppPorts.
{% endhint %}

{% hint style="success" %}
**Flechas de acceso directo en Finder**

Los lanzadores antiguos pueden ser enlaces simbólicos completos y mostrar flecha. La versión actual usa Stub Portal por defecto para los `.app` normales y normalmente no muestra flecha. Si sigue apareciendo, devuelva la app al Mac y migre de nuevo.
{% endhint %}

{% hint style="success" %}
**Sobre «Pendiente de mover fuera»**

«Pendiente de mover fuera» requiere versiones comparables y una identificación fiable de la misma app. AppPorts usa primero el Bundle ID y, si es necesario, el nombre normalizado. No aparece si faltan versiones, no se pueden comparar o apps homónimas tienen distintos Bundle ID.
{% endhint %}

### Según el tipo de directorio de datos <a href="#segun-el-tipo-de-directorio-de-datos" id="segun-el-tipo-de-directorio-de-datos"></a>

| Directorio | Método | Riesgo |
|------|:---:|------|
| `~/Library/Application Support/` | Enlace simbólico | Medio: puede usar bloqueos de archivo o registros SQLite WAL |
| `~/Library/Preferences/` | Enlace simbólico | Bajo a medio: la caché `cfprefsd` puede devolver ajustes antiguos |
| `~/Library/Containers/` | Montaje | Medio: exige APFS sin encriptar, permiso en la primera apertura y disco conectado antes de usar |
| `~/Library/Group Containers/` | Montaje | Medio: lo anterior, y los datos compartidos afectan a otras apps de la misma Team |
| `~/Library/Caches/` | Enlace simbólico | Bajo: la caché puede recrearse |
| `~/Library/Logs/` | Enlace simbólico | Bajo: solo registros |
| `~/Library/WebKit/` | Enlace simbólico | Medio: almacenamiento local de WebKit |
| `~/Library/HTTPStorages/` | Enlace simbólico | Bajo: sesiones de red |
| `~/Library/Application Scripts/` | Enlace simbólico | Bajo: scripts de extensiones |
| `~/Library/Saved Application State/` | Enlace simbólico | Bajo: restauración del estado de ventanas |
| Carpetas ocultas como `~/.npm` y `~/.m2` | Enlace simbólico | Bajo: cachés de herramientas de desarrollo |
| Carpetas personalizadas dentro de la carpeta de inicio | Enlace simbólico | Depende del contenido: cierre las apps o herramientas que estén escribiendo antes de migrar |

{% hint style="warning" %}
**Directorios de datos importantes**

Historiales de WeChat, imágenes de máquinas virtuales, bibliotecas de juegos, bases de datos y cachés de modelos suelen ser grandes, escribirse con frecuencia y depender de rutas y bloqueos. Haga una copia independiente antes de migrar. Si hay problemas, restaure primero los datos en el Mac y después investigue.
{% endhint %}

{% hint style="warning" %}
**Los contenedores solo pueden migrarse por montaje**

Las apps aisladas no pueden leer los datos de `~/Library/Containers/` y `~/Library/Group Containers/` trasladados mediante enlaces simbólicos. El método antiguo lo evitaba volviendo a firmar, pero la app podía dejar de abrirse en macOS 27. Desde 1.9.0 estos directorios solo ofrecen [migración por montaje](datamigrae/mount-migration.md) y se rechaza volver a firmar apps aisladas. Consulte [Datos de contenedores, aislamiento e identidad de firma](datamigrae/container-identity.md).
{% endhint %}

{% hint style="warning" %}
**Alcance de las carpetas personalizadas**

La migración admite carpetas reales dentro de la carpeta de inicio. No admite archivos, enlaces simbólicos, rutas dentro del destino externo, directorios del sistema ni rutas que contengan elementos gestionados o estén contenidas en ellos.
{% endhint %}

{% hint style="warning" %}
**Conflicto de destino**

Un tamaño parecido no basta para recuperar o asumir la gestión de un directorio externo. AppPorts solo continúa automáticamente si sus metadatos coinciden completamente con la operación actual. Si no, lo considera un conflicto con un directorio real y se detiene.
{% endhint %}

## Elementos que no se pueden migrar <a href="#elementos-que-no-se-pueden-migrar" id="elementos-que-no-se-pueden-migrar"></a>

### Protegidos por SIP <a href="#protegidos-por-sip" id="protegidos-por-sip"></a>

| Ruta | Motivo |
|------|------|
| Apps del sistema macOS, como Safari o Finder | Protección de integridad del sistema |
| Directorios de nivel superior de `~/Library/Containers/` | Protección del sistema macOS |

### Con referencias a rutas <a href="#con-referencias-a-rutas" id="con-referencias-a-rutas"></a>

| Ruta | Motivo |
|------|------|
| `~/.local` | Contiene rutas de ejecutables; las herramientas de línea de comandos pueden dejar de funcionar |
| `~/.config` | Contiene ajustes con rutas absolutas que pueden dejar de ser válidos |

## Requisitos de almacenamiento externo <a href="#requisitos-de-almacenamiento-externo" id="requisitos-de-almacenamiento-externo"></a>

| Requisito | Descripción |
|------|------|
| Sistema de archivos | Apps y datos normales: APFS, HFS+ o exFAT. **Contenedores: solo APFS** |
| Espacio mínimo | Depende del tamaño de las apps |
| Interfaz | Compatible con USB, Thunderbolt y NVMe |
| Conexión | Debe permanecer conectado tras migrar; sin él no arrancarán las apps afectadas |

{% hint style="success" %}
**Sistema de archivos recomendado**

- **APFS**: recomendado, único formato compatible con el montaje de contenedores y con el mejor rendimiento.
- **HFS+**: compatible con Mac antiguos, pero no permite migrar datos de contenedores.
- **exFAT**: multiplataforma, pero no permite migrar contenedores. Para compartir con Windows puede usar una partición APFS independiente. Si exFAT ocupa todo el disco, las herramientas integradas no pueden reducirlo directamente: haga una copia y reparticione. Si ya hay espacio sin asignar, puede crear APFS según las [condiciones de particionado](why-apfs.md#prepare-apfs).

Consulte las razones y alternativas probadas en [Por qué el disco externo debe ser APFS](why-apfs.md).
{% endhint %}

### Unidades de red <a href="#unidades-de-red" id="unidades-de-red"></a>

NAS, SMB, rclone y SFTP no son los principales objetivos de validación de AppPorts. Pueden funcionar, pero debe comprobar la estabilidad, consistencia de rutas, permisos, atributos extendidos y enlaces simbólicos. No son la opción recomendada para datos que se escriben continuamente.
