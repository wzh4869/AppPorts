---
outline: deep
---

# Configuración

La página de configuración de AppPorts es accesible mediante el icono de engranaje en la esquina superior derecha de la ventana principal.

## Configuración de App Store e iOS

| Configuración | Descripción | Predeterminado |
|---------------|-------------|----------------|
| Migración de Apps App Store | Permite la migración de aplicaciones de App Store. Debe habilitarse manualmente en versiones de macOS inferiores a 15.1 | Desactivado |
| Migración de Apps iOS | Permite la migración de aplicaciones iOS/iPadOS (versión Mac) | Desactivado |

::: tip 💡 Usuarios de macOS 15.1+
macOS 15.1 y posteriores soportan la instalación nativa de aplicaciones App Store en discos externos. Se recomienda habilitar "Descargar e instalar aplicaciones grandes en un disco externo" en la configuración de App Store en lugar de usar el interruptor de migración de AppPorts.
:::

## Configuración de Firmado

| Configuración | Descripción | Predeterminado |
|---------------|-------------|----------------|
| Re-firmado Automático | Ejecuta automáticamente el re-firmado Ad-hoc en aplicaciones asociadas después de la migración del directorio de datos | Desactivado |
| Re-firmado al iniciar sesión | Re-firma automáticamente las apps migradas con firmas caducadas cada vez que el usuario inicia sesión | Activado |

Cuando está habilitado, cada migración de directorio de datos hace automáticamente una copia de seguridad de la firma original y ejecuta el re-firmado para evitar mensajes de "Dañado" después de la migración. El re-firmado al iniciar sesión utiliza un LaunchAgent de macOS para ejecutarse automáticamente en segundo plano cada vez que el usuario inicia sesión, garantizando que las firmas caducadas se renueven sin intervención manual.

::: tip 💡 Re-firmado automático para apps vinculadas
Para apps vinculadas (estado: "Vinculada"), el re-firmado automático resuelve automáticamente la **ruta real de la app externa** detrás del shell Stub Portal o el enlace simbólico, asegurando que los cambios de firma se apliquen al paquete de aplicación real. La copia de seguridad y el re-firmado se identifican por el Bundle ID de la app real.
:::

## Configuración de Registro

| Configuración | Descripción | Predeterminado |
|---------------|-------------|----------------|
| Habilitar Registro | Escribe registros de ejecución en archivo | Activado |
| Tamaño Máximo del Registro | Trunca automáticamente la mitad más antigua cuando el archivo de registro excede este tamaño | 2 MB |
| Ubicación del Registro | Ruta de guardado del archivo de registro | `~/Library/Application Support/AppPorts/AppPorts_Log.txt` |

### Operaciones de Registro

| Operación | Descripción |
|-----------|-------------|
| Ver en Finder | Abre el directorio que contiene el archivo de registro |
| Exportar Paquete de Diagnóstico | Genera un archivo ZIP que contiene registros, registros de operaciones e información del sistema |
| Limpiar Registro | Limpia el contenido actual del archivo de registro |

Para descripciones detalladas del registro, consulte [Registro y Diagnóstico](/es/logging).
