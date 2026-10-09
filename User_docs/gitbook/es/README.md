---
description: "La guía de macOS para instalar AppPorts, migrar apps y datos y mantenerlos en el día a día."
layout:
  width: "wide"
  outline:
    visible: false
  pagination:
    visible: false
  metadata:
    visible: false
  title:
    visible: false
  description:
    visible: false
  cover:
    visible: true
    size: "background"
icon: "book-open"
cover: ".gitbook/assets/home-cover.svg"
coverY: 0
---

# AppPorts

## Los discos externos salvan el mundo <a href="#los-discos-externos-salvan-el-mundo" id="los-discos-externos-salvan-el-mundo"></a>

La guía de macOS para instalar AppPorts, migrar apps y datos y mantenerlos en el día a día.

<button type="button" class="button primary" data-action="ask" data-icon="gitbook-assistant">¿Qué quieres saber sobre AppPorts?</button>

<a href="faststart.md" class="button primary">Inicio rápido</a> <a href="AppPorts.md" class="button secondary">Introducción</a>

<h3 align="center">Empieza aquí <a href="#empieza-aqui" id="empieza-aqui"></a></h3>

<p align="center">Elige una guía para empezar, mover aplicaciones o migrar datos.</p>

<table data-view="cards">
<thead><tr><th width="48"></th><th></th><th></th><th></th><th></th><th></th></tr></thead>
<tbody>
<tr><td><i class="fa-rocket"></i></td><td><h4>Primeros pasos <a href="#start-1" id="start-1"></a></h4></td><td>Conoce AppPorts, la instalación, los permisos y la configuración básica.</td><td><a data-mention href="faststart.md">Inicio rápido</a></td><td><a data-mention href="AppPorts.md">Introducción</a></td><td><a data-mention href="settings.md">Ajustes</a></td></tr>
<tr><td><i class="fa-layer-group"></i></td><td><h4>Migración de aplicaciones <a href="#start-2" id="start-2"></a></h4></td><td>Consulta cómo migrar y restaurar aplicaciones y las estrategias según su tipo.</td><td><a data-mention href="core.md">Funciones principales</a></td><td><a data-mention href="migration-strategy/portal.md">Estrategias de migración</a></td><td><a data-mention href="migration-strategy/strategy-map.md">Tipos de apps y estrategias</a></td></tr>
<tr><td><i class="fa-database"></i></td><td><h4>Migración de datos <a href="#start-3" id="start-3"></a></h4></td><td>Consulta las guías de directorios de datos, datos de herramientas y migración de contenedores por montaje.</td><td><a data-mention href="datamigrae/operation.md">Guía de migración</a></td><td><a data-mention href="datamigrae/tools.md">Detección de directorios de herramientas</a></td><td><a data-mention href="datamigrae/mount-migration.md">Migración por montaje</a></td></tr>
</tbody>
</table>

***

<h3 align="center">Almacenamiento y mantenimiento <a href="#storage-and-maintenance" id="storage-and-maintenance"></a></h3>

<p align="center">Consulta los requisitos de los discos externos, las actualizaciones y las guías de solución de problemas.</p>

<table data-view="cards">
<thead><tr><th width="48"></th><th></th><th></th><th></th><th></th><th></th></tr></thead>
<tbody>
<tr><td><i class="fa-hard-drive"></i></td><td><h4>Almacenamiento externo <a href="#maintain-1" id="maintain-1"></a></h4></td><td>Consulta cómo elegir un disco, cuándo se necesita APFS y los límites de compatibilidad.</td><td><a data-mention href="storage-guide.md">Guía de almacenamiento externo</a></td><td><a data-mention href="why-apfs.md">Requisitos de APFS</a></td><td><a data-mention href="limitations.md">Compatibilidad y limitaciones</a></td></tr>
<tr><td><i class="fa-arrows-rotate"></i></td><td><h4>Actualizaciones y mantenimiento <a href="#maintain-2" id="maintain-2"></a></h4></td><td>Conoce las actualizaciones de apps, los cambios de macOS 27 y la relación entre datos de contenedores e identidad de firma.</td><td><a data-mention href="migration-strategy/updater-detection.md">Apps con actualización automática</a></td><td><a data-mention href="macos-27.md">Actualización a macOS 27</a></td><td><a data-mention href="datamigrae/container-identity.md">Datos de contenedores y firma</a></td></tr>
<tr><td><i class="fa-life-ring"></i></td><td><h4>Solución de problemas <a href="#maintain-3" id="maintain-3"></a></h4></td><td>Consulta las comprobaciones por síntoma, las preguntas frecuentes y las guías de registros y diagnóstico.</td><td><a data-mention href="troubleshooting.md">Solución de problemas</a></td><td><a data-mention href="faq.md">Preguntas frecuentes</a></td><td><a data-mention href="logging.md">Registro y diagnóstico</a></td></tr>
</tbody>
</table>

***

<h3 align="center">Explora las funciones principales <a href="#explora-las-funciones-principales" id="explora-las-funciones-principales"></a></h3>

<p align="center">Conoce las tres funciones principales de AppPorts.</p>

<table data-view="cards">
<thead><tr><th width="48"></th><th></th><th></th><th data-hidden data-card-target data-type="content-ref"></th></tr></thead>
<tbody>
<tr><td><i class="fa-layer-group"></i></td><td><strong>Migración sin flecha de acceso directo</strong></td><td>Traslada aplicaciones grandes al almacenamiento externo con un clic. Solo queda un contenedor de lanzamiento ligero en el Mac; Finder no muestra flechas de acceso directo, y Launchpad y los menús de aplicaciones funcionan con normalidad.</td><td><a href="core.md">core.md</a></td></tr>
<tr><td><i class="fa-arrows-rotate"></i></td><td><strong>Protección frente a actualizaciones automáticas</strong></td><td>AppPorts detecta aplicaciones con actualización automática, como Sparkle y Electron, y ofrece «Migración bloqueada». Si la versión local es más reciente que la copia externa, muestra «Pendiente de mover fuera».</td><td><a href="migration-strategy/updater-detection.md">migration-strategy/updater-detection.md</a></td></tr>
<tr><td><i class="fa-database"></i></td><td><strong>Gestión de directorios de datos</strong></td><td>Traslada subdirectorios de ~/Library/, ~/.npm y otros datos al almacenamiento externo. Los datos de contenedores de aplicaciones aisladas, como el historial de WeChat, se migran por montaje a un disco externo APFS sin modificar la firma.</td><td><a href="datamigrae/README.md">datamigrae/README.md</a></td></tr>
</tbody>
</table>

***

<h3 align="center">Sigue explorando <a href="#keep-exploring" id="keep-exploring"></a></h3>

<table data-view="cards">
<thead><tr><th width="48"></th><th></th><th></th><th data-hidden data-card-target data-type="content-ref"></th></tr></thead>
<tbody>
<tr><td><i class="fa-clock-rotate-left"></i></td><td><h4>Registro de cambios <a href="#explore-1" id="explore-1"></a></h4></td><td>Consulta los cambios y las correcciones por versión.</td><td><a href="changelog.md">changelog.md</a></td></tr>
<tr><td><i class="fa-flask"></i></td><td><h4>Experimentos <a href="#explore-2" id="explore-2"></a></h4></td><td>Consulta experimentos sobre aislamiento, montajes, desconexión de discos y arranque.</td><td><a href="research/README.md">research/README.md</a></td></tr>
<tr><td><i class="fa-code-pull-request"></i></td><td><h4>Contribuir <a href="#explore-3" id="explore-3"></a></h4></td><td>Descubre cómo participar en el desarrollo, las pruebas y la documentación.</td><td><a href="contributing.md">contributing.md</a></td></tr>
</tbody>
</table>
