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
icon: "book-open"
---

# AppPorts

## Los discos externos salvan el mundo <a href="#los-discos-externos-salvan-el-mundo" id="los-discos-externos-salvan-el-mundo"></a>

<a href="faststart.md" class="button primary">Inicio rápido</a> <a href="AppPorts.md" class="button secondary">Introducción</a>

**Empieza aquí**

<table data-view="cards">
<thead><tr><th width="48"></th><th></th><th></th><th data-hidden data-card-target data-type="content-ref"></th></tr></thead>
<tbody>
<tr><td><i class="fa-rocket"></i></td><td><strong>Inicio rápido</strong></td><td>Descarga e instala AppPorts y concede los permisos necesarios para el primer inicio.</td><td><a href="faststart.md">faststart.md</a></td></tr>
<tr><td><i class="fa-hard-drive"></i></td><td><strong>Guía de almacenamiento externo</strong></td><td>Consulta los requisitos de selección, formato y uso de discos externos.</td><td><a href="storage-guide.md">storage-guide.md</a></td></tr>
<tr><td><i class="fa-wrench"></i></td><td><strong>Solución de problemas</strong></td><td>Encuentra comprobaciones y soluciones para permisos, estados de migración y problemas habituales.</td><td><a href="troubleshooting.md">troubleshooting.md</a></td></tr>
</tbody>
</table>

**Explora las funciones principales**

<table data-view="cards">
<thead><tr><th width="48"></th><th></th><th></th><th data-hidden data-card-target data-type="content-ref"></th></tr></thead>
<tbody>
<tr><td><i class="fa-layer-group"></i></td><td><strong>Migración sin flecha de acceso directo</strong></td><td>Traslada aplicaciones grandes al almacenamiento externo con un clic. Solo queda un contenedor de lanzamiento ligero en el Mac; Finder no muestra flechas de acceso directo, y Launchpad y los menús de aplicaciones funcionan con normalidad.</td><td><a href="core.md">core.md</a></td></tr>
<tr><td><i class="fa-arrows-rotate"></i></td><td><strong>Protección frente a actualizaciones automáticas</strong></td><td>AppPorts detecta aplicaciones con actualización automática, como Sparkle y Electron, y ofrece «Migración bloqueada». Si la versión local es más reciente que la copia externa, muestra «Pendiente de mover fuera».</td><td><a href="migration-strategy/updater-detection.md">migration-strategy/updater-detection.md</a></td></tr>
<tr><td><i class="fa-database"></i></td><td><strong>Gestión de directorios de datos</strong></td><td>Traslada subdirectorios de ~/Library/, ~/.npm y otros datos al almacenamiento externo. Los datos de contenedores de aplicaciones aisladas, como el historial de WeChat, se migran por montaje a un disco externo APFS sin modificar la firma.</td><td><a href="datamigrae/README.md">datamigrae/README.md</a></td></tr>
</tbody>
</table>
