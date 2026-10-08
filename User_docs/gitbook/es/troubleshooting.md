# Resolución de problemas

## El icono aparece y desaparece al hacer doble clic <a href="#el-icono-aparece-y-desaparece-al-hacer-doble-clic" id="el-icono-aparece-y-desaparece-al-hacer-doble-clic"></a>

La causa más habitual es una app que AppPorts volvió a firmar y a la que macOS 27 rechaza el acceso a su contenedor tras actualizar. No afecta a todas las apps firmadas de nuevo, pero está confirmado en WeChat. Los datos están intactos.

Para comprobarlo:

```bash
codesign -dv --verbose=4 /Applications/<应用名>.app 2>&1 | grep -E "Signature|TeamIdentifier"
# 出现 Signature=adhoc 和 TeamIdentifier=not set 即是
```

Reparación: restaurar datos de contenedores → reinstalar desde una fuente oficial → migrar por montaje si se necesita. **No vuelva a firmar otra vez** ni considere suficiente restaurar solo los datos. Consulte los [pasos de macOS 27](macos-27.md#reparacion).

## Falla la migración por montaje <a href="#falla-la-migracion-por-montaje" id="falla-la-migracion-por-montaje"></a>

| Mensaje | Causa | Acción |
|------|------|------|
| El almacenamiento externo no es APFS | Disco exFAT / NTFS / HFS+ | Deje los contenedores en el Mac y migre el resto normalmente. Para migrarlos, use otro disco APFS o siga la [preparación](why-apfs.md#prepare-apfs). Las herramientas integradas no reducen exFAT directamente |
| Almacenamiento externo encriptado | APFS encriptado; el nuevo volumen no heredaría la contraseña | Dejar como está o elegir APFS sin encriptar; consulte [Discos encriptados](why-apfs.md#encrypted-drives) |
| Espacio insuficiente | Falta espacio externo para migrar o local para restaurar | Libere espacio y reintente. Se comprueba antes de crear el volumen o copiar; ningún dato ha cambiado |
| Fallo de comando de disco … `kDAReturnNotPrivileged` | Sistemas antiguos como macOS 12 no permiten al usuario montar en rutas personalizadas | AppPorts reintenta con un diálogo de administrador. Introduzca la contraseña; este paso no existía antes de 1.9.0 |
| Autorización de administrador cancelada | Se canceló el diálogo de contraseña | Repita la operación |
| Punto de montaje no vacío | La app escribió archivos locales sin el volumen | Muévalos y pulse «Montar» |
| Verificación posterior al montaje fallida | El volumen está montado en otra ruta | Exporte un diagnóstico y abra una Issue |
| Volumen externo no encontrado | Disco desconectado o volumen eliminado | Reconecte y actualice; si el volumen fue eliminado, los datos no son recuperables |

Si falla, AppPorts elimina el volumen nuevo y devuelve el directorio original a su sitio. Puede comprobar en Utilidad de Discos que no queden volúmenes residuales `AppPorts-`.

## La app no ve los datos después de migrar por montaje <a href="#la-app-no-ve-los-datos-despues-de-migrar-por-montaje" id="la-app-no-ve-los-datos-despues-de-migrar-por-montaje"></a>

Compruebe en este orden:

1. **Conexión y montaje**: el directorio debe estar «Montado» en «App Data». Si está «Montaje pendiente», pulse «Montar»; si está «Disco externo desconectado», conecte el disco.
2. **Permiso denegado**: vaya a Ajustes del Sistema → Privacidad y seguridad → Archivos y carpetas y active Volúmenes extraíbles para la app. También puede ejecutar `tccutil reset SystemPolicyRemovableVolumes <Bundle ID>` en Terminal para volver a pedir permiso.
3. **App del sistema**: las apps de `/System/Applications` se rechazan sin diálogo. AppPorts no admite migrar sus datos.
4. Consulte los registros del sistema:

   ```bash
   log show --last 2m --style compact 2>/dev/null | grep -E "deny\(1\)|RemovableVolumes"
   ```

   `kTCCServiceSystemPolicyRemovableVolumes` corresponde al punto 2.

## La app no arranca después de migrar <a href="#la-app-no-arranca-despues-de-migrar" id="la-app-no-arranca-despues-de-migrar"></a>

1. Compruebe que el disco externo esté conectado.
2. «Enlace huérfano» significa que falta la app externa y hay que quitar el enlace.
3. Si se indica que está dañada, pruebe primero a reinstalar y después considere «Firmar esta app». Se rechazan las apps aisladas; consulte [Firma y prevención de cierres inesperados](datamigrae/resign.md).
4. El bloqueo `uchg` puede impedir ejecutar el actualizador; es lo esperado.
5. Abra la barra de menús → Registros → Ver en Finder y busque los errores.
6. Use «Devolver a este Mac» en la biblioteca externa para comprobar si el disco es la causa.

## Falla la restauración de la firma <a href="#falla-la-restauracion-de-la-firma" id="falla-la-restauracion-de-la-firma"></a>

| Causa | Acción |
|------|------|
| No existe copia de seguridad | No hay registro utilizable; reinstale desde una fuente oficial. El registro pudo haberse limpiado y su ausencia no demuestra que nunca se volviera a firmar |
| Copia antigua sin la app original | Seleccione un `.app` oficial de la misma versión o reinstale. Una copia completa nueva no requiere clave privada |
| App actualizada o copia no válida | Conservar app y copia sin sobrescribir; seleccionar un original oficial coincidente o reinstalar |
| App protegida que no se puede sustituir | Conservar app y copia; reinstalar desde App Store o el instalador oficial |
| App propiedad de root | Se pide contraseña de administrador para cambiar el propietario; cancelar hace fallar la operación |
| App aislada | Volver a firmar se rechaza por defecto. Tras firmar en modo clásico, restaure los contenedores antes de la firma original |

## Migración interrumpida <a href="#migracion-interrumpida" id="migracion-interrumpida"></a>

Si se desconecta el disco, falla el sistema o se fuerza el cierre de AppPorts:

- **Enlace simbólico**: abra AppPorts. Comprueba `.appports-link-metadata.plist` en el disco externo y reanuda si todo coincide; si no, espera su intervención. Busque «Necesita normalización» o «Pendiente de reenlace».
- **Montaje**: los fallos durante la operación se revierten automáticamente. Si se forzó el cierre de AppPorts, ábralo de nuevo: si el directorio original sigue ahí, está intacto y puede eliminar los volúmenes `AppPorts-` sobrantes en Utilidad de Discos. Si pasó a llamarse `.appports-migration-backup-*`, devuélvale su nombre original.

## Almacenamiento externo sin conexión <a href="#almacenamiento-externo-sin-conexion" id="almacenamiento-externo-sin-conexion"></a>

- Directorios por enlace simbólico: el enlace apunta a una ruta no disponible y la app no puede leer datos.
- Directorios por montaje: aparecen vacíos y la app no escribe datos locales.
- App: el lanzador no puede abrir la app externa, pero él mismo no falla.

Al reconectar, AppPorts vuelve a analizar y monta automáticamente los volúmenes migrados. Los sistemas antiguos requieren introducir una vez la contraseña de administrador.

## No se puede migrar una app de App Store al disco externo <a href="#no-se-puede-migrar-una-app-de-app-store-al-disco-externo" id="no-se-puede-migrar-una-app-de-app-store-al-disco-externo"></a>

**Antes de macOS 15.1**: no hay instalación externa nativa. Active la migración de App Store en los ajustes de AppPorts y migre manualmente; repita después de actualizar la app.

**macOS 15.1 y posteriores**: active «Descargar e instalar apps grandes en un disco distinto» en los ajustes de App Store y elija el mismo disco que en AppPorts.

## El destino ya existe <a href="#el-destino-ya-existe" id="el-destino-ya-existe"></a>

- **App**: AppPorts se detiene si el destino externo no es la copia antigua correspondiente a «Pendiente de mover fuera» ni un lanzador antiguo reconocido. Identifíquelo en Finder antes de decidir.
- **Datos**: sin un marcador coincidente, AppPorts no asume la gestión ni sobrescribe basándose solo en el tamaño. Compruebe el contenido y actúe manualmente.
- **Devolver al Mac**: no sobrescribe una app real con el mismo nombre ni un enlace perteneciente a otra app externa.

## La lista de directorios de datos es incorrecta <a href="#la-lista-de-directorios-de-datos-es-incorrecta" id="la-lista-de-directorios-de-datos-es-incorrecta"></a>

1. AppPorts vigila los cambios del sistema de archivos y suele actualizarse automáticamente.
2. Al cambiar rápido de app, los resultados anteriores no sustituyen los actuales. Si la lista queda vacía brevemente, espere al análisis.
3. Si no se actualiza, pulse el botón de actualización superior.
4. Si persiste, consulte los errores de análisis de los registros.
