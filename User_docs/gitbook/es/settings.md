# Ajustes

Los ajustes de AppPorts se abren desde el icono de engranaje de la esquina superior derecha de la ventana principal.

## Ajustes de App Store e iOS <a href="#ajustes-de-app-store-e-ios" id="ajustes-de-app-store-e-ios"></a>

| Ajuste | Descripción | Valor predeterminado |
|------|------|------|
| Migración de apps de App Store | Permite migrar apps de App Store. En versiones anteriores a macOS 15.1, debe activarse manualmente para migrarlas | Desactivado |
| Migración de apps de iOS | Permite migrar apps de iOS/iPadOS para Mac | Desactivado |

{% hint style="success" %}
**Usuarios de macOS 15.1+**

macOS 15.1 y posteriores permiten instalar apps de App Store directamente en almacenamiento externo. Es preferible activar «Descargar e instalar apps grandes en un disco distinto» en los ajustes de App Store en lugar de usar la migración manual de AppPorts.
{% endhint %}

## Ajustes de firma <a href="#ajustes-de-firma" id="ajustes-de-firma"></a>

| Ajuste | Ubicación | Descripción | Valor predeterminado |
|------|------|------|------|
| Volver a firmar después de la migración | Barra de herramientas de directorios de datos, **solo en modo clásico** | Vuelve a firmar con Ad-hoc la app asociada tras migrar mediante enlace simbólico | Desactivado |
| Re-firmado al iniciar sesión | Ajustes | Al iniciar sesión, vuelve a firmar apps cuya copia de seguridad indica que ya tenían firma Ad-hoc, para resolver su invalidación tras reiniciar; omite las apps aisladas, salvo en modo clásico | Desactivado en instalaciones nuevas; sigue activado para quienes ya tenían instalado el agente de inicio de sesión |

Fuera del modo clásico, ninguna opción vuelve a firmar apps aisladas, porque podrían dejar de abrirse en macOS 27. Los datos de contenedores usan [migración por montaje](datamigrae/mount-migration.md), sin necesidad de cambiar la firma.

El script de inicio de sesión omite los registros nuevos con una copia completa de la app original. AppPorts verifica las operaciones de firma y sustituye los archivos de forma segura. El script instalado se sincroniza al abrir la app.

«Re-firmado al iniciar sesión» instala el LaunchAgent `com.shimoko.AppPorts.re-sign` y escribe en el registro predeterminado de AppPorts. La firma y la copia de seguridad afectan a la app real del disco externo, no al lanzador local. Consulte [Firma y prevención de cierres inesperados](datamigrae/resign.md).

## Modo clásico de migración de datos (no recomendado) <a href="#classic-data-migration-mode" id="classic-data-migration-mode"></a>

El interruptor situado al final de los ajustes está desactivado por defecto. Se conserva para quienes ya dependen del método de la versión 1.8.1 y todavía no pueden cambiarlo. Si el disco externo no es APFS, mantenga la situación actual y deje los datos de contenedores en el Mac, en vez de activar este modo para evitar ese requisito. Consulte [Por qué el disco externo debe ser APFS](why-apfs.md#what-to-do). Antes de activarlo debe marcar «Entiendo estos riesgos» en la confirmación. En macOS 27, un aviso junto al interruptor indica que las apps aisladas firmadas de nuevo podrían no abrirse. Al activarlo:

| Elemento | Desactivado (predeterminado) | Activado |
|------|------|------|
| Botones de directorios de contenedores | Solo «Migración por montaje» | «Migrate» mediante enlace simbólico y «Migración por montaje» |
| Confirmación para volver a firmar antes de migrar un contenedor | No aparece | Aparece, con solo migración como opción predeterminada |
| Volver a firmar apps aisladas | Se rechaza en todas las opciones | Se permite tras una segunda confirmación que explica las consecuencias |
| Interruptor «Volver a firmar después de la migración» | Oculto | Visible en la barra de herramientas de directorios de datos |
| «Normalizar», «Volver a enlazar» y «Detalles del enlace» de contenedores | Desactivados; indica restaurar antes de migrar por montaje | Disponibles |

El modo clásico recupera todo el método anterior, incluidos sus riesgos: las apps aisladas firmadas de nuevo podrían no abrirse en macOS 27 y requerir restaurar los datos y reinstalar. AppPorts las marca como «Firma sustituida» y avisa al arrancar; consulte la [guía de actualización a macOS 27](macos-27.md). Desactivar el modo clásico no modifica las migraciones por enlace simbólico existentes. «Restaurar» sigue disponible.

## Ajustes relacionados con la migración por montaje <a href="#ajustes-relacionados-con-la-migracion-por-montaje" id="ajustes-relacionados-con-la-migracion-por-montaje"></a>

Esta migración no tiene un ajuste independiente. «Estado de preparación» comprueba el acceso total al disco, la ubicación de AppPorts y el formato del almacenamiento externo, e indica qué requiere atención. Tras la primera migración por montaje correcta, AppPorts instala el agente de inicio de sesión `com.shimoko.AppPorts.container-mount` para volver a montar los volúmenes disponibles en sus contenedores. Se desinstala cuando se restaura el último registro de montaje. En sistemas antiguos como macOS 12, el agente no puede mostrar el diálogo de contraseña de administrador; abra AppPorts tras iniciar sesión para completar el montaje.

## Ajustes de registro <a href="#ajustes-de-registro" id="ajustes-de-registro"></a>

| Ajuste | Descripción | Valor predeterminado |
|------|------|------|
| Activar registro | Escribe los registros de ejecución en un archivo | Activado |
| Tamaño máximo del registro | Elimina la mitad más antigua cuando se supera el límite | 2 MB |
| Ubicación del registro | Ruta del archivo de registro | `~/Library/Application Support/AppPorts/AppPorts_Log.txt` |

### Operaciones de registro <a href="#operaciones-de-registro" id="operaciones-de-registro"></a>

| Operación | Descripción |
|------|------|
| Ver en Finder | Abre la carpeta que contiene el registro |
| Exportar paquete de diagnóstico | Genera un ZIP con registros, operaciones e información del sistema |
| Vaciar registro | Borra el contenido del registro actual |

Para más información, consulte [Registros y diagnóstico](logging.md).

Antes de crear una copia, firmar o restaurar manualmente, AppPorts detiene la tarea de firma en segundo plano de esta sesión y espera a que terminen sus procesos hijos, para evitar que sobrescriban una firma recién restaurada. La configuración del agente se conserva y el ajuste vuelve a aplicarse en el siguiente inicio de sesión. Si no puede confirmar que la tarea se ha detenido, se cancela la operación manual.
