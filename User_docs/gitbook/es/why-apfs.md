---
icon: "shield-halved"
description: "Comprende por qué la migración requiere el sistema de archivos APFS."
layout:
  width: "default"
  outline:
    visible: true
---

# Por qué el disco externo debe ser APFS

{% hint style="success" %}
**Lo esencial**

Desde la versión 1.9.0, al migrar `~/Library/Containers/`, que incluye datos como el historial de WeChat, AppPorts crea un volumen en el contenedor APFS del disco externo y lo conecta directamente al directorio original. Solo un disco APFS permite hacerlo. Probamos una imagen de disco como alternativa en exFAT / NTFS, pero **desconectar el disco dejó inutilizable toda la imagen**, así que no la ofrecemos.

**Si su disco no es APFS, no necesita modificarlo ahora.** Las apps y los directorios de datos normales pueden seguir migrándose; solo los datos de contenedores quedan en el Mac, sin afectar al uso. Cuando quiera migrarlos, consulte [Preparar un disco externo APFS](#prepare-apfs). Tener espacio libre dentro de exFAT no significa que se pueda crear directamente otra partición.
{% endhint %}

## Qué operaciones tienen este requisito <a href="#que-operaciones-tienen-este-requisito" id="que-operaciones-tienen-este-requisito"></a>

| Operación | Requisito de formato externo |
|---|---|
| Migrar la app, moviendo el `.app` al disco externo | Ninguno; exFAT también sirve |
| Migrar datos normales: `Application Support`, cachés, herramientas como `~/.npm` o carpetas personalizadas | Ninguno |
| Migrar **datos de contenedores** de `~/Library/Containers/` y `~/Library/Group Containers/`, donde guardan datos WeChat, QQ Music y las apps de App Store | **APFS obligatorio** |

Solo afecta a la tercera categoría, aunque suele contener los datos más grandes y que más interesa mover.

## Por qué los datos de contenedores son especiales <a href="#por-que-los-datos-de-contenedores-son-especiales" id="por-que-los-datos-de-contenedores-son-especiales"></a>

La mayoría de las apps de Mac funcionan aisladas: el sistema asigna a cada una una carpeta exclusiva bajo `~/Library/Containers/` donde puede leer y escribir. Es una medida de seguridad de macOS, obligatoria para las apps de App Store.

Antes, AppPorts copiaba la carpeta al disco externo y dejaba un «acceso directo», o enlace simbólico, en la ubicación original. Funciona bien para datos normales, pero **nunca funcionó realmente para apps aisladas**:

- El sistema no comprueba dónde está el acceso directo, sino **adónde apunta**. Apuntar al disco externo supone salir de la carpeta exclusiva, así que se rechaza.
- Parecía funcionar porque la migración añadía una nueva firma que quitaba la identidad aislada de la app. Al dejar de estar aislada, ya no estaba sujeta a esa restricción.
- La consecuencia aparece en macOS 27: al comprobar si la app tiene derecho a acceder a la carpeta, la identidad puede no coincidir y la app se cierra un segundo después del doble clic. Está confirmado en WeChat; QQ Music aún se abre. Solo reinstalar la app permite repararlo. Consulte la [guía de actualización a macOS 27](macos-27.md).

El nuevo método debe cumplir una condición: **los datos deben estar en el disco externo sin «salir» de la carpeta exclusiva.**

## Cómo funciona el nuevo método <a href="#como-funciona-el-nuevo-metodo" id="como-funciona-el-nuevo-metodo"></a>

En vez de un acceso directo, se **monta una parte del disco externo directamente en la carpeta original**. La carpeta sigue en su sitio, pero su «suelo» pasa a ser el disco externo.

- La ruta que ve la app no cambia y las comprobaciones del sistema siguen pasando.
- No se modifica ni un byte de la firma. No hay que volver a firmar y este método no causa problemas al actualizar el sistema en el futuro.
- Si falta el disco externo, la carpeta está vacía. La app ve que no hay datos y no escribe otra copia local.

Para montar un espacio en una carpeta, debe ser un **volumen** independiente. APFS permite **añadir varios volúmenes a un mismo contenedor y compartir el espacio libre**, sin fijar de antemano sus tamaños ni reparticionar. AppPorts utiliza esta capacidad para crear un volumen por directorio migrado. Añadir un volumen no equivale a crear una partición en el disco físico.

No se puede añadir así un volumen APFS dentro de exFAT o NTFS. Para conservar esos formatos junto a APFS en el mismo disco, APFS necesita una partición propia: use espacio sin asignar o reduzca primero la partición existente con una herramienta compatible. Si no es posible, haga una copia y reparticione. AppPorts no modifica las particiones por usted.

## La alternativa que probamos <a href="#la-alternativa-que-probamos" id="la-alternativa-que-probamos"></a>

Como muchos usuarios tienen discos exFAT, estudiamos una imagen sparsebundle, del tipo que Time Machine usa para copias en discos de red. La imagen contiene APFS y puede montarse en una carpeta.

Las primeras pruebas en macOS 27, en septiembre de 2026, parecían prometedoras:

- No exigía un disco APFS; el archivo podía guardarse en cualquier formato.
- No pedía acceso a volúmenes extraíbles al abrir la app por primera vez, a diferencia del volumen APFS.
- Velocidades de lectura y escritura similares a las del volumen APFS.
- Incluso funcionaba con apps del sistema como Notas Adhesivas, a diferencia del método de volumen APFS.

Después hicimos una prueba realista: **desconectar mientras se escriben datos**. En una memoria USB de 64 GB formateada en APFS preparamos un volumen APFS y una imagen, cada uno montado en una carpeta. Dos programas escribían bases de datos sin parar, como WeChat o QQ Music con sus conversaciones y listas de reproducción. Tras algo más de diez segundos, desconectamos y volvimos a conectar la memoria.

| | Escrito antes de desconectar | Tras reconectar |
|---|---|---|
| Volumen APFS, prueba 1, escritura normal | 7177 entradas | Un error de corrupción de la base; la reparación recuperó las 7172 entradas, con sistema de archivos intacto |
| Volumen APFS, prueba 2, escritura forzada a disco | 1906 entradas | 1905 intactas; solo se perdió la última |
| Imagen, prueba 1, escritura normal | 25574 entradas | **La imagen dejó de abrirse**, todos sus datos quedaron inaccesibles |
| Imagen, prueba 2, escritura forzada a disco | 373 entradas | **La imagen siguió sin abrirse** |

No es la diferencia entre perder un poco más o menos, sino entre perder unas entradas y perder todo el acceso a los datos.

Una imagen se compone de archivos de 8 MB en el disco externo. Su propio «catálogo» está en el primer archivo y se reescribe cada pocos segundos. Al desconectar, el disco externo garantiza la integridad de los archivos en sí, no la de su contenido interrumpido a mitad de escritura. Si ocurre en el catálogo, toda la imagen queda fragmentada y sin índice. Forzar la escritura desde la app no arregla esa capa: pertenece a la imagen y la app no la controla.

Quienes usan Time Machine en red pueden haber visto el aviso de que una copia está dañada y hay que crear otra. Es el mismo problema. Una copia puede repetirse; un historial de conversaciones perdido, no.

Por eso descartamos las imágenes tras probarlas. Una herramienta de migración no puede ofrecer una opción que haga inaccesibles todos los datos por una sola desconexión, aunque tenga otras ventajas.

## Qué hacer ahora <a href="#what-to-do" id="what-to-do"></a>

Primero determine si quiere migrar **datos de contenedores**. Si no, no cambie nada. Si sí, elija según el estado del disco:

| Situación | Recomendación |
|---|---|
| El disco ya es APFS sin encriptar | Pulse «Migración por montaje» en «App Data» |
| Es exFAT / NTFS y no quiere modificarlo | **Dejar como está**: los contenedores permanecen en el Mac y el resto se migra normalmente |
| Tiene otro disco APFS o quiere preparar uno dedicado | Selecciónelo como almacenamiento en AppPorts y migre los contenedores |
| Quiere reservar espacio APFS en el disco actual | Siga [Preparar un disco externo APFS](#prepare-apfs), después de hacer una copia |
| Es APFS encriptado | Aún no se admite; consulte [Discos externos encriptados](#encrypted-drives) |

Si tiene dudas, pulse «Migración por montaje» una vez: AppPorts hará primero una comprobación de solo lectura y le indicará la situación, sin modificar nada.

**Consultar el formato**: seleccione el disco en Finder, pulse `⌘ I` y mire «Formato». APFS es válido; ExFAT, NTFS o Mac OS Plus (HFS+) corresponden al segundo caso de la tabla.

## Preparar un disco externo APFS <a href="#prepare-apfs" id="prepare-apfs"></a>

{% hint style="warning" %}
**Antes de modificar el disco**

Haga una copia de los datos antes de cualquiera de los métodos siguientes. AppPorts no borra discos ni modifica particiones por usted.
{% endhint %}

**No hay datos importantes**: abra Utilidad de Discos, seleccione el disco, pulse Borrar, elija APFS y Mapa de particiones GUID. Se borrará todo el disco.

**Hay datos y quiere conservar la partición**: compruebe primero que usa Mapa de particiones GUID. La capacidad disponible de Finder es el espacio libre **dentro del sistema de archivos, no el espacio sin asignar fuera de las particiones**.

| Situación actual | Cómo preparar espacio APFS |
|---|---|
| Ya hay un contenedor APFS | Seleccione uno de sus volúmenes en AppPorts; añadirá automáticamente los volúmenes de migración sin reparticionar |
| Ya hay espacio suficiente sin asignar apto para una partición | Cree allí una partición APFS sin borrar la existente; revise el alcance de los cambios en Utilidad de Discos |
| exFAT ocupa todo el disco | Ni Utilidad de Discos de macOS ni Administración de discos de Windows pueden reducir exFAT. Con las herramientas integradas hay que copiar los datos, borrar, reparticionar y restaurarlos |
| NTFS sin espacio sin asignar | macOS no puede reducir NTFS sin pérdida. Redúzcalo primero con Administración de discos de Windows y cree después la partición APFS en macOS. La reducción posible depende, entre otras cosas, de la distribución de archivos |
| Mac OS Plus con registro (HFS+) o contenedor APFS | macOS permite reducirlo sin pérdida si el espacio y la distribución lo permiten y crear después una partición APFS. Haga una copia igualmente |

Si el disco no usa Mapa de particiones GUID, no aplique directamente estos pasos: haga una copia y reparticione primero con ese esquema. Después seleccione el volumen APFS como almacenamiento externo en AppPorts.

Referencias: `resizeVolume` en `man diskutil` exige **journaled HFS+**; APFS usa `apfs resizeContainer`. La [documentación de Microsoft sobre reducir un volumen básico](https://learn.microsoft.com/en-us/windows-server/storage/disk-management/shrink-a-basic-volume) indica que las herramientas integradas admiten NTFS o volúmenes sin sistema de archivos, no exFAT. La reducción sin pérdida de exFAT mediante terceros debe comprobarse por separado; no es una función integrada del sistema.

**También necesita usarlo en Windows**: Windows no lee ni escribe APFS por defecto. Puede usar dos particiones: exFAT para Windows y APFS para AppPorts. Si exFAT ocupa todo el disco, las herramientas integradas no pueden extraer directamente una partición APFS; primero hay que copiar los datos y reparticionar.

## Discos externos encriptados <a href="#encrypted-drives" id="encrypted-drives"></a>

La migración crea un volumen en el contenedor APFS externo que **no hereda** la contraseña original. Un historial protegido localmente por FileVault pasaría a un volumen que cualquiera puede leer al conectar el disco. Hasta resolver el desbloqueo automático al iniciar sesión y la gestión de contraseñas, AppPorts no ofrece migración por montaje a APFS encriptado ni crea silenciosamente un volumen sin encriptar.

Opciones disponibles:

- **Dejar como está**: los datos de contenedores siguen en el Mac y FileVault los protege.
- **Usar un disco o partición APFS sin encriptar**: migre sabiendo que esos datos no estarán encriptados en el disco externo.

## Modo clásico de migración de datos <a href="#modo-clasico-de-migracion-de-datos" id="modo-clasico-de-migracion-de-datos"></a>

El modo clásico de los ajustes recupera los enlaces simbólicos y la nueva firma de la versión 1.8.1. No requiere APFS, pero mantiene todos los riesgos: las apps aisladas podrían no abrirse en macOS 27 y perder su sesión. Solo se conserva para quienes ya dependen del método antiguo. **No se recomienda activarlo para evitar el requisito APFS.** Consulte los [ajustes](settings.md#classic-data-migration-mode).

## Preguntas frecuentes <a href="#preguntas-frecuentes" id="preguntas-frecuentes"></a>

### Qué ocurre con los contenedores ya migrados a exFAT <a href="#que-ocurre-con-los-contenedores-ya-migrados-a-exfat" id="que-ocurre-con-los-contenedores-ya-migrados-a-exfat"></a>

La migración antigua usaba un enlace y una nueva firma, independientemente del formato. El problema es la firma, no el formato. Siga la [guía de macOS 27](macos-27.md) y después [prepare un disco APFS](#prepare-apfs) si quiere seguir usando almacenamiento externo.

### Por qué no ofrecer «Acepto el riesgo» para exFAT <a href="#por-que-no-ofrecer-«acepto-el-riesgo»-para-exfat" id="por-que-no-ofrecer-«acepto-el-riesgo»-para-exfat"></a>

El riesgo no es perder un poco de vez en cuando, sino perder todo el acceso a los datos tras una desconexión, algo habitual en un disco portátil. Cuando el historial ya se ha perdido, recordar que hubo un aviso no sirve de nada.

### Cambiar a APFS afecta al rendimiento <a href="#cambiar-a-apfs-afecta-al-rendimiento" id="cambiar-a-apfs-afecta-al-rendimiento"></a>

No: APFS es el formato nativo de macOS y suele ser más rápido que exFAT en SSD. En las pruebas con la misma memoria USB, la escritura de bases de datos en el volumen APFS fue unas diez veces más rápida que directamente en exFAT.

### Sirve HFS+ (Mac OS Plus) <a href="#sirve-hfs-mac-os-plus" id="sirve-hfs-mac-os-plus"></a>

No directamente para migración por montaje. HFS+ no permite compartir espacio entre varios volúmenes como APFS. Sin embargo, las herramientas de macOS pueden reducir HFS+ con registro sin pérdida para crear una partición APFS si se cumplen las condiciones, a diferencia de exFAT. Haga una copia antes y consulte [Preparar un disco externo APFS](#prepare-apfs).

## Documentación relacionada <a href="#documentacion-relacionada" id="documentacion-relacionada"></a>

- [Migración por montaje](datamigrae/mount-migration.md): cómo usar el nuevo método
- [Experimento: desconexión del disco](https://app.gitbook.com/s/OOJEV4rd6jhAZxZO5wvY/guide/research/unplug-test): datos originales de las pruebas
- [Guía de actualización a macOS 27](macos-27.md): por qué falla el método antiguo en 27
- [Guía de almacenamiento externo](storage-guide.md): interfaces, capacidad y sistemas de archivos
