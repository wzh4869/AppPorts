import { posix } from "node:path";
import matter from "gray-matter";
import yaml from "js-yaml";

// File paths are shared by the eight spaces; titles and published routes are not.
const icons = {
  "README.md": "book-open",
  "AppPorts.md": "compass",
  "faststart.md": "rocket",
  "core.md": "layer-group",
  "badges.md": "tags",
  "datamigrae/README.md": "database",
  "datamigrae/baseinfo.md": "diagram-project",
  "datamigrae/tools.md": "terminal",
  "datamigrae/operation.md": "arrows-left-right",
  "datamigrae/mount-migration.md": "hard-drive",
  "datamigrae/resign.md": "shield-halved",
  "datamigrae/container-identity.md": "fingerprint",
  "migration-strategy/README.md": "route",
  "migration-strategy/portal.md": "route",
  "migration-strategy/strategy-map.md": "table-list",
  "migration-strategy/updater-detection.md": "arrows-rotate",
  "migration-strategy/appstore-update.md": "arrows-rotate",
  "settings.md": "sliders",
  "external-storage/README.md": "hard-drive",
  "storage-guide.md": "hard-drive",
  "why-apfs.md": "shield-halved",
  "upgrades-and-repairs/README.md": "screwdriver-wrench",
  "macos-27.md": "arrows-rotate",
  "limitations.md": "triangle-exclamation",
  "troubleshooting.md": "wrench",
  "faq.md": "circle-question",
  "logging.md": "file-lines",
  "research/README.md": "flask",
  "research/sandbox-symlink.md": "link",
  "research/sandbox-mountpoint.md": "hard-drive",
  "research/unplug-test.md": "plug",
  "research/prelogin-mount.md": "power-off",
  "changelog.md": "clock-rotate-left",
  "sponsor.md": "heart",
  "contributing.md": "code-pull-request",
  "licenses.md": "scale-balanced",
  "privacy.md": "shield-halved",
};

// These short descriptions explain the destination without adding product claims.
const copy = {
  "zh-Hans": {
    home: "安装、迁移与日常维护：AppPorts 的 macOS 使用指南。",
    faststart: "下载并安装 AppPorts，完成首次启动所需的授权。",
    storage: "了解外置存储的选择、格式与使用要求。",
    troubleshooting: "按症状检查权限、迁移状态与修复方法。",
    navigation: ["快速开始", "外部存储指南", "故障排除"],
    labels: ["从这里开始", "探索核心功能"],
    groups: {
      datamigrae: "识别数据目录，选择迁移方式，并了解还原与签名处理。",
      "migration-strategy": "根据应用类型和更新方式，了解 AppPorts 的迁移策略。",
      "external-storage": "准备适合迁移的外置存储，了解 APFS 与日常使用要求。",
      "upgrades-and-repairs": "了解 macOS 升级、沙盒与签名变化，以及对应的排查路径。",
      research: "查阅沙盒、挂载、拔盘和开机时序的实验过程与结果。",
    },
    pages: {
      baseinfo: "了解数据目录识别与迁移的基本机制。",
      tools: "查看工具数据目录的识别范围。",
      operation: "按步骤迁移或还原数据目录。",
      "mount-migration": "将沙盒容器数据迁移到 APFS 外置盘。",
      resign: "了解重新签名的适用范围与崩溃防护。",
      portal: "了解 AppPorts 如何选择应用迁移方案。",
      "strategy-map": "按应用类型查找对应的迁移策略。",
      "updater-detection": "查看自更新应用的识别与保护机制。",
      "appstore-update": "管理 App Store 应用迁移后的更新。",
      "why-apfs": "理解迁移对 APFS 文件系统的要求。",
      "macos-27": "查看升级后的兼容性变化与修复路径。",
      "container-identity": "了解沙盒容器数据与签名身份的关系。",
      "sandbox-symlink": "沙盒应用通过符号链接访问数据的实验记录。",
      "sandbox-mountpoint": "沙盒应用使用挂载点访问数据的实验记录。",
      "unplug-test": "比较拔盘对 APFS 卷与磁盘映像的影响。",
      "prelogin-mount": "查看登录前挂载的实验步骤与结果。",
    },
  },
  en: {
    home: "Your macOS guide to installing AppPorts, moving apps and data, and everyday maintenance.",
    faststart: "Download and install AppPorts, then grant the permissions needed for first launch.",
    storage: "Review external drive selection, formatting, and usage requirements.",
    troubleshooting: "Find checks and fixes for permissions, migration states, and common symptoms.",
    navigation: ["Getting Started", "External Storage Guide", "Troubleshooting"],
    labels: ["Start here", "Explore the core features"],
    groups: {
      datamigrae: "Find data directories, choose a migration method, and understand restoration and signing.",
      "migration-strategy": "Understand migration strategies for different app types and update methods.",
      "external-storage": "Prepare an external drive and understand APFS and everyday storage requirements.",
      "upgrades-and-repairs": "Review macOS upgrades, sandboxing, signing changes, and the relevant repair guides.",
      research: "Explore experiments on sandboxing, mounts, drive removal, and startup timing.",
    },
    pages: {
      baseinfo: "Understand how data directories are detected and migrated.",
      tools: "See which tool data directories AppPorts can detect.",
      operation: "Follow the steps to migrate or restore data directories.",
      "mount-migration": "Move sandbox container data to an external APFS drive.",
      resign: "Understand when re-signing applies and how crash prevention works.",
      portal: "Learn how AppPorts chooses an app migration method.",
      "strategy-map": "Find the migration strategy for each app type.",
      "updater-detection": "Understand detection and protection for self-updating apps.",
      "appstore-update": "Manage App Store app updates after migration.",
      "why-apfs": "Understand why migration requires the APFS file system.",
      "macos-27": "Review compatibility changes and repair options after upgrading.",
      "container-identity": "Understand the relationship between container data and signing identity.",
      "sandbox-symlink": "Experiments with sandboxed apps accessing data through symbolic links.",
      "sandbox-mountpoint": "Experiments with sandboxed apps accessing data through mount points.",
      "unplug-test": "Compare drive removal effects on APFS volumes and disk images.",
      "prelogin-mount": "Review the procedure and results of mounting before login.",
    },
  },
  "zh-Hant": {
    home: "安裝、遷移與日常維護：AppPorts 的 macOS 使用指南。",
    faststart: "下載並安裝 AppPorts，完成首次啟動所需的授權。",
    storage: "了解外接儲存裝置的選擇、格式與使用要求。",
    troubleshooting: "依症狀檢查權限、遷移狀態與修復方法。",
    navigation: ["快速開始", "外接儲存裝置指南", "故障排除"],
    labels: ["從這裡開始", "探索核心功能"],
    groups: {
      datamigrae: "辨識資料目錄、選擇遷移方式，並了解還原與簽名處理。",
      "migration-strategy": "依應用程式類型與更新方式，了解 AppPorts 的遷移策略。",
      "external-storage": "準備適合遷移的外接儲存裝置，了解 APFS 與日常使用要求。",
      "upgrades-and-repairs": "了解 macOS 升級、沙盒與簽名變化，以及對應的排查方式。",
      research: "查閱沙盒、掛載、拔除磁碟與開機時序的實驗過程和結果。",
    },
    pages: {
      baseinfo: "了解資料目錄辨識與遷移的基本機制。",
      tools: "查看工具資料目錄的辨識範圍。",
      operation: "依步驟遷移或還原資料目錄。",
      "mount-migration": "將沙盒容器資料遷移到 APFS 外接磁碟。",
      resign: "了解重新簽名的適用範圍與崩潰防護。",
      portal: "了解 AppPorts 如何選擇應用程式遷移方案。",
      "strategy-map": "依應用程式類型查找對應的遷移策略。",
      "updater-detection": "查看自動更新應用程式的辨識與保護機制。",
      "appstore-update": "管理 App Store 應用程式遷移後的更新。",
      "why-apfs": "理解遷移對 APFS 檔案系統的要求。",
      "macos-27": "查看升級後的相容性變化與修復方式。",
      "container-identity": "了解沙盒容器資料與簽名身分的關係。",
      "sandbox-symlink": "沙盒應用程式透過符號連結存取資料的實驗紀錄。",
      "sandbox-mountpoint": "沙盒應用程式透過掛載點存取資料的實驗紀錄。",
      "unplug-test": "比較拔除磁碟對 APFS 卷宗與磁碟映像檔的影響。",
      "prelogin-mount": "查看登入前掛載的實驗步驟與結果。",
    },
  },
  ja: {
    home: "AppPorts のインストールからアプリ・データの移行、日常のメンテナンスまで。",
    faststart: "AppPorts をダウンロードしてインストールし、初回起動に必要な権限を設定します。",
    storage: "外部ドライブの選び方、フォーマット、使用条件を確認します。",
    troubleshooting: "症状に応じて権限や移行状態を確認し、修復方法を探します。",
    navigation: ["クイックスタート", "外部ストレージガイド", "トラブルシューティング"],
    labels: ["ここから始める", "主な機能を知る"],
    groups: {
      datamigrae: "データディレクトリを確認し、移行方法、復元、署名の扱いを理解します。",
      "migration-strategy": "アプリの種類と更新方法に応じた移行戦略を確認します。",
      "external-storage": "移行に使う外部ドライブを準備し、APFS と日常の使用条件を確認します。",
      "upgrades-and-repairs": "macOS のアップグレード、サンドボックス、署名の変更と修復方法を確認します。",
      research: "サンドボックス、マウント、ドライブ取り外し、起動時の動作に関する実験を紹介します。",
    },
    pages: {
      baseinfo: "データディレクトリの検出と移行の基本的な仕組みを確認します。",
      tools: "検出対象となるツールのデータディレクトリを確認します。",
      operation: "データディレクトリを移行・復元する手順を確認します。",
      "mount-migration": "サンドボックスのコンテナデータを外部 APFS ドライブへ移行します。",
      resign: "再署名の適用範囲とクラッシュ防止について確認します。",
      portal: "AppPorts がアプリの移行方式を選ぶ仕組みを確認します。",
      "strategy-map": "アプリの種類ごとに対応する移行戦略を探します。",
      "updater-detection": "自動更新アプリの検出と保護の仕組みを確認します。",
      "appstore-update": "移行後の App Store アプリの更新方法を確認します。",
      "why-apfs": "移行に APFS ファイルシステムが必要な理由を確認します。",
      "macos-27": "アップグレード後の互換性の変化と修復方法を確認します。",
      "container-identity": "コンテナデータと署名 ID の関係を確認します。",
      "sandbox-symlink": "シンボリックリンク経由のデータアクセスに関する実験記録です。",
      "sandbox-mountpoint": "マウントポイント経由のデータアクセスに関する実験記録です。",
      "unplug-test": "ドライブ取り外しが APFS ボリュームとディスクイメージに与える影響を比較します。",
      "prelogin-mount": "ログイン前にマウントする実験の手順と結果を確認します。",
    },
  },
  ko: {
    home: "AppPorts 설치부터 앱과 데이터 마이그레이션, 일상적인 관리까지 안내합니다.",
    faststart: "AppPorts를 다운로드하고 설치한 뒤 첫 실행에 필요한 권한을 설정합니다.",
    storage: "외장 드라이브의 선택, 포맷과 사용 조건을 확인합니다.",
    troubleshooting: "증상에 따라 권한과 마이그레이션 상태를 점검하고 복구 방법을 찾습니다.",
    navigation: ["시작하기", "외장 저장 장치 가이드", "문제 해결"],
    labels: ["여기에서 시작하세요", "핵심 기능 살펴보기"],
    groups: {
      datamigrae: "데이터 디렉토리를 찾고 마이그레이션 방식, 복원과 서명 처리를 알아봅니다.",
      "migration-strategy": "앱 유형과 업데이트 방식에 따른 마이그레이션 전략을 확인합니다.",
      "external-storage": "외장 드라이브를 준비하고 APFS와 일상적인 사용 조건을 확인합니다.",
      "upgrades-and-repairs": "macOS 업그레이드, 샌드박스와 서명 변경 및 관련 복구 방법을 확인합니다.",
      research: "샌드박스, 마운트, 드라이브 분리와 시작 시점에 관한 실험을 살펴봅니다.",
    },
    pages: {
      baseinfo: "데이터 디렉토리 감지와 마이그레이션의 기본 원리를 알아봅니다.",
      tools: "감지할 수 있는 도구 데이터 디렉토리를 확인합니다.",
      operation: "데이터 디렉토리를 옮기거나 복원하는 절차를 확인합니다.",
      "mount-migration": "샌드박스 컨테이너 데이터를 외장 APFS 드라이브로 옮깁니다.",
      resign: "재서명의 적용 범위와 크래시 방지 방법을 알아봅니다.",
      portal: "AppPorts가 앱 마이그레이션 방식을 선택하는 방법을 알아봅니다.",
      "strategy-map": "앱 유형별로 알맞은 마이그레이션 전략을 찾습니다.",
      "updater-detection": "자체 업데이트 앱의 감지와 보호 방식을 확인합니다.",
      "appstore-update": "마이그레이션 후 App Store 앱의 업데이트를 관리합니다.",
      "why-apfs": "마이그레이션에 APFS 파일 시스템이 필요한 이유를 알아봅니다.",
      "macos-27": "업그레이드 후 호환성 변경과 복구 방법을 확인합니다.",
      "container-identity": "컨테이너 데이터와 서명 신원의 관계를 알아봅니다.",
      "sandbox-symlink": "심볼릭 링크를 통한 샌드박스 앱의 데이터 접근 실험입니다.",
      "sandbox-mountpoint": "마운트 지점을 통한 샌드박스 앱의 데이터 접근 실험입니다.",
      "unplug-test": "드라이브 분리가 APFS 볼륨과 디스크 이미지에 미치는 영향을 비교합니다.",
      "prelogin-mount": "로그인 전 마운트 실험의 절차와 결과를 확인합니다.",
    },
  },
  de: {
    home: "Der macOS-Leitfaden für Installation, Migration und den Alltag mit AppPorts.",
    faststart: "AppPorts herunterladen, installieren und die nötigen Berechtigungen für den ersten Start erteilen.",
    storage: "Auswahl, Formatierung und Anforderungen an externe Laufwerke verstehen.",
    troubleshooting: "Passende Prüfungen und Lösungen für Berechtigungen, Migrationszustände und typische Probleme finden.",
    navigation: ["Schnellstart", "Leitfaden für externen Speicher", "Fehlerbehebung"],
    labels: ["Hier beginnen", "Die Kernfunktionen entdecken"],
    groups: {
      datamigrae: "Datenverzeichnisse finden, eine Migrationsmethode wählen und Wiederherstellung sowie Signierung verstehen.",
      "migration-strategy": "Migrationsstrategien für unterschiedliche App-Typen und Aktualisierungsmethoden verstehen.",
      "external-storage": "Ein externes Laufwerk vorbereiten und APFS sowie die Anforderungen im Alltag kennenlernen.",
      "upgrades-and-repairs": "Änderungen durch macOS-Upgrades, Sandbox und Signierung sowie passende Reparaturwege nachlesen.",
      research: "Versuche zu Sandbox, Mountpunkten, dem Abziehen von Laufwerken und dem Systemstart nachlesen.",
    },
    pages: {
      baseinfo: "Erkennung und Migration von Datenverzeichnissen verstehen.",
      tools: "Die erkannten Datenverzeichnisse von Werkzeugen kennenlernen.",
      operation: "Datenverzeichnisse Schritt für Schritt migrieren oder wiederherstellen.",
      "mount-migration": "Sandbox-Containerdaten auf ein externes APFS-Laufwerk verschieben.",
      resign: "Einsatzbereiche der Neusignierung und Schutz vor Abstürzen verstehen.",
      portal: "Nachlesen, wie AppPorts eine Migrationsmethode auswählt.",
      "strategy-map": "Die passende Migrationsstrategie für jeden App-Typ finden.",
      "updater-detection": "Erkennung und Schutz für Apps mit eigener Aktualisierung verstehen.",
      "appstore-update": "App-Store-Aktualisierungen nach der Migration verwalten.",
      "why-apfs": "Verstehen, warum die Migration das APFS-Dateisystem benötigt.",
      "macos-27": "Kompatibilitätsänderungen und Reparaturwege nach dem Upgrade prüfen.",
      "container-identity": "Den Zusammenhang zwischen Containerdaten und Signaturidentität verstehen.",
      "sandbox-symlink": "Versuche zum Datenzugriff von Sandbox-Apps über symbolische Links.",
      "sandbox-mountpoint": "Versuche zum Datenzugriff von Sandbox-Apps über Mountpunkte.",
      "unplug-test": "Die Auswirkungen des Abziehens auf APFS-Volumes und Disk-Images vergleichen.",
      "prelogin-mount": "Ablauf und Ergebnisse des Einbindens vor der Anmeldung nachlesen.",
    },
  },
  fr: {
    home: "Le guide macOS pour installer AppPorts, migrer vos apps et données et les gérer au quotidien.",
    faststart: "Téléchargez et installez AppPorts, puis accordez les autorisations nécessaires au premier lancement.",
    storage: "Consultez les critères de choix, de formatage et d’utilisation des disques externes.",
    troubleshooting: "Trouvez les vérifications et correctifs liés aux autorisations, aux états de migration et aux problèmes courants.",
    navigation: ["Démarrage rapide", "Guide du stockage externe", "Dépannage"],
    labels: ["Commencer ici", "Découvrir les fonctions principales"],
    groups: {
      datamigrae: "Repérez les répertoires de données et découvrez les méthodes de migration, de restauration et de signature.",
      "migration-strategy": "Comprenez les stratégies de migration selon le type d’application et son mode de mise à jour.",
      "external-storage": "Préparez un disque externe et consultez les exigences liées à APFS et à son utilisation quotidienne.",
      "upgrades-and-repairs": "Consultez les changements de macOS, du bac à sable et des signatures, ainsi que les guides de réparation.",
      research: "Explorez les expériences sur le bac à sable, les montages, le débranchement des disques et le démarrage.",
    },
    pages: {
      baseinfo: "Comprenez comment les répertoires de données sont détectés et migrés.",
      tools: "Consultez les répertoires de données des outils qui peuvent être détectés.",
      operation: "Suivez les étapes de migration ou de restauration des répertoires de données.",
      "mount-migration": "Déplacez les données de conteneur vers un disque externe APFS.",
      resign: "Comprenez les usages de la nouvelle signature et la prévention des plantages.",
      portal: "Découvrez comment AppPorts choisit une méthode de migration.",
      "strategy-map": "Trouvez la stratégie de migration correspondant à chaque type d’application.",
      "updater-detection": "Comprenez la détection et la protection des applications à mise à jour automatique.",
      "appstore-update": "Gérez les mises à jour des applications App Store après leur migration.",
      "why-apfs": "Comprenez pourquoi la migration nécessite le système de fichiers APFS.",
      "macos-27": "Consultez les changements de compatibilité et les réparations après la mise à niveau.",
      "container-identity": "Comprenez le lien entre les données de conteneur et l’identité de signature.",
      "sandbox-symlink": "Expériences d’accès aux données via des liens symboliques dans le bac à sable.",
      "sandbox-mountpoint": "Expériences d’accès aux données via des points de montage dans le bac à sable.",
      "unplug-test": "Comparez les effets du débranchement sur les volumes APFS et les images disque.",
      "prelogin-mount": "Consultez la procédure et les résultats du montage avant connexion.",
    },
  },
  es: {
    home: "La guía de macOS para instalar AppPorts, migrar apps y datos y mantenerlos en el día a día.",
    faststart: "Descarga e instala AppPorts y concede los permisos necesarios para el primer inicio.",
    storage: "Consulta los requisitos de selección, formato y uso de discos externos.",
    troubleshooting: "Encuentra comprobaciones y soluciones para permisos, estados de migración y problemas habituales.",
    navigation: ["Inicio rápido", "Guía de almacenamiento externo", "Solución de problemas"],
    labels: ["Empieza aquí", "Explora las funciones principales"],
    groups: {
      datamigrae: "Localiza directorios de datos y conoce las opciones de migración, restauración y firma.",
      "migration-strategy": "Comprende las estrategias de migración según el tipo de app y su método de actualización.",
      "external-storage": "Prepara un disco externo y consulta los requisitos de APFS y de uso cotidiano.",
      "upgrades-and-repairs": "Consulta los cambios de macOS, el aislamiento y las firmas, junto con las guías de reparación.",
      research: "Explora experimentos sobre aislamiento, montajes, desconexión de discos y arranque.",
    },
    pages: {
      baseinfo: "Comprende cómo se detectan y migran los directorios de datos.",
      tools: "Consulta qué directorios de datos de herramientas se pueden detectar.",
      operation: "Sigue los pasos para migrar o restaurar directorios de datos.",
      "mount-migration": "Traslada los datos de contenedores a un disco externo APFS.",
      resign: "Comprende cuándo se aplica la nueva firma y cómo se previenen los fallos.",
      portal: "Descubre cómo AppPorts elige un método de migración.",
      "strategy-map": "Encuentra la estrategia de migración para cada tipo de app.",
      "updater-detection": "Comprende la detección y protección de apps con actualización automática.",
      "appstore-update": "Gestiona las actualizaciones de apps de la App Store después de migrarlas.",
      "why-apfs": "Comprende por qué la migración requiere el sistema de archivos APFS.",
      "macos-27": "Consulta los cambios de compatibilidad y las reparaciones tras actualizar.",
      "container-identity": "Comprende la relación entre los datos de contenedores y la identidad de firma.",
      "sandbox-symlink": "Experimentos de acceso a datos mediante enlaces simbólicos en apps aisladas.",
      "sandbox-mountpoint": "Experimentos de acceso a datos mediante puntos de montaje en apps aisladas.",
      "unplug-test": "Compara los efectos de la desconexión en volúmenes APFS e imágenes de disco.",
      "prelogin-mount": "Consulta el procedimiento y los resultados del montaje antes de iniciar sesión.",
    },
  },
};

function html(value) {
  return String(value).replace(/&/g, "&amp;").replace(/</g, "&lt;")
    .replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

function descriptionFor(target, translation) {
  if (target === "README.md") return translation.home;
  if (target === "faststart.md") return translation.faststart;
  if (target === "storage-guide.md") return translation.storage;
  if (target === "troubleshooting.md") return translation.troubleshooting;
  const group = posix.dirname(target);
  if (target.endsWith("/README.md")) return Object.hasOwn(translation.groups, group) ? translation.groups[group] : undefined;
  const page = posix.basename(target, ".md");
  return Object.hasOwn(translation.pages, page) ? translation.pages[page] : undefined;
}

function cardTable(rows) {
  return [
    '<table data-view="cards">',
    '<thead><tr><th width="48"></th><th></th><th></th><th data-hidden data-card-target data-type="content-ref"></th></tr></thead>',
    "<tbody>",
    ...rows.map((row) => `<tr><td><i class="fa-${row.icon}"></i></td><td>${row.titleHTML}</td><td>${row.descriptionHTML}</td><td><a href="${html(row.href)}">${html(row.href)}</a></td></tr>`),
    "</tbody>",
    "</table>",
  ].join("\n");
}

const featureTargets = ["core.md", "migration-strategy/updater-detection.md", "datamigrae/README.md"];

function featureCard(titleHTML, descriptionHTML, href) {
  return {
    icon: icons[href], href, descriptionHTML,
    titleHTML: titleHTML.replace(/^<strong>(?:🔄|🔒|📦) /u, "<strong>"),
  };
}

function finishHomepage(body) {
  // Keep native buttons in one paragraph so they share a row and can wrap naturally.
  const button = '<a\\b[^>\\n]*\\bclass="button (?:primary|secondary)"[^>\\n]*>[^\\n]*<\\/a>';
  body = body.replace(new RegExp(`^(${button})[ \\t]*\\n(?:[ \\t]*\\n)*(${button})$`, "m"), "$1 $2");

  // Also upgrade the exact iconless feature table emitted by the first design revision.
  return body.replace(/<table data-view="cards">\n<thead><tr><th><\/th><th><\/th><th data-hidden data-card-target data-type="content-ref"><\/th><\/tr><\/thead>\n<tbody>\n([\s\S]*?)\n<\/tbody>\n<\/table>/g, (table, rows) => {
    const pattern = /<tr><td>([\s\S]*?)<\/td><td>([\s\S]*?)<\/td><td><a href="([^"]*)">[^<]*<\/a><\/td><\/tr>/g;
    const features = [...rows.matchAll(pattern)];
    if (features.length !== 3 || rows.replace(pattern, "").trim() || features.some((feature, index) => feature[3] !== featureTargets[index])) return table;
    return cardTable(features.map((feature) => featureCard(feature[1], feature[2], feature[3])));
  });
}

function homepage(body, translation, oldDescription) {
  if (/\bdata-card-target\b/.test(body)) return finishHomepage(body);
  const table = body.match(/<table data-view="cards"><thead><tr><th><\/th><th><\/th><\/tr><\/thead><tbody>([\s\S]*?)<\/tbody><\/table>/);
  if (!table) throw new Error("Expected the three feature cards in the exported GitBook homepage");
  const rowPattern = /<tr><td>([\s\S]*?)<\/td><td>([\s\S]*?)<\/td><\/tr>/g;
  const features = [...table[1].matchAll(rowPattern)];
  if (features.length !== 3 || table[1].replace(rowPattern, "").trim()) {
    throw new Error("Expected exactly three feature rows in the exported GitBook homepage");
  }
  const prefix = body.slice(0, table.index).split(/\n{2,}/).filter((block) => {
    if (/^<figure><img src="[^"]*logo\.png" alt="[^"]*" width="160"><figcaption><\/figcaption><\/figure>$/.test(block.trim())) return false;
    return block.trim() !== String(oldDescription ?? "").trim();
  }).join("\n\n").trim();
  const shortcuts = ["faststart.md", "storage-guide.md", "troubleshooting.md"].map((href, index) => ({
    icon: icons[href], href,
    titleHTML: `<strong>${html(translation.navigation[index])}</strong>`,
    descriptionHTML: html(descriptionFor(href, translation)),
  }));
  const featureCards = features.map((feature, index) => featureCard(feature[1], feature[2], featureTargets[index]));
  return finishHomepage([
    prefix,
    `**${translation.labels[0]}**`,
    cardTable(shortcuts),
    `**${translation.labels[1]}**`,
    cardTable(featureCards),
    body.slice(table.index + table[0].length).trim(),
  ].filter(Boolean).join("\n\n") + "\n");
}

function pageForLink(href, target) {
  const path = href.split(/[?#]/)[0];
  if (!/^https?:\/\//.test(path)) return posix.normalize(posix.join(posix.dirname(target), path));
  if (!/^https:\/\/app\.gitbook\.com\/(?:o\/[^/]+\/)?s\//.test(path)) return null;
  const basename = posix.basename(path).replace(/\.md$/, "");
  return Object.keys(icons).find((page) => posix.basename(page, ".md") === basename);
}

function groupHomepage(body, target, translation) {
  if (/\bdata-view=["']cards["']/.test(body)) return body;
  const lines = body.trim().split("\n").filter((line) => line.trim());
  const title = lines.shift();
  if (!/^# .+$/.test(title ?? "")) throw new Error(`Expected a group title in ${target}`);
  const rows = lines.map((line) => {
    const match = line.match(/^\* \[((?:\\.|[^\]])+)\]\(([^\s)]+)\)$/);
    if (!match) throw new Error(`Expected a navigation link in ${target}: ${line}`);
    const [, label, href] = match;
    const page = pageForLink(href, target);
    const description = page && descriptionFor(page, translation);
    if (!page || !Object.hasOwn(icons, page) || !description) {
      throw new Error(`No card description for ${target}: ${href}`);
    }
    return {
      icon: icons[page], href,
      titleHTML: `<strong>${html(label.replace(/\\([\\[\]])/g, "$1"))}</strong>`,
      descriptionHTML: html(description),
    };
  });
  if (!rows.length) throw new Error(`No navigation links in ${target}`);
  return `${title}\n\n${cardTable(rows)}\n`;
}

// Only read top-level headings outside code; stepper insertion preserves all source bytes.
function scanBlocks(body) {
  const headings = [];
  let fence = null, hasStepper = false;
  for (const match of body.matchAll(/[^\n]*(?:\n|$)/g)) {
    if (!match[0]) continue;
    const line = match[0].replace(/\r?\n$/, "");
    const marker = line.match(/^ {0,3}(`{3,}|~{3,})(.*)$/);
    if (marker) {
      if (!fence) fence = marker[1];
      else if (marker[1][0] === fence[0] && marker[1].length >= fence.length && !marker[2].trim()) fence = null;
      continue;
    }
    if (fence) continue;
    if (/^\{%\s*stepper\s*%\}/.test(line)) hasStepper = true;
    const heading = line.match(/^(#{1,6})[ \t]+.+$/);
    if (heading) headings.push({ level: heading[1].length, offset: match.index });
  }
  return { headings, hasStepper };
}

function quickstart(body) {
  const { headings, hasStepper } = scanBlocks(body);
  if (hasStepper) return body;
  const steps = headings.filter((heading) => heading.level === 3);
  const appendix = steps.length === 3 && headings.find((heading) => heading.level === 4 && heading.offset > steps[2].offset);
  if (!appendix) throw new Error("Expected three quickstart steps followed by the App Store authorization section");
  const insertions = [
    [steps[0].offset, "{% stepper %}\n{% step %}\n\n"],
    [steps[1].offset, "{% endstep %}\n\n{% step %}\n\n"],
    [steps[2].offset, "{% endstep %}\n\n{% step %}\n\n"],
    [appendix.offset, "{% endstep %}\n{% endstepper %}\n\n"],
  ];
  for (const [offset, addition] of insertions.reverse()) body = body.slice(0, offset) + addition + body.slice(offset);
  return body;
}

/** Apply the native GitBook design to an exported page without rewriting its factual content. */
export function applyGitBookDesign(content, { locale, target }) {
  target = target.replace(/\\/g, "/").replace(/^\.\//, "");
  if (target === "SUMMARY.md") return content;
  const language = typeof locale === "string" ? locale : locale?.directory ?? locale?.key;
  const key = language === "root" ? "zh-Hans" : language;
  if (!Object.hasOwn(copy, key)) throw new Error(`Unsupported GitBook design locale: ${language}`);
  const translation = copy[key];
  const parsed = matter(content);
  const metadata = { ...parsed.data };
  let body = parsed.content;
  const isHome = target === "README.md";
  const isGroup = target.endsWith("/README.md") && Object.hasOwn(translation.groups, posix.dirname(target));
  if (isHome) body = homepage(body, translation, metadata.description);
  else if (isGroup) body = groupHomepage(body, target, translation);
  else if (target === "faststart.md") body = quickstart(body);

  metadata.icon = Object.hasOwn(icons, target) ? icons[target] : "file-lines";
  const description = descriptionFor(target, translation);
  if (description) metadata.description = description;
  const layout = { ...metadata.layout, width: isHome || isGroup ? "wide" : "default" };
  layout.outline = { ...layout.outline, visible: !(isHome || isGroup) };
  if (isHome || isGroup) {
    layout.pagination = { ...layout.pagination, visible: false };
    layout.metadata = { ...layout.metadata, visible: false };
  }
  metadata.layout = layout;
  const frontmatter = yaml.dump(metadata, { lineWidth: -1, noRefs: true, quotingType: '"', forceQuotes: true });
  return `---\n${frontmatter}---\n${body.startsWith("\n") ? "" : "\n"}${body}`;
}
