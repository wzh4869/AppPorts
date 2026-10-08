# Contribuir

¡Gracias por su interés en AppPorts! Damos la bienvenida a los miembros de la comunidad para contribuir, ya sea corrigiendo errores, mejorando la documentación o añadiendo nuevas características.

## Antes de Comenzar <a href="#antes-de-comenzar" id="antes-de-comenzar"></a>

1. Busque en los [Issues](https://github.com/wzh4869/AppPorts/issues) existentes para confirmar que no hay duplicados relacionados
2. Haga Fork del proyecto y clone localmente
3. Cree una rama de características (`feat/su-caracteristica`) o una rama de corrección (`fix/su-corrección`) basada en la rama `develop`

## Enfoque de Desarrollo <a href="#enfoque-de-desarrollo" id="enfoque-de-desarrollo"></a>

### Sobre Vibe Coding <a href="#sobre-vibe-coding" id="sobre-vibe-coding"></a>

El proyecto AppPorts acepta el desarrollo Vibe Coding usando herramientas asistidas por IA (ej., Cursor, GitHub Copilot, Claude). Entendemos que las herramientas de IA pueden mejorar significativamente la eficiencia del desarrollo, **pero la calidad y corrección del código enviado es responsabilidad del contribuidor**.

Al usar Vibe Coding:

- **Los asistentes de IA deben seguir el archivo `CLAUDE.md` en la raíz del proyecto**, que define directrices de codificación, convenciones de arquitectura, comandos de compilación y flujo de trabajo de desarrollo. Si el asistente de IA no lee automáticamente este archivo, pídale explícitamente que lea `CLAUDE.md` primero en sus instrucciones
- Considere validar cruzadamente la calidad y seguridad del código generado con múltiples modelos de IA para evitar puntos ciegos de un solo modelo
- El código generado por IA puede no coincidir con el estilo existente del proyecto; por favor revíselo manualmente antes de enviar
- La IA no puede reemplazar la comprensión del comportamiento del sistema macOS; por favor verifique manualmente la lógica que involucra operaciones del sistema de archivos, firmado de código y gestión de permisos
- Los cambios de **funcionalidad principal** (ej., estrategias de migración, migración de directorios de datos, firmado de código) deben discutirse primero vía Issue antes del desarrollo

### Convenciones de Código <a href="#convenciones-de-codigo" id="convenciones-de-codigo"></a>

- Siga las convenciones de código Swift y el estilo existente del proyecto
- Escriba comentarios de documentación Swift claros para lógica compleja
- Las cadenas literales de SwiftUI usan la API `LocalizedStringKey`; las cadenas de AppKit/API usan `.localized`

## Requisitos de Pruebas <a href="#requisitos-de-pruebas" id="requisitos-de-pruebas"></a>

{% hint style="warning" %}
**⚠️ Todos los PRs Deben Pasar las Pruebas**

Independientemente del método de desarrollo, las siguientes pruebas deben completarse antes de enviar un PR. CI ejecuta automáticamente verificaciones de compilación; los PRs no aprobados serán bloqueados para merge.
{% endhint %}

### Requerido: Verificación de Compilación <a href="#requerido-verificacion-de-compilacion" id="requerido-verificacion-de-compilacion"></a>

Todos los PRs deben pasar la compilación Release de Xcode — este es un requisito estricto para merge:

```bash
xcodebuild clean build \
  -scheme "AppPorts" \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath build \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_ENTITLEMENTS="" \
  CODE_SIGNING_ALLOWED=NO
```

### Bajo Demanda: Pruebas Especializadas <a href="#bajo-demanda-pruebas-especializadas" id="bajo-demanda-pruebas-especializadas"></a>

Cuando un PR involucra los módulos correspondientes, se recomienda ejecutar proactivamente las siguientes pruebas especializadas. CI también las ejecuta en modo Advisory en PRs; los resultados no bloquean el merge pero proporcionan retroalimentación.

#### Pruebas de Directorios de Datos <a href="#pruebas-de-directorios-de-datos" id="pruebas-de-directorios-de-datos"></a>

Ejecutar cuando el PR involucra `DataDirMover`, `DataDirScanner` o lógica de migración de directorios de datos:

```bash
xcodebuild test \
  -scheme "AppPorts" \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath build \
  -only-testing:"AppPortsTests/DataDirMoverTests" \
  -only-testing:"AppPortsTests/DataDirScannerTests" \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_ENTITLEMENTS="" \
  CODE_SIGNING_ALLOWED=NO
```

#### Pruebas de Migración de Aplicaciones <a href="#pruebas-de-migracion-de-aplicaciones" id="pruebas-de-migracion-de-aplicaciones"></a>

Ejecutar cuando el PR involucra `AppMigrationService`, `AppScanner` o lógica de migración de aplicaciones:

```bash
xcodebuild test \
  -scheme "AppPorts" \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath build \
  -only-testing:"AppPortsTests/AppMigrationServiceTests" \
  -only-testing:"AppPortsTests/AppScannerTests" \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_ENTITLEMENTS="" \
  CODE_SIGNING_ALLOWED=NO
```

#### Pruebas de Registro <a href="#pruebas-de-registro" id="pruebas-de-registro"></a>

Ejecutar cuando el PR involucra `AppLogger` o funcionalidad de diagnóstico:

```bash
xcodebuild test \
  -scheme "AppPorts" \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath build \
  -only-testing:"AppPortsTests/AppLoggerTests" \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_ENTITLEMENTS="" \
  CODE_SIGNING_ALLOWED=NO
```

#### Auditoría de Localización <a href="#auditoria-de-localizacion" id="auditoria-de-localizacion"></a>

Ejecutar cuando el PR involucra texto visible por el usuario, menús, ventanas emergentes, configuración o mensajes de error:

```bash
xcodebuild test \
  -scheme "AppPorts" \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath build \
  -only-testing:"AppPortsTests/LocalizationAuditTests" \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_ENTITLEMENTS="" \
  CODE_SIGNING_ALLOWED=NO
```

### Resumen de Pruebas <a href="#resumen-de-pruebas" id="resumen-de-pruebas"></a>

| Suite de Pruebas | Módulos | Cuándo Ejecutar |
|------------------|---------|-----------------|
| Verificación de Compilación | Proyecto completo | **Requerido** (CI aplicado) |
| `DataDirMoverTests` | Migración de directorios de datos | Cuando involucra `DataDirMover` |
| `DataDirScannerTests` | Escaneo de directorios de datos | Cuando involucra `DataDirScanner` |
| `AppMigrationServiceTests` | Migración de apps | Cuando involucra `AppMigrationService` |
| `AppScannerTests` | Escaneo de apps | Cuando involucra `AppScanner` |
| `AppLoggerTests` | Registro y diagnóstico | Cuando involucra `AppLogger` |
| `LocalizationAuditTests` | Localización | Cuando involucra texto visible por el usuario |

## Localización <a href="#localizacion" id="localizacion"></a>

- La adaptación de localización es recomendada pero no obligatoria para PRs de contribuidores externos
- Si un PR añade, modifica o elimina texto visible por el usuario, es bienvenido a actualizar `Localizable.xcstrings` en el mismo PR
- Si no lo maneja esta vez, por favor explique brevemente la razón o plan futuro en la descripción del PR
- Las cadenas literales de SwiftUI usan la API `LocalizedStringKey`; las cadenas de AppKit/API usan `.localized`
- El texto dinámico debe usar claves formateadas, ej., `String(format: "Sort: %@".localized, value)`
- La lista de idiomas se mantiene en `AppLanguageCatalog`; no duplique en múltiples páginas
- Si un PR cambia menús, ventanas emergentes, configuración, exportaciones de registros, mensajes de error, texto de estado o texto de bienvenida, se recomienda verificar al menos los resultados de visualización `zh-Hans` y `en`

Más reglas consulte: [LOCALIZATION.md](https://github.com/wzh4869/AppPorts/blob/main/LOCALIZATION.md)

## Convenciones de Commits <a href="#convenciones-de-commits" id="convenciones-de-commits"></a>

- **Issue Primero**: Los cambios importantes de características deben discutirse primero vía Issue
- **Mantener Atómico**: Cada PR debe idealmente abordar solo un problema o añadir una característica
- **Sugerencias de Mensajes de Commit**:
  - `feat: ...` — Nueva característica
  - `fix: ...` — Corrección de error
  - `docs: ...` — Actualización de documentación
  - `refactor: ...` — Refactorización
  - `test: ...` — Relacionado con pruebas

## Enviar un PR <a href="#enviar-un-pr" id="enviar-un-pr"></a>

1. Asegúrese de que su rama está basada en la última rama `develop`
2. Push a su repositorio Fork
3. Envíe un Pull Request a la rama `develop` de AppPorts
4. Complete los elementos requeridos en la plantilla del PR
5. Espere a que las verificaciones de CI pasen y el Code Review

{% hint style="success" %}
**💡 Mejorar la Eficiencia de Merge**

- Mantenga cada PR enfocado en un solo problema o característica
- Complete honestamente la situación de pruebas en la plantilla del PR
- Incluya capturas de pantalla para cambios de UI
{% endhint %}

## Áreas de Contribución Bienvenidas <a href="#areas-de-contribucion-bienvenidas" id="areas-de-contribucion-bienvenidas"></a>

- Mejoras de estabilidad y rendimiento para la lógica principal como `AppScanner`
- Optimización de UI/UX, especialmente mejoras que se sientan nativas de macOS
- Sincronización y mejora de documentación en chino e inglés
