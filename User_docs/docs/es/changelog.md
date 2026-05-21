---
outline: deep
---

# Registro de Cambios

## v1.6.2

- Nuevo: Re-firmado automático al iniciar sesión. Re-firma automáticamente las apps migradas con caducadas cada vez que el usuario inicia sesión, sin acción manual. Activado por defecto, se puede desactivar en Ajustes
- Mejora: Stub Portal ahora usa un lanzador binario Mach-O nativo en lugar del script bash heredado, corrigiendo el problema de que hacer doble clic en documentos asociados en Finder no podía abrir la app externa (#42)
- Mejora: Diseño de la página Acerca de optimizado con área de contenido desplazable, corrigiendo que el contenido se cortara cuando la ventana era demasiado pequeña
- Corregido: El Stub Portal nativo se identificaba incorrectamente como una app local regular
- Corregido: No se podía limpiar correctamente el Stub Portal nativo al mover apps de vuelta al almacenamiento local
- Corregido: El shell de la app se trataba como una app completa durante las operaciones de vinculación inversa
- Corregido: AutoResignInstaller informaba éxito silenciosamente cuando la instalación fallaba

## v1.6.1

- Corregido: El re-firmado automático después de la migración del directorio de datos ahora firma correctamente la app real externa en lugar del shell stub local
- Corregido: Las operaciones de re-firmado y restauración de firma ahora resuelven correctamente la ruta real para apps vinculadas
- Corregido: La detección del estado 'Re-firmado' para apps vinculadas ahora identifica correctamente el estado de firma de la app real externa
- Mejorado: La salida de logs incluye códigos de error estructurados e información de rutas relacionadas

## v1.6.0

- Las apps migradas ya no muestran flechas de marcador
- Las apps de auto-actualización ya no se corrompen por actualizaciones después de la migración
- Añadida función de gestión de firma de apps para corregir mensajes de 'Dañado' después de la migración
- La desconexión del almacenamiento externo ahora muestra advertencias rojas de 'Enlace huérfano'
- Los usuarios de macOS 15.1+ pueden instalar apps de App Store directamente en discos externos
- Migración de directorios de datos más segura: previene la migración accidental del directorio del sistema, recuperación automática después de interrupción
- Escaneo y cálculo de tamaño más rápidos; la lista ya no salta
- Copia de archivos al almacenamiento externo más estable; sin errores por interrupción
- Insignias de estado de apps rediseñadas con información más rica y detalles clicables
- La lista de apps mantiene la selección después de actualizar; los directorios de datos soportan vista de árbol
- Mejoras de UI: búsqueda, ordenación, tarjetas de grupo, carga de iconos, etc.
- Añadida opción de idioma Marciano
- Actualización de pruebas automatizadas

## v1.5.5

- Añadido soporte de instalación externa de apps App Store en macOS 15.1+
- Añadida función de re-firmado automático (se ejecuta automáticamente después de la migración del directorio de datos)
- Añadidas pruebas de auditoría de localización `LocalizationAuditTests`
- Mejorada la lógica de generación de Info.plist de Stub Portal
- Corregido el problema de pérdida de iconos de Launchpad para algunas apps después de la migración

## v1.4.0

- Añadida vista de árbol de directorios de datos
- Añadida detección de directorios de herramientas (30+ herramientas de desarrollo)
- Añadida función de exportación de paquete de diagnóstico
- Mejorada la detección de auto-actualización (Chrome, Edge y otros actualizadores personalizados)
- Corregido el mecanismo de recuperación automática después de la interrupción de migración

## v1.3.0

- Añadida función de migración de directorios de datos
- Añadida gestión de firma de código (copia de seguridad/restauración de firmas originales)
- Añadida auto-detección de aplicaciones Sparkle y Electron
- Mejorada la protección de migración bloqueada (`chflags uchg`)
- Corregidos problemas de visualización de marcadores en Finder

## v1.2.0

- Añadida estrategia de migración Stub Portal (reemplazando Deep Contents Wrapper)
- Añadido soporte de migración de apps iOS (apps iOS versión Mac)
- Mejorado el rendimiento de migración por lotes
- Corregido el problema donde algunas apps no podían iniciarse después de la restauración

## v1.1.0

- Añadido soporte multi-idioma (20+ idiomas)
- Añadida migración de directorios de suites de apps (ej., Microsoft Office)
- Mejorada la detección de almacenamiento externo desconectado
- Corregido el problema de penetración de enlaces simbólicos con la estrategia Deep Contents Wrapper

## v1.0.0

- Primera versión oficial
- Soportada migración de apps al almacenamiento externo (Deep Contents Wrapper / Whole App Symlink)
- Soportada restauración de apps y gestión de enlaces
- Soportado monitoreo de sistema de archivos en tiempo real con FolderMonitor
