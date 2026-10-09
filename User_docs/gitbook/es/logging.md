---
icon: "file-lines"
layout:
  width: "default"
  outline:
    visible: true
---

# Registro y Diagnóstico

AppPorts tiene un sistema de registro integrado que registra eventos clave, operaciones de migración, información del sistema y detalles de errores durante la ejecución de la aplicación. Cuando surgen problemas, puede exportar un paquete de diagnóstico y enviarlo a los [Issues](https://github.com/wzh4869/AppPorts/issues) del proyecto para solución de problemas.

## Contenido Registrado <a href="#contenido-registrado" id="contenido-registrado"></a>

### Información de Sesión de Inicio <a href="#informacion-de-sesion-de-inicio" id="informacion-de-sesion-de-inicio"></a>

La siguiente información se registra cada vez que la aplicación se inicia:

| Elemento | Descripción |
|----------|-------------|
| ID de Sesión | Identificador único para esta ejecución (prefijo UUID de 8 caracteres) |
| ID de Proceso | Identificador de proceso del sistema |
| Bundle ID | Identificador de la aplicación |
| Idioma de la App | Código de idioma actualmente seleccionado |
| Configuración Regional del Sistema | Identificador de configuración regional del sistema |
| Zona Horaria | Identificador de zona horaria actual |
| Lista de Idiomas Preferidos | Orden de idiomas preferidos del sistema |

### Información de Diagnóstico del Sistema <a href="#informacion-de-diagnostico-del-sistema" id="informacion-de-diagnostico-del-sistema"></a>

| Elemento | Descripción |
|----------|-------------|
| Versión de la App | Número de versión y número de compilación |
| Versión de macOS | Versión del sistema y nombre comercial (ej., "macOS Sequoia 15.x") |
| Modelo del Dispositivo | Modelo y nombre amigable (ej., "MacBook Pro (14-inch, M3 Pro, 2023)") |
| Info del Procesador | Cadena de marca, número de núcleos, número de núcleos activos |
| Memoria Física | Memoria total |

### Información de Almacenamiento Externo <a href="#informacion-de-almacenamiento-externo" id="informacion-de-almacenamiento-externo"></a>

Registrada al seleccionar un volumen de almacenamiento externo:

| Elemento | Descripción |
|----------|-------------|
| Nombre del Volumen | Nombre del volumen de almacenamiento |
| Capacidad Total / Espacio Disponible | Información de espacio de almacenamiento |
| Formato del Sistema de Archivos | ej., APFS, HFS+, exFAT, etc. |
| Protocolo de Interfaz | USB, Thunderbolt, NVMe/SATA |
| Velocidad del Dispositivo | Información de tasa de transferencia |
| Tamaño de Bloque | Tamaño de bloque de almacenamiento |
| UUID del Volumen | Identificador único del volumen de almacenamiento |

### Eventos de Operación de Migración <a href="#eventos-de-operacion-de-migracion" id="eventos-de-operacion-de-migracion"></a>

Cada operación de migración genera un ID de operación único (ej., `data-migrate-ABCD1234`), registrando:

- Inicio y fin de la operación
- Progreso de cada paso (copiar, eliminar directorio original, crear enlace simbólico, rollback)
- Capturas de estado de rutas antes y después de los pasos (existencia, permisos, tamaño, destino de symlink, bandera inmutable)
- Detección de datos de migración residuales y recuperación automática
- Progreso de copia de archivos, errores y reintentos

### Informes de Rendimiento de Migración <a href="#informes-de-rendimiento-de-migracion" id="informes-de-rendimiento-de-migracion"></a>

| Elemento | Descripción |
|----------|-------------|
| Nombre de la App | Nombre de la aplicación migrada |
| Tamaño de Datos | Volumen de datos migrado |
| Duración | Duración de la migración (segundos) |
| Velocidad de Transferencia | Tasa de transferencia (MB/s) |
| Ruta de Origen / Ruta de Destino | Rutas de inicio y fin de la migración |

### Detalles de Error <a href="#detalles-de-error" id="detalles-de-error"></a>

Los registros de errores contienen información estructurada:

| Campo | Descripción |
|-------|-------------|
| Descripción del Error | Descripción legible del error |
| Tipo / Dominio / Código de Error | Información estructurada de NSError |
| Código de Error | Código de error interno de AppPorts (ver tabla abajo) |
| Razón del Fallo | Razón detallada del fallo |
| Sugerencia de Recuperación | Sugerencia de recuperación proporcionada por el sistema |
| Ruta de Archivo | Ruta del archivo afectado |
| Rutas Relacionadas | Rutas de apps relacionadas en la operación (`relatedURLs`) |
| Error Subyacente | Error anidado registrado recursivamente |

### Códigos de Error <a href="#codigos-de-error" id="codigos-de-error"></a>

| Código de error | Significado |
|--------|------|
| `BACKUP-SIGNATURE-FAILED` | Fallo de la copia de seguridad de la firma |
| `APP-MOVE-DESTINATION-CONFLICT` | El destino de migración de la aplicación ya existe y no se puede confirmar que sea seguro sustituirlo |
| `APP-RESTORE-LOCAL-CONFLICT` | Al devolver la aplicación al Mac se ha encontrado un elemento local del mismo nombre que no se puede sobrescribir automáticamente |
| `DATA-MIGRATE-DESTINATION-CONFLICT` | El destino de migración del directorio ya existe y los metadatos no coinciden por completo |
| `RESIGN-FAILED` | Fallo al volver a firmar; la aplicación podría no superar la verificación de firma de macOS |
| `DATA-RESIGN-FAILED` | Fallo al volver a firmar automáticamente después de migrar el directorio de datos |
| `RESIGN-REFUSED-SANDBOXED` | Se ha rechazado volver a firmar una aplicación aislada |
| `RESTORE-SIGNATURE-IDENTITY-UNAVAILABLE` | El certificado de firma original no está en este Mac; se ha rechazado la restauración |
| `CONTAINER-MOUNT-*` | Fallo en una etapa de la migración por montaje, por ejemplo `CONTAINER-MOUNT-EXTERNAL-NOT-APFS` o `CONTAINER-MOUNT-SWITCH-FAILED` |
| `CONTAINER-RESTORE-*` | Fallo en una etapa de restauración de un directorio migrado por montaje |
| `DATA-BACKUP-SIGNATURE-FAILED` | Fallo de la copia de seguridad de la firma antes de migrar el directorio de datos; una restauración posterior no podrá usar la identidad original |


### Contexto de Operaciones de Directorio de Datos <a href="#contexto-de-operaciones-de-directorio-de-datos" id="contexto-de-operaciones-de-directorio-de-datos"></a>

Las operaciones de directorio de datos (migración, restauración, normalización, re-vinculación) incluyen automáticamente información de contexto de la app asociada en los registros:

| Campo | Descripción |
|-------|-------------|
| `app_name` | Nombre de la app asociada |
| `app_status` | Estado de la app («Enlazado», «Local», etc.) |
| `app_is_resigned` | Si la app ha sido re-firmada |
| `app_bundle_id` | Bundle ID de la app (leído de la ruta real) |
| `app_real_path` | Ruta real externa de la app |

### Resumen de Operación <a href="#resumen-de-operacion" id="resumen-de-operacion"></a>

Cada operación de migración genera un `OperationSummaryRecord`, reteniendo los 100 registros más recientes:

| Campo | Descripción |
|-------|-------------|
| `operationID` | Identificador único de la operación |
| `category` | Categoría de la operación (`app_move`, `data-migrate`, `file-copy`, etc.) |
| `result` | Resultado (`success`, `failed`, `rolled_back`, `success_with_warning`) |
| `errorCode` | Código de error (si existe) |
| `startedAt` / `endedAt` | Hora de inicio y fin |
| `durationMs` | Duración (milisegundos) |

## Configuración del Registro <a href="#configuracion-del-registro" id="configuracion-del-registro"></a>

### Ubicación de Almacenamiento <a href="#ubicacion-de-almacenamiento" id="ubicacion-de-almacenamiento"></a>

Ruta predeterminada del registro:

```text
~/Library/Application Support/AppPorts/AppPorts_Log.txt
```

Se puede personalizar mediante:

- Barra de menú → Registros → Establecer ubicación del registro...
- Configuración → Configuración de registro → ruta personalizada

### Formato del Registro <a href="#formato-del-registro" id="formato-del-registro"></a>

```text
[2026-05-08 09:30:00] [INFO] [session:a1b2c3d4] [pid:12345] 应用启动
[2026-05-08 09:30:01] [DIAG] [session:a1b2c3d4] [pid:12345]   app_version: 1.6.1 (123)
[2026-05-08 09:30:05] [PERF] [session:a1b2c3d4] [pid:12345]   迁移完成: 2.3 GB, 45.2 MB/s, 52.1s
```

### Niveles de Registro <a href="#niveles-de-registro" id="niveles-de-registro"></a>

| Nivel | Descripción |
|-------|-------------|
| `INFO` | Información general |
| `ERROR` | Información de errores (con detalles de error estructurados) |
| `DIAG` | Información de diagnóstico del sistema |
| `DISK` | Información de volúmenes de almacenamiento externo |
| `PERF` | Informe de rendimiento de migración |
| `TRACE` | Estado de rutas de bajo nivel y monitoreo de carpetas |
| `DEBUG` | Información de depuración (cálculo de tamaño, verificación de directorios anidados) |
| `WARN` | Advertencias (datos de migración residuales, modo de recuperación) |

### Rotación de Registros <a href="#rotacion-de-registros" id="rotacion-de-registros"></a>

- Tamaño máximo predeterminado: **2 MB** (configurable: 1 MB, 5 MB, 10 MB, 50 MB, 100 MB)
- Auto-truncamiento al exceder: Descarta la mitad más antigua de las líneas, mantiene la mitad más nueva

## Exportar paquete de diagnóstico <a href="#exportar-paquete-de-diagnostico" id="exportar-paquete-de-diagnostico"></a>

Cuando surgen problemas que requieren retroalimentación, por favor exporte un paquete de diagnóstico y adjúntelo al Issue.

### Métodos de Exportación <a href="#metodos-de-exportacion" id="metodos-de-exportacion"></a>

**Método 1: Barra de Menú**

1. Haga clic en Barra de menú → Registros → Exportar paquete de diagnóstico
2. Elija la ubicación de guardado
3. El sistema genera automáticamente un archivo `.zip` y lo abre en Finder

**Método 2: Página de Configuración**

1. Abra AppPorts → Configuración (esquina superior derecha)
2. Encuentre la sección "Configuración de registro"
3. Haga clic en el botón "Exportar paquete de diagnóstico"
4. Elija la ubicación de guardado

### Contenido del Paquete de Diagnóstico <a href="#contenido-del-paquete-de-diagnostico" id="contenido-del-paquete-de-diagnostico"></a>

El `AppPorts-Diagnostic-<日期时间>.zip` exportado contiene:

| Archivo | Formato | Descripción |
|---------|---------|-------------|
| `diagnostic-summary.json` | JSON | Metadatos (ID de sesión, versión, configuración regional, zona horaria, etc.) |
| `diagnostic-summary.txt` | Texto plano | Resumen de diagnóstico legible |
| `recent-operations.json` | JSON | Los 100 registros de operaciones más recientes |
| `recent-failures.json` | JSON | Las 20 operaciones fallidas/con advertencia más recientes |
| `AppPorts_Log.share-safe.txt` | Texto plano | Registro completo (anonimizado) |

### Protección de Privacidad <a href="#proteccion-de-privacidad" id="proteccion-de-privacidad"></a>

Los archivos de registro en el paquete de diagnóstico están anonimizados:

| Contenido Original | Reemplazado Con |
|--------------------|-----------------|
| Ruta del directorio home del usuario (ej., `/Users/john`) | `/Users/<redacted-user>` |
| Nombre del volumen de almacenamiento externo (ej., `/Volumes/MyDrive`) | `/Volumes/<redacted-volume>` |
| Ruta completa de `$HOME` | `~` |

## Enviar Issues <a href="#enviar-issues" id="enviar-issues"></a>

Después de obtener el paquete de diagnóstico, siga estos pasos para enviar:

1. Visite la página de [Issues](https://github.com/wzh4869/AppPorts/issues) del proyecto
2. Haga clic en "New Issue", seleccione la plantilla de reporte de Bug
3. Describa el problema y los pasos de reproducción
4. Arrastre el archivo `.zip` de diagnóstico al área de adjuntos para subir
5. Envíe el Issue

{% hint style="success" %}
**💡 Mejorar la Eficiencia de Retroalimentación**

Enviar Issues con paquetes de diagnóstico puede acelerar significativamente la resolución de problemas. El paquete de diagnóstico contiene el historial completo de operaciones, detalles de errores e información del entorno del sistema, permitiendo a los desarrolladores reproducir y analizar problemas sin comunicación repetida.
{% endhint %}
