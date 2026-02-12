import json

# Define languages
langs = ['en', 'zh-Hans', 'zh-Hant', 'hi', 'es', 'ar', 'ru', 'pt', 'fr', 'it', 'ja', 
         'eo', 'de', 'ko', 'tr', 'vi', 'th', 'nl', 'pl', 'id', 'br']

def to_braille(text):
    # Basic English to Braille mapping (Grade 1 simplified)
    mapping = {
        'a': '⠁', 'b': '⠃', 'c': '⠉', 'd': '⠙', 'e': '⠑', 'f': '⠋', 'g': '⠛', 'h': '⠓', 'i': '⠊', 'j': '⠚',
        'k': '⠅', 'l': '⠇', 'm': '⠍', 'n': '⠝', 'o': '⠕', 'p': '⠏', 'q': '⠟', 'r': '⠗', 's': '⠎', 't': '⠞',
        'u': '⠥', 'v': '⠧', 'w': '⠺', 'x': '⠭', 'y': '⠽', 'z': '⠵',
        'A': '⠠⠁', 'B': '⠠⠃', 'C': '⠠⠉', 'D': '⠠⠙', 'E': '⠠⠑', 'F': '⠠⠋', 'G': '⠠⠛', 'H': '⠠⠓', 'I': '⠠⠊', 'J': '⠠⠚',
        'K': '⠠⠅', 'L': '⠠⠇', 'M': '⠠⠍', 'N': '⠠⠝', 'O': '⠠⠕', 'P': '⠠⠏', 'Q': '⠠⠟', 'R': '⠠⠗', 'S': '⠠⠎', 'T': '⠠⠞',
        'U': '⠠⠥', 'V': '⠠⠧', 'W': '⠠⠺', 'X': '⠠⠭', 'Y': '⠠⠽', 'Z': '⠠⠵',
        '1': '⠼⠁', '2': '⠼⠃', '3': '⠼⠉', '4': '⠼⠙', '5': '⠼⠑', '6': '⠼⠋', '7': '⠼⠛', '8': '⠼⠓', '9': '⠼⠊', '0': '⠼⠚',
        ' ': ' ', '.': '⠲', ',': '⠂', '!': '⠖', '?': '⠦', '\'': '⠄', '-': '⠤',
        '/': '⠌', '(': '⠐⠣', ')': '⠐⠜', ':': '⠒', ';': '⠆'
    }
    # Fallback to original char if not found
    return "".join(mapping.get(char, char) for char in text)

# Dictionary of translations
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
    "语言": {
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
    "Version %@": {
        "en": "Version %@", "zh-Hans": "版本 %@", "zh-Hant": "版本 %@",
        "hi": "संस्करण %@", "es": "Versión %@", "ar": "إصدار %@", "ru": "Версия %@",
        "pt": "Versão %@", "fr": "Version %@", "it": "Versione %@", "ja": "バージョン %@",
        "eo": "Versio %@", "de": "Version %@", "ko": "버전 %@", "tr": "Sürüm %@",
        "vi": "Phiên bản %@", "th": "เวอร์ชัน %@", "nl": "Versie %@", "pl": "Wersja %@", "id": "Versi %@"
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
    "未链接": {
        "en": "Not Linked", "zh-Hans": "未链接", "zh-Hant": "未連結",
        "hi": "लिंक नहीं किया गया", "es": "No enlazado", "ar": "غير مرتبط", "ru": "Не связано",
        "pt": "Não vinculado", "fr": "Non lié", "it": "Non collegato", "ja": "未リンク",
        "eo": "Ne ligita", "de": "Nicht verknüpft", "ko": "연결되지 않음", "tr": "Bağlı Değil",
        "vi": "Chưa liên kết", "th": "ไม่ได้เชื่อมโยง", "nl": "Niet gekoppeld", "pl": "Niepołączone", "id": "Tidak Terhubung"
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
        "vi": "Ứng dụng sedang chạy. Vui lòng thoát và thử lại.",
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
    },
    
    # --- New Strings (2026-01-26) ---
    
    "搜索应用 (本地 / 外部)...": {
        "en": "Search apps (Local / External)...", "zh-Hans": "搜索应用 (本地 / 外部)...", "zh-Hant": "搜尋應用程式 (本地 / 外部)...",
        "hi": "ऐप्स खोजें (स्थानीय / बाहरी)...", "es": "Buscar apps (Local / Externo)...", "ar": "بحث عن التطبيقات (محلي / خارجي)...", "ru": "Поиск приложений (Локальные / Внешние)...",
        "pt": "Buscar apps (Local / Externo)...", "fr": "Rechercher des apps (Local / Externe)...", "it": "Cerca app (Locale / Esterno)...", "ja": "アプリを検索 (ローカル / 外部)...",
        "eo": "Serĉi aplikaĵojn (Loka / Ekstera)...", "de": "Apps suchen (Lokal / Extern)...", "ko": "앱 검색 (로컬 / 외부)...", "tr": "Uygulamaları ara (Yerel / Harici)...",
        "vi": "Tìm kiếm ứng dụng (Cục bộ / Bên ngoài)...", "th": "ค้นหาแอป (ในเครื่อง / ภายนอก)...", "nl": "Apps zoeken (Lokaal / Extern)...", "pl": "Szukaj aplikacji (Lokalne / Zewnętrzne)...", "id": "Cari aplikasi (Lokal / Eksternal)..."
    },
    "排序": {
        "en": "Sort", "zh-Hans": "排序", "zh-Hant": "排序",
        "hi": "क्रमबद्ध करें", "es": "Ordenar", "ar": "فرز", "ru": "Сортировка",
        "pt": "Ordenar", "fr": "Trier", "it": "Ordina", "ja": "並べ替え",
        "eo": "Ordigu", "de": "Sortieren", "ko": "정렬", "tr": "Sırala",
        "vi": "Sắp xếp", "th": "เรียงลำดับ", "nl": "Sorteren", "pl": "Sortuj", "id": "Urutkan"
    },
    "排序方式": {
        "en": "Sort Order", "zh-Hans": "排序方式", "zh-Hant": "排序方式",
        "hi": "क्रमबद्ध करने का तरीका", "es": "Orden de clasificación", "ar": "ترتيب الفرز", "ru": "Порядок сортировки",
        "pt": "Ordem de classificação", "fr": "Ordre de tri", "it": "Ordine di cernita", "ja": "並べ替え順",
        "eo": "Ordo de ordigo", "de": "Sortierreihenfolge", "ko": "정렬 순서", "tr": "Sıralama Düzeni",
        "vi": "Thứ tự sắp xếp", "th": "ลำดับการเรียง", "nl": "Sorteervolgorde", "pl": "Kolejność sortowania", "id": "Urutan Sortir"
    },
    "按名称": {
        "en": "By Name", "zh-Hans": "按名称", "zh-Hant": "按名稱",
        "hi": "नाम के अनुसार", "es": "Por nombre", "ar": "بالاسم", "ru": "По имени",
        "pt": "Por nome", "fr": "Par nom", "it": "Per nome", "ja": "名前順",
        "eo": "Laŭ Nomo", "de": "Nach Name", "ko": "이름순", "tr": "İsme Göre",
        "vi": "Theo tên", "th": "ตามชื่อ", "nl": "Op naam", "pl": "Według nazwy", "id": "Berdasarkan Nama"
    },
    "按大小": {
        "en": "By Size", "zh-Hans": "按大小", "zh-Hant": "按大小",
        "hi": "आकार के अनुसार", "es": "Por tamaño", "ar": "بالحجم", "ru": "По размеру",
        "pt": "Por tamanho", "fr": "Par taille", "it": "Per dimensione", "ja": "サイズ順",
        "eo": "Laŭ Grandeco", "de": "Nach Größe", "ko": "크기순", "tr": "Boyuta Göre",
        "vi": "Theo kích thước", "th": "ตามขนาด", "nl": "Op grootte", "pl": "Według rozmiaru", "id": "Berdasarkan Ukuran"
    },
    "发现新版本": {
        "en": "New Version Found", "zh-Hans": "发现新版本", "zh-Hant": "發現新版本",
        "hi": "नया संस्करण मिला", "es": "Nueva versión encontrada", "ar": "تم العثور على إصدار جديد", "ru": "Найден новый версия",
        "pt": "Nova versão encontrada", "fr": "Nouvelle version trouvée", "it": "Nuova versione trovata", "ja": "新しいバージョンが見つかりました",
        "eo": "Nova Versio Trovita", "de": "Neue Version gefunden", "ko": "새 버전 발견", "tr": "Yeni Sürüm Bulundu",
        "vi": "Đã tìm thấy phiên bản mới", "th": "พบเวอร์ชันใหม่", "nl": "Nieuwe versie gevonden", "pl": "Znaleziono nową wersję", "id": "Versi Baru Ditemukan"
    },
    "前往下载": {
        "en": "Download Now", "zh-Hans": "前往下载", "zh-Hant": "前往下載",
        "hi": "अभी डाउनलोड करें", "es": "Descargar ahora", "ar": "تحميل الآن", "ru": "Скачать сейчас",
        "pt": "Baixar agora", "fr": "Télécharger maintenant", "it": "Scarica ora", "ja": "今すぐダウンロード",
        "eo": "Elŝutu Nun", "de": "Jetzt herunterladen", "ko": "지금 다운로드", "tr": "Şimdi İndir",
        "vi": "Tải xuống ngay", "th": "ดาวน์โหลดเดี๋ยวนี้", "nl": "Nu downloaden", "pl": "Pobierz teraz", "id": "Unduh Sekarang"
    },
    "以后再说": {
        "en": "Later", "zh-Hans": "以后再说", "zh-Hant": "以後再說",
        "hi": "बाद में", "es": "Más tarde", "ar": "لاحقاً", "ru": "Позже",
        "pt": "Mais tarde", "fr": "Plus tard", "it": "Più tardi", "ja": "後で",
        "eo": "Poste", "de": "Später", "ko": "나중에", "tr": "Daha Sonra",
        "vi": "Để sau", "th": "ภายหลัง", "nl": "Later", "pl": "Później", "id": "Nanti"
    },
    
    # --- New Strings (2026-02-02) Batch Migration & Progress ---
    
    "正在迁移应用...": {
        "en": "Migrating apps...", "zh-Hans": "正在迁移应用...", "zh-Hant": "正在遷移應用程式...",
        "hi": "ऐप्स माइग्रेट हो रहे हैं...", "es": "Migrando apps...", "ar": "جاري نقل التطبيقات...", "ru": "Перенос приложений...",
        "pt": "Migrando apps...", "fr": "Migration des apps...", "it": "Migrazione app...", "ja": "アプリを移行中...",
        "eo": "Migrante aplikaĵojn...", "de": "Apps werden migriert...", "ko": "앱 마이그레이션 중...", "tr": "Uygulamalar taşınıyor...",
        "vi": "Đang di chuyển ứng dụng...", "th": "กำลังย้ายแอป...", "nl": "Apps migreren...", "pl": "Migrowanie aplikacji...", "id": "Memigrasikan aplikasi..."
    },
    "迁移 %lld 个应用": {
        "en": "Move %lld Apps", "zh-Hans": "迁移 %lld 个应用", "zh-Hant": "遷移 %lld 個應用程式",
        "hi": "%lld ऐप्स स्थानांतरित करें", "es": "Mover %lld apps", "ar": "نقل %lld تطبيقات", "ru": "Переместить %lld приложений",
        "pt": "Mover %lld apps", "fr": "Déplacer %lld apps", "it": "Sposta %lld app", "ja": "%lld アプリを移動",
        "eo": "Movi %lld aplikaĵojn", "de": "%lld Apps verschieben", "ko": "%lld개 앱 이동", "tr": "%lld Uygulama Taşı",
        "vi": "Di chuyển %lld ứng dụng", "th": "ย้าย %lld แอป", "nl": "%lld apps verplaatsen", "pl": "Przenieś %lld aplikacji", "id": "Pindahkan %lld Aplikasi"
    },
    "链接 %lld 个应用": {
        "en": "Link %lld Apps", "zh-Hans": "链接 %lld 个应用", "zh-Hant": "連結 %lld 個應用程式",
        "hi": "%lld ऐप्स लिंक करें", "es": "Enlazar %lld apps", "ar": "ربط %lld تطبيقات", "ru": "Связать %lld приложений",
        "pt": "Vincular %lld apps", "fr": "Lier %lld apps", "it": "Collega %lld app", "ja": "%lld アプリをリンク",
        "eo": "Ligi %lld aplikaĵojn", "de": "%lld Apps verknüpfen", "ko": "%lld개 앱 연결", "tr": "%lld Uygulama Bağla",
        "vi": "Liên kết %lld ứng dụng", "th": "เชื่อมโยง %lld แอป", "nl": "%lld apps koppelen", "pl": "Połącz %lld aplikacji", "id": "Tautkan %lld Aplikasi"
    },
    "迁移回本地": {
        "en": "Move Back to Local", "zh-Hans": "迁移回本地", "zh-Hant": "遷移回本地",
        "hi": "स्थानीय में वापस ले जाएं", "es": "Mover de vuelta a local", "ar": "نقل إلى المحلي", "ru": "Вернуть в локальное",
        "pt": "Mover de volta ao local", "fr": "Déplacer vers local", "it": "Sposta di nuovo in locale", "ja": "ローカルに戻す",
        "eo": "Renigi al Loka", "de": "Zurück nach lokal verschieben", "ko": "로컬로 되돌리기", "tr": "Yerele Geri Taşı",
        "vi": "Di chuyển về cục bộ", "th": "ย้ายกลับไปในเครื่อง", "nl": "Terug naar lokaal verplaatsen", "pl": "Przenieś z powrotem na dysk lokalny", "id": "Pindahkan Kembali ke Lokal"
    },
    "部分迁移失败": {
        "en": "Some migrations failed", "zh-Hans": "部分迁移失败", "zh-Hant": "部分遷移失敗",
        "hi": "कुछ माइग्रेशन विफल", "es": "Algunas migraciones fallaron", "ar": "فشلت بعض عمليات النقل", "ru": "Некоторые миграции не удались",
        "pt": "Algumas migrações falharam", "fr": "Certaines migrations ont échoué", "it": "Alcune migrazioni non riuscite", "ja": "一部の移行に失敗しました",
        "eo": "Kelkaj migradoj malsukcesis", "de": "Einige Migrationen fehlgeschlagen", "ko": "일부 마이그레이션 실패", "tr": "Bazı taşımalar başarısız oldu",
        "vi": "Một số di chuyển thất bại", "th": "บางการย้ายล้มเหลว", "nl": "Sommige migraties mislukt", "pl": "Niektóre migracje nie powiodły się", "id": "Beberapa migrasi gagal"
    },
    "部分链接失败": {
        "en": "Some links failed", "zh-Hans": "部分链接失败", "zh-Hant": "部分連結失敗",
        "hi": "कुछ लिंक विफल", "es": "Algunos enlaces fallaron", "ar": "فشلت بعض الروابط", "ru": "Некоторые связи не удались",
        "pt": "Alguns links falharam", "fr": "Certains liens ont échoué", "it": "Alcuni collegamenti non riusciti", "ja": "一部のリンクに失敗しました",
        "eo": "Kelkaj ligoj malsukcesis", "de": "Einige Verknüpfungen fehlgeschlagen", "ko": "일부 연결 실패", "tr": "Bazı bağlantılar başarısız oldu",
        "vi": "Một số liên kết thất bại", "th": "บางการเชื่อมโยงล้มเหลว", "nl": "Sommige koppelingen mislukt", "pl": "Niektóre połączenia nie powiodły się", "id": "Beberapa tautan gagal"
    },
    "含系统应用": {
        "en": "Contains System App", "zh-Hans": "含系统应用", "zh-Hant": "含系統應用程式",
        "hi": "सिस्टम ऐप शामिल है", "es": "Contiene app del sistema", "ar": "يحتوي على تطبيق نظام", "ru": "Содержит системное приложение",
        "pt": "Contém app do sistema", "fr": "Contient app système", "it": "Contiene app di sistema", "ja": "システムアプリを含む",
        "eo": "Enhavas Sisteman Aplikaĵon", "de": "Enthält System-App", "ko": "시스템 앱 포함", "tr": "Sistem Uygulaması İçerir",
        "vi": "Chứa ứng dụng hệ thống", "th": "มีแอประบบ", "nl": "Bevat systeem-app", "pl": "Zawiera aplikację systemową", "id": "Berisi Aplikasi Sistem"
    },
    "含运行中应用": {
        "en": "Contains Running App", "zh-Hans": "含运行中应用", "zh-Hant": "含執行中應用程式",
        "hi": "चल रहा ऐप शामिल है", "es": "Contiene app en ejecución", "ar": "يحتوي على تطبيق قيد التشغيل", "ru": "Содержит работающее приложение",
        "pt": "Contém app em execução", "fr": "Contient app en cours", "it": "Contiene app in esecuzione", "ja": "実行中のアプリを含む",
        "eo": "Enhavas Funkcianta Aplikaĵon", "de": "Enthält laufende App", "ko": "실행 중인 앱 포함", "tr": "Çalışan Uygulama İçerir",
        "vi": "Chứa ứng dụng đang chạy", "th": "มีแอปที่กำลังทำงาน", "nl": "Bevat actieve app", "pl": "Zawiera działającą aplikację", "id": "Berisi Aplikasi yang Berjalan"
    },
    "App Store 应用": {
        "en": "App Store App", "zh-Hans": "App Store 应用", "zh-Hant": "App Store 應用程式",
        "hi": "App Store ऐप", "es": "App de App Store", "ar": "تطبيق متجر التطبيقات", "ru": "Приложение App Store",
        "pt": "App da App Store", "fr": "Application App Store", "it": "App dell'App Store", "ja": "App Store アプリ",
        "eo": "App Store Aplikaĵo", "de": "App Store App", "ko": "App Store 앱", "tr": "App Store Uygulaması",
        "vi": "Ứng dụng App Store", "th": "แอป App Store", "nl": "App Store-app", "pl": "Aplikacja App Store", "id": "Aplikasi App Store"
    },
    "继续迁移": {
        "en": "Continue Migration", "zh-Hans": "继续迁移", "zh-Hant": "繼續遷移",
        "hi": "माइग्रेशन जारी रखें", "es": "Continuar migración", "ar": "متابعة النقل", "ru": "Продолжить миграцию",
        "pt": "Continuar migração", "fr": "Continuer la migration", "it": "Continua migrazione", "ja": "移行を続ける",
        "eo": "Daŭrigu Migradon", "de": "Migration fortsetzen", "ko": "마이그레이션 계속", "tr": "Taşımaya Devam Et",
        "vi": "Tiếp tục di chuyển", "th": "ดำเนินการย้ายต่อ", "nl": "Migratie voortzetten", "pl": "Kontynuuj migrację", "id": "Lanjutkan Migrasi"
    },
    "取消": {
        "en": "Cancel", "zh-Hans": "取消", "zh-Hant": "取消",
        "hi": "रद्द करें", "es": "Cancelar", "ar": "إلغاء", "ru": "Отмена",
        "pt": "Cancelar", "fr": "Annuler", "it": "Annulla", "ja": "キャンセル",
        "eo": "Nuligi", "de": "Abbrechen", "ko": "취소", "tr": "İptal",
        "vi": "Hủy", "th": "ยกเลิก", "nl": "Annuleren", "pl": "Anuluj", "id": "Batal"
    },
    
    # --- New Strings (2026-02-02) Menu & Alerts ---
    
    "日志": {
        "en": "Logs", "zh-Hans": "日志", "zh-Hant": "日誌",
        "hi": "लॉग", "es": "Registros", "ar": "السجلات", "ru": "Журналы",
        "pt": "Logs", "fr": "Journaux", "it": "Log", "ja": "ログ",
        "eo": "Protokoloj", "de": "Protokolle", "ko": "로그", "tr": "Günlükler",
        "vi": "Nhật ký", "th": "บันทึก", "nl": "Logs", "pl": "Dzienniki", "id": "Log"
    },
    "在 Finder 中查看日志": {
        "en": "View Log in Finder", "zh-Hans": "在 Finder 中查看日志", "zh-Hant": "在 Finder 中查看日誌",
        "hi": "Finder में लॉग देखें", "es": "Ver registro en Finder", "ar": "عرض السجل في Finder", "ru": "Просмотреть журнал в Finder",
        "pt": "Ver log no Finder", "fr": "Voir le journal dans le Finder", "it": "Visualizza log nel Finder", "ja": "Finderでログを表示",
        "eo": "Vidi protokolon en Finder", "de": "Protokoll im Finder anzeigen", "ko": "Finder에서 로그 보기", "tr": "Finder'da Günlüğü Görüntüle",
        "vi": "Xem nhật ký trong Finder", "th": "ดูบันทึกใน Finder", "nl": "Log bekijken in Finder", "pl": "Zobacz dziennik w Finderze", "id": "Lihat Log di Finder"
    },
    "设置日志位置...": {
        "en": "Set Log Location...", "zh-Hans": "设置日志位置...", "zh-Hant": "設定日誌位置...",
        "hi": "लॉग स्थान सेट करें...", "es": "Establecer ubicación del registro...", "ar": "تعيين موقع السجل...", "ru": "Установить расположение журнала...",
        "pt": "Definir local do log...", "fr": "Définir l'emplacement du journal...", "it": "Imposta posizione log...", "ja": "ログの場所を設定...",
        "eo": "Agordi protokolan lokon...", "de": "Protokollspeicherort festlegen...", "ko": "로그 위치 설정...", "tr": "Günlük Konumunu Ayarla...",
        "vi": "Đặt vị trí nhật ký...", "th": "ตั้งค่าตำแหน่งบันทึก...", "nl": "Loglocatie instellen...", "pl": "Ustaw lokalizację dziennika...", "id": "Atur Lokasi Log..."
    },
    "选择日志保存位置": {
        "en": "Choose Log Location", "zh-Hans": "选择日志保存位置", "zh-Hant": "選擇日誌儲存位置",
        "hi": "लॉग स्थान चुनें", "es": "Elegir ubicación del registro", "ar": "اختر موقع السجل", "ru": "Выберите расположение журнала",
        "pt": "Escolher local do log", "fr": "Choisir l'emplacement du journal", "it": "Scegli posizione log", "ja": "ログの保存場所を選択",
        "eo": "Elektu protokolan lokon", "de": "Protokollspeicherort auswählen", "ko": "로그 위치 선택", "tr": "Günlük Konumunu Seç",
        "vi": "Chọn vị trí lưu nhật ký", "th": "เลือกตำแหน่งบันทึก", "nl": "Loglocatie kiezen", "pl": "Wybierz lokalizację dziennika", "id": "Pilih Lokasi Log"
    },
    "当前大小: %@": {
        "en": "Current Size: %@", "zh-Hans": "当前大小: %@", "zh-Hant": "目前大小: %@",
        "hi": "वर्तमान आकार: %@", "es": "Tamaño actual: %@", "ar": "الحجم الحالي: %@", "ru": "Текущий размер: %@",
        "pt": "Tamanho atual: %@", "fr": "Taille actuelle : %@", "it": "Dimensione attuale: %@", "ja": "現在のサイズ: %@",
        "eo": "Nuna grandeco: %@", "de": "Aktuelle Größe: %@", "ko": "현재 크기: %@", "tr": "Mevcut Boyut: %@",
        "vi": "Kích thước hiện tại: %@", "th": "ขนาดปัจจุบัน: %@", "nl": "Huidige grootte: %@", "pl": "Bieżący rozmiar: %@", "id": "Ukuran Saat Ini: %@"
    },
    "清空日志": {
        "en": "Clear Log", "zh-Hans": "清空日志", "zh-Hant": "清空日誌",
        "hi": "लॉग साफ़ करें", "es": "Borrar registro", "ar": "مسح السجل", "ru": "Очистить журнал",
        "pt": "Limpar log", "fr": "Effacer le journal", "it": "Cancella log", "ja": "ログを消去",
        "eo": "Viŝi protokolon", "de": "Protokoll löschen", "ko": "로그 지우기", "tr": "Günlüğü Temizle",
        "vi": "Xóa nhật ký", "th": "ล้างบันทึก", "nl": "Log wissen", "pl": "Wyczyść dziennik", "id": "Hapus Log"
    },
    "App Store App": {
        "en": "App Store App", "zh-Hans": "App Store 应用", "zh-Hant": "App Store 應用程式",
        "hi": "App Store ऐप", "es": "App de App Store", "ar": "تطبيق App Store", "ru": "Приложение App Store",
        "pt": "App da App Store", "fr": "Application App Store", "it": "App dell'App Store", "ja": "App Store アプリ",
        "eo": "App Store Aplikaĵo", "de": "App Store App", "ko": "App Store 앱", "tr": "App Store Uygulaması",
        "vi": "Ứng dụng App Store", "th": "แอป App Store", "nl": "App Store-app", "pl": "Aplikacja App Store", "id": "Aplikasi App Store"
    },
    "Continue Migration": {
        "en": "Continue Migration", "zh-Hans": "继续迁移", "zh-Hant": "繼續遷移",
        "hi": "माइग्रेशन जारी रखें", "es": "Continuar migración", "ar": "متابعة النقل", "ru": "Продолжить миграцию",
        "pt": "Continuar migração", "fr": "Continuer la migration", "it": "Continua migrazione", "ja": "移行を続ける",
        "eo": "Daŭrigu Migradon", "de": "Migration fortsetzen", "ko": "마이그레이션 계속", "tr": "Taşımaya Devam Et",
        "vi": "Tiếp tục di chuyển", "th": "ดำเนินการย้ายต่อ", "nl": "Migratie voortzetten", "pl": "Kontynuuj migrację", "id": "Lanjutkan Migrasi"
    },
    "Cancel": {
        "en": "Cancel", "zh-Hans": "取消", "zh-Hant": "取消",
        "hi": "रद्द करें", "es": "Cancelar", "ar": "إلغاء", "ru": "Отмена",
        "pt": "Cancelar", "fr": "Annuler", "it": "Annulla", "ja": "キャンセル",
        "eo": "Nuligi", "de": "Abbrechen", "ko": "취소", "tr": "İptal",
        "vi": "Hủy", "th": "ยกเลิก", "nl": "Annuleren", "pl": "Anuluj", "id": "Batal"
    },
    "Link Back to Local": {
        "en": "Link Back to Local", "zh-Hans": "链接回本地", "zh-Hant": "連結回本地",
        "hi": "स्थानीय से लिंक करें", "es": "Enlazar de nuevo a local", "ar": "الرابط العودة إلى المحلي", "ru": "Связать обратно с локальным",
        "pt": "Vincular de volta ao local", "fr": "Lier à nouveau au local", "it": "Collega di nuovo al locale", "ja": "ローカルにリンクし直す",
        "eo": "Ligi reen al Loka", "de": "Zurück zu Lokal verknüpfen", "ko": "로컬로 다시 연결", "tr": "Yerele Geri Bağla",
        "vi": "Liên kết lại cục bộ", "th": "เชื่อมโยงกลับไปที่เครื่อง", "nl": "Link terug naar lokaal", "pl": "Połącz z powrotem z lokalnym", "id": "Tautkan Kembali ke Lokal"
    },
    "Move Back to Local": {
        "en": "Move Back to Local", "zh-Hans": "迁移回本地", "zh-Hant": "遷移回本地",
        "hi": "स्थानीय में वापस ले जाएं", "es": "Mover de vuelta a local", "ar": "نقل إلى المحلي", "ru": "Вернуть в локальное",
        "pt": "Mover de volta ao local", "fr": "Déplacer vers local", "it": "Sposta di nuovo in locale", "ja": "ローカルに戻す",
        "eo": "Renigi al Loka", "de": "Zurück nach lokal verschieben", "ko": "로컬로 되돌리기", "tr": "Yerele Geri Taşı",
        "vi": "Di chuyển về cục bộ", "th": "ย้ายกลับไปในเครื่อง", "nl": "Terug naar lokaal verplaatsen", "pl": "Przenieś z powrotem na dysk lokalny", "id": "Pindahkan Kembali ke Lokal"
    },
    "Link %lld Apps": {
        "en": "Link %lld Apps", "zh-Hans": "链接 %lld 个应用", "zh-Hant": "連結 %lld 個應用程式",
        "hi": "%lld ऐप्स लिंक करें", "es": "Enlazar %lld apps", "ar": "ربط %lld تطبيقات", "ru": "Связать %lld приложений",
        "pt": "Vincular %lld apps", "fr": "Lier %lld apps", "it": "Collega %lld app", "ja": "%lld アプリをリンク",
        "eo": "Ligi %lld aplikaĵojn", "de": "%lld Apps verknüpfen", "ko": "%lld개 앱 연결", "tr": "%lld Uygulama Bağla",
        "vi": "Liên kết %lld ứng dụng", "th": "เชื่อมโยง %lld แอป", "nl": "%lld apps koppelen", "pl": "Połącz %lld aplikacji", "id": "Tautkan %lld Aplikasi"
    },
    
    # --- New Strings (2026-02-06) Settings & Status ---
    
    "Auto": {
        "en": "Auto", "zh-Hans": "自动", "zh-Hant": "自動",
        "hi": "स्वचालित", "es": "Automático", "ar": "تلقائي", "ru": "Авто",
        "pt": "Automático", "fr": "Auto", "it": "Auto", "ja": "自動",
        "eo": "Aŭtomata", "de": "Auto", "ko": "자동", "tr": "Otomatik",
        "vi": "Tự động", "th": "อัตโนมัติ", "nl": "Auto", "pl": "Auto", "id": "Otomatis"
    },
    "设置": {
        "en": "Settings", "zh-Hans": "设置", "zh-Hant": "設定",
        "hi": "सेटिंग्स", "es": "Configuración", "ar": "الإعدادات", "ru": "Настройки",
        "pt": "Configurações", "fr": "Paramètres", "it": "Impostazioni", "ja": "設定",
        "eo": "Agordoj", "de": "Einstellungen", "ko": "설정", "tr": "Ayarlar",
        "vi": "Cài đặt", "th": "การตั้งค่า", "nl": "Instellingen", "pl": "Ustawienia", "id": "Pengaturan"
    },
    "默认情况下，来自 App Store 的应用不允许迁移，因为迁移后将无法通过 App Store 更新。": {
        "en": "By default, App Store apps are not allowed to migrate because they cannot be updated via App Store after migration.",
        "zh-Hans": "默认情况下，来自 App Store 的应用不允许迁移，因为迁移后将无法通过 App Store 更新。",
        "zh-Hant": "預設情況下，來自 App Store 的應用程式不允許遷移，因為遷移後將無法透過 App Store 更新。",
        "hi": "डिफ़ॉल्ट रूप से, ऐप स्टोर ऐप्स को माइग्रेट करने की अनुमति नहीं है क्योंकि माइग्रेशन के बाद उन्हें ऐप स्टोर के माध्यम से अपडेट नहीं किया जा सकता है।",
        "es": "Por defecto, no se permite migrar apps de App Store porque no se pueden actualizar tras la migración.",
        "ar": "افتراضيًا، لا يُسمح بترحيل تطبيقات App Store لأنه لا يمكن تحديثها عبر App Store بعد الترحيل.",
        "ru": "По умолчанию миграция приложений App Store запрещена, так как они не обновляются через App Store после переноса.",
        "pt": "Por padrão, apps da App Store não podem ser migrados pois não atualizam via App Store após migração.",
        "fr": "Par défaut, la migration des apps App Store est interdite car elles ne peuvent plus être mises à jour via l'App Store après.",
        "it": "Per impostazione predefinita, le app dell'App Store non possono essere migrate perché non aggiornabili dopo la migrazione.",
        "ja": "デフォルトでは、App Storeアプリの移行は許可されていません。移行後はApp Store経由で更新できなくなるためです。",
        "eo": "Defaŭlte, App Store-aplikaĵoj ne rajtas migri ĉar ili ne povas esti ĝisdatigitaj per App Store post migrado.",
        "de": "Standardmäßig dürfen App Store-Apps nicht migriert werden, da sie nach der Migration nicht mehr über den App Store aktualisiert werden können.",
        "ko": "기본적으로 App Store 앱은 마이그레이션 후 App Store를 통해 업데이트할 수 없으므로 마이그레이션이 허용되지 않습니다.",
        "tr": "Varsayılan olarak, App Store uygulamalarının taşınmasına izin verilmez çünkü taşındıktan sonra App Store üzerinden güncellenemezler.",
        "vi": "Theo mặc định, ứng dụng App Store không được phép di chuyển vì chúng không thể cập nhật qua App Store sau khi di chuyển.",
        "th": "ตามค่าเริ่มต้น แอป App Store จะไม่ได้รับอนุญาตให้ย้ายเนื่องจากไม่สามารถอัปเดตผ่าน App Store ได้หลังจากย้าย",
        "nl": "Standaard mogen App Store-apps niet worden gemigreerd omdat ze na migratie niet meer via de App Store kunnen worden bijgewerkt.",
        "pl": "Domyślnie aplikacje z App Store nie mogą być migrowane, ponieważ po migracji nie można ich aktualizować przez App Store.",
        "id": "Secara default, aplikasi App Store tidak diizinkan untuk migrasi karena tidak dapat diperbarui melalui App Store setelah migrasi."
    },
    "允许迁移 Mac App Store 应用": {
        "en": "Allow Mac App Store App Migration",
        "zh-Hans": "允许迁移 Mac App Store 应用",
        "zh-Hant": "允許遷移 Mac App Store 應用程式",
        "hi": "मैक ऐप स्टोर ऐप माइग्रेशन की अनुमति दें",
        "es": "Permitir migración de apps de Mac App Store",
        "ar": "السماح بترحيل تطبيقات Mac App Store",
        "ru": "Разрешить миграцию приложений Mac App Store",
        "pt": "Permitir migração de apps da Mac App Store",
        "fr": "Autoriser la migration des apps Mac App Store",
        "it": "Consenti migrazione app Mac App Store",
        "ja": "Mac App Storeアプリの移行を許可",
        "eo": "Permesi Migradon de Mac App Store Aplikaĵoj",
        "de": "Migration von Mac App Store-Apps erlauben",
        "ko": "Mac App Store 앱 마이그레이션 허용",
        "tr": "Mac App Store Uygulama Taşımasına İzin Ver",
        "vi": "Cho phép di chuyển ứng dụng Mac App Store",
        "th": "อนุญาตให้ย้ายแอป Mac App Store",
        "nl": "Migratie van Mac App Store-apps toestaan",
        "pl": "Zezwalaj na migrację aplikacji Mac App Store",
        "id": "Izinkan Migrasi Aplikasi Mac App Store"
    },
    "启用后可以迁移来自 Mac App Store 的原生 Mac 应用": {
        "en": "Enable to migrate native Mac apps from Mac App Store",
        "zh-Hans": "启用后可以迁移来自 Mac App Store 的原生 Mac 应用",
        "zh-Hant": "啟用後可以遷移來自 Mac App Store 的原生 Mac 應用程式",
        "hi": "मैक ऐप स्टोर से मूल मैक ऐप्स को माइग्रेट करने के लिए सक्षम करें",
        "es": "Habilite para migrar apps nativas de Mac desde Mac App Store",
        "ar": "قم بالتمكين لترحيل تطبيقات Mac الأصلية من Mac App Store",
        "ru": "Включите для миграции нативных приложений Mac из Mac App Store",
        "pt": "Ative para migrar apps nativos do Mac da Mac App Store",
        "fr": "Activez pour migrer les apps Mac natives du Mac App Store",
        "it": "Abilita per migrare app Mac native dal Mac App Store",
        "ja": "有効にすると、Mac App StoreからネイティブMacアプリを移行できます",
        "eo": "Ebligu por migri denaskajn Mac-aplikaĵojn de Mac App Store",
        "de": "Aktivieren, um native Mac-Apps aus dem Mac App Store zu migrieren",
        "ko": "Mac App Store에서 기본 Mac 앱을 마이그레이션하려면 활성화하세요",
        "tr": "Mac App Store'dan yerel Mac uygulamalarını taşımak için etkinleştirin",
        "vi": "Bật để di chuyển ứng dụng Mac gốc từ Mac App Store",
        "th": "เปิดใช้งานเพื่อย้ายแอป Mac ดั้งเดิมจาก Mac App Store",
        "nl": "Schakel in om native Mac-apps van Mac App Store te migreren",
        "pl": "Włącz, aby migrować natywne aplikacje Mac z Mac App Store",
        "id": "Aktifkan untuk memigrasikan aplikasi Mac asli dari Mac App Store"
    },
    "迁移后的 App Store 应用将无法自动更新，需要手动还原后才能更新": {
        "en": "Migrated App Store apps cannot auto-update. Restore manually to update.",
        "zh-Hans": "迁移后的 App Store 应用将无法自动更新，需要手动还原后才能更新",
        "zh-Hant": "遷移後的 App Store 應用程式將無法自動更新，需要手動還原後才能更新",
        "hi": "माइग्रेटेड ऐप स्टोर ऐप्स ऑटो-अपडेट नहीं हो सकते। अपडेट करने के लिए मैन्युअल रूप से पुनर्स्थापित करें।",
        "es": "Las apps migradas no se actualizan automáticamente. Restaure manualmente para actualizar.",
        "ar": "لا يمكن تحديث التطبيقات المنقولة تلقائيًا. استعد يدويًا للتحديث.",
        "ru": "Мигрированные приложения не обновляются автом. Восстановите вручную для обновления.",
        "pt": "Apps migrados não atualizam automaticamente. Restaure manualmente para atualizar.",
        "fr": "Les apps migrées ne se mettent pas à jour auto. Restaurez manuellement pour mettre à jour.",
        "it": "Le app migrate non si aggiornano automaticamente. Ripristina manualmente per aggiornare.",
        "ja": "移行したアプリは自動更新されません。更新するには手動で復元してください。",
        "eo": "Migritaj aplikaĵoj ne aŭtomate ĝisdatigas. Restarigu mane por ĝisdatigi.",
        "de": "Migrierte Apps werden nicht automatisch aktualisiert. Zum Aktualisieren manuell wiederherstellen.",
        "ko": "마이그레이션된 앱은 자동 업데이트되지 않습니다. 업데이트하려면 수동으로 복원하세요.",
        "tr": "Taşınan uygulamalar otomatik güncellenmez. Güncellemek için manuel olarak geri yükleyin.",
        "vi": "Ứng dụng đã di chuyển không tự cập nhật. Khôi phục thủ công để cập nhật.",
        "th": "แอปที่ย้ายแล้วจะไม่อัปเดตอัตโนมัติ กู้คืนด้วยตนเองเพื่ออัปเดต",
        "nl": "Gemigreerde apps updaten niet automatisch. Herstel handmatig om te updaten.",
        "pl": "Migrowane aplikacje nie aktualizują się automatycznie. Przywróć ręcznie, aby zaktualizować.",
        "id": "Aplikasi yang dimigrasikan tidak dapat diperbarui otomatis. Pulihkan secara manual untuk memperbarui."
    },
    "允许迁移非原生应用": {
        "en": "Allow Non-Native App Migration",
        "zh-Hans": "允许迁移非原生应用",
        "zh-Hant": "允許遷移非原生應用程式",
        "hi": "गैर-मूल ऐप माइग्रेशन की अनुमति दें",
        "es": "Permitir migración de apps no nativas",
        "ar": "السماح بترحيل التطبيقات غير الأصلية",
        "ru": "Разрешить миграцию не нативных приложений",
        "pt": "Permitir migração de apps não nativos",
        "fr": "Autoriser la migration d'apps non natives",
        "it": "Consenti migrazione app non native",
        "ja": "非ネイティブアプリの移行を許可",
        "eo": "Permesi Migradon de Ne-Denaskaj Aplikaĵoj",
        "de": "Migration von nicht-nativen Apps erlauben",
        "ko": "비기본 앱 마이그레이션 허용",
        "tr": "Yerel Olmayan Uygulama Taşımasına İzin Ver",
        "vi": "Cho phép di chuyển ứng dụng không phải gốc",
        "th": "อนุญาตให้ย้ายแอปที่ไม่ใช่แอปดั้งเดิม",
        "nl": "Migratie van niet-native apps toestaan",
        "pl": "Zezwalaj na migrację aplikacji nienatywnych",
        "id": "Izinkan Migrasi Aplikasi Non-Nativa"
    },
    "启用后可以迁移来自 iPhone/iPad 的非原生 Mac 应用（使用整体链接）": {
        "en": "Enable to migrate iPhone/iPad apps (using seamless linking)",
        "zh-Hans": "启用后可以迁移来自 iPhone/iPad 的非原生 Mac 应用（使用整体链接）",
        "zh-Hant": "啟用後可以遷移來自 iPhone/iPad 的非原生 Mac 應用程式（使用整體連結）",
        "hi": "iPhone/iPad ऐप्स को माइग्रेट करने के लिए सक्षम करें (सीमलेस लिंकिंग का उपयोग करके)",
        "es": "Habilite para migrar apps de iPhone/iPad (usando enlace perfecto)",
        "ar": "قم بالتمكين لترحيل تطبيقات iPhone/iPad (باستخدام الربط السلس)",
        "ru": "Включите для миграции приложений iPhone/iPad (с использованием бесшовной связи)",
        "pt": "Ative para migrar apps de iPhone/iPad (usando vinculação perfeita)",
        "fr": "Activez pour migrer les apps iPhone/iPad (liaison transparente)",
        "it": "Abilita per migrare app iPhone/iPad (collegamento continuo)",
        "ja": "有効にすると、iPhone/iPadアプリを移行できます（シームレスリンクを使用）",
        "eo": "Ebligu por migri iPhone/iPad-aplikaĵojn (uzante senjuntan ligadon)",
        "de": "Aktivieren, um iPhone/iPad-Apps zu migrieren (mit nahtloser Verknüpfung)",
        "ko": "iPhone/iPad 앱을 마이그레이션하려면 활성화하세요 (원활한 연결 사용)",
        "tr": "iPhone/iPad uygulamalarını taşımak için etkinleştirin (kesintisiz bağlantı kullanarak)",
        "vi": "Bật để di chuyển ứng dụng iPhone/iPad (sử dụng liên kết liền mạch)",
        "th": "เปิดใช้งานเพื่อย้ายแอป iPhone/iPad (ใช้การเชื่อมโยงที่ราบรื่น)",
        "nl": "Schakel in om iPhone/iPad-apps te migreren (met naadloze koppeling)",
        "pl": "Włącz, aby migrować aplikacje iPhone/iPad (używając płynnego łączenia)",
        "id": "Aktifkan untuk memigrasikan aplikasi iPhone/iPad (menggunakan penautan mulus)"
    },
    "由于 iOS 应用结构限制，迁移后 Finder 图标会显示箭头（macOS 系统行为）": {
        "en": "Due to iOS app structure, Finder icon will show an arrow after migration (macOS system behavior).",
        "zh-Hans": "由于 iOS 应用结构限制，迁移后 Finder 图标会显示箭头（macOS 系统行为）",
        "zh-Hant": "由於 iOS 應用程式結構限制，遷移後 Finder 圖示會顯示箭頭（macOS 系統行為）",
        "hi": "iOS ऐप संरचना के कारण, माइग्रेशन के बाद फाइंडर आइकन एक तीर दिखाएगा (macOS सिस्टम व्यवहार)।",
        "es": "Debido a la estructura de la app iOS, el icono del Finder mostrará una flecha (comportamiento del sistema macOS).",
        "ar": "بسبب هيكل تطبيق iOS، سيظهر رمز Finder سهمًا بعد الترحيل (سلوك نظام macOS).",
        "ru": "Из-за структуры приложения iOS значок Finder будет показывать стрелку (системное поведение macOS).",
        "pt": "Devido à estrutura do app iOS, o ícone do Finder mostrará uma seta (comportamento do sistema macOS).",
        "fr": "En raison de la structure de l'app iOS, l'icône du Finder affichera une flèche (comportement système macOS).",
        "it": "A causa della struttura dell'app iOS, l'icona del Finder mostrerà una freccia (comportamento di sistema macOS).",
        "ja": "iOSアプリの構造上、移行後のFinderアイコンには矢印が表示されます（macOSの仕様）。",
        "eo": "Pro strukturo de iOS-aplikaĵo, Finder-ikono montros sagon post migrado (sisteme konduto de macOS).",
        "de": "Aufgrund der iOS-App-Struktur zeigt das Finder-Symbol nach der Migration einen Pfeil (macOS-Systemverhalten).",
        "ko": "iOS 앱 구조로 인해 마이그레이션 후 Finder 아이콘에 화살표가 표시됩니다(macOS 시스템 동작).",
        "tr": "iOS uygulama yapısı nedeniyle, Finder simgesi taşıma işleminden sonra bir ok gösterecektir (macOS sistem davranışı).",
        "vi": "Do cấu trúc ứng dụng iOS, biểu tượng Finder sẽ hiển thị mũi tên sau khi di chuyển (hành vi hệ thống macOS).",
        "th": "เนื่องจากโครงสร้างแอป iOS ไอคอน Finder จะแสดงลูกศรหลังจากย้าย (พฤติกรรมของระบบ macOS)",
        "nl": "Vanwege de structuur van iOS-apps toont het Finder-pictogram een pijl na migratie (macOS-systeemgedrag).",
        "pl": "Ze względu na strukturę aplikacji iOS, ikona Findera pokaże strzałkę po migracji (zachowanie systemu macOS).",
        "id": "Karena struktur aplikasi iOS, ikon Finder akan menampilkan panah setelah migrasi (perilaku sistem macOS)."
    },
    "管理应用运行日志和诊断信息": {
        "en": "Manage app logs and diagnostics.",
        "zh-Hans": "管理应用运行日志和诊断信息",
        "zh-Hant": "管理應用程式執行日誌和診斷資訊",
        "hi": "ऐप लॉग और निदान प्रबंधित करें।",
        "es": "Administrar registros y diagnósticos de la app.",
        "ar": "إدارة سجلات التطبيق والتشخيصات.",
        "ru": "Управление журналами и диагностикой.",
        "pt": "Gerenciar logs e diagnósticos do app.",
        "fr": "Gérer les journaux et diagnostics de l'app.",
        "it": "Gestisci log e diagnostica dell'app.",
        "ja": "アプリのログと診断情報を管理します。",
        "eo": "Administri aplikaĵajn protokolojn kaj diagnozojn.",
        "de": "App-Protokolle und Diagnosen verwalten.",
        "ko": "앱 로그 및 진단을 관리합니다.",
        "tr": "Uygulama günlüklerini ve tanılamayı yönetin.",
        "vi": "Quản lý nhật ký và chẩn đoán ứng dụng.",
        "th": "จัดการบันทึกและการวินิจฉัยแอป",
        "nl": "Beheer app-logs en diagnostiek.",
        "pl": "Zarządzaj dziennikami i diagnostyką aplikacji.",
        "id": "Kelola log dan diagnostik aplikasi."
    },

    "日志设置": {
        "en": "Log Settings", "zh-Hans": "日志设置", "zh-Hant": "日誌設定",
        "hi": "लॉग सेटिंग्स", "es": "Configuración de registro", "ar": "إعدادات السجل", "ru": "Настройки журнала",
        "pt": "Configurações de Log", "fr": "Paramètres du journal", "it": "Impostazioni log", "ja": "ログ設定",
        "eo": "Protokolaj Agordoj", "de": "Protokolleinstellungen", "ko": "로그 설정", "tr": "Günlük Ayarları",
        "vi": "Cài đặt nhật ký", "th": "การตั้งค่าบันทึก", "nl": "Loginstellingen", "pl": "Ustawienia dziennika", "id": "Pengaturan Log"
    },
    "启用日志记录": {
        "en": "Enable Logging", "zh-Hans": "启用日志记录", "zh-Hant": "啟用日誌記錄",
        "hi": "लॉगिंग सक्षम करें", "es": "Habilitar registro", "ar": "تمكين التسجيل", "ru": "Включить журналирование",
        "pt": "Habilitar Log", "fr": "Activer la journalisation", "it": "Abilita registrazione", "ja": "ログ記録を有効にする",
        "eo": "Ebligi Protokoladon", "de": "Protokollierung aktivieren", "ko": "로깅 활성화", "tr": "Günlüğe Kaydetmeyi Etkinleştir",
        "vi": "Bật ghi nhật ký", "th": "เปิดใช้งานการบันทึก", "nl": "Loggen inschakelen", "pl": "Włącz logowanie", "id": "Aktifkan Pencatatan"
    },
    "最大日志大小": {
        "en": "Max Log Size", "zh-Hans": "最大日志大小", "zh-Hant": "最大日誌大小",
        "hi": "अधिकतम लॉग आकार", "es": "Tamaño máx. de registro", "ar": "أقصى حجم للسجل", "ru": "Макс. размер журнала",
        "pt": "Tamanho máx. do log", "fr": "Taille max du journal", "it": "Dim. max log", "ja": "最大ログサイズ",
        "eo": "Maksimuma Protokola Grandeco", "de": "Max. Protokollgröße", "ko": "최대 로그 크기", "tr": "Maks. Günlük Boyutu",
        "vi": "Kích thước nhật ký tối đa", "th": "ขนาดบันทึกสูงสุด", "nl": "Max. loggrootte", "pl": "Maks. rozmiar dziennika", "id": "Ukuran Log Maks"
    },
    "在 Finder 中查看": {
        "en": "View in Finder", "zh-Hans": "在 Finder 中查看", "zh-Hant": "在 Finder 中查看",
        "hi": "Finder में देखें", "es": "Ver en Finder", "ar": "عرض في Finder", "ru": "Посмотреть в Finder",
        "pt": "Ver no Finder", "fr": "Voir dans le Finder", "it": "Vedi nel Finder", "ja": "Finderで表示",
        "eo": "Vidi en Finder", "de": "Im Finder anzeigen", "ko": "Finder에서 보기", "tr": "Finder'da Görüntüle",
        "vi": "Xem trong Finder", "th": "ดูใน Finder", "nl": "Bekijk in Finder", "pl": "Zobacz w Finderze", "id": "Lihat di Finder"
    },
    "更改设置后，请刷新应用列表以查看效果": {
        "en": "Please refresh the app list after changing settings.",
        "zh-Hans": "更改设置后，请刷新应用列表以查看效果",
        "zh-Hant": "更改設定後，請重新整理應用程式列表以查看效果",
        "hi": "सेटिंग्स बदलने के बाद कृपया ऐप सूची को ताज़ा करें।",
        "es": "Actualice la lista de apps después de cambiar la configuración.",
        "ar": "يرجى تحديث قائمة التطبيقات بعد تغيير الإعدادات.",
        "ru": "Пожалуйста, обновите список приложений после изменения настроек.",
        "pt": "Atualize a lista de apps após alterar as configurações.",
        "fr": "Veuillez actualiser la liste des apps après avoir modifié les paramètres.",
        "it": "Aggiorna l'elenco delle app dopo aver modificato le impostazioni.",
        "ja": "設定変更後、アプリリストを更新してください。",
        "eo": "Bonvolu refreŝigi la aplikaĵan liston post ŝanĝo de agordoj.",
        "de": "Bitte aktualisieren Sie die App-Liste nach Änderung der Einstellungen.",
        "ko": "설정을 변경한 후 앱 목록을 새로 고치십시오.",
        "tr": "Ayarları değiştirdikten sonra lütfen uygulama listesini yenileyin.",
        "vi": "Vui lòng làm mới danh sách ứng dụng sau khi thay đổi cài đặt.",
        "th": "โปรดรีเฟรชรายการแอปหลังจากเปลี่ยนการตั้งค่า",
        "nl": "Vernieuw de app-lijst na het wijzigen van instellingen.",
        "pl": "Odśwież listę aplikacji po zmianie ustawień.",
        "id": "Harap segarkan daftar aplikasi setelah mengubah pengaturan."
    },
    "部分链接": {
        "en": "Partially Linked", "zh-Hans": "部分链接", "zh-Hant": "部分連結",
        "hi": "आंशिक रूप से लिंक किया गया", "es": "Parcialmente enlazado", "ar": "مرتبط جزئيا", "ru": "Частично связано",
        "pt": "Parcialmente vinculado", "fr": "Partiellement lié", "it": "Parzialmente collegato", "ja": "部分的にリンク",
        "eo": "Parte Ligita", "de": "Teilweise verknüpft", "ko": "부분적으로 연결됨", "tr": "Kısmen Bağlı",
        "vi": "Liên kết một phần", "th": "เชื่อมโยงบางส่วน", "nl": "Gedeeltelijk gekoppeld", "pl": "Częściowo połączone", "id": "Tautan Sebagian"
    },
    "非原生": {
        "en": "Non-Native", "zh-Hans": "非原生", "zh-Hant": "非原生",
        "hi": "गैर-मूल", "es": "No nativo", "ar": "غير أصلي", "ru": "Не нативный",
        "pt": "Não nativo", "fr": "Non natif", "it": "Non nativo", "ja": "非ネイティブ",
        "eo": "Ne-Denaska", "de": "Nicht-nativ", "ko": "비기본", "tr": "Yerel Olmayan",
        "vi": "Không phải gốc", "th": "ไม่ใช่แอปดั้งเดิม", "nl": "Niet-native", "pl": "Nienatywny", "id": "Non-Nativa"
    },
    "商店": {
        "en": "Store", "zh-Hans": "商店", "zh-Hant": "商店",
        "hi": "स्टोर", "es": "Tienda", "ar": "متجر", "ru": "Магазин",
        "pt": "Loja", "fr": "Store", "it": "Store", "ja": "ストア",
        "eo": "Vendejo", "de": "Store", "ko": "스토어", "tr": "Mağaza",
        "vi": "Cửa hàng", "th": "ร้านค้า", "nl": "Store", "pl": "Sklep", "id": "Toko"
    },
    "选中的 %lld 个应用均来自 App Store，迁移时会使用 Finder 删除，您会听到垃圾桶的声音。\n\n这是正常的，应用会被安全地移动到外部存储。": {
        "en": "All %lld selected apps are from App Store. They will be deleted via Finder during migration (you'll hear a trash sound).\n\nThis is normal, apps are safely moved to external drive.",
        "zh-Hans": "选中的 %lld 个应用均来自 App Store，迁移时会使用 Finder 删除，您会听到垃圾桶的声音。\n\n这是正常的，应用会被安全地移动到外部存储。",
        "zh-Hant": "選中的 %lld 個應用程式均來自 App Store，遷移時會使用 Finder 刪除，您會聽到垃圾桶的聲音。\n\n這是正常的，應用程式會被安全地移動到外部儲存。",
        "hi": "सभी %lld चयनित ऐप्स ऐप स्टोर से हैं। माइग्रेशन के दौरान उन्हें फाइंडर के माध्यम से हटा दिया जाएगा (आपको कचरे की आवाज़ सुनाई देगी)।\n\nयह सामान्य है, ऐप्स सुरक्षित रूप से बाहरी ड्राइव में ले जाए जाते हैं।",
        "es": "Las %lld apps seleccionadas son de App Store. Se eliminarán mediante Finder durante la migración (oirá un sonido de papelera).\n\nEsto es normal, las apps se mueven de forma segura.",
        "ar": "جميع التطبيقات المحددة البالغ عددها %lld هي من App Store. سيتم حذفها عبر Finder أثناء الترحيل (ستسمع صوت سلة المهملات).\n\nهذا طبيعي، يتم نقل التطبيقات بأمان.",
        "ru": "Все %lld выбранных приложений из App Store. Они будут удалены через Finder (вы услышите звук корзины).\n\nЭто нормально, приложения перемещаются на внешний диск.",
        "pt": "Todos os %lld apps selecionados são da App Store. Serão excluídos via Finder durante a migração (som de lixo).\n\nIsso é normal, apps são movidos com segurança.",
        "fr": "Les %lld apps sélectionnées proviennent de l'App Store. Elles seront supprimées via le Finder (son de corbeille).\n\nC'est normal, les apps sont déplacées en toute sécurité.",
        "it": "Tutte le %lld app selezionate provengono dall'App Store. Verranno eliminate tramite Finder (sentirai un suono).\n\nÈ normale, le app vengono spostate in sicurezza.",
        "ja": "選択された %lld 個のアプリはすべてApp Storeからのものです。移行中にFinder経由で削除されます（ゴミ箱の音がします）。\n\nこれは正常であり、アプリは安全に外部ドライブに移動されます。",
        "eo": "Ĉiuj %lld elektitaj aplikaĵoj estas de App Store. Ili estos forigitaj per Finder dum migrado (vi aŭdos rubsonon).\n\nĈi tio estas normala, aplikaĵoj estas sekure movitaj.",
        "de": "Alle %lld ausgewählten Apps stammen aus dem App Store. Sie werden während der Migration über den Finder gelöscht (Papierkorb-Geräusch).\n\nDas ist normal, Apps werden sicher verschoben.",
        "ko": "선택된 %lld개 앱 모두 App Store 앱입니다. 마이그레이션 중 Finder를 통해 삭제됩니다(휴지통 소리가 들림).\n\n이는 정상이며 앱은 안전하게 이동됩니다.",
        "tr": "Seçilen %lld uygulamanın tümü App Store'dandır. Taşıma sırasında Finder aracılığıyla silineceklerdir (çöp kutusu sesi duyacaksınız).\n\nBu normaldir.",
        "vi": "Tất cả %lld ứng dụng đã chọn đều từ App Store. Chúng sẽ bị xóa qua Finder trong quá trình di chuyển (bạn sẽ nghe thấy tiếng rác).\n\nĐiều này là bình thường.",
        "th": "แอปที่เลือกทั้งหมด %lld แอปมาจาก App Store จะถูกลบผ่าน Finder ระหว่างการย้าย (คุณจะได้ยินเสียงถังขยะ)\n\nนี่เป็นเรื่องปกติ แอปจะถูกย้ายอย่างปลอดภัย",
        "nl": "Alle %lld geselecteerde apps komen uit de App Store. Ze worden verwijderd via Finder tijdens migratie (u hoort een prullenbakgeluid).\n\nDit is normaal.",
        "pl": "Wszystkie wybrane aplikacje (%lld) pochodzą z App Store. Zostaną usunięte przez Finder podczas migracji (usłyszysz dźwięk kosza).\n\nTo normalne.",
        "id": "Semua %lld aplikasi yang dipilih berasal dari App Store. Mereka akan dihapus melalui Finder selama migrasi (Anda akan mendengar suara sampah).\n\nIni normal."
    },
    "选中的 %lld 个应用包含 %lld 个 App Store 应用，迁移时会使用 Finder 删除，您会听到垃圾桶的声音。\n\n这是正常的，应用会被安全地移动到外部存储。": {
        "en": "Selected %lld apps include %lld App Store apps. They will be deleted via Finder (trash sound).\n\nThis is normal, apps are safely moved.",
        "zh-Hans": "选中的 %lld 个应用包含 %lld 个 App Store 应用，迁移时会使用 Finder 删除，您会听到垃圾桶的声音。\n\n这是正常的，应用会被安全地移动到外部存储。",
        "zh-Hant": "選中的 %lld 個應用程式包含 %lld 個 App Store 應用程式，遷移時會使用 Finder 刪除，您會聽到垃圾桶的聲音。\n\n這是正常的，應用程式會被安全地移動到外部儲存。",
        "hi": "चयनित %lld ऐप्स में %lld ऐप स्टोर ऐप्स शामिल हैं। उन्हें फाइंडर (कचरा ध्वनि) के माध्यम से हटा दिया जाएगा।\n\nयह सामान्य है, ऐप्स सुरक्षित रूप से स्थानांतरित हो जाते हैं।",
        "es": "Las %lld apps seleccionadas incluyen %lld de App Store. Se eliminarán vía Finder (sonido papelera).\n\nEs normal, se mueven con seguridad.",
        "ar": "تتضمن التطبيقات المحددة %lld تطبيقًا %lld من App Store. سيتم حذفها عبر Finder (صوت سلة المهملات).\n\nهذا طبيعي.",
        "ru": "Выбрано %lld приложений, включая %lld из App Store. Они будут удалены через Finder.\n\nЭто нормальный процесс.",
        "pt": "Os %lld apps selecionados incluem %lld da App Store. Serão excluídos via Finder.\n\nIsso é normal.",
        "fr": "Les %lld apps sélectionnées incluent %lld apps App Store. Elles seront supprimées via Finder.\n\nC'est normal.",
        "it": "Le %lld app selezionate includono %lld app App Store. Verranno eliminate tramite Finder.\n\nÈ normale.",
        "ja": "選択された %lld 個のアプリには %lld 個のApp Storeアプリが含まれています。Finder経由で削除されます（ゴミ箱の音）。\n\nこれは正常です。",
        "eo": "Elektitaj %lld aplikaĵoj inkluzivas %lld App Store-aplikaĵojn. Ili estos forigitaj per Finder.\n\nĈi tio estas normala.",
        "de": "Ausgewählte %lld Apps enthalten %lld App Store-Apps. Sie werden über den Finder gelöscht.\n\nDas ist normal.",
        "ko": "선택된 %lld개 앱에 %lld개의 App Store 앱이 포함되어 있습니다. Finder를 통해 삭제됩니다.\n\n이는 정상입니다.",
        "tr": "Seçilen %lld uygulama, %lld App Store uygulaması içeriyor. Finder aracılığıyla silinecekler.\n\nBu normaldir.",
        "vi": "Đã chọn %lld ứng dụng bao gồm %lld ứng dụng App Store. Chúng sẽ bị xóa qua Finder.\n\nĐiều này là bình thường.",
        "th": "แอปที่เลือก %lld รายการมีแอป App Store %lld รายการ จะถูกลบผ่าน Finder\n\nนี่เป็นเรื่องปกติ",
        "nl": "Geselecteerde %lld apps bevatten %lld App Store-apps. Ze worden verwijderd via Finder.\n\nDit is normaal.",
        "pl": "Wybrane aplikacje (%lld) zawierają aplikacje z App Store (%lld). Zostaną usunięte przez Finder.\n\nTo normalne.",
        "id": "Dipilih %lld aplikasi termasuk %lld aplikasi App Store. Mereka akan dihapus melalui Finder.\n\nIni normal."
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
    for lang_code in langs:
        val = ""
        if lang_code == "br":
            # Generate Braille from English source unless English is missing, then from Key
            source_text = trans_dict.get("en", key)
            val = to_braille(source_text)
        else:
            val = trans_dict.get(lang_code, key) # Fallback to key if missing
        
        string_entry["localizations"][lang_code] = {
            "stringUnit": {
                "state": "translated",
                "value": val
            }
        }
    xcstrings_format["strings"][key] = string_entry

with open('Localizable.xcstrings', 'w') as f:
    json.dump(xcstrings_format, f, indent=2, ensure_ascii=False)

print("Generated Localizable.xcstrings successfully.")
