---
icon: "circle-question"
layout:
  width: "default"
  outline:
    visible: true
---

# Preguntas frecuentes

## Instalación y permisos <a href="#instalacion-y-permisos" id="instalacion-y-permisos"></a>

### Qué permisos necesita AppPorts <a href="#que-permisos-necesita-appports" id="que-permisos-necesita-appports"></a>

AppPorts necesita **acceso total al disco** para leer y modificar `/Applications`. La primera apertura le guía para concederlo. También puede añadir AppPorts en Ajustes del Sistema → Privacidad y seguridad → Acceso total al disco.

### Qué versiones de macOS son compatibles <a href="#que-versiones-de-macos-son-compatibles" id="que-versiones-de-macos-son-compatibles"></a>

AppPorts requiere como mínimo macOS 12.0 (Monterey). macOS 15.1 (Sequoia) y posteriores también permiten instalar apps de App Store en almacenamiento externo y actualizarlas allí.

### Puedo usar un NAS o una unidad de red <a href="#puedo-usar-un-nas-o-una-unidad-de-red" id="puedo-usar-un-nas-o-una-unidad-de-red"></a>

AppPorts está pensado principalmente para dispositivos externos locales, como discos portátiles, SSD o cajas de discos. NAS, SMB, rclone y SFTP pueden funcionar como rutas del sistema de archivos, pero la estabilidad, permisos, latencia y recuperación tras desconexiones dependen del método de montaje.

Pruebe primero con apps poco importantes o datos que pueda recrear y compruebe que:

- La ruta es accesible antes de abrir AppPorts.
- Tras perder la red, puede volver a montarse automáticamente en la misma ruta.
- El sistema de archivos admite los permisos, atributos extendidos y enlaces simbólicos necesarios.
- No empiece por WeChat, máquinas virtuales o bibliotecas de juegos, por su valor o frecuencia de escritura.

## Migración de apps <a href="#migracion-de-apps" id="migracion-de-apps"></a>

### Cómo analizar apps fuera de /Applications <a href="#como-analizar-apps-fuera-de-applications" id="como-analizar-apps-fuera-de-applications"></a>

Pulse «+» a la derecha de «Apps locales» y seleccione el directorio adicional. Sirve para herramientas como JetBrains Toolbox o Steam, que instalan apps en rutas personalizadas. Los directorios se guardan, se analizan al volver a abrir AppPorts y se vigilan automáticamente. El encabezado muestra cuántos hay; abra ese menú para verlos o quitarlos.

### Qué hacer si una app no se abre después de migrar <a href="#que-hacer-si-una-app-no-se-abre-despues-de-migrar" id="que-hacer-si-una-app-no-se-abre-despues-de-migrar"></a>

1. Compruebe que el almacenamiento externo esté conectado y accesible.
2. Revise las insignias. «Enlace huérfano» significa que falta la app externa y hay que quitar el enlace manualmente.
3. Si el sistema indica que está dañada, pruebe a reinstalar; si persiste, use «Firmar esta app» en el menú contextual. Las apps aisladas se rechazan.
4. Si no se resuelve, use «Devolver a este Mac» en la biblioteca externa para volver a ejecutarla localmente.
5. Si el icono aparece y desaparece al hacer doble clic, consulte la [guía de macOS 27](macos-27.md).

### Qué hacer con el aviso de app dañada <a href="#que-hacer-con-el-aviso-de-app-danada" id="que-hacer-con-el-aviso-de-app-danada"></a>

Normalmente la comprobación de firma de macOS ha detectado cambios en la estructura de la app:

1. Descargue e instale de nuevo desde la web oficial o App Store; suele bastar.
2. Si persiste, seleccione «Firmar esta app» en AppPorts. Se guarda la firma original y se aplica una firma Ad-hoc.
3. Las apps aisladas se rechazan porque volver a firmarlas podría impedir abrirlas en macOS 27. Deben reinstalarse.

Consulte [Firma y prevención de cierres inesperados](datamigrae/resign.md).

### La app falla si desconecto el almacenamiento externo <a href="#la-app-falla-si-desconecto-el-almacenamiento-externo" id="la-app-falla-si-desconecto-el-almacenamiento-externo"></a>

El lanzador local Stub Portal usa `open` para abrir la app externa. Sin el disco, la app no arranca, pero el lanzador no se bloquea. Al reconectar vuelve el funcionamiento normal.

### Por qué sigue apareciendo una flecha de acceso directo <a href="#por-que-sigue-apareciendo-una-flecha-de-acceso-directo" id="por-que-sigue-apareciendo-una-flecha-de-acceso-directo"></a>

Puede proceder de una versión antigua de AppPorts. La actual usa Stub Portal para los `.app` normales y muestra un icono de app sin flecha en la mayoría de los casos.

Si la flecha sigue ahí, probablemente se conserve un enlace simbólico completo antiguo. Devuelva la app al Mac y migre de nuevo con la versión actual.

### Se pueden actualizar las apps después de migrar <a href="#se-pueden-actualizar-las-apps-despues-de-migrar" id="se-pueden-actualizar-las-apps-despues-de-migrar"></a>

Depende del tipo:

| Tipo de app | Actualización automática | Explicación |
|------|:---:|------|
| App nativa sin actualizador propio | ✓ | Mantiene su método habitual |
| Chrome, Edge, actualizador personalizado | ✓ | La actualización se instala localmente; AppPorts marca «Pendiente de mover fuera» si es más reciente |
| Sparkle / Electron | ✗ | El bloqueo impide actualizar desde la app; hay que devolverla al Mac antes de actualizar |
| App Store, macOS 15.1+ | ✓ | App Store actualiza directamente en el disco externo |
| App Store, macOS <15.1 | ✗ | Requiere otra migración manual |

### Qué significa «Pendiente de mover fuera» <a href="#que-significa-«pendiente-de-mover-fuera»" id="que-significa-«pendiente-de-mover-fuera»"></a>

«Pendiente de mover fuera» indica que hay una app real local más reciente que su copia externa. Suele ocurrir cuando Chrome, Edge u otro actualizador instala la versión nueva en el Mac y deja la antigua fuera.

Vuelva a migrar al almacenamiento externo para sustituir la copia antigua. AppPorts compara primero el Bundle ID y después el nombre normalizado. Si faltan versiones, no se pueden comparar o apps con el mismo nombre tienen distintos Bundle ID, no muestra ese estado.

### Se sobrescribe un destino externo que ya existe <a href="#se-sobrescribe-un-destino-externo-que-ya-existe" id="se-sobrescribe-un-destino-externo-que-ya-existe"></a>

No directamente. AppPorts solo lo limpia automáticamente y continúa en estos casos:

- La app está «Pendiente de mover fuera» y el destino es la copia antigua de la misma app.
- El destino se reconoce como un Stub Portal, Deep Contents Wrapper o enlace simbólico completo antiguo creado por AppPorts.
- Es un resto de una migración anterior de AppPorts.

Si hay una app o un directorio real externo cuya pertenencia no puede confirmar, se detiene y muestra un conflicto para no eliminar datos del usuario.

### Cómo migrar apps de App Store a un disco externo <a href="#como-migrar-apps-de-app-store-a-un-disco-externo" id="como-migrar-apps-de-app-store-a-un-disco-externo"></a>

**macOS 15.1+**: active «Descargar e instalar apps grandes en un disco distinto» en los ajustes de App Store y seleccione el mismo almacenamiento que en AppPorts.

**macOS <15.1**: active la migración de apps de App Store en los ajustes de AppPorts. Es un proceso manual; tras actualizar una app debe migrarla de nuevo para sustituir la copia externa.

### Por qué aparece un aviso de app protegida <a href="#por-que-aparece-un-aviso-de-app-protegida" id="por-que-aparece-un-aviso-de-app-protegida"></a>

Las apps de App Store o propiedad de root suelen estar protegidas por permisos de macOS, por lo que AppPorts puede no poder eliminar o sustituir la copia local. Es más seguro moverla al almacenamiento externo desde Finder, introduciendo la contraseña de administrador, y después crear su enlace local con AppPorts. Puede continuar con la migración automática, pero podría fallar por falta de permisos.

### Por qué hay varias opciones «Abrir con» o versiones distintas tras actualizar desde App Store <a href="#por-que-hay-varias-opciones-«abrir-con»-o-versiones-distintas-tras-actualizar-desde-app-store" id="por-que-hay-varias-opciones-«abrir-con»-o-versiones-distintas-tras-actualizar-desde-app-store"></a>

Desde la versión 1.8.0 se sincroniza automáticamente la versión externa con el Stub Portal local y se actualiza «Abrir con». Si persiste una diferencia, pulse actualizar para sincronizar manualmente.

En versiones 1.7.0 y anteriores:

1. Abra AppPorts y actualice las listas locales y externas.
2. Si la versión local es más reciente, vuelva a migrarla para reemplazar la externa.
3. Si solo falla el lanzador, quite el enlace y use «Enlazar de nuevo a local» en la biblioteca externa.

En macOS 15.1+ es preferible la instalación externa nativa de App Store para reducir versiones divergentes.

### La app se abre al hacer doble clic en un documento, pero no abre el archivo <a href="#la-app-se-abre-al-hacer-doble-clic-en-un-documento-pero-no-abre-el-archivo" id="la-app-se-abre-al-hacer-doble-clic-en-un-documento-pero-no-abre-el-archivo"></a>

Suele ocurrir con Office o WPS, que dependen de argumentos de asociación de archivos. Un Stub Portal antiguo podía abrir la app sin pasar la ruta del documento. Actualice a la versión 1.6.2 o posterior y devuelva la app al Mac para migrarla otra vez, o vuelva a usar «Enlazar de nuevo a local» en la biblioteca externa.

Si persiste, exporte un diagnóstico y abra una Issue indicando el origen de la app, App Store, `.pkg` oficial, DMG, etc., y los pasos para reproducirlo.

### Pueden migrarse suites como Adobe u Office <a href="#pueden-migrarse-suites-como-adobe-u-office" id="pueden-migrarse-suites-como-adobe-u-office"></a>

Puede intentarlo, pero suelen incluir varias apps, componentes compartidos, servicios en segundo plano y módulos de licencia, no un único `.app` independiente. AppPorts intenta tratarlas por directorio, aunque la compatibilidad depende de su estructura.

Cierre todas las apps de la suite y compruebe que ha iniciado sesión o activado la licencia. Si después hay fallos de licencia, documentos que no se abren o componentes ausentes, devuélvala al Mac y migre solo las apps independientes o directorios de datos grandes.

### La migración es lenta o parece detenida <a href="#la-migracion-es-lenta-o-parece-detenida" id="la-migracion-es-lenta-o-parece-detenida"></a>

- Cerca del 100 % puede detenerse uno o dos segundos mientras crea el lanzador y realiza las comprobaciones finales.
- Apps grandes como Xcode o Adobe tardan más; es normal.
- Si pasa mucho tiempo sin progreso, revise la estabilidad del almacenamiento externo.
- USB 2.0 es lento; se recomienda USB 3.0 o posterior, o Thunderbolt.

## Migración de directorios de datos <a href="#migracion-de-directorios-de-datos" id="migracion-de-directorios-de-datos"></a>

### Pueden perderse los datos al migrar <a href="#pueden-perderse-los-datos-al-migrar" id="pueden-perderse-los-datos-al-migrar"></a>

Normalmente no. AppPorts copia todos los datos al almacenamiento externo y confirma que la copia terminó antes de eliminar el directorio local original y crear el enlace simbólico. Si falla algún paso, intenta revertirlo.

Si ya existe el destino, solo reanuda cuando `.appports-link-metadata.plist` coincide completamente con la ruta de origen, la de destino y el tipo de datos. Un directorio real sin metadatos coincidentes se considera un conflicto; un tamaño parecido no basta para asumir su gestión ni sobrescribirlo.

### Cuándo puede una migración causar problemas en la app <a href="#cuando-puede-una-migracion-causar-problemas-en-la-app" id="cuando-puede-una-migracion-causar-problemas-en-la-app"></a>

- La app usa bloqueos de archivo o registros SQLite WAL.
- Los atributos extendidos pueden perderse o comportarse de otra forma al acceder por enlaces simbólicos.
- Varias apps de la misma Team comparten `Group Containers`.

Los directorios de `~/Library/Containers/` y `~/Library/Group Containers/` usan montaje, no enlaces simbólicos. Requieren un disco APFS y aceptar el permiso en la primera apertura. Consulte [Migración por montaje](datamigrae/mount-migration.md).

### Puede guardarse el historial de WeChat en un disco externo <a href="#puede-guardarse-el-historial-de-wechat-en-un-disco-externo" id="puede-guardarse-el-historial-de-wechat-en-un-disco-externo"></a>

Sí, con «Migración por montaje». Seleccione WeChat en «App Data». Los subdirectorios `xwechat_files` del grupo `Containers`, separados por cuenta, y `Application Support/com.tencent.xinWeChat` se pueden migrar por montaje. El disco debe ser APFS. Permita el acceso al abrir WeChat por primera vez después de migrar.

**No use** el método antiguo de migrar y volver a firmar: impide que WeChat se abra en macOS 27.

### No veo el historial de WeChat después de migrar <a href="#no-veo-el-historial-de-wechat-despues-de-migrar" id="no-veo-el-historial-de-wechat-despues-de-migrar"></a>

Hay dos casos:

- **Migración por montaje con 1.9.0**: compruebe la conexión del disco, el estado «Montado» y que no haya denegado el permiso. Consulte [Resolución de problemas](troubleshooting.md#la-app-no-ve-los-datos-despues-de-migrar-por-montaje).
- **Migración antigua con enlace simbólico**: el aislamiento impide a WeChat leer fuera de su contenedor. Es una restricción del sistema. Use «Restaurar» para devolver los datos al Mac; si aceptó volver a firmar, reinstale WeChat desde su web. Consulte [Reparación en macOS 27](macos-27.md#reparacion).

**No vuelva a firmar para repararlo**: solo empeorará el problema.

### Mi disco es exFAT: puedo migrar los datos de WeChat <a href="#mi-disco-es-exfat-puedo-migrar-los-datos-de-wechat" id="mi-disco-es-exfat-puedo-migrar-los-datos-de-wechat"></a>

No; la migración por montaje solo admite APFS. **No cambiar nada es una opción perfectamente válida**: deje los datos de WeChat en el Mac y migre la app y los demás datos normalmente. Más adelante, lo más sencillo es usar otro disco APFS. En el disco actual, puede crear una partición APFS si ya hay espacio sin asignar y la distribución lo permite. Si exFAT ocupa todo el disco, ni macOS ni Windows pueden reducirlo directamente con sus herramientas integradas: haga una copia y reparticione. El espacio libre dentro de exFAT no es espacio sin asignar. Descartamos la alternativa de imagen de disco porque quedó totalmente inutilizable al probar una desconexión. Consulte [Por qué APFS](why-apfs.md#what-to-do). La app y los otros directorios no tienen esta restricción.

### Aparecen nuevos iconos de disco en Finder al migrar por montaje <a href="#aparecen-nuevos-iconos-de-disco-en-finder-al-migrar-por-montaje" id="aparecen-nuevos-iconos-de-disco-en-finder-al-migrar-por-montaje"></a>

No. AppPorts oculta los volúmenes de datos de la barra lateral y el escritorio. Pueden verse brevemente durante uno o dos segundos al conectar, pero desaparecen al volver a su sitio. Utilidad de Discos sigue mostrando los volúmenes `AppPorts-…`: contienen sus datos, no los borre ni elimine. Consulte [Uso diario](datamigrae/mount-migration.md#uso-diario).

### Por qué no puedo migrar por montaje a un disco encriptado <a href="#por-que-no-puedo-migrar-por-montaje-a-un-disco-encriptado" id="por-que-no-puedo-migrar-por-montaje-a-un-disco-encriptado"></a>

El volumen nuevo no hereda la contraseña del original. Migrar normalmente dejaría datos protegidos en un volumen sin contraseña. AppPorts se detiene en lugar de reducir la protección silenciosamente. Consulte [Discos externos encriptados](why-apfs.md#encrypted-drives).

### Qué debo hacer antes de eliminar AppPorts <a href="#que-debo-hacer-antes-de-eliminar-appports" id="que-debo-hacer-antes-de-eliminar-appports"></a>

Si usó migración por montaje, restaure primero esos directorios en el Mac con «Restaurar» en «App Data». Si no, los datos siguen en los volúmenes externos, pero nada los monta al iniciar sesión y las apps ven carpetas vacías. Reinstale AppPorts y ábralo una vez para recuperar el acceso.

### Una migración anterior explica que una app no se abra en macOS 27 <a href="#una-migracion-anterior-explica-que-una-app-no-se-abra-en-macos-27" id="una-migracion-anterior-explica-que-una-app-no-se-abra-en-macos-27"></a>

Los datos no están dañados; es un problema de firma. Si aceptó volver a firmar al migrar contenedores con una versión antigua, se eliminó la identidad aislada y macOS 27 empieza a rechazar el acceso al contenedor propio. Restaure los datos y reinstale la app; consulte la [guía de macOS 27](macos-27.md).

### Conviene migrar Crossover, Parallels, máquinas virtuales o bibliotecas de juegos <a href="#conviene-migrar-crossover-parallels-maquinas-virtuales-o-bibliotecas-de-juegos" id="conviene-migrar-crossover-parallels-maquinas-virtuales-o-bibliotecas-de-juegos"></a>

La app puede no ser muy grande; suelen ocupar más las imágenes de máquinas virtuales, contenedores, bibliotecas de juegos o cachés de modelos. Compruebe primero si «Directorios de datos» y «Directorios de herramientas» reconocen sus directorios de datos grandes.

Si contienen discos virtuales, bases de datos o archivos que se escriben con frecuencia, asegure un almacenamiento externo estable y haga una copia. No se recomiendan unidades de red para estos datos de escritura frecuente.

### Cómo restaurar un directorio migrado <a href="#como-restaurar-un-directorio-migrado" id="como-restaurar-un-directorio-migrado"></a>

Búsquelo en la lista y pulse «Restaurar». La migración por enlace simbólico copia los datos al Mac y elimina después el enlace y la copia externa. La migración por montaje copia los datos del volumen y después lo elimina. Mantenga el disco externo conectado.

## Otras preguntas <a href="#otras-preguntas" id="otras-preguntas"></a>

### AppPorts recopila mis datos <a href="#appports-recopila-mis-datos" id="appports-recopila-mis-datos"></a>

No. AppPorts funciona completamente sin conexión y no recopila ni envía datos del usuario. Los registros se guardan en `~/Library/Application Support/AppPorts/`.

### Cómo informar de un problema <a href="#como-informar-de-un-problema" id="como-informar-de-un-problema"></a>

Use las [Issues del proyecto](https://github.com/wzh4869/AppPorts/issues). Adjunte un diagnóstico desde la barra de menús → Registros → «Exportar paquete de diagnóstico» para facilitar el análisis.
