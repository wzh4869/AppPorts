---
icon: "hard-drive"
description: "Consulta los requisitos de selección, formato y uso de discos externos."
layout:
  width: "default"
  outline:
    visible: true
---

# Guía de almacenamiento externo

La estabilidad del almacenamiento externo afecta directamente al inicio de las aplicaciones migradas, al acceso a los directorios de datos y a las actualizaciones posteriores. Se recomienda un SSD externo con rendimiento estable y capacidad suficiente.

## Configuración recomendada <a href="#configuracion-recomendada" id="configuracion-recomendada"></a>

| Elemento | Recomendación | Descripción |
|--------|--------|------|
| Capacidad | 256 GB o más | Las necesidades dependen del número de aplicaciones y directorios de datos que se migren |
| Interfaz | USB 3.0 o superior / Thunderbolt | USB 2.0 es lento y alarga la migración de aplicaciones grandes |
| Sistema de archivos | APFS | Único formato compatible con la migración de datos de contenedores; admite clones, instantáneas y espacio compartido, con el mejor rendimiento |

## Comparación de interfaces <a href="#comparacion-de-interfaces" id="comparacion-de-interfaces"></a>

| Interfaz | Velocidad teórica | Velocidad real de migración | Uso |
|------|----------|-------------|----------|
| USB 2.0 | 480 Mbps | ~30 MB/s | No recomendado: tarda mucho en migrar aplicaciones grandes |
| USB 3.0 (USB-A) | 5 Gbps | ~350 MB/s | Suficiente para un uso básico |
| USB 3.1 Gen 2 (USB-C) | 10 Gbps | ~700 MB/s | Recomendado |
| Thunderbolt 3/4 | 40 Gbps | ~2500 MB/s | Mejor rendimiento |
| NVMe (Thunderbolt) | 40 Gbps | ~2800 MB/s | Mejor rendimiento |

## Elección del sistema de archivos <a href="#eleccion-del-sistema-de-archivos" id="eleccion-del-sistema-de-archivos"></a>

### APFS (recomendado) <a href="#apfs-recomendado" id="apfs-recomendado"></a>

- Admite clones, instantáneas y espacio compartido.
- Ofrece el mejor rendimiento, especialmente en SSD.
- Es compatible de forma nativa con macOS.
- **La migración de datos de contenedores (`~/Library/Containers/`, como el historial de WeChat) requiere un disco externo APFS**. Consulta los motivos y los experimentos en [Por qué el disco externo debe ser APFS](why-apfs.md).

### HFS+ <a href="#hfs" id="hfs"></a>

- Buena compatibilidad, adecuado para Mac antiguos.
- No admite clones ni instantáneas.
- Adecuado para discos duros mecánicos.

### exFAT <a href="#exfat" id="exfat"></a>

- Buena compatibilidad entre plataformas, para compartir archivos entre macOS y Windows.
- No admite enlaces físicos ni clones.
- Rendimiento relativamente bajo.
- Adecuado para intercambiar archivos entre varios sistemas.
- No permite migrar datos de contenedores. Si también necesitas Windows, puedes dedicar una partición APFS a AppPorts. Cuando exFAT ocupa todo el disco, las herramientas del sistema no pueden reducirlo directamente: primero hay que hacer una copia de seguridad y después volver a particionar. Consulta los [requisitos y métodos de particionado](why-apfs.md#prepare-apfs).

## Planificar la capacidad <a href="#planificar-la-capacidad" id="planificar-la-capacidad"></a>

El espacio externo que usa AppPorts depende del tamaño de las aplicaciones y los directorios de datos migrados. Estos son algunos tamaños orientativos:

| Tipo de aplicación | Tamaño |
|----------|------|
| Chrome | ~500 MB |
| Microsoft Office | ~5 GB |
| Adobe Creative Cloud | ~20-50 GB |
| Xcode | ~15 GB |
| Final Cut Pro | ~5 GB |
| Modelos de lenguaje grandes locales (Ollama) | ~4-30 GB |

{% hint style="success" %}
**Capacidad aconsejada**

- Uso ligero (5-10 aplicaciones): 128 GB.
- Uso moderado (10-20 aplicaciones): 256 GB.
- Uso intensivo (20+ aplicaciones y directorios de datos): 512 GB o más.
{% endhint %}

## Precauciones <a href="#precauciones" id="precauciones"></a>

- El almacenamiento externo debe permanecer conectado; las aplicaciones y los directorios de datos migrados no están disponibles mientras esté desconectado.
- Haz copias de seguridad periódicas de los datos importantes del almacenamiento externo.
- No desconectes el almacenamiento externo durante una migración, para evitar interrupciones de copia o estados incoherentes.
- Antes de desconectar el disco, cierra las aplicaciones que utilicen datos externos. Para los directorios migrados por montaje, se recomienda hacer clic primero en «Desmontar» en AppPorts.
- No coloques manualmente un archivo normal en la ruta de destino de un directorio de datos externo de AppPorts; solo se pueden reenlazar o normalizar directorios reales.
- Si el almacenamiento externo falla, puedes intentar devolver las aplicaciones al Mac mediante AppPorts una vez restablecida la conexión.
