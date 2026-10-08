# Guía de insignias de estado

AppPorts utiliza insignias de colores con forma de cápsula para mostrar el estado de las aplicaciones y los directorios de datos. Algunas permiten hacer clic para ver más detalles o recomendaciones.

## Insignias de las aplicaciones <a href="#insignias-de-las-aplicaciones" id="insignias-de-las-aplicaciones"></a>

### Estado del enlace <a href="#estado-del-enlace" id="estado-del-enlace"></a>

| Insignia | Icono | Color | Significado |
|------|------|------|------|
| Enlazado | `link` | Verde | La aplicación se ha migrado al almacenamiento externo y tiene una entrada local |
| Migración bloqueada | `lock.fill` | Verde | La aplicación está enlazada y bloqueada mediante `uchg` para proteger la copia externa frente a las actualizaciones automáticas |
| Migración no bloqueada | `lock.open` | Naranja | La aplicación está enlazada pero no bloqueada; sus actualizaciones pueden eliminar o sobrescribir la copia externa |
| Parcialmente enlazado | `link.badge.plus` | Amarillo | Algunos componentes están enlazados, como parte de los paquetes `.app` de un directorio |
| Enlace huérfano | `link.badge.exclamationmark` | Rojo | La aplicación externa ha desaparecido, pero su entrada local aún existe |
| No enlazado | `externaldrive.badge.xmark` | Naranja | La aplicación está en el almacenamiento externo y aún no se ha enlazado al Mac |
| Externo | `externaldrive` | Naranja | Aplicación externa sin entrada local |
| Pendiente de mover fuera | `arrow.up.right.circle` | Cian | La aplicación real local es más reciente que la copia externa del mismo nombre; se puede trasladar para sustituir esa copia antigua |
| Local | `macmini` | Color secundario | Aplicación local normal, sin migrar; se muestra cuando no hay otras etiquetas |

{% hint style="success" %}
**Cómo se determina «Pendiente de mover fuera»**

AppPorts compara primero las aplicaciones locales y externas por Bundle ID y, si hace falta, por su nombre normalizado. «Pendiente de mover fuera» solo aparece cuando ambas versiones se pueden comparar y la local es más reciente. Si falta una versión, el formato no permite compararlas o las aplicaciones con el mismo nombre tienen distintos Bundle ID, AppPorts conserva el estado local normal para evitar sobrescribir una aplicación externa por error.
{% endhint %}

### Frameworks <a href="#frameworks" id="frameworks"></a>

| Insignia | Icono | Color | Significado | Explicación al hacer clic |
|------|------|------|------|----------|
| Sparkle | `arrow.triangle.2.circlepath` | Cian | Usa Sparkle para las actualizaciones automáticas | Tras la migración, actualizar desde la aplicación puede causar la pérdida de la copia externa; se recomienda bloquear la migración |
| Electron | `atom` | Índigo | Aplicación Electron que puede admitir actualizaciones automáticas | Tras la migración, actualizar desde la aplicación puede causar la pérdida de la copia externa; se recomienda bloquear la migración |

### Tipos de aplicación <a href="#tipos-de-aplicacion" id="tipos-de-aplicacion"></a>

| Insignia | Icono | Color | Significado |
|------|------|------|------|
| Ejecutando | `play.fill` | Morado | La aplicación está en ejecución |
| Sistema | `lock.fill` | Gris | Aplicación del sistema macOS |
| No nativo | `iphone` | Rosa | Aplicación de iOS/iPadOS ejecutada en un chip de Apple |
| Tienda | `applelogo` | Azul | Aplicación de Mac App Store |

### Insignias especiales <a href="#insignias-especiales" id="insignias-especiales"></a>

| Insignia | Icono | Color | Significado |
|------|------|------|------|
| Re-firmado | `seal.fill` | Cian | La aplicación tiene actualmente una firma Ad-hoc y AppPorts conserva una copia de seguridad de su firma |
| Firma sustituida | `exclamationmark.shield.fill` | Rojo | AppPorts sustituyó la firma del desarrollador por una firma Ad-hoc. La aplicación puede no abrirse en macOS 27. Haz clic para ver la explicación, o elige «Ver los pasos de reparación» en el menú contextual para abrir el panel de reparación. Consulta la [guía de actualización a macOS 27](macos-27.md) |

{% hint style="success" %}
**Diferencia entre «Re-firmado» y «Firma sustituida»**

Ambas indican que la firma actual es Ad-hoc; la diferencia es **la firma original**. Una aplicación con «Re-firmado» no tenía firma de desarrollador, o ya no se puede confirmar cuál tenía: volver a firmarla simplemente permite que se abra con normalidad. Una aplicación con «Firma sustituida» tenía una firma de desarrollador que se sustituyó por Ad-hoc. Esto puede impedir que una aplicación aislada se abra en macOS 27, por lo que se marca en rojo y ofrece acceso a la reparación.
{% endhint %}

{% hint style="success" %}
**Particularidad de la insignia «Tienda»**

La insignia «Tienda» permite hacer clic y muestra las instrucciones de instalación nativa en discos externos de macOS 15.1+ cuando:

- La aplicación está en `/Volumes/{drive}/Applications/`, en el almacenamiento externo.
- macOS gestiona la aplicación de forma nativa y App Store puede realizar actualizaciones incrementales directamente en ese directorio.
{% endhint %}

## Insignias de los directorios de datos <a href="#insignias-de-los-directorios-de-datos" id="insignias-de-los-directorios-de-datos"></a>

| Estado | Color | Significado |
|------|------|------|
| Local | Color secundario | Directorio local sin migrar. El escudo junto a un contenedor indica que utiliza la migración por montaje |
| Enlazado | Verde | Migración mediante enlace simbólico completada; el enlace local apunta al disco externo |
| Montado | Morado | Migración por montaje completada; el volumen externo está montado en el directorio original |
| Montaje pendiente | Naranja | El volumen de migración por montaje está en línea, pero sin montar; haz clic en «Montar» |
| Disco externo desconectado | Rojo | No se encuentra el volumen de datos, normalmente porque el disco externo está desconectado; AppPorts lo reconecta automáticamente al conectarlo |
| Necesita normalización | Amarillo | Enlace gestionado por AppPorts cuyo destino externo no está en la ubicación estándar; usa «Normalizar» |
| Pendiente de reenlace | Naranja | Los datos externos siguen presentes, pero falta el enlace local; usa «Volver a enlazar» |
| Enlace simbólico existente | Azul | Enlace simbólico creado fuera de AppPorts, que puedes incorporar a su gestión |

## Ejemplos de combinaciones <a href="#ejemplos-de-combinaciones" id="ejemplos-de-combinaciones"></a>

Una aplicación puede mostrar varias insignias a la vez:

```text
[已链接] [Sparkle] [运行中]
```
Significado: la aplicación se ha migrado al almacenamiento externo, usa Sparkle para actualizarse automáticamente y está en ejecución.

```text
[外部] [商店] [非原生]
```
Significado: aplicación de iOS para Mac instalada por App Store en el almacenamiento externo.

```text
[孤立链接]
```
Significado: la aplicación externa ha desaparecido o se ha eliminado, pero su entrada local permanece. Es necesario quitar el enlace manualmente.

```text
[待迁出]
```
Significado: existe una versión nueva de la aplicación real en el Mac y una copia antigua en el almacenamiento externo. Puedes repetir la migración para trasladar la versión local nueva y sustituir la copia externa antigua.
