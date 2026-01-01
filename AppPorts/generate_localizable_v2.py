5import json

# Define languages with their emoji flags for reference (script just needs codes)
# en: 🇺🇸, zh-Hans: 🇨🇳, zh-Hant: 🇭🇰, es: 🇪🇸, fr: 🇫🇷, pt: 🇵🇹, it: 🇮🇹, ja: 🇯🇵, ru: 🇷🇺, ar: 🇸🇦, hi: 🇮🇳
# eo: 🇪🇴, de: 🇩🇪, ko: 🇰🇷, tr: 🇹🇷, vi: 🇻🇳, th: 🇹🇭, nl: 🇳🇱, pl: 🇵🇱, id: 🇮🇩

langs = ['en', 'zh-Hans', 'zh-Hant', 'hi', 'es', 'ar', 'ru', 'pt', 'fr', 'it', 'ja', 
         'eo', 'de', 'ko', 'tr', 'vi', 'th', 'nl', 'pl', 'id']

# Dictionary of translations
# Key: { lang_code: translation }
data = {
    "AppPorts": {
        "en": "AppPorts", "zh-Hans": "AppPorts", "zh-Hant": "AppPorts",
        "hi": "AppPorts", "es": "AppPorts", "ar": "AppPorts", "ru": "AppPorts",
        "pt": "AppPorts", "fr": "AppPorts", "it": "AppPorts", "ja": "AppPorts",
        "eo": "AppPorts", "de": "AppPorts", "ko": "AppPorts", "tr": "AppPorts",
        "vi": "AppPorts", "th": "AppPorts", "nl": "AppPorts", "pl": "AppPorts", "id": "AppPorts"
    },
    "Change Language / 切换语言": {
        "en": "Change Language", "zh-Hans": "切换语言", "zh-Hant": "切換語言",
        "hi": "भाषा बदलें", "es": "Cambiar idioma", "ar": "تغيير اللغة", "ru": "Сменить язык",
        "pt": "Mudar idioma", "fr": "Changer de langue", "it": "Cambia lingua", "ja": "言語を変更",
        "eo": "Ŝanĝi lingvon", "de": "Sprache ändern", "ko": "언어 변경", "tr": "Dili değiştir",
        "vi": "Thay đổi ngôn ngữ", "th": "เปลี่ยนภาษา", "nl": "Taal wijzigen", "pl": "Zmień język", "id": "Ganti Bahasa"
    },
    "English": {
        "en": "English", "zh-Hans": "英语", "zh-Hant": "英語",
        "hi": "अंग्रेज़ी", "es": "Inglés", "ar": "إنجليزي", "ru": "Английский",
        "pt": "Inglês", "fr": "Anglais", "it": "Inglese", "ja": "英語",
        "eo": "Angla", "de": "Englisch", "ko": "영어", "tr": "İngilizce",
        "vi": "Tiếng Anh", "th": "ภาษาอังกฤษ", "nl": "Engels", "pl": "Angielski", "id": "Inggris"
    },
    "Language": {
        "en": "Language", "zh-Hans": "语言", "zh-Hant": "語言",
        "hi": "भाषा", "es": "Idioma", "ar": "لغة", "ru": "Язык",
        "pt": "Idioma", "fr": "Langue", "it": "Lingua", "ja": "言語",
        "eo": "Lingvo", "de": "Sprache", "ko": "언어", "tr": "Dil",
        "vi": "Ngôn ngữ", "th": "ภาษา", "nl": "Taal", "pl": "Język", "id": "Bahasa"
    },
    "Mac 本地应用": {
        "en": "Local Apps", "zh-Hans": "Mac 本地应用", "zh-Hant": "Mac 本地應用程式",
        "hi": "स्थानीय ऐप्स", "es": "Apps locales", "ar": "تطبيقات محلية", "ru": "Локальные приложения",
        "pt": "Apps locais", "fr": "Applications locales", "it": "App locali", "ja": "ローカルアプリ",
        "eo": "Lokaj Aplikaĵoj", "de": "Lokale Apps", "ko": "로컬 앱", "tr": "Yerel Uygulamalar",
        "vi": "Ứng dụng cục bộ", "th": "แอปในเครื่อง", "nl": "Lokale apps", "pl": "Aplikacje lokalne", "id": "Aplikasi Lokal"
    },
    "Version 1.0.0": {
        "en": "Version 1.0.0", "zh-Hans": "版本 1.0.0", "zh-Hant": "版本 1.0.0",
        "hi": "संस्करण 1.0.0", "es": "Versión 1.0.0", "ar": "إصدار 1.0.0", "ru": "Версия 1.0.0",
        "pt": "Versão 1.0.0", "fr": "Version 1.0.0", "it": "Versione 1.0.0", "ja": "バージョン 1.0.0",
        "eo": "Versio 1.0.0", "de": "Version 1.0.0", "ko": "버전 1.0.0", "tr": "Sürüm 1.0.0",
        "vi": "Phiên bản 1.0.0", "th": "เวอร์ชัน 1.0.0", "nl": "Versie 1.0.0", "pl": "Wersja 1.0.0", "id": "Versi 1.0.0"
    },
    "Version 1.1.0": {
        "en": "Version 1.1.0", "zh-Hans": "版本 1.1.0", "zh-Hant": "版本 1.1.0",
        "hi": "संस्करण 1.1.0", "es": "Versión 1.1.0", "ar": "إصدار 1.1.0", "ru": "Версия 1.1.0",
        "pt": "Versão 1.1.0", "fr": "Version 1.1.0", "it": "Versione 1.1.0", "ja": "バージョン 1.1.0",
        "eo": "Versio 1.1.0", "de": "Version 1.1.0", "ko": "버전 1.1.0", "tr": "Sürüm 1.1.0",
        "vi": "Phiên bản 1.1.0", "th": "เวอร์ชัน 1.1.0", "nl": "Versie 1.1.0", "pl": "Wersja 1.1.0", "id": "Versi 1.1.0"
    },
    "个人网站": {
        "en": "Website", "zh-Hans": "个人网站", "zh-Hant": "個人網站",
        "hi": "वेबसाइट", "es": "Sitio web", "ar": "موقع الكتروني", "ru": "Веб-сайт",
        "pt": "Site", "fr": "Site web", "it": "Sito web", "ja": "ウェブサイト",
        "eo": "Retejo", "de": "Webseite", "ko": "웹사이트", "tr": "Web Sitesi",
        "vi": "Trang web", "th": "เว็บไซต์", "nl": "Website", "pl": "Strona internetowa", "id": "Situs Web"
    },
    "关于 AppPorts...": {
        "en": "About AppPorts...", "zh-Hans": "关于 AppPorts...", "zh-Hant": "關於 AppPorts...",
        "hi": "AppPorts के बारे में...", "es": "Acerca de AppPorts...", "ar": "حول AppPorts...", "ru": "О AppPorts...",
        "pt": "Sobre o AppPorts...", "fr": "À propos d'AppPorts...", "it": "Info su AppPorts...", "ja": "AppPortsについて...",
        "eo": "Pri AppPorts...", "de": "Über AppPorts...", "ko": "AppPorts 정보...", "tr": "AppPorts Hakkında...",
        "vi": "Về AppPorts...", "th": "เกี่ยวกับ AppPorts...", "nl": "Over AppPorts...", "pl": "O AppPorts...", "id": "Tentang AppPorts..."
    },
    "关闭": {
        "en": "Close", "zh-Hans": "关闭", "zh-Hant": "關閉",
        "hi": "बंद करें", "es": "Cerrar", "ar": "إغلاق", "ru": "Закрыть",
        "pt": "Fechar", "fr": "Fermer", "it": "Chiudi", "ja": "閉じる",
        "eo": "Fermi", "de": "Schließen", "ko": "닫기", "tr": "Kapat",
        "vi": "Đóng", "th": "ปิด", "nl": "Sluiten", "pl": "Zamknij", "id": "Tutup"
    },
    "刷新列表": {
        "en": "Refresh List", "zh-Hans": "刷新列表", "zh-Hant": "重新整理列表",
        "hi": "सूची ताज़ा करें", "es": "Actualizar lista", "ar": "تحديث القائمة", "ru": "Обновить список",
        "pt": "Atualizar lista", "fr": "Actualiser la liste", "it": "Aggiorna elenco", "ja": "リストを更新",
        "eo": "Refreŝigi liston", "de": "Liste aktualisieren", "ko": "목록 새로고침", "tr": "Listeyi Yenile",
        "vi": "Làm mới danh sách", "th": "รีเฟรชรายการ", "nl": "Lijst vernieuwen", "pl": "Odśwież listę", "id": "Segarkan Daftar"
    },
    "去设置授予权限": {
        "en": "Go to Settings", "zh-Hans": "去设置授予权限", "zh-Hant": "前往設定授予權限",
        "hi": "सेटिंग्स में जाएं", "es": "Ir a Configuración", "ar": "الذهاب إلى الإعدادات", "ru": "Перейти в настройки",
        "pt": "Ir para Configurações", "fr": "Aller aux paramètres", "it": "Vai alle Impostazioni", "ja": "設定に移動",
        "eo": "Iru al Agordoj", "de": "Zu den Einstellungen", "ko": "설정으로 이동", "tr": "Ayarlara Git",
        "vi": "Đi tới Cài đặt", "th": "ไปที่การตั้งค่า", "nl": "Ga naar Instellingen", "pl": "Idź do ustawień", "id": "Buka Pengaturan"
    },
    "在 Finder 中显示": {
        "en": "Show in Finder", "zh-Hans": "在 Finder 中显示", "zh-Hant": "在 Finder 中顯示",
        "hi": "Finder में दिखाएं", "es": "Mostrar en Finder", "ar": "عرض في Finder", "ru": "Показать в Finder",
        "pt": "Mostrar no Finder", "fr": "Afficher dans le Finder", "it": "Mostra nel Finder", "ja": "Finderで表示",
        "eo": "Montri en Finder", "de": "Im Finder anzeigen", "ko": "Finder에서 보기", "tr": "Finder'da Göster",
        "vi": "Hiển thị trong Finder", "th": "แสดงใน Finder", "nl": "Toon in Finder", "pl": "Pokaż w Finderze", "id": "Tampilkan di Finder"
    },
    "在原位置自动创建符号链接，系统和 Launchpad 依然能正常识别应用。": {
        "en": "Automatically create symlinks in place. System and Launchpad recognize apps as normal.",
        "zh-Hans": "在原位置自动创建符号链接，系统和 Launchpad 依然能正常识别应用。",
        "zh-Hant": "在原位置自動建立符號連結，系統和 Launchpad 依然能正常識別應用程式。",
        "hi": "स्वचालित रूप से सिम्लिंक बनाएं। सिस्टम और लॉन्चपैड ऐप्स को सामान्य रूप से पहचानते हैं।",
        "es": "Crea enlaces simbólicos automáticamente. El sistema y Launchpad reconocen las apps normalmente.",
        "ar": "إنشاء روابط رمزية تلقائيًا. يتعرف النظام و Launchpad على التطبيقات بشكل طبيعي.",
        "ru": "Автоматически создавать символические ссылки. Система и Launchpad распознают приложения как обычно.",
        "pt": "Cria links simbólicos automaticamente. O sistema e o Launchpad reconhecem os apps normalmente.",
        "fr": "Créez automatiquement des liens symboliques. Le système et le Launchpad reconnaissent les applications normalement.",
        "it": "Crea automaticamente collegamenti simbolici. Il sistema e il Launchpad riconoscono le app normalmente.",
        "ja": "自動的にシンボリックリンクを作成します。システムとLaunchpadはアプリを正常に認識します。",
        "eo": "Aŭtomate krei simbolajn ligilojn. Sistemo kaj Launchpad rekonas aplikaĵojn normale.",
        "de": "Erstellt automatisch symbolische Verknüpfungen. System und Launchpad erkennen Apps normal.",
        "ko": "제자리에 심볼릭 링크를 자동으로 생성합니다. 시스템과 Launchpad는 앱을 정상적으로 인식합니다.",
        "tr": "Otomatik olarak sembolik linkler oluşturun. Sistem ve Launchpad uygulamaları normal olarak tanır.",
        "vi": "Tự động tạo liên kết tượng trưng tại chỗ. Hệ thống và Launchpad nhận dạng ứng dụng bình thường.",
        "th": "สร้าง symlink โดยอัตโนมัติในที่เดิม ระบบและ Launchpad จะจดจำแอปได้ตามปกติ",
        "nl": "Maak automatisch symlinks aan. Systeem en Launchpad herkennen apps normaal.",
        "pl": "Automatycznie twórz dowiązania symboliczne. System i Launchpad rozpoznają aplikacje normalnie.",
        "id": "Secara otomatis membuat symlink di tempat. Sistem dan Launchpad mengenali aplikasi seperti biasa."
    },
    "外部": {
        "en": "External", "zh-Hans": "外部", "zh-Hant": "外部",
        "hi": "बाहरी", "es": "Externo", "ar": "خارجي", "ru": "Внешний",
        "pt": "Externo", "fr": "Externe", "it": "Esterno", "ja": "外部",
        "eo": "Ekstera", "de": "Extern", "ko": "외부", "tr": "Harici",
        "vi": "Bên ngoài", "th": "ภายนอก", "nl": "Extern", "pl": "Zewnętrzny", "id": "Eksternal"
    },
    "外部应用库": {
        "en": "External Drive", "zh-Hans": "外部应用库", "zh-Hant": "外部儲存",
        "hi": "बाहरी ड्राइव", "es": "Unidad externa", "ar": "قرص خارجي", "ru": "Внешний диск",
        "pt": "Unidade Externa", "fr": "Disque externe", "it": "Unità esterna", "ja": "外部ドライブ",
        "eo": "Ekstera Disko", "de": "Externes Laufwerk", "ko": "외부 드라이브", "tr": "Harici Sürücü",
        "vi": "Ổ đĩa ngoài", "th": "ไดรฟ์ภายนอก", "nl": "Externe schijf", "pl": "Dysk zewnętrzny", "id": "Drive Eksternal"
    },
    "好的": {
        "en": "OK", "zh-Hans": "好的", "zh-Hant": "好",
        "hi": "ठीक है", "es": "Aceptar", "ar": "موافق", "ru": "ОК",
        "pt": "OK", "fr": "D'accord", "it": "OK", "ja": "OK",
        "eo": "Bone", "de": "OK", "ko": "확인", "tr": "Tamam",
        "vi": "OK", "th": "ตกลง", "nl": "OK", "pl": "OK", "id": "Oke"
    },
    "将应用迁移回本地": {
        "en": "Migrate app back to local", "zh-Hans": "将应用迁移回本地", "zh-Hant": "將應用程式遷移回本地",
        "hi": "ऐप को स्थानीय पर वापस माइग्रेट करें", "es": "Migrar app de vuelta a local", "ar": "نقل التطبيق مرة أخرى إلى المحلي", "ru": "Перенести приложение обратно на локальный диск",
        "pt": "Migrar app de volta para local", "fr": "Migrer l'app vers le local", "it": "Migra app di nuovo in locale", "ja": "アプリをローカルに戻す",
        "eo": "Reranslogi aplikaĵon al loka", "de": "App zurück nach lokal migrieren", "ko": "앱을 다시 로컬로 마이그레이션", "tr": "Uygulamayı yerele geri taşı",
        "vi": "Di chuyển ứng dụng trở lại cục bộ", "th": "ย้ายแอปกลับไปที่เครื่อง", "nl": "Migreer app terug naar lokaal", "pl": "Przenieś aplikację z powrotem na dysk lokalny", "id": "Migrasikan aplikasi kembali ke lokal"
    },
    "将庞大的应用程序一键迁移至外部移动硬盘，释放宝贵的 Mac 本地空间。": {
        "en": "One-click migrate large apps to external drive, freeing up valuable Mac space.",
        "zh-Hans": "将庞大的应用程序一键迁移至外部移动硬盘，释放宝贵的 Mac 本地空间。",
        "zh-Hant": "將龐大的應用程式一鍵遷移至外接硬碟，釋放寶貴的 Mac 本地空間。",
        "hi": "बड़े ऐप्स को बाहरी ड्राइव में माइग्रेट करें और मैक स्पेस खाली करें।",
        "es": "Migra grandes apps a una unidad externa con un solo clic, liberando espacio en tu Mac.",
        "ar": "نقل التطبيقات الكبيرة إلى محرك أقراص خارجي بنقرة واحدة، مما يوفر مساحة Mac قيمة.",
        "ru": "Миграция больших приложений на внешний диск в один клик, освобождая место на Mac.",
        "pt": "Migre apps grandes para unidade externa com um clique, liberando espaço no Mac.",
        "fr": "Migrez les grandes applications vers un disque externe en un clic, libérant de l'espace sur Mac.",
        "it": "Migra grandi app su unità esterna con un clic, liberando spazio prezioso su Mac.",
        "ja": "ワンクリックで大きなアプリを外部ドライブに移行し、Macのスペースを解放します。",
        "eo": "Unuklaka migrado de grandaj aplikaĵoj al ekstera disko, liberigante valoran spacon de Mac.",
        "de": "Migrieren Sie große Apps mit einem Klick auf ein externes Laufwerk und geben Sie wertvollen Mac-Speicherplatz frei.",
        "ko": "원클릭으로 대용량 앱을 외부 드라이브로 마이그레이션하여 귀중한 Mac 공간을 확보하세요.",
        "tr": "Büyük uygulamaları tek tıklamayla harici sürücüye taşıyın, değerli Mac alanını boşaltın.",
        "vi": "Di chuyển các ứng dụng lớn sang ổ đĩa ngoài chỉ bằng một cú nhấp chuột, giải phóng không gian Mac quý giá.",
        "th": "ย้ายแอปขนาดใหญ่ไปยังไดรฟ์ภายนอกได้ในคลิกเดียว เพิ่มพื้นที่ว่างอันมีค่าให้กับ Mac ของคุณ",
        "nl": "Migreer grote apps met één klik naar een externe schijf en maak waardevolle Mac-ruimte vrij.",
        "pl": "Jednym kliknięciem przenieś duże aplikacje na dysk zewnętrzny, zwalniając cenne miejsce na Macu.",
        "id": "Migrasikan aplikasi besar ke drive eksternal dengan sekali klik, membebaskan ruang Mac yang berharga."
    },
    "已链接": {
        "en": "Linked", "zh-Hans": "已链接", "zh-Hant": "已連結",
        "hi": "लिंक किया गया", "es": "Enlazado", "ar": "مرتبط", "ru": "Связано",
        "pt": "Vinculado", "fr": "Lié", "it": "Collegato", "ja": "リンク済み",
        "eo": "Ligitas", "de": "Verknüpft", "ko": "연결됨", "tr": "Bağlı",
        "vi": "Đã liên kết", "th": "เชื่อมโยงแล้ว", "nl": "Gekoppeld", "pl": "Połączone", "id": "Terhubung"
    },
    "应用瘦身": {
        "en": "App Slimming", "zh-Hans": "应用瘦身", "zh-Hant": "應用程式瘦身",
        "hi": "ऐप स्लिमिंग", "es": "Adelgazamiento de App", "ar": "تقليص التطبيق", "ru": "Оптимизация приложений",
        "pt": "Otimização de App", "fr": "Amincissement d'app", "it": "Snellimento app", "ja": "アプリの軽量化",
        "eo": "Aplikaĵa Maldikiĝo", "de": "App-Optimierung", "ko": "앱 슬리밍", "tr": "Uygulama Zayıflatma",
        "vi": "Làm gọn ứng dụng", "th": "การลดขนาดแอป", "nl": "App afslanken", "pl": "Odchudzanie aplikacji", "id": "Pengecilan Aplikasi"
    },
    "应用运行中": {
        "en": "App Running", "zh-Hans": "应用运行中", "zh-Hant": "應用程式執行中",
        "hi": "ऐप चल रहा है", "es": "Aplicación en ejecución", "ar": "التطبيق قيد التشغيل", "ru": "Приложение запущен",
        "pt": "App em execução", "fr": "Application en cours", "it": "App in esecuzione", "ja": "アプリ実行中",
        "eo": "Aplikaĵo Ruzas", "de": "App läuft", "ko": "앱 실행 중", "tr": "Uygulama Çalışıyor",
        "vi": "Ứng dụng đang chạy", "th": "แอปกำลังทำงาน", "nl": "App draait", "pl": "Aplikacja działa", "id": "Aplikasi Berjalan"
    },
    "应用需要读写 /Applications 目录才能工作。请在系统设置中开启。": {
        "en": "App needs read/write access to /Applications. Please enable in System Settings.",
        "zh-Hans": "应用需要读写 /Applications 目录才能工作。请在系统设置中开启。",
        "zh-Hant": "應用程式需要讀寫 /Applications 目錄才能運作。請在系統設定中開啟。",
        "hi": "ऐप को /Applications तक पहुंच की आवश्यकता है। कृपया सेटिंग्स में सक्षम करें।",
        "es": "La app necesita acceso de lectura/escritura a /Applications. Habilítalo en Configuración.",
        "ar": "يحتاج التطبيق إلى الوصول للقراءة/الكتابة إلى /Applications. يرجى التمكين في الإعدادات.",
        "ru": "Приложению требуется доступ к /Applications. Включите в настройках.",
        "pt": "O app precisa de acesso de leitura/gravação em /Applications. Ative nas Configurações.",
        "fr": "L'app a besoin d'un accès lecture/écriture à /Applications. Activez dans les Réglages.",
        "it": "L'app necessita di accesso lettura/scrittura a /Applications. Abilita nelle Impostazioni.",
        "ja": "アプリには/Applicationsへの読み書きアクセスが必要です。設定で有効にしてください。",
        "eo": "Aplikaĵo bezonas legi/skribi aliron al /Applications. Bonvolu ebligi en Sistemaj Agordoj.",
        "de": "App benötigt Lese-/Schreibzugriff auf /Applications. Bitte in den Systemeinstellungen aktivieren.",
        "ko": "앱에 /Applications에 대한 읽기/쓰기 액세스가 필요합니다. 시스템 설정에서 활성화하십시오.",
        "tr": "Uygulamanın /Applications klasörüne okuma/yazma erişimine ihtiyacı var. Lütfen Sistem Ayarlarında etkinleştirin.",
        "vi": "Ứng dụng cần quyền đọc/ghi vào /Applications. Vui lòng bật trong Cài đặt hệ thống.",
        "th": "แอปต้องการสิทธิ์อ่าน/เขียนใน /Applications โปรดเปิดใช้งานในการตั้งค่าระบบ",
        "nl": "App heeft lees-/schrijftoegang nodig tot /Applications. Schakel dit in bij Systeeminstellingen.",
        "pl": "Aplikacja wymaga dostępu do odczytu/zapisu w /Applications. Włącz w Ustawieniach systemowych.",
        "id": "Aplikasi memerlukan akses baca/tulis ke /Applications. Harap aktifkan di Pengaturan Sistem."
    },
    "感谢你使用本工具，外置硬盘拯救世界！": {
        "en": "Thanks for using. External drives save the world!",
        "zh-Hans": "感谢你使用本工具，外置硬盘拯救世界！",
        "zh-Hant": "感謝你使用本工具，外接硬碟拯救世界！",
        "hi": "उपयोग के लिए धन्यवाद। बाहरी ड्राइव दुनिया बचाते हैं!",
        "es": "¡Gracias por usar! ¡Los discos externos salvan el mundo!",
        "ar": "شكرا لاستخدامك. محركات الأقراص الخارجية تنقذ العالم!",
        "ru": "Спасибо за использование. Внешние диски спасают мир!",
        "pt": "Obrigado por usar. Unidades externas salvam o mundo!",
        "fr": "Merci d'utiliser. Les disques externes sauvent le monde !",
        "it": "Grazie per l'uso. Le unità esterne salvano il mondo!",
        "ja": "ご利用ありがとうございます。外部ドライブが世界を救う！",
        "eo": "Dankon pro uzado. Eksteraj diskoj savas la mondon!",
        "de": "Danke für die Nutzung. Externe Laufwerke retten die Welt!",
        "ko": "이용해 주셔서 감사합니다. 외부 드라이브가 세상을 구합니다!",
        "tr": "Kullandığınız için teşekkürler. Harici sürücüler dünyayı kurtarır!",
        "vi": "Cảm ơn bạn đã sử dụng. Ổ đĩa ngoài cứu thế giới!",
        "th": "ขอบคุณที่ใช้บริการ ไดรฟ์ภายนอกกู้โลก!",
        "nl": "Bedankt voor het gebruik. Externe schijven redden de wereld!",
        "pl": "Dzięki za używanie. Dyski zewnętrzne ratują świat!",
        "id": "Terima kasih telah menggunakan. Drive eksternal menyelamatkan dunia!"
    },
    "我已授权，开始使用": {
        "en": "Authorized, Start Now", "zh-Hans": "我已授权，开始使用", "zh-Hant": "我已授權，開始使用",
        "hi": "अधिकृत, अभी शुरू करें", "es": "Autorizado, Comencemos", "ar": "مصرح به، ابدأ الآن", "ru": "Авторизовано, Начать",
        "pt": "Autorizado, Começar Agora", "fr": "Autorisé, Commencer", "it": "Autorizzato, Inizia Ora", "ja": "許可しました、開始",
        "eo": "Rajtshavigita, Komenci Nu", "de": "Autorisiert, Jetzt starten", "ko": "승인됨, 지금 시작", "tr": "Yetkilendirildi, Şimdi Başla",
        "vi": "Đã ủy quyền, Bắt đầu ngay", "th": "ได้รับอนุญาตแล้ว เริ่มเลย", "nl": "Geautoriseerd, Start nu", "pl": "Autoryzowano, Rozpocznij teraz", "id": "Diotorisasi, Mulai Sekarang"
    },
    "搜索应用名称": {
        "en": "Search app name", "zh-Hans": "搜索应用名称", "zh-Hant": "搜尋應用程式名稱",
        "hi": "ऐप का नाम खोजें", "es": "Buscar nombre de app", "ar": "البحث عن اسم التطبيق", "ru": "Поиск приложения",
        "pt": "Buscar nome do app", "fr": "Rechercher une app", "it": "Cerca nome app", "ja": "アプリ名を検索",
        "eo": "Serĉi aplikaĵan nomon", "de": "App-Namen suchen", "ko": "앱 이름 검색", "tr": "Uygulama adını ara",
        "vi": "Tìm tên ứng dụng", "th": "ค้นหาชื่อแอป", "nl": "Zoek app-naam", "pl": "Szukaj nazwy aplikacji", "id": "Cari nama aplikasi"
    },
    "断开": {
        "en": "Unlink", "zh-Hans": "断开", "zh-Hant": "斷開",
        "hi": "अनलिंक करें", "es": "Desvincular", "ar": "فك الارتباط", "ru": "Отвязать",
        "pt": "Desvincular", "fr": "Délier", "it": "Scollega", "ja": "リンク解除",
        "eo": "Malkonekti", "de": "Trennen", "ko": "연결 해제", "tr": "Bağlantıyı Kes",
        "vi": "Hủy liên kết", "th": "ยกเลิกการเชื่อมโยง", "nl": "Ontkoppelen", "pl": "Odłącz", "id": "Putuskan Tautan"
    },
    "断开此链接并删除文件": {
        "en": "Disconnect and delete file", "zh-Hans": "断开此链接并删除文件", "zh-Hant": "斷開此連結並刪除檔案",
        "hi": "डिस्कनेक्ट करें और फ़ाइल हटाएं", "es": "Desconectar y eliminar archivo", "ar": "قطع الاتصال وحذف الملف", "ru": "Отключить и удалить файл",
        "pt": "Desconectar e excluir arquivo", "fr": "Déconnecter et supprimer le fichier", "it": "Disconnetti ed elimina file", "ja": "切断してファイルを削除",
        "eo": "Malkonekti kaj forigi dosieron", "de": "Trennen und Datei löschen", "ko": "연결 해제 및 파일 삭제", "tr": "Bağlantıyı kes ve dosyayı sil",
        "vi": "Ngắt kết nối và xóa tập tin", "th": "ตัดการเชื่อมต่อและลบไฟล์", "nl": "Verbinding verbreken en bestand verwijderen", "pl": "Rozłącz i usuń plik", "id": "Putuskan sambungan dan hapus file"
    },
    "无感链接": {
        "en": "Seamless Linking", "zh-Hans": "无感链接", "zh-Hant": "無感連結",
        "hi": "निर्बाध लिंकिंग", "es": "Vinculación perfecta", "ar": "ربط سلس", "ru": "Бесшовная связь",
        "pt": "Vinculação Perfeita", "fr": "Liaison transparente", "it": "Collegamento continuo", "ja": "シームレスなリンク",
        "eo": "Senjunta Ligado", "de": "Nahtlose Verknüpfung", "ko": "원활한 연결", "tr": "Kesintisiz Bağlantı",
        "vi": "Liên kết liền mạch", "th": "การเชื่อมโยงที่ราบรื่น", "nl": "Naadloze koppeling", "pl": "Płynne łączenie", "id": "Penautan yang Mulus"
    },
    "未找到匹配应用": {
        "en": "No matching apps found", "zh-Hans": "未找到匹配应用", "zh-Hant": "未找到相符的應用程式",
        "hi": "कोई मेल खाने वाले ऐप्स नहीं मिले", "es": "No se encontraron apps", "ar": "لم يتم العثور على تطبيقات", "ru": "Приложения не найдены",
        "pt": "Nenhum app encontrado", "fr": "Aucune application trouvée", "it": "Nessuna app trovata", "ja": "一致するアプリなし",
        "eo": "Neniuj kongruaj aplikaĵoj trovitaj", "de": "Keine passenden Apps gefunden", "ko": "일치하는 앱을 찾을 수 없음", "tr": "Eşleşen uygulama bulunamadı",
        "vi": "Không tìm thấy ứng dụng phù hợp", "th": "ไม่พบแอปที่ตรงกัน", "nl": "Geen overeenkomende apps gevonden", "pl": "Nie znaleziono pasujących aplikacji", "id": "Tidak ada aplikasi yang cocok ditemukan"
    },
    "未选择": {
        "en": "Not Selected", "zh-Hans": "未选择", "zh-Hant": "未選擇",
        "hi": "चयनित नहीं", "es": "No seleccionado", "ar": "لم يتم الاختيار", "ru": "Не выбрано",
        "pt": "Não selecionado", "fr": "Non sélectionné", "it": "Non selezionato", "ja": "未選択",
        "eo": "Ne elektita", "de": "Nicht ausgewählt", "ko": "선택되지 않음", "tr": "Seçilmedi",
        "vi": "Chưa chọn", "th": "ไม่ได้เลือก", "nl": "Niet geselecteerd", "pl": "Nie wybrano", "id": "Tidak Dipilih"
    },
    "本地": {
        "en": "Local", "zh-Hans": "本地", "zh-Hant": "本地",
        "hi": "स्थानीय", "es": "Local", "ar": "محلي", "ru": "Локальный",
        "pt": "Local", "fr": "Local", "it": "Locale", "ja": "ローカル",
        "eo": "Loka", "de": "Lokal", "ko": "로컬", "tr": "Yerel",
        "vi": "Cục bộ", "th": "ในเครื่อง", "nl": "Lokaal", "pl": "Lokalny", "id": "Lokal"
    },
    "本地已存在同名真实应用": {
        "en": "Real app with same name exists locally",
        "zh-Hans": "本地已存在同名真实应用", "zh-Hant": "本地已存在同名真實應用程式",
        "hi": "समान नाम वाला वास्तविक ऐप स्थानीय रूप से मौजूद है",
        "es": "La app real con el mismo nombre existe localmente",
        "ar": "التطبيق الحقيقي بنفس الاسم موجود محلياً",
        "ru": "Приложение с таким именем уже существует",
        "pt": "App real com mesmo nome existe localmente",
        "fr": "L'application réelle avec le même nom existe localement",
        "it": "L'app reale con lo stesso nome esiste localmente",
        "ja": "同名の実際のアプリがローカルに存在します",
        "eo": "Reala aplikaĵo kun la sama nomo ekzistas loke",
        "de": "Echte App mit gleichem Namen existiert lokal",
        "ko": "동일한 이름의 실제 앱이 로컬에 존재합니다",
        "tr": "Aynı isme sahip gerçek uygulama yerel olarak mevcut",
        "vi": "Ứng dụng thực có cùng tên tồn tại cục bộ",
        "th": "มีแอปจริงที่มีชื่อเดียวกันอยู่ในเครื่อง",
        "nl": "Echte app met dezelfde naam bestaat lokaal",
        "pl": "Prawdziwa aplikacja o tej samej nazwie istnieje lokalnie",
        "id": "Aplikasi nyata dengan nama yang sama ada secara lokal"
    },
    "权限不足。请前往“系统设置 > 隐私与安全性 > 完全磁盘访问权限”，允许 AppPorts 访问磁盘，然后重启应用。": {
        "en": "Permission denied. Please allow Full Disk Access in System Settings.",
        "zh-Hans": "权限不足。请前往“系统设置 > 隐私与安全性 > 完全磁盘访问权限”，允许 AppPorts 访问磁盘，然后重启应用。",
        "zh-Hant": "權限不足。請前往「系統設定 > 隱私權與安全性 > 完全磁碟存取權」，允許 AppPorts 存取磁碟，然後重新啟動應用程式。",
        "hi": "अनुमति अस्वीकृत। कृपया सिस्टम सेटिंग्स में पूर्ण डिस्क एक्सेस की अनुमति दें।",
        "es": "Permiso denegado. Permita el acceso total al disco en la configuración del sistema.",
        "ar": "تم رفض الإذن. يرجى السماح بالوصول الكامل إلى القرص في إعدادات النظام.",
        "ru": "Доступ запрещен. Разрешите полный доступ к диску в настройках системы.",
        "pt": "Permissão negada. Permita o Acesso Total ao Disco nas Configurações do Sistema.",
        "fr": "Permission refusée. Veuillez autoriser l'accès complet au disque dans les réglages système.",
        "it": "Permesso negato. Consenti Accesso completo al disco nelle Impostazioni di sistema.",
        "ja": "アクセス拒否。システム設定でフルディスクアクセスを許可してください。",
        "eo": "Permeso rifuzita. Bonvolu permesi Plenan Diskan Aliron en Sistemaj Agordoj.",
        "de": "Zugriff verweigert. Bitte erlauben Sie den vollen Festplattenzugriff in den Systemeinstellungen.",
        "ko": "권한이 거부되었습니다. 시스템 설정에서 전체 디스크 액세스를 허용하십시오.",
        "tr": "İzin reddedildi. Lütfen Sistem Ayarlarında Tam Disk Erişimine izin verin.",
        "vi": "Quyền bị từ chối. Vui lòng cho phép Truy cập toàn bộ đĩa trong Cài đặt hệ thống.",
        "th": "สิทธิ์ถูกปฏิเสธ โปรดอนุญาตการเข้าถึงดิสก์เต็มรูปแบบในการตั้งค่าระบบ",
        "nl": "Toestemming geweigerd. Sta volledige schijftoegang toe in Systeeminstellingen.",
        "pl": "Odmowa dostępu. Zezwól na pełny dostęp do dysku w Ustawieniach systemowych.",
        "id": "Izin ditolak. Harap izinkan Akses Disk Penuh di Pengaturan Sistem."
    },
    "欢迎使用 AppPorts": {
        "en": "Welcome to AppPorts", "zh-Hans": "欢迎使用 AppPorts", "zh-Hant": "歡迎使用 AppPorts",
        "hi": "AppPorts में आपका स्वागत है", "es": "Bienvenido a AppPorts", "ar": "مرحبا بك في AppPorts", "ru": "Добро пожаловать в AppPorts",
        "pt": "Bem-vindo ao AppPorts", "fr": "Bienvenue sur AppPorts", "it": "Benvenuto in AppPorts", "ja": "AppPortsへようこそ",
        "eo": "Bonvenon al AppPorts", "de": "Willkommen bei AppPorts", "ko": "AppPorts에 오신 것을 환영합니다", "tr": "AppPorts'a Hoş Geldiniz",
        "vi": "Chào mừng đến với AppPorts", "th": "ยินดีต้อนรับสู่ AppPorts", "nl": "Welkom bij AppPorts", "pl": "Witamy w AppPorts", "id": "Selamat datang di AppPorts"
    },
    "正在扫描...": {
        "en": "Scanning...", "zh-Hans": "正在扫描...", "zh-Hant": "正在掃描...",
        "hi": "स्कैनिंग...", "es": "Escaneando...", "ar": "يتم المسح...", "ru": "Сканирование...",
        "pt": "Escaneando...", "fr": "Scan en cours...", "it": "Scansione...", "ja": "スキャン中...",
        "eo": "Skanante...", "de": "Scannen...", "ko": "스캔 중...", "tr": "Taranıyor...",
        "vi": "Đang quét...", "th": "กำลังสแกน...", "nl": "Scannen...", "pl": "Skanowanie...", "id": "Memindai..."
    },
    "目标已存在真实文件": {
        "en": "Target real file exists", "zh-Hans": "目标已存在真实文件", "zh-Hant": "目標已存在真實檔案",
        "hi": "लक्ष्य वास्तविक फ़ाइल मौजूद है", "es": "El archivo real de destino existe", "ar": "الملف الحقيقي المستهدف موجود", "ru": "Целевой файл существует",
        "pt": "Arquivo real de destino existe", "fr": "Le fichier réel cible existe", "it": "Il file reale di destinazione esiste", "ja": "ターゲットの実ファイルが存在します",
        "eo": "Cella reala dosiero ekzistas", "de": "Ziel-Echtdatei existiert", "ko": "대상 실제 파일이 존재합니다", "tr": "Hedef gerçek dosya mevcut",
        "vi": "Tập tin thực đích tồn tại", "th": "มีไฟล์จริงเป้าหมายอยู่", "nl": "Doelbestand bestaat", "pl": "Docelowy plik rzeczywisty istnieje", "id": "File nyata target ada"
    },
    "空文件夹": {
        "en": "Empty Folder", "zh-Hans": "空文件夹", "zh-Hant": "空檔案夾",
        "hi": "खाली फ़ोल्डर", "es": "Carpeta vacía", "ar": "مجلد فارغ", "ru": "Пустая папка",
        "pt": "Pasta vazia", "fr": "Dossier vide", "it": "Cartella vuota", "ja": "空のフォルダ",
        "eo": "Malplena Dosierujo", "de": "Leerer Ordner", "ko": "빈 폴더", "tr": "Boş Klasör",
        "vi": "Thư mục trống", "th": "โฟลเดอร์ว่าง", "nl": "Lege map", "pl": "Pusty folder", "id": "Folder Kosong"
    },
    "简体中文": {
        "en": "Simplified Chinese", "zh-Hans": "简体中文", "zh-Hant": "簡體中文",
        "hi": "सरलीकृत चीनी", "es": "Chino simplificado", "ar": "صينية مبسطة", "ru": "Упрощенный китайский",
        "pt": "Chinês Simplificado", "fr": "Chinois simplifié", "it": "Cinese semplificato", "ja": "簡体字中国語",
        "eo": "Simpligita Ĉina", "de": "Vereinfachtes Chinesisch", "ko": "중국어 간체", "tr": "Basitleştirilmiş Çince",
        "vi": "Tiếng Trung giản thể", "th": "จีนตัวย่อ", "nl": "Vereenvoudigd Chinees", "pl": "Chiński uproszczony", "id": "Cina Sederhana"
    },
    "繁体中文": {
        "en": "Traditional Chinese", "zh-Hans": "繁体中文", "zh-Hant": "繁體中文",
        "hi": "पारंपरिक चीनी", "es": "Chino tradicional", "ar": "صينية تقليدية", "ru": "Традиционный китайский",
        "pt": "Chinês Tradicional", "fr": "Chinois traditionnel", "it": "Cinese tradizionale", "ja": "繁体字中国語",
        "eo": "Tradicia Ĉina", "de": "Traditionelles Chinesisch", "ko": "중국어 번체", "tr": "Geleneksel Çince",
        "vi": "Tiếng Trung phồn thể", "th": "จีนตัวเต็ม", "nl": "Traditioneel Chinees", "pl": "Chiński tradycyjny", "id": "Cina Tradisional"
    },
    "系统": {
        "en": "System", "zh-Hans": "系统", "zh-Hant": "系統",
        "hi": "सिस्टम", "es": "Sistema", "ar": "نظام", "ru": "Система",
        "pt": "Sistema", "fr": "Système", "it": "Sistema", "ja": "システム",
        "eo": "Sistemo", "de": "System", "ko": "시스템", "tr": "Sistem",
        "vi": "Hệ thống", "th": "ระบบ", "nl": "Systeem", "pl": "System", "id": "Sistem"
    },
    "系统应用": {
        "en": "System App", "zh-Hans": "系统应用", "zh-Hant": "系統應用程式",
        "hi": "सिस्टम ऐप", "es": "App del sistema", "ar": "تطبيق النظام", "ru": "Системное приложение",
        "pt": "App do Sistema", "fr": "App système", "it": "App di sistema", "ja": "システムアプリ",
        "eo": "Sistema Aplikaĵo", "de": "System-App", "ko": "시스템 앱", "tr": "Sistem Uygulaması",
        "vi": "Ứng dụng hệ thống", "th": "แอประบบ", "nl": "Systeem-app", "pl": "Aplikacja systemowa", "id": "Aplikasi Sistem"
    },
    "计算中...": {
        "en": "Calculating...", "zh-Hans": "计算中...", "zh-Hant": "計算中...",
        "hi": "गणना हो रही है...", "es": "Calculando...", "ar": "جاري الحساب...", "ru": "Вычисление...",
        "pt": "Calculando...", "fr": "Calcul...", "it": "Calcolo...", "ja": "計算中...",
        "eo": "Kalkulante...", "de": "Berechnung...", "ko": "계산 중...", "tr": "Hesaplanıyor...",
        "vi": "Đang tính toán...", "th": "กำลังคำนวณ...", "nl": "Berekenen...", "pl": "Obliczanie...", "id": "Menghitung..."
    },
    "该应用正在运行。请先退出应用，然后再试。": {
        "en": "App is running. Please quit and try again.",
        "zh-Hans": "该应用正在运行。请先退出应用，然后再试。",
        "zh-Hant": "該應用程式正在執行。請先退出應用程式，然後再試。",
        "hi": "ऐप चल रहा है। कृपया इसे बंद करें और पुनः प्रयास करें।",
        "es": "La app se está ejecutando. Salga e inténtelo de nuevo.",
        "ar": "التطبيق قيد التشغيل. يرجى الإنهاء والمحاولة مرة أخرى.",
        "ru": "Приложение запущено. Выйдите и попробуйте снова.",
        "pt": "O app está em execução. Saia e tente novamente.",
        "fr": "L'application est en cours d'exécution. Veuillez quitter et réessayer.",
        "it": "L'app è in esecuzione. Esci e riprova.",
        "ja": "アプリが実行中です。終了してもう一度お試しください。",
        "eo": "Aplikaĵo funkcias. Bonvolu forlasi kaj reprovi.",
        "de": "App läuft. Bitte beenden und erneut versuchen.",
        "ko": "앱이 실행 중입니다. 종료하고 다시 시도하십시오.",
        "tr": "Uygulama çalışıyor. Lütfen çıkın ve tekrar deneyin.",
        "vi": "Ứng dụng đang chạy. Vui lòng thoát và thử lại.",
        "th": "แอปกำลังทำงาน โปรดออกและลองอีกครั้ง",
        "nl": "App is actief. Sluit af en probeer het opnieuw.",
        "pl": "Aplikacja działa. Wyjdź i spróbuj ponownie.",
        "id": "Aplikasi sedang berjalan. Silakan keluar dan coba lagi."
    },
    "请选择外部存储路径": {
        "en": "Choose External Drive Path", "zh-Hans": "请选择外部存储路径", "zh-Hant": "請選擇外部儲存路徑",
        "hi": "बाहरी ड्राइव पथ चुनें", "es": "Elegir ruta de unidad externa", "ar": "اختر مسار القرص الخارجي", "ru": "Выберите путь к внешнему диску",
        "pt": "Escolher caminho da unidade externa", "fr": "Choisir le chemin du disque externe", "it": "Scegli percorso unità esterna", "ja": "外部ドライブのパスを選択",
        "eo": "Elektu Eksteran Diskan Vojon", "de": "Wählen Sie den Pfad zum externen Laufwerk", "ko": "외부 드라이브 경로 선택", "tr": "Harici Sürücü Yolunu Seç",
        "vi": "Chọn đường dẫn ổ đĩa ngoài", "th": "เลือกเส้นทางไดรฟ์ภายนอก", "nl": "Kies extern schijfpad", "pl": "Wybierz ścieżkę dysku zewnętrznego", "id": "Pilih Jalur Drive Eksternal"
    },
    "跟随系统 (System)": {
        "en": "Follow System", "zh-Hans": "跟随系统 (System)", "zh-Hant": "跟隨系統 (System)",
        "hi": "सिस्टम का पालन करें", "es": "Seguir el sistema", "ar": "اتبع النظام", "ru": "Как в системе",
        "pt": "Seguir o Sistema", "fr": "Suivre le système", "it": "Segui il sistema", "ja": "システムに従う",
        "eo": "Sekvi Sistemon", "de": "System folgen", "ko": "시스템 따르기", "tr": "Sistemi Takip Et",
        "vi": "Theo hệ thống", "th": "ตามระบบ", "nl": "Volg Systeem", "pl": "Podążaj za systemem", "id": "Ikuti Sistem"
    },
    "迁移到外部": {
        "en": "Move to External", "zh-Hans": "迁移到外部", "zh-Hant": "遷移到外部",
        "hi": "बाहरी में ले जाएं", "es": "Mover a externo", "ar": "نقل إلى خارجي", "ru": "Переместить во внешний",
        "pt": "Mover para Externo", "fr": "Déplacer vers externe", "it": "Sposta su esterno", "ja": "外部へ移動",
        "eo": "Movi al Ekstera", "de": "Nach Extern verschieben", "ko": "외부로 이동", "tr": "Dışa Taşı",
        "vi": "Di chuyển ra ngoài", "th": "ย้ายไปภายนอก", "nl": "Verplaats naar extern", "pl": "Przenieś na zewnątrz", "id": "Pindah ke Eksternal"
    },
    "迁移成功": {
        "en": "Migration Successful", "zh-Hans": "迁移成功", "zh-Hant": "遷移成功",
        "hi": "माइग्रेशन सफल", "es": "Migración exitosa", "ar": "تم النقل بنجاح", "ru": "Миграция успешна",
        "pt": "Migração com Sucesso", "fr": "Migration réussie", "it": "Migrazione riuscita", "ja": "移行成功",
        "eo": "Migrado Sukcesa", "de": "Migration erfolgreich", "ko": "마이그레이션 성공", "tr": "Taşıma Başarılı",
        "vi": "Di chuyển thành công", "th": "การย้ายสำเร็จ", "nl": "Migratie succesvol", "pl": "Migracja zakończona sukcesem", "id": "Migrasi Berhasil"
    },
    "运行中": {
        "en": "Running", "zh-Hans": "运行中", "zh-Hant": "執行中",
        "hi": "चल रहा है", "es": "Ejecutando", "ar": "تشغيل", "ru": "Запущено",
        "pt": "Executando", "fr": "En cours", "it": "In esecuzione", "ja": "実行中",
        "eo": "Kuris", "de": "Läuft", "ko": "실행 중", "tr": "Çalışıyor",
        "vi": "Đang chạy", "th": "กำลังทำงาน", "nl": "Actief", "pl": "Działa", "id": "Berjalan"
    },
    "还原": {
        "en": "Restore", "zh-Hans": "还原", "zh-Hant": "還原",
        "hi": "पुनर्स्थापित करें", "es": "Restaurar", "ar": "استعادة", "ru": "Восстановить",
        "pt": "Restaurar", "fr": "Restaurer", "it": "Ripristina", "ja": "復元",
        "eo": "Restarigi", "de": "Wiederherstellen", "ko": "복원", "tr": "Geri Yükle",
        "vi": "Khôi phục", "th": "กู้คืน", "nl": "Herstellen", "pl": "Przywróć", "id": "Pulihkan"
    },
    "选择文件夹": {
        "en": "Select Folder", "zh-Hans": "选择文件夹", "zh-Hant": "選擇檔案夾",
        "hi": "फ़ोल्डर चुनें", "es": "Seleccionar carpeta", "ar": "اختر مجلد", "ru": "Выбрать папку",
        "pt": "Selecionar Pasta", "fr": "Sélectionner un dossier", "it": "Seleziona cartella", "ja": "フォルダを選択",
        "eo": "Elektu Dosierujon", "de": "Ordner auswählen", "ko": "폴더 선택", "tr": "Klasör Seç",
        "vi": "Chọn thư mục", "th": "เลือกโฟลเดอร์", "nl": "Selecteer map", "pl": "Wybierz folder", "id": "Pilih Folder"
    },
    "链接回本地": {
        "en": "Link Back to Local", "zh-Hans": "链接回本地", "zh-Hant": "連結回本地",
        "hi": "स्थानीय से लिंक करें", "es": "Enlazar de nuevo a local", "ar": "الرابط العودة إلى المحلي", "ru": "Связать обратно с локальным",
        "pt": "Vincular de volta ao local", "fr": "Lier à nouveau au local", "it": "Collega di nuovo al locale", "ja": "ローカルにリンクし直す",
        "eo": "Ligi reen al Loka", "de": "Zurück zu Lokal verknüpfen", "ko": "로컬로 다시 연결", "tr": "Yerele Geri Bağla",
        "vi": "Liên kết lại cục bộ", "th": "เชื่อมโยงกลับไปที่เครื่อง", "nl": "Link terug naar lokaal", "pl": "Połącz z powrotem z lokalnym", "id": "Tautkan Kembali ke Lokal"
    },
    "错误": {
        "en": "Error", "zh-Hans": "错误", "zh-Hant": "錯誤",
        "hi": "त्रुटि", "es": "Error", "ar": "خطأ", "ru": "Ошибка",
        "pt": "Erro", "fr": "Erreur", "it": "Errore", "ja": "エラー",
        "eo": "Eraro", "de": "Fehler", "ko": "오류", "tr": "Hata",
        "vi": "Lỗi", "th": "ข้อผิดพลาด", "nl": "Fout", "pl": "Błąd", "id": "Kesalahan"
    },
    "随时还原": {
        "en": "Restore Anytime", "zh-Hans": "随时还原", "zh-Hant": "隨時還原",
        "hi": "कभी भी पुनर्स्थापित करें", "es": "Restaurar en cualquier momento", "ar": "استعادة في أي وقت", "ru": "Восстановить в любое время",
        "pt": "Restaurar a Qualquer Momento", "fr": "Restaurer à tout moment", "it": "Ripristina in qualsiasi momento", "ja": "いつでも復元",
        "eo": "Restarigi Iam ajn", "de": "Jederzeit wiederherstellen", "ko": "언제든지 복원", "tr": "Her Zaman Geri Yükle",
        "vi": "Khôi phục bất cứ lúc nào", "th": "กู้คืนได้ทุกเวลา", "nl": "Op elk moment herstellen", "pl": "Przywróć w dowolnym momencie", "id": "Pulihkan Kapan Saja"
    },
    "需要“完全磁盘访问权限”": {
        "en": "Full Disk Access Required", "zh-Hans": "需要“完全磁盘访问权限”", "zh-Hant": "需要「完全磁碟存取權」",
        "hi": "पूर्ण डिस्क एक्सेस आवश्यक", "es": "Se requiere acceso total al disco", "ar": "مطلوب الوصول الكامل إلى القرص", "ru": "Требуется полный доступ к диску",
        "pt": "Acesso Total ao Disco Necessário", "fr": "Accès complet au disque requis", "it": "Accesso completo al disco richiesto", "ja": "フルディスクアクセスが必要です",
        "eo": "Plena Diska Aliro Bezonata", "de": "Voller Festplattenzugriff erforderlich", "ko": "전체 디스크 액세스 필요", "tr": "Tam Disk Erişimi Gerekli",
        "vi": "Cần quyền truy cập toàn bộ đĩa", "th": "ต้องการการเข้าถึงดิสก์เต็มรูปแบบ", "nl": "Volledige schijftoegang vereist", "pl": "Wymagany pełny dostęp do dysku", "id": "Akses Disk Penuh Diperlukan"
    },
    "需要时，可随时将应用一键完整迁回本地 /Applications 目录。": {
        "en": "Instantly move apps back to local /Applications whenever needed.",
        "zh-Hans": "需要时，可随时将应用一键完整迁回本地 /Applications 目录。",
        "zh-Hant": "需要時，可隨時將應用程式一鍵完整遷回本地 /Applications 目錄。",
        "hi": "जब भी आवश्यकता हो ऐप्स को तुरंत स्थानीय /Applications में वापस ले जाएं।",
        "es": "Mueve instantáneamente las apps de vuelta a /Applications local cuando sea necesario.",
        "ar": "انقل التطبيقات فورًا إلى /Applications المحلي عند الحاجة.",
        "ru": "Мгновенно переносите приложения обратно в /Applications при необходимости.",
        "pt": "Mova instantaneamente apps de volta para /Applications local quando necessário.",
        "fr": "Déplacez instantanément les applications vers /Applications localement si nécessaire.",
        "it": "Sposta istantaneamente le app in /Applications locale quando necessario.",
        "ja": "必要に応じて、いつでもアプリをローカルの/Applicationsディレクトリに戻せます。",
        "eo": "Tuj movu aplikaĵojn reen al loka /Applications kiam necese.",
        "de": "Verschieben Sie Apps bei Bedarf sofort zurück in den lokalen /Applications-Ordner.",
        "ko": "필요할 때마다 앱을 즉시 로컬 /Applications로 다시 이동하십시오.",
        "tr": "Gerektiğinde uygulamaları anında yerel /Applications klasörüne geri taşıyın.",
        "vi": "Di chuyển ứng dụng ngay lập tức trở lại /Applications cục bộ bất cứ khi nào cần thiết.",
        "th": "ย้ายแอปกลับไปที่ /Applications ในเครื่องได้ทันทีเมื่อจำเป็น",
        "nl": "Verplaats apps indien nodig direct terug naar lokaal /Applications.",
        "pl": "Natychmiast przenieś aplikacje z powrotem do lokalnego /Applications w razie potrzeby.",
        "id": "Segera pindahkan aplikasi kembali ke /Applications lokal kapan pun diperlukan."
    },
    "项目地址": {
        "en": "Project URL", "zh-Hans": "项目地址", "zh-Hant": "專案位址",
        "hi": "प्रोजेक्ट URL", "es": "URL del proyecto", "ar": "رابط المشروع", "ru": "URL проекта",
        "pt": "URL do Projeto", "fr": "URL du projet", "it": "URL del progetto", "ja": "プロジェクトURL",
        "eo": "Projekta URL", "de": "Projekt-URL", "ko": "프로젝트 URL", "tr": "Proje URL'si",
        "vi": "URL dự án", "th": "URL โครงการ", "nl": "Project-URL", "pl": "Adres URL projektu", "id": "URL Proyek"
    },
    "您的应用，随处安家。": {
        "en": "Your apps, anywhere.", "zh-Hans": "您的应用，随处安家。", "zh-Hant": "您的應用程式，隨處安家。",
        "hi": "आपके ऐप्स, कहीं भी।", "es": "Tus apps, donde sea.", "ar": "تطبيقاتك، في أي مكان.", "ru": "Ваши приложения, где угодно.",
        "pt": "Seus apps, em qualquer lugar.", "fr": "Vos applications, partout.", "it": "Le tue app, ovunque.", "ja": "あなたのアプリ、どこでも。",
        "eo": "Viaj aplikaĵoj, ie ajn.", "de": "Ihre Apps, überall.", "ko": "어디서나 당신의 앱.", "tr": "Uygulamalarınız, her yerde.",
        "vi": "Ứng dụng của bạn, ở bất cứ đâu.", "th": "แอปของคุณ ทุกที่", "nl": "Uw apps, overal.", "pl": "Twoje aplikacje, gdziekolwiek.", "id": "Aplikasi Anda, di mana saja."
    }
}

xcstrings_format = {
    "sourceLanguage": "zh-Hans",
    "strings": {},
    "version": "1.1"
}

for key, trans_dict in data.items():
    string_entry = {
        "extractionState": "manual",
        "localizations": {}
    }
    for lang_code, translated_text in trans_dict.items():
        string_entry["localizations"][lang_code] = {
            "stringUnit": {
                "state": "translated",
                "value": translated_text
            }
        }
    xcstrings_format["strings"][key] = string_entry

with open('Localizable.xcstrings', 'w') as f:
    json.dump(xcstrings_format, f, indent=2, ensure_ascii=False)

print("Generated Localizable.xcstrings successfully.")
