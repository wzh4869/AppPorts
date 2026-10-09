// Homepage navigation copy; destinations are relative to each locale's README.
export const homepageCopy = {
  "zh-Hans": {
    ask: "你想了解 AppPorts 的哪方面？",
    startIntro: "从首次使用到应用与数据迁移，按当前任务选择指南。",
    journeys: [
      {
        title: "首次使用",
        description: "了解 AppPorts，查看安装、授权与基本设置。",
        links: [
          { href: "faststart.md", label: "快速开始" },
          { href: "AppPorts.md", label: "AppPorts 简介" },
          { href: "settings.md", label: "设置" },
        ],
      },
      {
        title: "应用迁移",
        description: "了解应用的迁移、还原与不同类型的对应策略。",
        links: [
          { href: "core.md", label: "核心功能" },
          { href: "migration-strategy/portal.md", label: "迁移策略" },
          { href: "migration-strategy/strategy-map.md", label: "应用类型与策略" },
        ],
      },
      {
        title: "数据迁移",
        description: "查阅数据目录操作、工具数据识别与容器挂载迁移指南。",
        links: [
          { href: "datamigrae/operation.md", label: "迁移操作指南" },
          { href: "datamigrae/tools.md", label: "工具目录识别" },
          { href: "datamigrae/mount-migration.md", label: "容器挂载迁移" },
        ],
      },
    ],
    careTitle: "存储与日常维护",
    careIntro: "查看外置盘要求、更新说明与常见问题的排查路径。",
    care: [
      {
        title: "外置存储",
        description: "了解外置盘怎么选、哪些场景需要 APFS，以及兼容性限制。",
        links: [
          { href: "storage-guide.md", label: "外部存储指南" },
          { href: "why-apfs.md", label: "APFS 要求" },
          { href: "limitations.md", label: "兼容性与限制" },
        ],
      },
      {
        title: "更新与维护",
        description: "了解应用更新、macOS 27 变化，以及容器数据与签名身份的关系。",
        links: [
          { href: "migration-strategy/updater-detection.md", label: "自更新应用识别" },
          { href: "macos-27.md", label: "macOS 27 升级说明" },
          { href: "datamigrae/container-identity.md", label: "容器数据与签名" },
        ],
      },
      {
        title: "故障排查",
        description: "按症状查找排查步骤、常见问题解答与日志诊断方法。",
        links: [
          { href: "troubleshooting.md", label: "故障排除" },
          { href: "faq.md", label: "常见问题" },
          { href: "logging.md", label: "日志与诊断" },
        ],
      },
    ],
    featuresIntro: "了解 AppPorts 的三项核心功能。",
    moreTitle: "继续探索",
    more: [
      { title: "更新日志", description: "按版本查看改动与修复记录。", href: "changelog.md" },
      { title: "实验记录", description: "查阅沙盒、挂载、拔盘与开机时序的实验记录。", href: "research/README.md" },
      { title: "参与贡献", description: "了解如何参与开发、测试与文档改进。", href: "contributing.md" },
    ],
  },
  en: {
    ask: "What would you like to know about AppPorts?",
    startIntro: "Choose a guide for getting started, moving apps, or migrating data.",
    journeys: [
      {
        title: "Getting started",
        description: "Learn about AppPorts, installation, permissions, and basic settings.",
        links: [
          { href: "faststart.md", label: "Quick start" },
          { href: "AppPorts.md", label: "Introduction" },
          { href: "settings.md", label: "Settings" },
        ],
      },
      {
        title: "App migration",
        description: "Review app migration, restoration, and strategies for different app types.",
        links: [
          { href: "core.md", label: "Core features" },
          { href: "migration-strategy/portal.md", label: "Migration strategies" },
          { href: "migration-strategy/strategy-map.md", label: "App types & strategies" },
        ],
      },
      {
        title: "Data migration",
        description: "Find guides for data directories, tool data, and container mount migration.",
        links: [
          { href: "datamigrae/operation.md", label: "Data migration guide" },
          { href: "datamigrae/tools.md", label: "Tool directory detection" },
          { href: "datamigrae/mount-migration.md", label: "Container mount migration" },
        ],
      },
    ],
    careTitle: "Storage and maintenance",
    careIntro: "Review external drive requirements, updates, and troubleshooting guides.",
    care: [
      {
        title: "External storage",
        description: "Review drive selection, when APFS is required, and compatibility limits.",
        links: [
          { href: "storage-guide.md", label: "Storage guide" },
          { href: "why-apfs.md", label: "APFS requirements" },
          { href: "limitations.md", label: "Compatibility & limits" },
        ],
      },
      {
        title: "Updates and maintenance",
        description: "Explore app updates, macOS 27 changes, and how container data relates to signing identity.",
        links: [
          { href: "migration-strategy/updater-detection.md", label: "Self-updater detection" },
          { href: "macos-27.md", label: "Upgrading to macOS 27" },
          { href: "datamigrae/container-identity.md", label: "Container data & signing" },
        ],
      },
      {
        title: "Troubleshooting",
        description: "Find checks for specific symptoms, answers to common questions, and logging guidance.",
        links: [
          { href: "troubleshooting.md", label: "Troubleshooting" },
          { href: "faq.md", label: "FAQ" },
          { href: "logging.md", label: "Logs & diagnostics" },
        ],
      },
    ],
    featuresIntro: "Explore the three core features of AppPorts.",
    moreTitle: "Keep exploring",
    more: [
      { title: "Changelog", description: "Review changes and fixes by version.", href: "changelog.md" },
      { title: "Experiment logs", description: "Read experiments on sandboxes, mounts, drive removal, and startup.", href: "research/README.md" },
      { title: "Contributing", description: "Learn how to contribute through development, testing, and documentation.", href: "contributing.md" },
    ],
  },
  "zh-Hant": {
    ask: "你想了解 AppPorts 的哪方面？",
    startIntro: "從首次使用到應用程式與資料遷移，依目前任務選擇指南。",
    journeys: [
      {
        title: "首次使用",
        description: "了解 AppPorts，查看安裝、授權與基本設定。",
        links: [
          { href: "faststart.md", label: "快速開始" },
          { href: "AppPorts.md", label: "AppPorts 簡介" },
          { href: "settings.md", label: "設定" },
        ],
      },
      {
        title: "應用程式遷移",
        description: "了解應用程式的遷移、還原與不同類型的對應策略。",
        links: [
          { href: "core.md", label: "核心功能" },
          { href: "migration-strategy/portal.md", label: "遷移策略" },
          { href: "migration-strategy/strategy-map.md", label: "應用類型與策略" },
        ],
      },
      {
        title: "資料遷移",
        description: "查閱資料目錄操作、工具資料識別與容器掛載遷移指南。",
        links: [
          { href: "datamigrae/operation.md", label: "遷移操作指南" },
          { href: "datamigrae/tools.md", label: "工具目錄識別" },
          { href: "datamigrae/mount-migration.md", label: "容器掛載遷移" },
        ],
      },
    ],
    careTitle: "儲存與日常維護",
    careIntro: "查看外接磁碟要求、更新說明與常見問題的排查方式。",
    care: [
      {
        title: "外接儲存裝置",
        description: "了解外接磁碟怎麼選、哪些情境需要 APFS，以及相容性限制。",
        links: [
          { href: "storage-guide.md", label: "外接儲存裝置指南" },
          { href: "why-apfs.md", label: "APFS 要求" },
          { href: "limitations.md", label: "相容性與限制" },
        ],
      },
      {
        title: "更新與維護",
        description: "了解應用程式更新、macOS 27 變化，以及容器資料與簽名身分的關係。",
        links: [
          { href: "migration-strategy/updater-detection.md", label: "自更新應用識別" },
          { href: "macos-27.md", label: "macOS 27 升級說明" },
          { href: "datamigrae/container-identity.md", label: "容器資料與簽名" },
        ],
      },
      {
        title: "故障排查",
        description: "依症狀查找排查步驟、常見問題解答與日誌診斷方法。",
        links: [
          { href: "troubleshooting.md", label: "故障排除" },
          { href: "faq.md", label: "常見問題" },
          { href: "logging.md", label: "日誌與診斷" },
        ],
      },
    ],
    featuresIntro: "了解 AppPorts 的三項核心功能。",
    moreTitle: "繼續探索",
    more: [
      { title: "更新日誌", description: "依版本查看變更與修復紀錄。", href: "changelog.md" },
      { title: "實驗紀錄", description: "查閱沙盒、掛載、拔除磁碟與開機時序的實驗紀錄。", href: "research/README.md" },
      { title: "參與貢獻", description: "了解如何參與開發、測試與文件改進。", href: "contributing.md" },
    ],
  },
  ja: {
    ask: "AppPorts について何を知りたいですか？",
    startIntro: "初回の利用、アプリ移行、データ移行から、目的に合うガイドを選びます。",
    journeys: [
      {
        title: "はじめる",
        description: "AppPorts の概要、インストール、権限、基本設定を確認します。",
        links: [
          { href: "faststart.md", label: "クイックスタート" },
          { href: "AppPorts.md", label: "はじめに" },
          { href: "settings.md", label: "設定" },
        ],
      },
      {
        title: "アプリ移行",
        description: "アプリの移行・復元手順と、種類別の移行戦略を確認します。",
        links: [
          { href: "core.md", label: "主な機能" },
          { href: "migration-strategy/portal.md", label: "移行戦略" },
          { href: "migration-strategy/strategy-map.md", label: "アプリの種類と戦略" },
        ],
      },
      {
        title: "データ移行",
        description: "データディレクトリの操作、ツールデータの検出、コンテナのマウント移行を確認します。",
        links: [
          { href: "datamigrae/operation.md", label: "データ移行ガイド" },
          { href: "datamigrae/tools.md", label: "ツールディレクトリ検出" },
          { href: "datamigrae/mount-migration.md", label: "コンテナのマウント移行" },
        ],
      },
    ],
    careTitle: "ストレージと日常の管理",
    careIntro: "外部ドライブの要件、更新情報、問題の確認手順を探します。",
    care: [
      {
        title: "外部ストレージ",
        description: "外部ドライブの選び方、APFS が必要な場面、互換性の制限を確認します。",
        links: [
          { href: "storage-guide.md", label: "外部ストレージガイド" },
          { href: "why-apfs.md", label: "APFS の要件" },
          { href: "limitations.md", label: "互換性と制限" },
        ],
      },
      {
        title: "更新とメンテナンス",
        description: "アプリの更新、macOS 27 の変更、コンテナデータと署名 ID の関係を確認します。",
        links: [
          { href: "migration-strategy/updater-detection.md", label: "自動更新アプリの検出" },
          { href: "macos-27.md", label: "macOS 27 へのアップグレード" },
          { href: "datamigrae/container-identity.md", label: "コンテナデータと署名" },
        ],
      },
      {
        title: "トラブルシューティング",
        description: "症状別の確認手順、よくある質問、ログの調べ方を探します。",
        links: [
          { href: "troubleshooting.md", label: "トラブルシューティング" },
          { href: "faq.md", label: "よくある質問" },
          { href: "logging.md", label: "ログと診断" },
        ],
      },
    ],
    featuresIntro: "AppPorts の主な 3 つの機能を紹介します。",
    moreTitle: "さらに詳しく",
    more: [
      { title: "変更履歴", description: "バージョンごとの変更点と修正内容を確認します。", href: "changelog.md" },
      { title: "実験記録", description: "サンドボックス、マウント、ドライブ取り外し、起動時の実験記録を確認します。", href: "research/README.md" },
      { title: "コントリビューション", description: "開発、テスト、ドキュメント改善への参加方法を確認します。", href: "contributing.md" },
    ],
  },
  ko: {
    ask: "AppPorts에 대해 무엇이 궁금한가요?",
    startIntro: "처음 사용하기부터 앱과 데이터 마이그레이션까지, 필요한 가이드를 선택하세요.",
    journeys: [
      {
        title: "시작하기",
        description: "AppPorts의 개요, 설치, 권한과 기본 설정을 확인합니다.",
        links: [
          { href: "faststart.md", label: "빠른 시작" },
          { href: "AppPorts.md", label: "소개" },
          { href: "settings.md", label: "설정" },
        ],
      },
      {
        title: "앱 마이그레이션",
        description: "앱을 옮기거나 복원하는 방법과 유형별 전략을 알아봅니다.",
        links: [
          { href: "core.md", label: "핵심 기능" },
          { href: "migration-strategy/portal.md", label: "마이그레이션 전략" },
          { href: "migration-strategy/strategy-map.md", label: "앱 유형별 전략" },
        ],
      },
      {
        title: "데이터 마이그레이션",
        description: "데이터 디렉토리 작업, 도구 데이터 감지와 컨테이너 마운트 마이그레이션을 확인합니다.",
        links: [
          { href: "datamigrae/operation.md", label: "데이터 마이그레이션 가이드" },
          { href: "datamigrae/tools.md", label: "도구 디렉토리 감지" },
          { href: "datamigrae/mount-migration.md", label: "컨테이너 마운트 마이그레이션" },
        ],
      },
    ],
    careTitle: "저장 장치와 일상 관리",
    careIntro: "외장 드라이브 요구 사항, 업데이트 안내와 문제 해결 가이드를 확인합니다.",
    care: [
      {
        title: "외장 저장 장치",
        description: "외장 드라이브 선택 기준, APFS가 필요한 경우와 호환성 제한을 확인합니다.",
        links: [
          { href: "storage-guide.md", label: "외장 저장 장치 가이드" },
          { href: "why-apfs.md", label: "APFS 요구 사항" },
          { href: "limitations.md", label: "호환성 및 제한 사항" },
        ],
      },
      {
        title: "업데이트 및 유지 관리",
        description: "앱 업데이트, macOS 27의 변경 사항, 컨테이너 데이터와 서명 ID의 관계를 알아봅니다.",
        links: [
          { href: "migration-strategy/updater-detection.md", label: "자체 업데이트 앱 식별" },
          { href: "macos-27.md", label: "macOS 27 업그레이드" },
          { href: "datamigrae/container-identity.md", label: "컨테이너 데이터와 서명" },
        ],
      },
      {
        title: "문제 해결",
        description: "증상별 확인 절차, 자주 묻는 질문과 로그 진단 방법을 찾습니다.",
        links: [
          { href: "troubleshooting.md", label: "문제 해결" },
          { href: "faq.md", label: "자주 묻는 질문" },
          { href: "logging.md", label: "로그 및 진단" },
        ],
      },
    ],
    featuresIntro: "AppPorts의 세 가지 핵심 기능을 알아봅니다.",
    moreTitle: "더 알아보기",
    more: [
      { title: "변경 이력", description: "버전별 변경 사항과 수정 내용을 확인합니다.", href: "changelog.md" },
      { title: "실험 기록", description: "샌드박스, 마운트, 드라이브 분리와 시스템 시작에 관한 실험 기록을 확인합니다.", href: "research/README.md" },
      { title: "기여하기", description: "개발, 테스트와 문서 개선에 참여하는 방법을 알아봅니다.", href: "contributing.md" },
    ],
  },
  de: {
    ask: "Was möchten Sie über AppPorts wissen?",
    startIntro: "Wählen Sie einen Leitfaden für den Einstieg, die App-Migration oder die Datenmigration.",
    journeys: [
      {
        title: "Erste Schritte",
        description: "AppPorts, Installation, Berechtigungen und Grundeinstellungen kennenlernen.",
        links: [
          { href: "faststart.md", label: "Schnellstart" },
          { href: "AppPorts.md", label: "Einführung" },
          { href: "settings.md", label: "Einstellungen" },
        ],
      },
      {
        title: "Apps migrieren",
        description: "Apps verschieben oder zurückholen und die Strategien nach App-Typ verstehen.",
        links: [
          { href: "core.md", label: "Kernfunktionen" },
          { href: "migration-strategy/portal.md", label: "Migrationsstrategien" },
          { href: "migration-strategy/strategy-map.md", label: "App-Typen und Strategien" },
        ],
      },
      {
        title: "Daten migrieren",
        description: "Anleitungen zu Datenverzeichnissen, Tool-Daten und der Mount-Migration von Containerdaten lesen.",
        links: [
          { href: "datamigrae/operation.md", label: "Migrationsanleitung" },
          { href: "datamigrae/tools.md", label: "Tool-Verzeichniserkennung" },
          { href: "datamigrae/mount-migration.md", label: "Mount-Migration" },
        ],
      },
    ],
    careTitle: "Speicher und Wartung",
    careIntro: "Anforderungen an externe Laufwerke, Updates und Anleitungen zur Fehlerbehebung nachlesen.",
    care: [
      {
        title: "Externer Speicher",
        description: "Laufwerke auswählen und prüfen, wann APFS nötig ist und welche Kompatibilitätsgrenzen gelten.",
        links: [
          { href: "storage-guide.md", label: "Leitfaden für externen Speicher" },
          { href: "why-apfs.md", label: "APFS-Anforderungen" },
          { href: "limitations.md", label: "Kompatibilität und Grenzen" },
        ],
      },
      {
        title: "Updates und Wartung",
        description: "App-Updates, Änderungen in macOS 27 und den Bezug zwischen Containerdaten und Signaturidentität verstehen.",
        links: [
          { href: "migration-strategy/updater-detection.md", label: "Auto-Update-Erkennung" },
          { href: "macos-27.md", label: "Upgrade auf macOS 27" },
          { href: "datamigrae/container-identity.md", label: "Containerdaten und Signierung" },
        ],
      },
      {
        title: "Fehlerbehebung",
        description: "Prüfschritte nach Symptomen, Antworten auf häufige Fragen und Hinweise zu Logs finden.",
        links: [
          { href: "troubleshooting.md", label: "Fehlerbehebung" },
          { href: "faq.md", label: "Häufige Fragen" },
          { href: "logging.md", label: "Protokollierung und Diagnose" },
        ],
      },
    ],
    featuresIntro: "Die drei Kernfunktionen von AppPorts kennenlernen.",
    moreTitle: "Mehr entdecken",
    more: [
      { title: "Änderungsprotokoll", description: "Änderungen und Fehlerbehebungen nach Version nachlesen.", href: "changelog.md" },
      { title: "Versuchsprotokolle", description: "Versuche zu Sandbox, Mountpunkten, dem Abziehen von Laufwerken und dem Systemstart nachlesen.", href: "research/README.md" },
      { title: "Mitwirken", description: "Erfahren, wie Beiträge zu Entwicklung, Tests und Dokumentation möglich sind.", href: "contributing.md" },
    ],
  },
  fr: {
    ask: "Que souhaitez-vous savoir sur AppPorts ?",
    startIntro: "Choisissez un guide pour débuter, déplacer vos applications ou migrer vos données.",
    journeys: [
      {
        title: "Premiers pas",
        description: "Découvrez AppPorts, son installation, les autorisations et les réglages de base.",
        links: [
          { href: "faststart.md", label: "Démarrage rapide" },
          { href: "AppPorts.md", label: "Introduction" },
          { href: "settings.md", label: "Réglages" },
        ],
      },
      {
        title: "Migration des applications",
        description: "Consultez les méthodes de migration et de restauration, ainsi que les stratégies par type d’application.",
        links: [
          { href: "core.md", label: "Fonctionnalités principales" },
          { href: "migration-strategy/portal.md", label: "Stratégies de migration" },
          { href: "migration-strategy/strategy-map.md", label: "Types d’apps et stratégies" },
        ],
      },
      {
        title: "Migration de données",
        description: "Consultez les guides sur les répertoires de données, les données des outils et la migration des conteneurs par montage.",
        links: [
          { href: "datamigrae/operation.md", label: "Guide de migration" },
          { href: "datamigrae/tools.md", label: "Détection des répertoires d’outils" },
          { href: "datamigrae/mount-migration.md", label: "Migration par montage" },
        ],
      },
    ],
    careTitle: "Stockage et maintenance",
    careIntro: "Consultez les exigences des disques externes, les mises à jour et les guides de dépannage.",
    care: [
      {
        title: "Stockage externe",
        description: "Consultez les critères de choix d’un disque, les cas nécessitant APFS et les limites de compatibilité.",
        links: [
          { href: "storage-guide.md", label: "Guide du stockage externe" },
          { href: "why-apfs.md", label: "Exigences APFS" },
          { href: "limitations.md", label: "Compatibilité et limites" },
        ],
      },
      {
        title: "Mises à jour et maintenance",
        description: "Comprenez les mises à jour des apps, les changements de macOS 27 et le lien entre données de conteneur et identité de signature.",
        links: [
          { href: "migration-strategy/updater-detection.md", label: "Apps à mise à jour automatique" },
          { href: "macos-27.md", label: "Mise à niveau vers macOS 27" },
          { href: "datamigrae/container-identity.md", label: "Données de conteneur et signature" },
        ],
      },
      {
        title: "Dépannage",
        description: "Consultez les vérifications par symptôme, la FAQ et les conseils d’analyse des journaux.",
        links: [
          { href: "troubleshooting.md", label: "Dépannage" },
          { href: "faq.md", label: "Questions fréquentes" },
          { href: "logging.md", label: "Journalisation et diagnostic" },
        ],
      },
    ],
    featuresIntro: "Découvrez les trois fonctionnalités principales d’AppPorts.",
    moreTitle: "Pour aller plus loin",
    more: [
      { title: "Journal des modifications", description: "Consultez les changements et les correctifs par version.", href: "changelog.md" },
      { title: "Expériences", description: "Consultez les expériences sur le bac à sable, les montages, le débranchement des disques et le démarrage.", href: "research/README.md" },
      { title: "Contribuer", description: "Découvrez comment participer au développement, aux tests et à la documentation.", href: "contributing.md" },
    ],
  },
  es: {
    ask: "¿Qué quieres saber sobre AppPorts?",
    startIntro: "Elige una guía para empezar, mover aplicaciones o migrar datos.",
    journeys: [
      {
        title: "Primeros pasos",
        description: "Conoce AppPorts, la instalación, los permisos y la configuración básica.",
        links: [
          { href: "faststart.md", label: "Inicio rápido" },
          { href: "AppPorts.md", label: "Introducción" },
          { href: "settings.md", label: "Ajustes" },
        ],
      },
      {
        title: "Migración de aplicaciones",
        description: "Consulta cómo migrar y restaurar aplicaciones y las estrategias según su tipo.",
        links: [
          { href: "core.md", label: "Funciones principales" },
          { href: "migration-strategy/portal.md", label: "Estrategias de migración" },
          { href: "migration-strategy/strategy-map.md", label: "Tipos de apps y estrategias" },
        ],
      },
      {
        title: "Migración de datos",
        description: "Consulta las guías de directorios de datos, datos de herramientas y migración de contenedores por montaje.",
        links: [
          { href: "datamigrae/operation.md", label: "Guía de migración" },
          { href: "datamigrae/tools.md", label: "Detección de directorios de herramientas" },
          { href: "datamigrae/mount-migration.md", label: "Migración por montaje" },
        ],
      },
    ],
    careTitle: "Almacenamiento y mantenimiento",
    careIntro: "Consulta los requisitos de los discos externos, las actualizaciones y las guías de solución de problemas.",
    care: [
      {
        title: "Almacenamiento externo",
        description: "Consulta cómo elegir un disco, cuándo se necesita APFS y los límites de compatibilidad.",
        links: [
          { href: "storage-guide.md", label: "Guía de almacenamiento externo" },
          { href: "why-apfs.md", label: "Requisitos de APFS" },
          { href: "limitations.md", label: "Compatibilidad y limitaciones" },
        ],
      },
      {
        title: "Actualizaciones y mantenimiento",
        description: "Conoce las actualizaciones de apps, los cambios de macOS 27 y la relación entre datos de contenedores e identidad de firma.",
        links: [
          { href: "migration-strategy/updater-detection.md", label: "Apps con actualización automática" },
          { href: "macos-27.md", label: "Actualización a macOS 27" },
          { href: "datamigrae/container-identity.md", label: "Datos de contenedores y firma" },
        ],
      },
      {
        title: "Solución de problemas",
        description: "Consulta las comprobaciones por síntoma, las preguntas frecuentes y las guías de registros y diagnóstico.",
        links: [
          { href: "troubleshooting.md", label: "Solución de problemas" },
          { href: "faq.md", label: "Preguntas frecuentes" },
          { href: "logging.md", label: "Registro y diagnóstico" },
        ],
      },
    ],
    featuresIntro: "Conoce las tres funciones principales de AppPorts.",
    moreTitle: "Sigue explorando",
    more: [
      { title: "Registro de cambios", description: "Consulta los cambios y las correcciones por versión.", href: "changelog.md" },
      { title: "Experimentos", description: "Consulta experimentos sobre aislamiento, montajes, desconexión de discos y arranque.", href: "research/README.md" },
      { title: "Contribuir", description: "Descubre cómo participar en el desarrollo, las pruebas y la documentación.", href: "contributing.md" },
    ],
  },
};
