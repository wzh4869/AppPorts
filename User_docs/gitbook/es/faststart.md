---
icon: "rocket"
description: "Descarga e instala AppPorts y concede los permisos necesarios para el primer inicio."
layout:
  width: "default"
  outline:
    visible: true
---

# Comenzar

## Instalación de AppPorts <a href="#instalacion-de-appports" id="instalacion-de-appports"></a>

La instalación de AppPorts requiere los siguientes dos requisitos previos:
1. Un dispositivo de almacenamiento externo estable (como un disco duro)
2. Sistema operativo no inferior a macOS 12.0 (Monterey) o posterior

{% stepper %}
{% step %}

### Descargar <a href="#descargar" id="descargar"></a>

Vaya a la página de [Github releases](https://github.com/wzh4869/AppPorts/releases) para descargar el último instalador .dmg

{% hint style="success" %}

Si no puede abrir el enlace anterior, visite este enlace para obtener el instalador [descarga directa](https://file.shimoko.com/AppPorts)
{% endhint %}

![](https://file.shimoko.com/d/openlist/openlist/%E7%BD%91%E7%AB%99%E5%AA%92%E4%BD%93%E6%96%87%E4%BB%B6/download.gif?sign=Xb9FOEqPxR8Q7WLixKzg5NCYcjVzmzq2eh0634xGdG0=:0)


{% endstep %}

{% step %}

### Instalar e Iniciar <a href="#instalar-e-iniciar" id="instalar-e-iniciar"></a>
1. Abra el instalador .dmg
2. Arrastre la aplicación a la carpeta Aplicaciones
3. Inicie la aplicación

![](https://file.shimoko.com/d/openlist/openlist/%E7%BD%91%E7%AB%99%E5%AA%92%E4%BD%93%E6%96%87%E4%BB%B6/install.gif?sign=dg-gU67tz19m6DGdI3NywEAcuqKnyTpWGas0YhZeGfM=:0)


{% endstep %}

{% step %}

### Autorización Requerida <a href="#autorizacion-requerida" id="autorizacion-requerida"></a>

En la primera ejecución, AppPorts necesita permiso de Acceso Total al Disco para leer y modificar el directorio /Applications.
1. Abra Configuración del Sistema → Privacidad y Seguridad.
Seleccione Acceso Total al Disco.
2. Haga clic en el botón +, agregue AppPorts, luego active el interruptor.
3. Reinicie AppPorts.

![](https://file.shimoko.com/d/openlist/openlist/%E7%BD%91%E7%AB%99%E5%AA%92%E4%BD%93%E6%96%87%E4%BB%B6/outh.gif?sign=fTXqbKCR_tZBKDb6p1DziuJYjD9NZAJk-Zsw7c4oOJM=:0)

{% endstep %}
{% endstepper %}

#### Autorización de Auto-Actualización de Aplicaciones App Store <a href="#autorizacion-de-auto-actualizacion-de-aplicaciones-app-store" id="autorizacion-de-auto-actualizacion-de-aplicaciones-app-store"></a>

Los usuarios con macOS 15.1 (Sequoia) o posterior deben habilitar "Descargar e instalar aplicaciones grandes en un disco externo" en la App Store para asegurar que AppPorts cree una carpeta `/Applications` en el almacenamiento externo para soportar actualizaciones automáticas de aplicaciones de App Store.
{% hint style="warning" %}
**⚠️ Los sistemas anteriores a macOS 15.1 (Sequoia) no soportan esta función debido a limitaciones del sistema operativo**

Debe habilitar la configuración "Permitir migración de aplicaciones App Store" en la configuración de AppPorts. Las actualizaciones posteriores de aplicaciones requieren una re-migración manual para sobrescribir.
{% endhint %}

1. Abra la App Store
2. En la barra de estado, haga clic en Configuración y marque "Descargar e instalar aplicaciones grandes en un disco externo", seleccionando el mismo dispositivo de almacenamiento externo que la biblioteca de almacenamiento externo de AppPorts

![](https://file.shimoko.com/d/openlist/openlist/%E7%BD%91%E7%AB%99%E5%AA%92%E4%BD%93%E6%96%87%E4%BB%B6/appstore.gif?sign=JwDPVgjgPb3AulPjZq6Y2KgubkHxmGNqaUawCBRhCEM=:0)
