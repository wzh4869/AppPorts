# Migración por montaje: llevar los datos de contenedores al disco externo

{% hint style="success" %}
**Lo esencial**

Los datos de `~/Library/Containers/` y `~/Library/Group Containers/`, como el historial de WeChat, la caché de QQ Music y los datos de apps de App Store, no se pueden trasladar mediante enlaces simbólicos. Desde AppPorts 1.9.0, se crea un volumen APFS de datos dedicado en el disco externo, se copian los datos y el volumen se **monta en el directorio original**. La app ve la misma ruta y su firma no cambia.

Tres requisitos: disco APFS sin encriptar, aceptar el permiso al abrir la app por primera vez y conectar el disco antes de usarla.
{% endhint %}

## Cuándo se utiliza <a href="#cuando-se-utiliza" id="cuando-se-utiliza"></a>

En «Directorios de datos» → «App Data», seleccione una app. Los directorios de `Containers` y `Group Containers` muestran «Migración por montaje» en vez de «Migrate». Otros grupos, como `Application Support` y cachés, y los directorios de herramientas o personalizados siguen usando enlaces simbólicos.

Para saber por qué los contenedores son especiales y por qué no se toma como criterio el aislamiento del programa principal, consulte [Datos de contenedores, aislamiento e identidad de firma](container-identity.md).

## Después de pulsar «Migración por montaje» <a href="#preflight" id="preflight"></a>

AppPorts primero comprueba el almacenamiento externo en modo de solo lectura, sin cambiar nada, y después propone el siguiente paso:

| Resultado | Qué se muestra | Opciones |
|---|---|---|
| APFS sin encriptar y con espacio suficiente | Espacio que se liberará en el Mac, permiso de la primera apertura y necesidad de mantener el disco conectado | «Migrar datos» para empezar |
| exFAT, NTFS, HFS+, etc. | «Este almacenamiento externo tiene formato exFAT» | «Dejar como está», «Elegir otra ubicación», «Ver cómo prepararlo» |
| APFS encriptado | «Este almacenamiento externo está encriptado» | Dejar como está o elegir una ubicación APFS sin encriptar |
| Espacio insuficiente | Espacio necesario y disponible | Liberar espacio y volver a comprobar, o elegir otra ubicación |
| No hay almacenamiento seleccionado o conectado | Indicación para seleccionarlo o conectarlo | Seleccionar almacenamiento y volver a comprobar |

**Si no puede migrar, no necesita cambiar nada.** La app, `Application Support`, las cachés y los directorios de herramientas pueden seguir migrándose a ese disco. Solo quedan los datos de contenedores en el Mac y la app se usa con normalidad. Para migrarlos más adelante, siga [Preparar un disco externo APFS](../why-apfs.md#prepare-apfs).

{% hint style="info" %}
**Por qué aún no se admiten discos APFS encriptados**

El nuevo volumen de datos no hereda la contraseña del original. Migrar normalmente dejaría en un volumen sin contraseña un historial antes protegido localmente por FileVault. AppPorts no reduce esa protección de forma silenciosa mientras no estén resueltos el desbloqueo automático y la gestión de contraseñas. Consulte [Discos externos encriptados](../why-apfs.md#encrypted-drives).
{% endhint %}

## Antes de migrar <a href="#antes-de-migrar" id="antes-de-migrar"></a>

- **Coloque AppPorts en Aplicaciones y ábralo desde allí.** El agente necesita una ruta permanente. Al ejecutarlo desde Descargas o un DMG, macOS puede usar una ruta temporal de App Translocation; si se detecta, AppPorts bloquea nuevas migraciones por montaje y pide instalarse. Tras mover o actualizar AppPorts, ábralo una vez para ajustar la ruta del agente. Si la ruta no cambia, el agente no se recarga.
- **Cierre completamente la app que va a migrar.** AppPorts lo comprueba e impide migrar mientras esté ejecutándose.
- **AppPorts necesita acceso total al disco.** El sistema controla el montaje en rutas de contenedores y lo rechaza sin permiso.
- **Piense en las copias de seguridad.** Como en cualquier migración, haga una copia independiente de los datos importantes. Después estarán en el disco externo, que Time Machine normalmente no incluye. Compruebe su inclusión en las opciones de Ajustes del Sistema › General › Time Machine si lo necesita.

## Qué ocurre durante la migración <a href="#que-ocurre-durante-la-migracion" id="que-ocurre-durante-la-migracion"></a>

1. Se crea un volumen en el contenedor APFS externo sin montarlo automáticamente en `/Volumes`. Su nombre sigue el patrón `AppPorts-<Bundle ID>-<目录名>-xxxxxx` y comparte el espacio libre con los demás volúmenes, sin tamaño fijo.
2. Se monta temporalmente bajo `~/Library/Application Support/AppPorts/mounts/`, se copia el contenido con el copiador de AppPorts, se escribe `.appports-mount-metadata.plist` en la raíz y se desmonta.
3. Se renombra el directorio original como copia de seguridad en el mismo volumen, se crea un directorio vacío en la ruta original, se monta el volumen allí y se verifica su identidad.
4. Se escribe el registro en `~/Library/Application Support/AppPorts/container-mounts.plist`, se instala el agente de montaje automático al iniciar sesión y se elimina la copia de seguridad.

Si falta espacio externo, AppPorts se detiene antes de crear el volumen. Si se produce un fallo antes de completar la migración, intenta revertir los cambios. Si no puede hacerlo con seguridad, conserva las copias e indica sus rutas.

Si la migración ha terminado y solo falla la eliminación final de la copia de seguridad local, los datos montados siguen disponibles. AppPorts muestra expresamente la ruta de la copia de seguridad que queda pendiente de limpieza. No es necesario repetir la migración.

Después, `mount` muestra el volumen directamente en la ruta del contenedor:

```
/dev/disk7s5 on /Users/<user>/Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files (apfs, local, nodev, nosuid, journaled, noowners, nobrowse)
```

## Primera apertura después de migrar <a href="#primera-apertura-despues-de-migrar" id="primera-apertura-despues-de-migrar"></a>

El sistema pregunta si la app puede acceder a archivos de un volumen extraíble. **Pulse Permitir.** Es una comprobación normal de macOS para datos externos y solo aparece una vez.

Si deniega el permiso, la app se comportará como si no hubiera datos. Para corregirlo, vaya a Ajustes del Sistema → Privacidad y seguridad → Archivos y carpetas, o Volúmenes extraíbles, y active el acceso para la app. También puede ejecutar `tccutil reset SystemPolicyRemovableVolumes <Bundle ID>` en Terminal para que vuelva a preguntarlo.

Las apps del sistema de `/System/Applications` se rechazan silenciosamente, sin diálogo. AppPorts no las migra.

## Uso diario <a href="#uso-diario" id="uso-diario"></a>

**Conecte el disco externo antes de abrir la app.** Si falta, el punto de montaje es un directorio vacío bloqueado con permisos 000. La app ve datos vacíos, no muestra errores y no escribe una segunda copia local. Al conectar el disco, AppPorts vuelve a montar automáticamente el volumen y los datos reaparecen.

**Estos volúmenes de datos normalmente no aparecen en Finder.** AppPorts usa `nobrowse` para ocultarlos de la barra lateral y el escritorio. Durante uno o dos segundos tras conectar, macOS puede montarlos primero en `/Volumes` y mostrar una imagen del disco; desaparece cuando AppPorts los coloca en su sitio. Los volúmenes antiguos aún visibles se ocultan sin desmontarlos al volver a abrir AppPorts o conectar el disco. Los volúmenes `AppPorts-…` siguen apareciendo en Utilidad de Discos. **No los borre ni los elimine: contienen los datos migrados.**

**Antes de desconectar, cierre la app y pulse «Desmontar» en AppPorts, o expulse el disco desde Finder.** Desconectarlo directamente puede perder los últimos segundos de escritura y exigir reparar la base de datos. En nuestras pruebas, los volúmenes APFS solo perdieron las últimas transacciones; consulte el [experimento de desconexión](https://app.gitbook.com/s/OOJEV4rd6jhAZxZO5wvY/guide/research/unplug-test).

**Cuándo se vuelve a conectar automáticamente:**

- Con AppPorts abierto: al arrancar y cada vez que aparece un volumen, vuelve a montar los volúmenes disponibles pendientes.
- Sin AppPorts abierto: tras migrar correctamente, instala un agente que monta silenciosamente al iniciar sesión y al conectar el disco, y después termina. Se desinstala cuando se restaura el último registro.
- Una app abierta inmediatamente después de iniciar sesión puede ver un directorio vacío durante unos diez segundos, porque el sistema inicia el agente después de los ítems de inicio. Cierre la app y ábrala de nuevo. El punto de montaje se mantiene vacío mientras espera: aunque la app arranque antes, no crea datos locales divergentes. Se recupera cuando vuelve el volumen, como se observó en tres pruebas con WeChat.

{% hint style="warning" %}
**Los sistemas antiguos, como macOS 12, piden contraseña de administrador**

macOS 27 permite a un usuario normal montar un volumen dentro de su propio directorio; en las pruebas, macOS 12 no lo permitía. AppPorts reintenta con el diálogo de contraseña de administrador, normalmente una sola vez por migración. El agente no tiene interfaz y no puede pedirla. En esos sistemas, abra AppPorts tras iniciar sesión para introducirla o pulse «Montar» manualmente en «App Data». Las versiones de 13 a 26 aún no se han comprobado una por una.
{% endhint %}

## Estados y acciones <a href="#statuses" id="statuses"></a>

| Estado | Significado | Acciones |
|------|------|------|
| Montado | Volumen montado en el directorio original; lectura y escritura normales | Desmontar, Restaurar |
| Montaje pendiente | Volumen disponible pero no montado, tras conectarlo o desmontarlo manualmente | Montar, Restaurar |
| Disco externo desconectado | No se encuentra el volumen de datos, normalmente porque el disco está desconectado | Conecte el disco para recuperarlo automáticamente; si ya está conectado, consulte [Resolución de problemas](#troubleshooting) |

**Restaurar** copia los datos del volumen al Mac y después elimina el volumen y el registro. El disco externo debe permanecer conectado:

- Se comprueba el espacio local antes de empezar. Si falta, se conservan el volumen y el registro sin cambios.
- Después de copiar, AppPorts convierte primero el registro de montaje en información de limpieza pendiente para impedir el montaje automático y después vuelve al directorio local. Solo elimina el punto de montaje vacío que queda al desmontar; nunca elimina directorios recursivamente.
- Si no se completa el cambio al directorio local, se conservan tanto la copia local provisional como el volumen externo. La copia local sigue en una carpeta oculta `.appports-restore-staging-…` del mismo directorio. Siga las rutas conservadas y las indicaciones que muestra AppPorts.
- Si el directorio local ya está restaurado y solo falla la eliminación del volumen externo o la actualización del registro de limpieza, AppPorts indica expresamente que la restauración ha terminado, pero la limpieza no. Puede reintentar la limpieza desde la página Directorios de datos. No repita la migración ni la restauración.

Si no puede confirmar si una copia sigue existiendo, puede elegir «Eliminar solo el registro de limpieza»; esta acción no elimina copias de seguridad locales ni volúmenes externos, ni vuelve a montarlos, y deberá limpiar manualmente las copias que aún existan.

Si aparecen archivos locales en el punto de montaje, por ejemplo porque una app consiguió escribir sin el disco, AppPorts se niega a ocultarlos con un montaje. Muévalos antes de montar el volumen.

## Antes de eliminar o mover AppPorts <a href="#antes-de-eliminar-o-mover-appports" id="antes-de-eliminar-o-mover-appports"></a>

La migración por montaje depende del agente de AppPorts para recuperar los volúmenes al iniciar sesión. **Antes de eliminar AppPorts, use «Restaurar» en «App Data» para devolver al Mac los directorios migrados.** De lo contrario, los datos siguen intactos en los volúmenes externos, pero nada los monta y la app ve directorios vacíos. Reinstalar AppPorts y abrirlo una vez recupera el funcionamiento.

Si solo actualiza o mueve AppPorts, abra la nueva versión una vez: actualizará automáticamente la ruta del agente.

## Resolución de problemas <a href="#troubleshooting" id="troubleshooting"></a>

| Síntoma | Acción |
|---|---|
| «Disco externo desconectado» aunque el disco está conectado | Compruebe en Utilidad de Discos que siguen existiendo los volúmenes `AppPorts-…`. Si existen, actualice AppPorts o reconecte el disco. Si se eliminaron, esos datos ya no están en el disco y solo pueden recuperarse desde una copia de seguridad |
| La app aparece vacía | Compruebe el estado «Montado». Si no lo tiene, conecte el disco o pulse «Montar». Si ya está montado, revise si denegó el permiso en la [primera apertura](#primera-apertura-despues-de-migrar) |
| «Montar» indica que el punto de montaje no está vacío | Identifique los archivos locales y muévalos antes de montar |
| Migrar o restaurar indica que se está conectando el almacenamiento en segundo plano | El agente está montando; espere unos segundos y vuelva a intentarlo |

## Por qué no se usan imágenes de disco <a href="#por-que-no-se-usan-imagenes-de-disco" id="por-que-no-se-usan-imagenes-de-disco"></a>

Para los usuarios de exFAT probamos seriamente guardar una imagen APFS sparsebundle en el disco y montarla. Evitaba el diálogo de permisos, rendía de forma similar y podía guardarse en cualquier formato.

Después desconectamos la memoria USB durante una escritura. El volumen APFS solo perdió las últimas transacciones y su base de datos se pudo reparar. En las dos pruebas, **la imagen de disco dejó de abrirse por completo** y todos sus datos quedaron inaccesibles. Su propio «catálogo» se reescribe cada pocos segundos; interrumpir esa escritura deja fragmentos sin catálogo. Consulte los [datos del experimento](https://app.gitbook.com/s/OOJEV4rd6jhAZxZO5wvY/guide/research/unplug-test) y la explicación [Por qué el disco externo debe ser APFS](../why-apfs.md).

Por eso solo se admiten volúmenes APFS.

## Detalles técnicos <a href="#technical-details" id="technical-details"></a>

### Secuencia del montaje automático <a href="#secuencia-del-montaje-automatico" id="secuencia-del-montaje-automatico"></a>

- El agente `~/Library/LaunchAgents/com.shimoko.AppPorts.container-mount.plist` ejecuta `AppPorts --mount-agent`. También vigila `/Volumes` y vuelve a ejecutarse cuando aparece un disco. En el arranque medido el 2026-09-22: inicio de sesión terminado → agente tras 4.6 segundos → dos volúmenes montados en los contenedores tras 18 segundos. Fue unos 19 segundos más rápido que antes, pero las apps de inicio arrancaban en unos 3 segundos. Consulte la secuencia en el [experimento de montaje antes del inicio de sesión](https://app.gitbook.com/s/OOJEV4rd6jhAZxZO5wvY/guide/research/prelogin-mount).
- **Si el disco tarda, el agente no se limita a un intento.** Observa `/Volumes` dentro del proceso y espera al siguiente **cambio real**, en vez de consultar a intervalos fijos. Al arrancar, el sistema puede tardar minutos en reconocerlo; el 2026-09-23 tardó 2 minutos y 33 segundos. Consultar periódicamente ejecutaría `diskutil` en el momento de mayor carga o perdería el arranque de la app. Si no hay eventos, comprueba cada 20 segundos como respaldo, durante un total de 180 segundos. No retiene el bloqueo mientras espera. Medición: aproximadamente 1 segundo desde que aparece el volumen hasta completar el montaje.
- **Mirar primero `/Volumes/<卷名>`.** Al arrancar o conectar, el sistema casi siempre monta ahí primero. `statfs` y una lectura del marcador de raíz, en microsegundos, identifican nuestro volumen y evitan una consulta `diskutil info`. En el arranque del 2026-09-23, esa consulta tardó **9 segundos**, el paso más costoso. Solo se recurre a `diskutil` si no puede reconocerse, por ejemplo por un cambio de nombre del sistema o un marcador ausente.
- **Verificar después del montaje.** Si el sistema ya montó el volumen en `/Volumes`, `diskutil mount -mountPoint` puede **ignorar la ruta solicitada, imprimir `mounted` y devolver 0 igualmente**. Por ello se comprueba siempre la ubicación real. Si no coincide, se consulta dónde está montado, se desmonta de `/Volumes` y se reintenta, hasta 3 ciclos. Ocurrió el 2026-09-21 y el 09-23; las versiones de entonces lo consideraban un fallo y abandonaban, y WeChat veía un directorio vacío.
- **Actuar solo sobre sus propios volúmenes.** Antes de montar, desmontar o restaurar, se verifica que el Volume UUID del punto de montaje coincida con el registro. Si hay otro volumen, se detiene sin desmontarlo, sobrescribirlo ni eliminarlo.
- El agente y AppPorts comparten un bloqueo entre procesos: `~/Library/Application Support/AppPorts/operation.lock`. Mientras AppPorts migra, desmonta o restaura, el agente espera hasta 120 segundos y después omite ese ciclo hasta la siguiente conexión o sesión. A la inversa, AppPorts no empieza sin obtenerlo e indica reintentar. El bloqueo solo se mantiene durante cada ciclo de montaje, no durante los minutos de espera del disco, para no bloquear sus operaciones.
- Si el archivo de registros no se puede leer, AppPorts no lo sobrescribe como si estuviera vacío: conserva el original y rechaza añadir o eliminar registros.
- No se usa `/etc/fstab`: en las pruebas, `UUID=` no montaba, los números de dispositivo cambiaban al reconectar y el montaje por root al arrancar seguía sujeto a controles de permisos.

### Índice Spotlight del volumen <a href="#indice-spotlight-del-volumen" id="indice-spotlight-del-volumen"></a>

El sistema trata los volúmenes montados en rutas de contenedores como volúmenes externos normales y crea su índice. Los dos volúmenes de WeChat probados sumaban 110 MB en `.Spotlight-V100` y seguían reescribiéndose tras el arranque. El índice no resulta útil para estos datos de apps:

- Tras crear el volumen, se escribe un archivo vacío `.metadata_never_index` en la raíz para que mds lo omita por completo. Si ya existe `.Spotlight-V100`, se elimina.
- El marcador acompaña al volumen; no hay que repetirlo al cambiar la ubicación del disco o restaurar la migración por montaje.
- Los volúmenes migrados antes de esta versión reciben el marcador en el siguiente montaje.
- No se copia al directorio local al restaurar: se omite `.metadata_never_index` igual que `.fseventsd` y `.Spotlight-V100`.

### Comandos de comprobación <a href="#comandos-de-comprobacion" id="comandos-de-comprobacion"></a>

```bash
# 挂载记录
plutil -p ~/Library/Application\ Support/AppPorts/container-mounts.plist

# 当前挂载
mount | grep Containers

# 登录代理
launchctl print gui/$(id -u)/com.shimoko.AppPorts.container-mount

# 卷根有没有防索引标记；系统的索引状态应为 Indexing disabled
ls -la "<挂载点路径>/.metadata_never_index"
mdutil -s "<挂载点路径>"

# 手动重挂（要在有完全磁盘访问权限的终端里执行；旧系统前面加 sudo）
diskutil mount nobrowse -mountPoint "<挂载点路径>" <Volume UUID>
```

## Documentación relacionada <a href="#documentacion-relacionada" id="documentacion-relacionada"></a>

- [Por qué el disco externo debe ser APFS](../why-apfs.md)
- [Datos de contenedores, aislamiento e identidad de firma](container-identity.md)
- [Guía de actualización a macOS 27](../macos-27.md): cómo cambiar desde el método antiguo
- [Experimento: puntos de montaje](https://app.gitbook.com/s/OOJEV4rd6jhAZxZO5wvY/guide/research/sandbox-mountpoint): pruebas en que se basa esta función
