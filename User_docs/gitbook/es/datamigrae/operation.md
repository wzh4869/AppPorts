---
icon: "arrows-left-right"
description: "Sigue los pasos para migrar o restaurar directorios de datos."
layout:
  width: "default"
  outline:
    visible: true
---

# Guía práctica de migración de datos

Esta página explica cómo migrar directorios de datos. Para los detalles técnicos, consulte el [funcionamiento](baseinfo.md).

## Buscar los directorios asociados a una app <a href="#buscar-los-directorios-asociados-a-una-app" id="buscar-los-directorios-asociados-a-una-app"></a>

1. Abra la pestaña «Directorios de datos» en la ventana principal de AppPorts.
2. En la parte superior, cambie entre «Directorios de herramientas» y «App Data».
3. Para los datos de apps, seleccione una app a la izquierda. A la derecha aparecerán sus directorios asociados en `~/Library/`.

AppPorts busca las siguientes ubicaciones mediante el Bundle ID o el nombre de la app:

| Ruta analizada | Coincidencia | Método de migración |
|------|------|------|
| `~/Library/Application Support/` | Bundle ID o nombre de la app | Enlace simbólico |
| `~/Library/Preferences/` | Bundle ID o nombre de la app | Enlace simbólico |
| `~/Library/Containers/` | Bundle ID | **Migración por montaje** |
| `~/Library/Group Containers/` | Bundle ID | **Migración por montaje** |
| `~/Library/Caches/` | Bundle ID o nombre de la app | Enlace simbólico |
| `~/Library/WebKit/` | Bundle ID | Enlace simbólico |
| `~/Library/HTTPStorages/` | Bundle ID | Enlace simbólico |
| `~/Library/Application Scripts/` | Bundle ID | Enlace simbólico |
| `~/Library/Logs/` | Nombre de la app | Enlace simbólico |
| `~/Library/Saved Application State/` | Nombre de la app | Enlace simbólico |

Para saber por qué los contenedores son distintos, consulte [Migración por montaje](mount-migration.md).

## Directorios de herramientas <a href="#directorios-de-herramientas" id="directorios-de-herramientas"></a>

AppPorts reconoce los directorios que crean las herramientas de desarrollo habituales en la carpeta de inicio, como `~/.npm` y `~/.gradle`:

1. En «Directorios de datos», cambie a «Directorios de herramientas».
2. La lista muestra los directorios reconocidos, su tamaño, prioridad y estado.

Si no existe el directorio local pero sigue habiendo un directorio gestionado por AppPorts en la ubicación canónica externa, aparece «Pendiente de reenlace». Consulte la lista en [Reconocimiento de directorios de herramientas](tools.md).

## Migración de carpetas personalizadas <a href="#migracion-de-carpetas-personalizadas" id="migracion-de-carpetas-personalizadas"></a>

La pestaña «Directory Migration» permite migrar cualquier carpeta dentro de la carpeta de inicio y resulta útil para proyectos grandes, modelos y bibliotecas de recursos.

1. Abra «Directory Migration».
2. Pulse «+» en el encabezado «Local Folders».
3. Elija la carpeta local y después el directorio raíz de destino externo. El destino es `目标根目录/文件夹名`.

Reglas de validación: la carpeta local debe estar dentro de la carpeta de inicio, sin ser esta misma; ni su ruta ni sus padres pueden ser enlaces simbólicos; no puede contener otro directorio gestionado ni estar contenida en él. El destino externo no puede estar dentro de la carpeta de inicio, ni contener la carpeta local o estar contenido en ella.

Después de migrar, el panel local muestra el estado de la ruta original y el externo el de la copia. Puede usar «Volver a enlazar» o «Restaurar». Quitar la configuración elimina únicamente el registro, no los datos.

## Migración mediante enlace simbólico <a href="#migracion-mediante-enlace-simbolico" id="migracion-mediante-enlace-simbolico"></a>

Se aplica a todos los directorios fuera de los contenedores.

1. Busque el directorio y pulse «Migrate».
2. AppPorts copia los datos al disco externo, escribe el marcador de gestión, renombra el directorio original como copia de seguridad, crea el enlace en la ruta original y elimina la copia de seguridad.
3. Al terminar, el estado cambia a «Enlazado».

{% hint style="success" %}
**Volver a firmar después de la migración**

El interruptor «Volver a firmar después de la migración» está en la barra de herramientas de directorios de datos y viene desactivado. Si se activa, AppPorts vuelve a firmar con Ad-hoc la app asociada tras migrar, solo para tratar el aviso de que está dañada; omite las apps aisladas. Normalmente no es necesario activarlo. Consulte [Firma y prevención de cierres inesperados](resign.md).
{% endhint %}

## Migración por montaje <a href="#migracion-por-montaje" id="migracion-por-montaje"></a>

Se aplica a los directorios de `Containers` y `Group Containers`. El botón muestra «Migración por montaje».

1. Compruebe que el disco externo sea APFS y cierre la app asociada.
2. Pulse «Migración por montaje», lea las tres indicaciones de la confirmación y continúe.
3. AppPorts crea un volumen externo, copia los datos y lo monta en el directorio original.
4. El estado pasa a «Montado». Al abrir la app por primera vez, permita el acceso en el diálogo del sistema.

Consulte la explicación completa en [Migración por montaje](mount-migration.md).

## Restauración <a href="#restauracion" id="restauracion"></a>

**Directorio migrado con enlace simbólico** (estado «Enlazado»): pulse «Restaurar». AppPorts copia los datos de vuelta al Mac, elimina el enlace y después la copia externa.

**Directorio migrado por montaje** (estado «Montado» o «Montaje pendiente»): pulse «Restaurar». AppPorts copia los datos del volumen al Mac, desmonta el volumen y lo elimina. Mantenga el disco externo conectado.

Ambas restauraciones copian primero los datos y después cambian las rutas. Un fallo intermedio no hace perder los datos.

## Resolver estados anómalos <a href="#resolver-estados-anomalos" id="resolver-estados-anomalos"></a>

| Estado | Significado | Acción |
|------|------|------|
| Necesita normalización | Enlace gestionado por AppPorts cuya ruta externa no es la canónica | «Normalizar» mueve los datos a la ruta canónica y recrea el enlace |
| Pendiente de reenlace | Los datos externos siguen ahí, pero falta el enlace local | «Volver a enlazar» recrea el enlace simbólico |
| Enlace simbólico existente | Enlace creado fuera de AppPorts | «Detalles del enlace» permite incorporarlo a la gestión |
| Montaje pendiente | El volumen está disponible, pero no está montado | «Montar» |
| Disco externo desconectado | No se encuentra el volumen de datos | Conecte el disco externo; AppPorts lo volverá a conectar automáticamente |

El reenlace y la normalización solo se aplican a directorios. Si un archivo normal ocupa el destino externo, AppPorts se detiene y conserva ese archivo.

## Contexto de los registros <a href="#contexto-de-los-registros" id="contexto-de-los-registros"></a>

Las operaciones de directorios de datos incluyen información sobre la app asociada para facilitar el diagnóstico:

| Campo | Descripción |
|------|------|
| `app_name` | Nombre de la app asociada |
| `app_status` | Estado de la app |
| `app_is_resigned` | Indica si la app se ha vuelto a firmar |
| `app_bundle_id` | Bundle ID de la app real |
| `app_real_path` | Ruta de la app real |

Las operaciones de migración por montaje también registran el nombre del volumen, su Volume UUID y la salida de los comandos `diskutil`.

## Vista de árbol <a href="#vista-de-arbol" id="vista-de-arbol"></a>

Los directorios con subdirectorios aparecen en árbol: el padre tiene una flecha para desplegarlos a su izquierda, los hijos aparecen sangrados y cada nodo muestra su tamaño, estado y botones de acción.
