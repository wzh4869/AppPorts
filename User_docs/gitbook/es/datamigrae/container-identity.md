# Datos de contenedores, aislamiento e identidad de firma

{% hint style="success" %}
**Lo esencial**

Los datos de `~/Library/Containers/` y `~/Library/Group Containers/` pertenecen a **apps aisladas**. Moverlos al disco externo con un «acceso directo», o enlace simbólico, impide que la app los lea. Antes, AppPorts lo evitaba volviendo a firmar la app, a costa de que pudiera dejar de abrirse en macOS 27 y perder su sesión.

Desde la versión 1.9.0, los contenedores usan [migración por montaje](mount-migration.md), sin modificar ni un byte de la firma. Las apps ya firmadas de nuevo necesitan reinstalarse; consulte la [guía de actualización a macOS 27](../macos-27.md).
{% endhint %}

Esta página explica el origen del problema. Si la app ya no se abre, consulte directamente la reparación en la [guía de macOS 27](../macos-27.md).

## Qué es un contenedor <a href="#que-es-un-contenedor" id="que-es-un-contenedor"></a>

La mayoría de las apps de macOS se ejecutan aisladas. El sistema asigna a cada una una carpeta exclusiva, `~/Library/Containers/<Bundle ID>/`, donde puede leer y escribir. Es obligatorio para App Store y habitual en apps descargadas de su web, como WeChat o QQ Music. Los datos compartidos se guardan en `~/Library/Group Containers/`.

Para saber si una app está aislada, busque `com.apple.security.app-sandbox` en sus derechos:

```bash
codesign -d --entitlements - --xml /Applications/WeChat.app 2>/dev/null | grep -c app-sandbox
# 输出 1 就是沙盒应用
```

**Que el programa principal no esté aislado no significa que se puedan mover libremente sus contenedores.** Los programas principales de Chrome y Edge no están aislados, pero sus widgets y extensiones tienen contenedores propios que pertenecen a procesos aislados. AppPorts trata todos los directorios de `Containers` por igual, sin basarse en el programa principal.

## Tres formas de mover datos de contenedores <a href="#tres-formas-de-mover-datos-de-contenedores" id="tres-formas-de-mover-datos-de-contenedores"></a>

| Método | Resultado | Motivo |
|------|------|------|
| Copiar al disco externo y dejar un enlace simbólico | La app se abre, pero no lee los datos; WeChat indica que la ubicación de almacenamiento no se puede usar | El aislamiento comprueba **adónde apunta** el enlace y rechaza cualquier destino fuera del contenedor, tanto un disco externo como el escritorio |
| Enlace simbólico y nueva firma Ad-hoc | Funciona hasta macOS 26; en 27 puede cerrarse tras el doble clic, confirmado en WeChat aunque QQ Music sigue abriéndose | El enlace «funciona» porque se elimina la identidad aislada. También se borra la relación de pertenencia entre app y contenedor, que 27 comprueba |
| Montar un volumen APFS externo en el directorio original | Funciona y conserva la firma | La ruta sigue dentro del contenedor y supera el control. El almacenamiento externo provoca un permiso del sistema que se acepta una vez |

Las tres opciones se han comprobado en macOS 27. Los registros originales están en los experimentos de [enlaces simbólicos](https://app.gitbook.com/s/XSPACE_EN/research/sandbox-symlink) y [puntos de montaje](https://app.gitbook.com/s/XSPACE_EN/research/sandbox-mountpoint).

## Qué cambia realmente al volver a firmar <a href="#que-cambia-realmente-al-volver-a-firmar" id="que-cambia-realmente-al-volver-a-firmar"></a>

La firma Ad-hoc mediante `codesign --force --deep --sign -` elimina:

| Elemento perdido | Consecuencia |
|------|------|
| `com.apple.security.app-sandbox` | La app deja de ejecutarse con identidad aislada |
| `com.apple.security.application-groups` | No puede leer los datos compartidos de `Group Containers` |
| `keychain-access-groups` | No puede leer la sesión ni las claves de bases de datos del llavero |
| Team ID | La identidad no coincide al comprobar la propiedad del contenedor |

La app no falla inmediatamente. Lee su contenedor como un proceso normal, permitido hasta macOS 26. En 27, si existe una autorización de la firma antigua, se rechaza por no coincidir el requisito de código:

```
sandboxd rejected approval request from WeChat for kTCCServiceSystemPolicyAppData
  (/Users/<user>/Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files): denied
runningboardd: termination reported by launchd (0, 0, 65280)
```

El mismo WeChat firmado de nuevo en la misma máquina:

| Sistema | Comportamiento |
|------|------|
| macOS 26.6.2 | Uso normal durante dos días y medio |
| macOS 27.0 | Se cierra unos 0.4 segundos después de cada arranque |

{% hint style="warning" %}
**Haber funcionado antes no demuestra que sea seguro**

Una app firmada de nuevo puede funcionar semanas o meses y fallar en la siguiente actualización importante, sin avisos antes ni después. Además, el certificado original del desarrollador no está en su Mac; no se pueden recrear los derechos eliminados firmando otra vez. Hay que reinstalar.
{% endhint %}

## Por qué se abre desde Terminal <a href="#por-que-se-abre-desde-terminal" id="por-que-se-abre-desde-terminal"></a>

Esto puede confundir el diagnóstico. El sistema atribuye permisos al «proceso responsable». Desde Finder o Dock, la propia app solicita acceso con su identidad y se rechaza. Desde Terminal u otra app que ya tiene acceso total al disco, la responsabilidad se atribuye al anfitrión y la app toma prestados sus permisos.

Por tanto, abrir desde Terminal no demuestra que esté reparada. La comprobación válida es el doble clic desde Finder / Dock.

## Comprobación <a href="#comprobacion" id="comprobacion"></a>

Sustituya `/Applications/WeChat.app` por la app que quiera revisar:

```bash
# 1. 签名身份
codesign -dv --verbose=4 /Applications/WeChat.app 2>&1 | grep -E "Authority|TeamIdentifier|Signature"

# 2. 授权（正常输出一段 XML；只有 Executable= 一行说明已被抹掉）
codesign -d --entitlements - /Applications/WeChat.app

# 3. 容器里有没有指向外置盘的符号链接
find ~/Library/Containers/<Bundle ID> -maxdepth 6 -type l -exec readlink {} \; 2>/dev/null

# 4. 复现一次，看系统有没有拒绝
open -a /Applications/WeChat.app; sleep 3
log show --last 1m --style compact 2>/dev/null | grep -iE "rejected approval request|deny\(1\) file-read-data"
```

| Observación | Significado |
|------|------|
| `Signature=adhoc` y `TeamIdentifier=not set` | La app se ha vuelto a firmar; si no se abre, necesita reinstalarse |
| El paso 3 muestra una ruta hacia `/Volumes/...` | Quedan enlaces simbólicos antiguos en el contenedor; restáurelos primero |
| `kTCCServiceSystemPolicyAppData ... denied` en los registros | Se rechaza el acceso al contenedor propio por haber vuelto a firmar |
| `deny(1) file-read-data /Volumes/...` en los registros | El aislamiento rechaza seguir el enlace a los datos externos |

Ambos mensajes pueden aparecer a la vez. Son dos problemas independientes que deben tratarse por separado.

## Reparación <a href="#reparacion" id="reparacion"></a>

Respete el orden; si no, la app reinstalada seguirá encontrando enlaces simbólicos y parecerá que no se ha arreglado:

1. **Restaurar los datos de contenedores**: en «App Data», use «Restaurar» en cada contenedor de esa app con estado «Enlazado».
2. **Reinstalar la app**: instale encima desde una fuente oficial para recuperar la firma y el aislamiento. No se eliminan los datos del contenedor.
3. **Migrar por montaje si lo necesita**: después aparecerá «Migración por montaje» en los contenedores. Úselo para volver a guardar los datos en el disco externo.

«Restaurar firma original» en la nueva versión restaura la app original desde una copia completa, sin clave privada del desarrollador. Un registro antiguo que solo contiene el nombre de identidad exige un original oficial de la misma versión o una reinstalación oficial. Consulte [Copia de seguridad y restauración de la firma](resign.md#copia-de-seguridad-y-restauracion-de-la-firma). Antes debe restaurar siempre los contenedores migrados en modo clásico.

Para los pasos detallados y el caso de una app que también está en el disco externo, consulte la [reparación en macOS 27](../macos-27.md#reparacion).

## Caso real <a href="#caso-real" id="caso-real"></a>

Cronología completa en una máquina real, en septiembre de 2026:

| Fecha | Suceso |
|------|------|
| 9/15 04:46 | AppPorts migra las conversaciones de WeChat al disco externo y deja un enlace simbólico |
| 9/15 04:47 | AppPorts vuelve a firmar WeChat con Ad-hoc |
| 9/16 a 9/18 | WeChat funciona normalmente dos días y medio en macOS 26.6.2 |
| 9/18 04:46 | Actualización a macOS 27.0 |
| Desde 9/18 | Se cierra unos 0.4 segundos después de cada arranque |
| 9/18 05:04 | El usuario restaura datos y vuelve a firmar; el problema persiste |
| 9/18 | Restaurar los datos y reinstalar WeChat desde su web recupera el funcionamiento, con el historial intacto |

Los datos nunca se dañaron. La causa latente era la nueva firma, sin síntomas antes de actualizar.

## Documentación relacionada <a href="#documentacion-relacionada" id="documentacion-relacionada"></a>

- [Guía de actualización a macOS 27](../macos-27.md): comprobaciones y reparación
- [Migración por montaje](mount-migration.md): nuevo método
- [Por qué el disco externo debe ser APFS](../why-apfs.md)
- [Firma y prevención de cierres inesperados](resign.md): límites actuales de esta función
