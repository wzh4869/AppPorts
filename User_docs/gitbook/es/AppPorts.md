# Guía del usuario de AppPorts

Esta guía presenta las funciones principales de AppPorts, sus principios de diseño y su implementación técnica. Para conocer más detalles técnicos, consulta [DeepWiki](https://deepwiki.com/wzh4869/AppPorts). Puedes enviar sugerencias de mejora a los [Issues](https://github.com/wzh4869/AppPorts/issues) del proyecto.

## Introducción <a href="#introduccion" id="introduccion"></a>

AppPorts es una herramienta de migración y enlace de aplicaciones diseñada para [macOS](https://www.apple.com/macos/). Permite trasladar aplicaciones grandes al almacenamiento externo, manteniendo en lo posible un comportamiento coherente en Finder, Launchpad, los menús de aplicaciones y las actualizaciones del sistema.

### Filosofía de AppPorts <a href="#filosofia-de-appports" id="filosofia-de-appports"></a>

| Principio | Descripción |
|------|------|
| **Experiencia transparente** | Procurar que tanto el usuario como el sistema utilicen las aplicaciones migradas como si fueran locales |
| **Estrategias estables** | Priorizar los métodos probados que ofrecen mayor estabilidad en la migración |
| **Baja carga del sistema** | Evitar la dependencia de demonios y el consumo continuo de recursos del sistema |
| **Amplia internacionalización** | Cubrir más idiomas y mejorar continuamente la calidad de las traducciones |
| **Accesibilidad** | Ofrecer una compatibilidad con las funciones de accesibilidad lo más completa posible |

## Funciones principales <a href="#funciones-principales" id="funciones-principales"></a>

- **Migración sin flecha de acceso directo**: traslada aplicaciones grandes al almacenamiento externo con un clic. Solo queda un contenedor de lanzamiento ligero en el Mac; Finder no muestra la flecha de acceso directo, y Launchpad y los menús de aplicaciones de macOS funcionan con normalidad.
- **Protección frente a actualizaciones automáticas**: detecta las aplicaciones que se actualizan por sí mismas (Sparkle, Electron, Chrome, etc.) y ofrece «Migración bloqueada» para impedir que sus actualizadores eliminen o sobrescriban la aplicación externa.
- **Aviso de sincronización de versiones**: si la aplicación real local es más reciente que la copia externa, «Pendiente de mover fuera» indica que puedes trasladar la versión nueva para sustituir la copia externa antigua.
- **Sincronización de versiones de Stub Portal**: cuando App Store actualiza una aplicación externa, la información de versión del Stub Portal local se sincroniza automáticamente. El menú «Abrir con» muestra siempre la versión correcta.
- **Directorios de análisis personalizados**: permite añadir directorios de aplicaciones locales, como los de JetBrains Toolbox o Steam, guardarlos automáticamente y vigilar sus cambios.
- **Gestión de firmas de código**: si la aplicación aparece como dañada después de trasladar sus archivos, puedes volver a firmarla desde el menú contextual. Se admite la copia de seguridad y la restauración de la firma original. Las aplicaciones aisladas nunca se vuelven a firmar.
- **Compatibilidad con App Store en macOS 15.1+**: permite instalar aplicaciones de App Store directamente en el almacenamiento externo y actualizarlas allí, sin devolverlas al Mac.
- **Restauración con un clic**: devuelve las aplicaciones al Mac y elimina los enlaces automáticamente. Una migración interrumpida se puede recuperar de forma automática.
- **Gestión de directorios de datos**: traslada los datos de aplicaciones (subdirectorios de `~/Library/`, `~/.npm`, etc.) al almacenamiento externo, con vista en árbol, búsqueda y ordenación. Los metadatos de AppPorts se usan para validar estrictamente los destinos de restauración.
- **Migración por montaje de datos de contenedores**: traslada datos de contenedores de aplicaciones aisladas, como el historial de WeChat, creando un volumen dedicado en un disco externo APFS y montándolo en el directorio original. La firma de la aplicación permanece intacta.
- **Migración de directorios**: traslada cualquier carpeta real de la carpeta de inicio al almacenamiento externo. Resulta útil para proyectos grandes, modelos, bibliotecas de recursos y cachés de herramientas; incluye reenlace, restauración y comprobación de rutas superpuestas.

## Estrategias de migración <a href="#estrategias-de-migracion" id="estrategias-de-migracion"></a>

### Deep Contents Wrapper (migración del directorio Contents) <a href="#deep-contents-wrapper-migracion-del-directorio-contents" id="deep-contents-wrapper-migracion-del-directorio-contents"></a>

Una aplicación de macOS tiene normalmente la siguiente estructura:

```text
/Applications/Safari.app/
├── Contents/
│   ├── MacOS/
│   ├── Resources/
│   ├── Frameworks/
│   └── Info.plist
└── ...
```

Deep Contents Wrapper traslada todo el contenido de la aplicación al almacenamiento externo y crea un directorio `.app` local vacío con el mismo nombre, que solo contiene un enlace simbólico al directorio `Contents` externo. Como macOS reconoce un paquete `.app` completo en lugar de un acceso directo, Finder no muestra la flecha; el icono, Launchpad y los menús de aplicaciones funcionan con normalidad.

{% hint style="warning" %}
**Esta estrategia está obsoleta en la versión actual**

El principal defecto de Deep Contents Wrapper es que el actualizador automático puede seguir el enlace simbólico y modificar directamente los archivos externos, lo que puede dañar la aplicación.
{% endhint %}

### Stub Portal (contenedor de lanzamiento) <a href="#stub-portal-contenedor-de-lanzamiento" id="stub-portal-contenedor-de-lanzamiento"></a>

Stub Portal crea un contenedor `.app` local mínimo, con solo estos cuatro elementos:

| Componente | Descripción |
|------|------|
| `Contents/MacOS/launcher` | Lanzador que ejecuta `open "/Volumes/External/SomeApp.app"` |
| `Contents/Resources/` | Archivos de iconos copiados de la aplicación externa |
| `Contents/Info.plist` | Versión simplificada del `Info.plist` externo: `CFBundleExecutable` se establece en `launcher`, `LSUIElement=true` oculta la aplicación en el Dock y se eliminan todas las claves de configuración relacionadas con las actualizaciones |
| `Contents/PkgInfo` | Archivo de identificación estándar de 4 bytes |

Al hacer clic en este contenedor, macOS ejecuta `launcher`, que abre la aplicación real del almacenamiento externo mediante `open`. No hay enlaces simbólicos locales, por lo que el actualizador no puede seguir un enlace hasta la aplicación externa.

### iOS Stub Portal (contenedor de lanzamiento para iOS) <a href="#ios-stub-portal-contenedor-de-lanzamiento-para-ios" id="ios-stub-portal-contenedor-de-lanzamiento-para-ios"></a>

El principio es el mismo que el de Stub Portal, pero el tratamiento de los iconos cambia. Las aplicaciones de iOS no definen sus iconos en `Info.plist`: los guardan como varios archivos `AppIcon.png` dentro de `Wrapper/` o `WrappedBundle/`. El proceso es el siguiente:

1. Buscar el archivo `AppIcon.png` de mayor resolución.
2. Redimensionarlo a 256×256 píxeles con `sips`.
3. Convertirlo al formato `.icns` con `sips`.
4. Generar `Info.plist` a partir de `iTunesMetadata.plist`, ya que las aplicaciones de iOS no incluyen un `Info.plist` estándar.

### Whole Symlink (enlace simbólico de toda la aplicación) <a href="#whole-symlink-enlace-simbolico-de-toda-la-aplicacion" id="whole-symlink-enlace-simbolico-de-toda-la-aplicacion"></a>

Todo el directorio `.app` se convierte en un enlace simbólico al almacenamiento externo:

```text
/Applications/SomeApp.app → /Volumes/External/SomeApp.app
```

Localmente solo queda un enlace simbólico, sin archivos de la aplicación. macOS suele poder abrirla con normalidad, pero Finder muestra una flecha de acceso directo en su icono y Launchpad puede presentar problemas de compatibilidad. El actualizador también puede seguir ese enlace para modificar los archivos externos. Por ello, AppPorts utiliza este método principalmente como estrategia de respaldo.
