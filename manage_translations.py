import os
import json
import re

# ==========================================
# 1. Config
# ==========================================

XCSTRINGS_PATH = "AppPorts/Localizable.xcstrings"
SWIFT_SCAN_DIR = "AppPorts"

LANGS = [
    "en", "zh-Hans", "zh-Hant", "hi", "es", "ar", "ru", "pt", "fr", "it", "ja", 
    "eo", "de", "ko", "tr", "vi", "th", "nl", "pl", "id", "br"
]

# ==========================================
# 2. Dictionary
# ==========================================

DICT = {
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
        "id": "Dipilih %lld aplikasi termasuk %lld aplikasi App Store. Mereka akan dihapus melalui Finder.\n\nIni normal."
    },
    
    # --- Data Directory Terms ---
    "npm 缓存": {"en": "npm Cache", "zh-Hans": "npm 缓存", "zh-Hant": "npm 快取"},
    "Node.js 包管理器本地缓存": {"en": "Node.js package manager local cache", "zh-Hans": "Node.js 包管理器本地缓存", "zh-Hant": "Node.js 套件管理員本地快取"},
    "Maven 仓库": {"en": "Maven Repository", "zh-Hans": "Maven 仓库", "zh-Hant": "Maven 倉庫"},
    "Java Maven 依赖仓库": {"en": "Java Maven dependency repository", "zh-Hans": "Java Maven 依赖仓库", "zh-Hant": "Java Maven 依賴倉庫"},
    "Bun 运行时": {"en": "Bun Runtime", "zh-Hans": "Bun 运行时", "zh-Hant": "Bun 執行階段"},
    "Bun JavaScript 运行时及缓存": {"en": "Bun JavaScript runtime and cache", "zh-Hans": "Bun JavaScript 运行时及缓存", "zh-Hant": "Bun JavaScript 執行階段及快取"},
    "Conda 环境": {"en": "Conda Environments", "zh-Hans": "Conda 环境", "zh-Hant": "Conda 環境"},
    "Anaconda/Miniconda 环境数据": {"en": "Anaconda/Miniconda environment data", "zh-Hans": "Anaconda/Miniconda 环境数据", "zh-Hant": "Anaconda/Miniconda 環境資料"},
    "Nexus 数据": {"en": "Nexus Data", "zh-Hans": "Nexus 数据", "zh-Hant": "Nexus 資料"},
    "Nexus 代理缓存": {"en": "Nexus proxy cache", "zh-Hans": "Nexus 代理缓存", "zh-Hant": "Nexus 代理快取"},
    "Composer 包": {"en": "Composer Packages", "zh-Hans": "Composer 包", "zh-Hant": "Composer 套件"},
    "PHP Composer 全局包": {"en": "PHP Composer global packages", "zh-Hans": "PHP Composer 全局包", "zh-Hant": "PHP Composer 全域套件"},
    "Ollama 模型": {"en": "Ollama Models", "zh-Hans": "Ollama 模型", "zh-Hant": "Ollama 模型"},
    "Ollama 本地大语言模型存储": {"en": "Ollama local LLM storage", "zh-Hans": "Ollama 本地大语言模型存储", "zh-Hant": "Ollama 本地大語言模型儲存"},
    "PyTorch 模型缓存": {"en": "PyTorch Model Cache", "zh-Hans": "PyTorch 模型缓存", "zh-Hant": "PyTorch 模型快取"},
    "PyTorch 预训练模型权重缓存": {"en": "PyTorch pre-trained model weight cache", "zh-Hans": "PyTorch 预训练模型权重缓存", "zh-Hant": "PyTorch 預訓練模型權重快取"},
    "Whisper 语音模型": {"en": "Whisper Voice Models", "zh-Hans": "Whisper 语音模型", "zh-Hant": "Whisper 語音模型"},
    "OpenAI Whisper 语音识别模型": {"en": "OpenAI Whisper speech recognition model", "zh-Hans": "OpenAI Whisper 语音识别模型", "zh-Hant": "OpenAI Whisper 語音辨識模型"},
    "Keras 数据": {"en": "Keras Data", "zh-Hans": "Keras 数据", "zh-Hant": "Keras 資料"},
    "Keras 模型和数据集": {"en": "Keras models and datasets", "zh-Hans": "Keras 模型和数据集", "zh-Hant": "Keras 模型和資料集"},
    "灵码 (Lingma) 数据": {"en": "Lingma Data", "zh-Hans": "灵码 (Lingma) 数据", "zh-Hant": "靈碼 (Lingma) 資料"},
    "阿里云灵码 AI 编程助手数据": {"en": "Alibaba Cloud Lingma AI coding assistant data", "zh-Hans": "阿里云灵码 AI 编程助手数据", "zh-Hant": "阿里雲靈碼 AI 編程助手資料"},
    "Trae IDE 数据": {"en": "Trae IDE Data", "zh-Hans": "Trae IDE 数据", "zh-Hant": "Trae IDE 資料"},
    "字节跳动 Trae IDE 运行数据": {"en": "ByteDance Trae IDE runtime data", "zh-Hans": "字节跳动 Trae IDE 运行数据", "zh-Hant": "字節跳動 Trae IDE 執行資料"},
    "Trae CN 数据": {"en": "Trae CN Data", "zh-Hans": "Trae CN 数据", "zh-Hant": "Trae CN 資料"},
    "字节跳动 Trae IDE 国内版数据": {"en": "ByteDance Trae IDE China version data", "zh-Hans": "字节跳动 Trae IDE 国内版数据", "zh-Hant": "字節跳動 Trae IDE 國內版資料"},
    "Trae AICC 数据": {"en": "Trae AICC Data", "zh-Hans": "Trae AICC 数据", "zh-Hant": "Trae AICC 資料"},
    "字节跳动 Trae AICC 数据": {"en": "ByteDance Trae AICC data", "zh-Hans": "字节跳动 Trae AICC 数据", "zh-Hant": "字節跳動 Trae AICC 資料"},
    "MarsCode 数据": {"en": "MarsCode Data", "zh-Hans": "MarsCode 数据", "zh-Hant": "MarsCode 資料"},
    "字节跳动 MarsCode IDE 数据": {"en": "ByteDance MarsCode IDE data", "zh-Hans": "字节跳动 MarsCode IDE 数据", "zh-Hant": "字節跳動 MarsCode IDE 資料"},
    "CodeBuddy 数据": {"en": "CodeBuddy Data", "zh-Hans": "CodeBuddy 数据", "zh-Hant": "CodeBuddy 資料"},
    "腾讯 CodeBuddy AI 助手数据": {"en": "Tencent CodeBuddy AI assistant data", "zh-Hans": "腾讯 CodeBuddy AI 助手数据", "zh-Hant": "騰訊 CodeBuddy AI 助手資料"},
    "CodeBuddy CN 数据": {"en": "CodeBuddy CN Data", "zh-Hans": "CodeBuddy CN 数据", "zh-Hant": "CodeBuddy CN 資料"},
    "腾讯 CodeBuddy 国内版 data": {"en": "Tencent CodeBuddy China version data", "zh-Hans": "腾讯 CodeBuddy 国内版数据", "zh-Hant": "騰訊 CodeBuddy 國內版資料"},
    "Qwen 数据": {"en": "Qwen Data", "zh-Hans": "Qwen 数据", "zh-Hant": "Qwen 資料"},
    "阿里通义千问相关数据": {"en": "Alibaba Qwen related data", "zh-Hans": "阿里通义千问相关数据", "zh-Hant": "阿里通義千問相關資料"},
    "ClawBOT 数据": {"en": "ClawBOT Data", "zh-Hans": "ClawBOT 数据", "zh-Hant": "ClawBOT 資料"},
    "ClawdBOT AI 工具数据": {"en": "ClawdBOT AI tool data", "zh-Hans": "ClawdBOT AI 工具数据", "zh-Hant": "ClawdBOT AI 工具資料"},
    "Selenium 浏览器": {"en": "Selenium Browsers", "zh-Hans": "Selenium 浏览器", "zh-Hant": "Selenium 瀏覽器"},
    "Selenium 自动下载的浏览器驱动": {"en": "Selenium auto-downloaded browser drivers", "zh-Hans": "Selenium 自动下载的浏览器驱动", "zh-Hant": "Selenium 自動下載的瀏覽器驅動"},
    "Chromium 快照": {"en": "Chromium Snapshots", "zh-Hans": "Chromium 快照", "zh-Hant": "Chromium 快照"},
    "Playwright/Selenium 使用的 Chromium 浏览器快照": {"en": "Chromium browser snapshots used by Playwright/Selenium", "zh-Hans": "Playwright/Selenium 使用的 Chromium 浏览器快照", "zh-Hant": "Playwright/Selenium 使用的 Chromium 瀏覽器快照"},
    "WDM 浏览器驱动": {"en": "WDM Browser Drivers", "zh-Hans": "WDM 浏览器驱动", "zh-Hant": "WDM 瀏覽器驅動"},
    "WebDriver Manager 下载的驱动程序": {"en": "Drivers downloaded by WebDriver Manager", "zh-Hans": "WebDriver Manager 下载的驱动程序", "zh-Hant": "WebDriver Manager 下載的驅動程式"},
    "VSCode 数据": {"en": "VSCode Data", "zh-Hans": "VSCode 数据", "zh-Hant": "VSCode 資料"},
    "Visual Studio Code 扩展及配置": {"en": "Visual Studio Code extensions and configurations", "zh-Hans": "Visual Studio Code 扩展及配置", "zh-Hant": "Visual Studio Code 擴充功能及設定"},
    "Cursor 数据": {"en": "Cursor Data", "zh-Hans": "Cursor 数据", "zh-Hant": "Cursor 資料"},
    "Cursor AI 编辑器数据": {"en": "Cursor AI editor data", "zh-Hans": "Cursor AI 编辑器数据", "zh-Hant": "Cursor AI 編輯器資料"},
    "STS4 数据": {"en": "STS4 Data", "zh-Hans": "STS4 数据", "zh-Hant": "STS4 資料"},
    "Spring Tool Suite 4 数据": {"en": "Spring Tool Suite 4 data", "zh-Hans": "Spring Tool Suite 4 数据", "zh-Hant": "Spring Tool Suite 4 資料"},
    "Docker CLI 配置": {"en": "Docker CLI Config", "zh-Hans": "Docker CLI 配置", "zh-Hant": "Docker CLI 設定"},
    "Docker Desktop CLI 配置和上下文": {"en": "Docker Desktop CLI config and contexts", "zh-Hans": "Docker Desktop CLI 配置和上下文", "zh-Hant": "Docker Desktop CLI 設定和上下文"},
    "OpenClaw 数据": {"en": "OpenClaw Data", "zh-Hans": "OpenClaw 数据", "zh-Hant": "OpenClaw 資料"},
    "OpenClaw 工具数据": {"en": "OpenClaw tool data", "zh-Hans": "OpenClaw 工具数据", "zh-Hant": "OpenClaw 工具資料"},
    "Python NLTK 数据": {"en": "Python NLTK Data", "zh-Hans": "Python NLTK 数据", "zh-Hant": "Python NLTK 資料"},
    "自然语言处理 NLTK 语料库": {"en": "NLP NLTK corpora", "zh-Hans": "自然语言处理 NLTK 语料库", "zh-Hant": "自然語言處理 NLTK 語料庫"},
    ".local (系统工具)": {"en": ".local (System Tools)", "zh-Hans": ".local (系统工具)", "zh-Hant": ".local (系統工具)"},
    "Python pip 等工具的用户级安装目录，内部结构复杂": {"en": "User-level installation directory for tools like Python pip, complex internal structure", "zh-Hans": "Python pip 等工具的用户级安装目录，内部结构复杂", "zh-Hant": "Python pip 等工具的用戶級安裝目錄，內部結構複雜"},
    ".config (工具配置)": {"en": ".config (Tool Config)", "zh-Hans": ".config (工具配置)", "zh-Hant": ".config (工具設定)"},
    "多个命令行工具的配置目录，包含硬编码路径": {"en": "Configuration directory for multiple CLI tools, contains hardcoded paths", "zh-Hans": "多个命令行工具的配置目录，包含硬编码路径", "zh-Hant": "多個命令列工具的設定目錄，包含硬編碼路徑"},
    "应用核心数据 (设置、数据库等)": {"en": "App core data (Settings, Databases, etc.)", "zh-Hans": "应用核心数据 (设置、数据库等)", "zh-Hant": "應用程式核心資料 (設定、資料庫等)"},
    "沙盒容器数据 (App Store 应用)": {"en": "Sandbox container data (App Store apps)", "zh-Hans": "沙盒容器数据 (App Store 应用)", "zh-Hant": "沙盒容器資料 (App Store 應用程式)"},
    "应用组共享数据": {"en": "App group shared data", "zh-Hans": "应用组共享数据", "zh-Hant": "應用程式組共享資料"},
    "应用缓存 (可重建)": {"en": "App cache (rebuildable)", "zh-Hans": "应用缓存 (可重建)", "zh-Hant": "應用程式快取 (可重建)"},
    "窗口状态恢复数据": {"en": "Saved application state data", "zh-Hans": "窗口状态恢复数据", "zh-Hant": "視窗狀態恢復資料"},
    "本地": {"en": "Local", "zh-Hans": "本地", "zh-Hant": "本地"},
    "已链接": {"en": "Linked", "zh-Hans": "已链接", "zh-Hant": "已連結"},
    "未找到": {"en": "Not Found", "zh-Hans": "未找到", "zh-Hant": "未找到"},
    "工具目录": {"en": "Tool Directories", "zh-Hans": "工具目录", "zh-Hant": "工具目錄"},
    "应用数据": {"en": "App Data", "zh-Hans": "应用数据", "zh-Hant": "應用程式資料"},
    "未发现已知工具目录": {"en": "No known tool directories found", "zh-Hans": "未发现已知工具目录", "zh-Hant": "未發現已知工具目錄"},
    "选择应用": {"en": "Select App", "zh-Hans": "选择应用", "zh-Hant": "選擇應用程式"},
    "无本地应用": {"en": "No local apps", "zh-Hans": "无本地应用", "zh-Hant": "無本地應用程式"},
    "%@ 的数据目录": {"en": "%@'s Data Directory", "zh-Hans": "%@ 的数据目录", "zh-Hant": "%@ 的資料目錄"},
    "请从左侧选择应用": {"en": "Please select an app from the left", "zh-Hans": "请从左侧选择应用", "zh-Hant": "請從左側選擇應用程式"},
    "从左侧选择一个应用": {"en": "Select an app from the left", "zh-Hans": "从左侧选择一个应用", "zh-Hant": "從左側選擇一個應用程式"},
    "未找到关联数据目录": {"en": "No associated data directory found", "zh-Hans": "未找到关联数据目录", "zh-Hant": "未找到關聯資料目錄"},
    "请先在「应用」页面选择外部存储路径": {"en": "Please select external drive path on Applications page first", "zh-Hans": "请先在「应用」页面选择外部存储路径", "zh-Hant": "請先在「應用程式」頁面選擇外部儲存路徑"},
    "去选择": {"en": "Go select", "zh-Hans": "去选择", "zh-Hant": "前往選擇"},
    "%lld 个目录": {"en": "%lld Directories", "zh-Hans": "%lld 个目录", "zh-Hant": "%lld 個目錄"},
    " 可释放": {"en": " freeable", "zh-Hans": " 可释放", "zh-Hant": " 可釋放"},
    "%lld 个已链接": {"en": "%lld Linked", "zh-Hans": "%lld 个已链接", "zh-Hant": "%lld 個已連結"},
    "扫描中...": {"en": "Scanning...", "zh-Hans": "扫描中...", "zh-Hant": "掃描中..."},
    "迁移数据目录": {"en": "Migrate Data Directory", "zh-Hans": "迁移数据目录", "zh-Hant": "遷移資料目錄"},
    "还原数据目录": {"en": "Restore Data Directory", "zh-Hans": "还原数据目录", "zh-Hant": "還原資料目錄"},
    "此目录不支持迁移": {"en": "This directory does not support migration", "zh-Hans": "此目录不支持迁移", "zh-Hant": "此目錄不支援遷移"},
    "迁移": {"en": "Migrate", "zh-Hans": "迁移", "zh-Hant": "遷移"},
    "还原": {"en": "Restore", "zh-Hans": "还原", "zh-Hant": "還原"},
    "将数据目录还原到本地": {"en": "Restore data directory to local", "zh-Hans": "将数据目录还原到本地", "zh-Hant": "將資料目錄還原到本地"},
    "将数据目录迁移到外部存储": {"en": "Migrate data directory to external storage", "zh-Hans": "将数据目录迁移到外部存储", "zh-Hant": "將資料目錄遷移到外部存儲"},
    "重要": {"en": "Critical", "zh-Hans": "重要", "zh-Hant": "重要"},
    "推荐": {"en": "Recommended", "zh-Hans": "推荐", "zh-Hant": "推薦"},
    "可选": {"en": "Optional", "zh-Hans": "可选", "zh-Hant": "可選"},
    "自定义": {"en": "Custom", "zh-Hans": "自定义", "zh-Hant": "自定義"},
    "Application Support": {"en": "Application Support", "zh-Hans": "Application Support", "zh-Hant": "Application Support"},
    "Containers": {"en": "Containers", "zh-Hans": "Containers", "zh-Hant": "Containers"},
    "Group Containers": {"en": "Group Containers", "zh-Hans": "Group Containers", "zh-Hant": "Group Containers"},
    "Caches": {"en": "Caches", "zh-Hans": "Caches", "zh-Hant": "Caches"},
    "Saved State": {"en": "Saved State", "zh-Hans": "Saved State", "zh-Hant": "Saved State"},
    "将「%@」迁移到外部存储": {"en": "Migrate \"%@\" to external storage", "zh-Hans": "将「%@」迁移到外部存储", "zh-Hant": "將「%@」遷移到外部存儲"},
    "将「%@」从外部存储还原到本地": {"en": "Restore \"%@\" from external storage to local", "zh-Hans": "将「%@」从外部存储还原到本地", "zh-Hant": "將「%@」從外部存儲還原到本地"},
    "正在迁移「%@」": {"en": "Migrating \"%@\"", "zh-Hans": "正在迁移「%@」", "zh-Hant": "正在遷移「%@」"},
    "正在还原「%@」": {"en": "Restoring \"%@\"", "zh-Hans": "正在还原「%@」", "zh-Hant": "正在還原「%@」"},
    "操作失败": {"en": "Operation Failed", "zh-Hans": "操作失败", "zh-Hant": "操作失敗"},
    "扫描关联目录中...": {"en": "Scanning associated directories...", "zh-Hans": "扫描关联目录中...", "zh-Hant": "掃描觀聯目錄中..."},
    "未发现关联数据目录": {"en": "No associated data directory found", "zh-Hans": "未发现关联数据目录", "zh-Hant": "未發現關聯資料目錄"},
    "迁移完成后，原路径将自动变成符号链接，相关工具无需任何修改即可继续使用。": {
        "en": "After migration, the original path will automatically become a symbolic link, and related tools can continue to be used without any modification.",
        "zh-Hans": "迁移完成后，原路径将自动变成符号链接，相关工具无需任何修改即可继续使用。",
        "zh-Hant": "遷移完成後，原路徑將自動變成符號連結，相關工具無需任何修改即可繼續使用。"
    },
    "还原完成后，外部存储中的副本将被删除。": {
        "en": "After restoration, the copy in external storage will be deleted.",
        "zh-Hans": "还原完成后，外部存储中的副本将被删除。",
        "zh-Hant": "還原完成後，外部存儲中的副本將被刪除。"
    },
    
    # --- Hardware Terms ---
    "设备速率": {"en": "Device Speed", "zh-Hans": "设备速率", "zh-Hant": "設備速率"},
    "总线速率": {"en": "Bus Speed", "zh-Hans": "总线速率", "zh-Hant": "總線速率"},
    "链接速率": {"en": "Link Speed", "zh-Hans": "链接速率", "zh-Hant": "連結速率"},
    "链接带宽": {"en": "Link Bandwidth", "zh-Hans": "链接带宽", "zh-Hant": "連結頻寬"},
    "链接宽度": {"en": "Link Width", "zh-Hans": "链接宽度", "zh-Hant": "連結寬度"},
    "连接类型": {"en": "Connection Type", "zh-Hans": "连接类型", "zh-Hant": "連接類型"},
    "卷名称": {"en": "Volume Name", "zh-Hans": "卷名称", "zh-Hant": "卷名稱"},
    "总容量": {"en": "Total Capacity", "zh-Hans": "总容量", "zh-Hant": "總容量"},
    "可用空间": {"en": "Available Space", "zh-Hans": "可用空间", "zh-Hant": "可用空間"},
    "文件系统": {"en": "File System", "zh-Hans": "文件系统", "zh-Hant": "文件系統"},
    "可移除": {"en": "Removable", "zh-Hans": "可移除", "zh-Hant": "可移除"},
    "可弹出": {"en": "Ejectable", "zh-Hans": "可弹出", "zh-Hant": "可彈出"},
    "是": {"en": "Yes", "zh-Hans": "是", "zh-Hant": "是"},
    "否": {"en": "No", "zh-Hans": "否", "zh-Hant": "否"},
    "设备位置": {"en": "Device Location", "zh-Hans": "设备位置", "zh-Hant": "設備位置"},
    "设备名称": {"en": "Device Name", "zh-Hans": "设备名称", "zh-Hant": "設備名稱"},
    "块大小": {"en": "Block Size", "zh-Hans": "块大小", "zh-Hant": "塊大小"},
    "接口协议": {"en": "Interface Protocol", "zh-Hans": "接口协议", "zh-Hant": "接口協議"},
    "卷 UUID": {"en": "Volume UUID", "zh-Hans": "卷 UUID", "zh-Hant": "卷 UUID"},
    "未知": {"en": "Unknown", "zh-Hans": "未知", "zh-Hant": "未知"},
    "耗时: %@ 秒": {"en": "Duration: %@ seconds", "zh-Hans": "耗时: %@ 秒", "zh-Hant": "耗時: %@ 秒"},
    "速度: %@ MB/s": {"en": "Speed: %@ MB/s", "zh-Hans": "速度: %@ MB/s", "zh-Hant": "速度: %@ MB/s"},
    "大小: %@": {"en": "Size: %@", "zh-Hans": "大小: %@", "zh-Hant": "大小: %@"},
    "应用: %@": {"en": "App: %@", "zh-Hans": "应用: %@", "zh-Hant": "應用程式: %@"},
    "接口速率": {"en": "Interface Rate", "zh-Hans": "接口速率", "zh-Hant": "介面速率"},
    "未检测到或内置存储": {"en": "Not detected or internal storage", "zh-Hans": "未检测到或内置存储", "zh-Hant": "未檢測到或內建儲存"},
    "========== 迁移性能报告 ==========": {"en": "========== Migration Performance Report ==========", "zh-Hans": "========== 迁移性能报告 ==========", "zh-Hant": "========== 遷移性能報告 =========="},
    
    # --- Critical UI Terms ---
    "应用": {
        "en": "Apps", "zh-Hans": "应用", "zh-Hant": "應用程式",
        "ja": "アプリ", "ko": "앱", "de": "Apps", "fr": "Apps",
        "es": "Apps", "it": "App", "pt": "Apps", "ru": "Приложения",
        "ar": "التطبيقات", "hi": "ऐप्स", "tr": "Uygulamalar", "vi": "Ứng dụng",
        "th": "แอป", "nl": "Apps", "pl": "Aplikacje", "id": "Aplikasi",
        "eo": "Aplikaĵoj"
    },
    "数据目录": {
        "en": "Data Directories", "zh-Hans": "数据目录", "zh-Hant": "資料目錄",
        "ja": "データディレクトリ", "ko": "데이터 디렉토리", "de": "Datenverzeichnisse", "fr": "Répertoires de données",
        "es": "Directorios de datos", "it": "Directory dati", "pt": "Diretórios de dados", "ru": "Каталоги данных",
        "ar": "دلائل البيانات", "hi": "डेटा डायरेक्ट्री", "tr": "Veri Dizinleri", "vi": "Thư mục dữ liệu",
        "th": "ไดเรกทอรีข้อมูล", "nl": "Gegevensmappen", "pl": "Katalogi danych", "id": "Direktori Data",
        "eo": "Datumaj Dosierujoj"
    },
    "工具目录": {
        "en": "Tool Directories", "zh-Hans": "工具目录", "zh-Hant": "工具目錄",
        "ja": "ツールディレクトリ", "ko": "도구 디렉토리", "de": "Tool-Verzeichnisse", "fr": "Répertoires d'outils",
        "es": "Directorios de herramientas", "it": "Directory strumenti", "pt": "Diretórios de ferramentas", "ru": "Каталоги инструментов",
        "ar": "دلائل الأدوات", "hi": "टूल डायरेक्ट्री", "tr": "Araç Dizinleri", "vi": "Thư mục công cụ",
        "th": "ไดเรกทอรีเครื่องมือ", "nl": "Hulpmiddelmappen", "pl": "Katalogi narzędzi", "id": "Direktori Alat",
        "eo": "Ilaj Dosierujoj"
    },
    "继续": {
        "en": "Continue", "zh-Hans": "继续", "zh-Hant": "繼續",
        "ja": "続行", "ko": "계속", "de": "Weiter", "fr": "Continuer",
        "es": "Continuar", "it": "Continua", "pt": "Continuar", "ru": "Продолжить",
        "ar": "متابعة", "hi": "जारी रखें", "tr": "Devam", "vi": "Tiếp tục",
        "th": "ดำเนินการต่อ", "nl": "Doorgaan", "pl": "Kontynuuj", "id": "Lanjutkan",
        "eo": "Daŭrigi"
    },
    "App Store 应用迁移设置": {
        "en": "App Store Migration Settings", "zh-Hans": "App Store 应用迁移设置", "zh-Hant": "App Store 應用程式遷移設定",
        "ja": "App Store アプリ移行設定", "ko": "App Store 앱 마이그레이션 설정", "de": "App Store Migrationseinstellungen",
        "fr": "Paramètres de migration App Store", "es": "Ajustes de migración App Store",
        "it": "Impostazioni migrazione App Store", "pt": "Configurações de migração da App Store",
        "ru": "Настройки миграции App Store", "ar": "إعدادات نقل App Store",
        "hi": "App Store माइग्रेशन सेटिंग्स", "tr": "App Store Taşıma Ayarları",
        "vi": "Cài đặt di chuyển App Store", "th": "ตั้งค่าการย้าย App Store",
        "nl": "App Store-migratie-instellingen", "pl": "Ustawienia migracji App Store",
        "id": "Pengaturan Migrasi App Store", "eo": "App Store Migraj Agordoj"
    },
    "外部": {
        "en": "External", "zh-Hans": "外部", "zh-Hant": "外部",
        "ja": "外部", "ko": "외부", "de": "Extern", "fr": "Externe",
        "es": "Externo", "it": "Esterno", "pt": "Externo", "ru": "Внешний",
        "ar": "خارجي", "hi": "बाहरी", "tr": "Harici", "vi": "Bên ngoài",
        "th": "ภายนอก", "nl": "Extern", "pl": "Zewnętrzny", "id": "Eksternal", "eo": "Ekstera"
    },
    "项目贡献者": {
        "en": "Project Contributors", "zh-Hans": "项目贡献者", "zh-Hant": "專案貢獻者",
        "ja": "プロジェクト貢献者", "ko": "프로젝트 기여자", "de": "Projektmitwirkende",
        "fr": "Contributeurs du projet", "es": "Colaboradores del proyecto",
        "it": "Collaboratori del progetto", "pt": "Contribuidores do projeto",
        "ru": "Участники проекта", "ar": "المساهمين في المشروع",
        "hi": "प्रोजेक्ट योगदानकर्ता", "tr": "Proje Katkıda Bulunanlar",
        "vi": "Người đóng góp dự án", "th": "ผู้มีส่วนร่วมในโครงการ",
        "nl": "Projectmedewerkers", "pl": "Współtwórcy projektu",
        "id": "Kontributor Proyek", "eo": "Projekto-Kontribuantoj"
    },
    "请先选择外部存储路径": {
        "en": "Please select an external storage path first",
        "zh-Hans": "请先选择外部存储路径", "zh-Hant": "請先選擇外部儲存路徑",
        "ja": "まず外部ストレージパスを選択してください",
        "ko": "먼저 외부 저장소 경로를 선택하세요",
        "de": "Bitte zuerst einen externen Speicherpfad auswählen",
        "fr": "Veuillez d'abord sélectionner un chemin de stockage externe",
        "es": "Seleccione primero una ruta de almacenamiento externo",
        "it": "Seleziona prima un percorso di archiviazione esterna",
        "pt": "Selecione primeiro um caminho de armazenamento externo",
        "ru": "Сначала выберите путь к внешнему хранилищу",
        "ar": "يرجى تحديد مسار التخزين الخارجي أولاً",
        "hi": "कृपया पहले बाहरी संग्रहण पथ चुनें",
        "tr": "Lütfen önce harici depolama yolunu seçin",
        "vi": "Vui lòng chọn đường dẫn lưu trữ ngoài trước",
        "th": "กรุณาเลือกพาธที่เก็บข้อมูลภายนอกก่อน",
        "nl": "Selecteer eerst een extern opslagpad",
        "pl": "Najpierw wybierz zewnętrzną ścieżkę przechowywania",
        "id": "Harap pilih jalur penyimpanan eksternal terlebih dahulu",
        "eo": "Bonvolu unue elekti eksteran stokadan vojon"
    },
    "，大小约 %@": {
        "en": ", size about %@",
        "zh-Hans": "，大小约 %@", "zh-Hant": "，大小約 %@",
        "ja": "、サイズ約 %@",
        "ko": "，크기 약 %@",
        "de": ", Größe ca. %@",
        "fr": ", taille env. %@",
        "es": ", tamaño aprox. %@",
        "it": ", dimensione circa %@",
        "pt": ", tamanho aprox. %@",
        "ru": ", размер ок. %@",
        "ar": "، الحجم تقريباً %@",
        "hi": ", आकार लगभग %@",
        "tr": ", boyut yaklaşık %@",
        "vi": ", kích thước khoảng %@",
        "th": " ขนาดประมาณ %@",
        "nl": ", grootte ca. %@",
        "pl": ", rozmiar ok. %@",
        "id": ", ukuran sekitar %@",
        "eo": ", grandeco ĉirkaŭ %@"
    },
    "%@ (%lld 个应用)": {
        "en": "%@ (%lld Apps)",
        "zh-Hans": "%@ (%lld 个应用)", "zh-Hant": "%@ (%lld 個應用程式)",
        "ja": "%@ (%lld 個のアプリ)",
        "ko": "%@ (%lld 개 앱)",
        "de": "%@ (%lld Apps)",
        "fr": "%@ (%lld apps)",
        "es": "%@ (%lld apps)",
        "it": "%@ (%lld app)",
        "pt": "%@ (%lld apps)",
        "ru": "%@ (%lld приложений)",
        "ar": "%@ (%lld تطبيقات)",
        "hi": "%@ (%lld ऐप्स)",
        "tr": "%@ (%lld uygulama)",
        "vi": "%@ (%lld ứng dụng)",
        "th": "%@ (%lld แอป)",
        "nl": "%@ (%lld apps)",
        "pl": "%@ (%lld aplikacji)",
        "id": "%@ (%lld aplikasi)",
        "eo": "%@ (%lld aplikaĵoj)"
    },
    "双击打开系统设置": {
        "en": "Double-click to open System Settings", "zh-Hans": "双击打开系统设置", "zh-Hant": "雙擊打開系統設定",
        "ja": "ダブルクリックしてシステム設定を開く", "ko": "더블 클릭하여 시스템 설정 열기"
    },
    "日志已清空": {
        "en": "Log cleared", "zh-Hans": "日志已清空", "zh-Hant": "日誌已清空",
        "ja": "ログをクリアしました", "ko": "로그 삭제됨"
    },
    "日志记录已启用": {
        "en": "Logging enabled", "zh-Hans": "日志记录已启用", "zh-Hant": "日誌記錄已啟用",
        "ja": "ログ記録が有効になりました", "ko": "로깅이 활성화됨"
    },
    "日志记录已禁用": {
        "en": "Logging disabled", "zh-Hans": "日志记录已禁用", "zh-Hant": "日誌記錄已停用",
        "ja": "ログ記録が無効になりました", "ko": "로깅이 비활성화됨"
    },
    "启用/禁用日志记录": {
        "en": "Enable/Disable logging", "zh-Hans": "启用/禁用日志记录", "zh-Hant": "啟用/停用日誌記錄",
        "ja": "ログ記録の有効/無効", "ko": "로깅 활성화/비활성화"
    },
    "GitHub API 响应无效": {
        "en": "Invalid GitHub API response", "zh-Hans": "GitHub API 响应无效", "zh-Hant": "GitHub API 回應無效",
        "ja": "GitHub API レスポンスが無効です", "ko": "GitHub API 응답이 잘못됨"
    },
    "Finder 删除失败": {
        "en": "Finder deletion failed", "zh-Hans": "Finder 删除失败", "zh-Hant": "Finder 刪除失敗",
        "ja": "Finderの削除に失敗しました", "ko": "Finder 삭제 실패"
    },
    "无法迁移": {
        "en": "Cannot migrate", "zh-Hans": "无法迁移", "zh-Hant": "無法遷移",
        "ja": "移行できません", "ko": "마이그레이션 불가"
    },
    "系统设置 > 隐私与安全性 > 完全磁盘访问权限": {
        "en": "System Settings > Privacy & Security > Full Disk Access", "zh-Hans": "系统设置 > 隐私与安全性 > 完全磁盘访问权限",
        "zh-Hant": "系統設定 > 隱私與安全性 > 完整磁碟存取權限",
        "ja": "システム設定 > プライバシーとセキュリティ > フルディスクアクセス",
        "ko": "시스템 설정 > 개인정보 및 보안 > 전체 디스크 접근"
    },
    "该目录包含可执行文件路径引用，整体迁移可能导致命令行工具失效": {
        "en": "This directory contains executable file path references, migrating may cause CLI tools to fail",
        "zh-Hans": "该目录包含可执行文件路径引用，整体迁移可能导致命令行工具失效",
        "zh-Hant": "該目錄包含可執行檔案路徑引用，整體遷移可能導致命令列工具失效",
        "ja": "このディレクトリには実行ファイルパス参照が含まれており、移行するとCLIツールが使用できなくなる可能性があります"
    },
    "本地已存在同名文件": {
        "en": "A file with the same name already exists locally", "zh-Hans": "本地已存在同名文件",
        "zh-Hant": "本地已存在同名檔案", "ja": "同名のファイルがローカルに既に存在します"
    },
    "本地已存在同名真实文件，无法覆盖": {
        "en": "A real file with the same name already exists locally, cannot overwrite",
        "zh-Hans": "本地已存在同名真实文件，无法覆盖", "zh-Hant": "本地已存在同名真實檔案，無法覆寫",
        "ja": "同名の実ファイルがローカルに既に存在し、上書きできません"
    },
    "本地已存在同名文件，无法覆盖": {
        "en": "A file with the same name already exists locally, cannot overwrite",
        "zh-Hans": "本地已存在同名文件，无法覆盖", "zh-Hant": "本地已存在同名檔案，無法覆寫",
        "ja": "同名のファイルがローカルに既に存在し、上書きできません"
    },
    " 或 ": {"en": " or ", "zh-Hans": " 或 ", "zh-Hant": " 或 ", "ja": " または ", "ko": " 또는 "},
    "尝试删除非链接文件": {
        "en": "Attempted to delete non-link file", "zh-Hans": "尝试删除非链接文件",
        "zh-Hant": "嘗試刪除非連結檔案", "ja": "リンクでないファイルの削除を試みました"
    },
    "diskutil错误": {"en": "diskutil error", "zh-Hans": "diskutil错误", "zh-Hant": "diskutil錯誤", "ja": "diskutilエラー"},
    "（未知）": {"en": "(Unknown)", "zh-Hans": "（未知）", "zh-Hant": "（未知）", "ja": "（不明）", "ko": "(알 수 없음)"},
    "发现新版本 %@。\\n%@": {
        "en": "New version %@ found.\\n%@", "zh-Hans": "发现新版本 %@。\\n%@", "zh-Hant": "發現新版本 %@。\\n%@",
        "ja": "新しいバージョン %@ が見つかりました。\\n%@", "ko": "새 버전 %@을(를) 발견했습니다.\\n%@"
    },
    "App Store 应用不支持迁移，因为迁移后将无法通过 App Store 更新。\\n\\n如需强制迁移，请在设置中启用相应选项。": {
        "en": "App Store apps cannot be migrated because they won't be updatable via App Store after migration.\\n\\nTo force migration, enable the option in Settings.",
        "zh-Hans": "App Store 应用不支持迁移，因为迁移后将无法通过 App Store 更新。\\n\\n如需强制迁移，请在设置中启用相应选项。",
        "zh-Hant": "App Store 應用程式不支援遷移，因為遷移後將無法透過 App Store 更新。\\n\\n如需強制遷移，請在設定中啟用相應選項。",
        "ja": "App Storeアプリは移行後にApp Store経由で更新できなくなるため、移行できません。\\n\\n強制移行するには、設定で対応するオプションを有効にしてください。"
    },
    "非原生 (iPhone/iPad) 应用不支持迁移。\\n\\n如需迁移，请在设置中启用「允许迁移非原生应用」选项。": {
        "en": "Non-native (iPhone/iPad) apps cannot be migrated.\\n\\nTo migrate, enable 'Allow non-native app migration' in Settings.",
        "zh-Hans": "非原生 (iPhone/iPad) 应用不支持迁移。\\n\\n如需迁移，请在设置中启用「允许迁移非原生应用」选项。",
        "zh-Hant": "非原生 (iPhone/iPad) 應用程式不支援遷移。\\n\\n如需遷移，請在設定中啟用「允許遷移非原生應用程式」選項。",
        "ja": "ネイティブでない (iPhone/iPad) アプリは移行できません。\\n\\n移行するには、設定で「非ネイティブアプリの移行を許可」オプションを有効にしてください。"
    },
    "选中的应用包含 App Store 应用和非原生应用。\\n\\n如需迁移，请在设置中启用相应选项。": {
        "en": "Selected apps include App Store apps and non-native apps.\\n\\nTo migrate, enable the corresponding options in Settings.",
        "zh-Hans": "选中的应用包含 App Store 应用和非原生应用。\\n\\n如需迁移，请在设置中启用相应选项。",
        "zh-Hant": "選中的應用程式包含 App Store 應用程式和非原生應用程式。\\n\\n如需遷移，請在設定中啟用相應選項。",
        "ja": "選択されたアプリにはApp Storeアプリと非ネイティブアプリが含まれています。\\n\\n移行するには、設定で対応するオプションを有効にしてください。"
    },
    "选中的 %lld 个应用均来自 App Store，迁移时会使用 Finder 删除，您会听到垃圾桶的声音。\\n\\n这是正常的，应用会被安全地移动到外部存储。": {
        "en": "All %lld selected apps are from the App Store. They will be deleted via Finder during migration (you'll hear the trash sound).\\n\\nThis is normal, apps are safely moved to external storage.",
        "zh-Hans": "选中的 %lld 个应用均来自 App Store，迁移时会使用 Finder 删除，您会听到垃圾桶的声音。\\n\\n这是正常的，应用会被安全地移动到外部存储。",
        "zh-Hant": "選中的 %lld 個應用程式均來自 App Store，遷移時會使用 Finder 刪除，您會聽到垃圾桶的聲音。\\n\\n這是正常的，應用程式會被安全地移動到外部儲存。",
        "ja": "選択された %lld 個のアプリはすべてApp Storeからのものです。移行時にFinderで削除されます（ゴミ箱の音がします）。\\n\\nこれは正常な動作で、アプリは安全に外部ストレージに移動されます。"
    },
    "腾讯 CodeBuddy 国内版数据": {"en": "Tencent CodeBuddy China version data", "zh-Hans": "腾讯 CodeBuddy 国内版数据", "zh-Hant": "騰訊 CodeBuddy 國內版資料"},
    "灵码（Lingma）数据": {"en": "Lingma Data", "zh-Hans": "灵码（Lingma）数据", "zh-Hant": "靈碼（Lingma）資料"},
    "应用缓存（可重建）": {"en": "App cache (rebuildable)", "zh-Hans": "应用缓存（可重建）", "zh-Hant": "應用程式快取（可重建）", "ja": "アプリキャッシュ（再構築可能）"},
    "应用核心数据（设置、数据库等）": {"en": "Application core data (settings, databases, etc.)", "zh-Hans": "应用核心数据（设置、数据库等）", "zh-Hant": "應用程式核心資料（設定、資料庫等）", "ja": "アプリコアデータ（設定、データベースなど）"},
    "沙盒容器数据（App Store 应用）": {"en": "Sandbox container data (App Store apps)", "zh-Hans": "沙盒容器数据（App Store 应用）", "zh-Hant": "沙盒容器資料（App Store 應用程式）", "ja": "サンドボックスコンテナデータ（App Storeアプリ）"},
    ".config（工具配置）": {"en": ".config (Tool Config)", "zh-Hans": ".config（工具配置）", "zh-Hant": ".config（工具設定）", "ja": ".config（ツール設定）"},
    "========== 系统诊断信息 ==========": {"en": "========== System Diagnostics ==========", "zh-Hans": "========== 系统诊断信息 ==========", "zh-Hant": "========== 系統診斷資訊 =========="},
    "========== 外接硬盘信息 ==========": {"en": "========== External Drive Diagnostics ==========", "zh-Hans": "========== 外接硬盘信息 ==========", "zh-Hant": "========== 外接硬碟資訊 =========="},
    "Mac": {"en": "Mac", "zh-Hans": "Mac", "zh-Hant": "Mac"},
    "容器内部拆分迁移的数据目录（如聊天记录、下载文件或运行时数据）": {
        "en": "Data directories split out from inside the container for migration (such as chat history, downloads, or runtime data)",
        "zh-Hans": "容器内部拆分迁移的数据目录（如聊天记录、下载文件或运行时数据）",
        "zh-Hant": "容器內部拆分遷移的資料目錄（如聊天記錄、下載檔案或執行時資料）"
    },
    "整理": {"en": "Normalize", "zh-Hans": "整理", "zh-Hant": "整理"},
    "将已接管的链接整理到 AppPorts 规范路径": {
        "en": "Move managed links to the AppPorts canonical path",
        "zh-Hans": "将已接管的链接整理到 AppPorts 规范路径",
        "zh-Hant": "將已接管的連結整理到 AppPorts 規範路徑"
    },
    "链接详情": {"en": "Link Details", "zh-Hans": "链接详情", "zh-Hant": "連結詳情"},
    "查看现有软链路径，并可将其纳入 AppPorts 管理": {
        "en": "View the existing symlink target and optionally bring it under AppPorts management",
        "zh-Hans": "查看现有软链路径，并可将其纳入 AppPorts 管理",
        "zh-Hant": "查看現有軟連結路徑，並可將其納入 AppPorts 管理"
    },
    "检测到已有符号链接，非 AppPorts 迁移结果": {
        "en": "An existing symbolic link was detected. It was not created by AppPorts",
        "zh-Hans": "检测到已有符号链接，非 AppPorts 迁移结果",
        "zh-Hant": "偵測到現有符號連結，並非 AppPorts 遷移結果"
    },
    "接回": {"en": "Relink", "zh-Hans": "接回", "zh-Hant": "接回"},
    "外部目录已存在，在原路径补建符号链接": {
        "en": "The external directory already exists. Recreate a symbolic link at the original path",
        "zh-Hans": "外部目录已存在，在原路径补建符号链接",
        "zh-Hant": "外部目錄已存在，於原路徑補建符號連結"
    },
    "确认规范化管理": {"en": "Confirm Normalization", "zh-Hans": "确认规范化管理", "zh-Hant": "確認規範化管理"},
    "确认": {"en": "Confirm", "zh-Hans": "确认", "zh-Hant": "確認"},
    "没有匹配当前筛选条件的数据目录": {
        "en": "No data directories match the current filters",
        "zh-Hans": "没有匹配当前筛选条件的数据目录",
        "zh-Hant": "沒有符合目前篩選條件的資料目錄"
    },
    "%lld 个待整理": {"en": "%lld to normalize", "zh-Hans": "%lld 个待整理", "zh-Hant": "%lld 個待整理"},
    "%lld 个现有软链": {"en": "%lld existing symlinks", "zh-Hans": "%lld 个现有软链", "zh-Hant": "%lld 個現有軟連結"},
    "%lld 个待接回": {"en": "%lld pending relink", "zh-Hans": "%lld 个待接回", "zh-Hant": "%lld 個待接回"},
    "无法读取现有软链的目标路径": {
        "en": "Unable to read the target path of the existing symlink",
        "zh-Hans": "无法读取现有软链的目标路径",
        "zh-Hant": "無法讀取現有軟連結的目標路徑"
    },
    "现有软链": {"en": "Existing Symlink", "zh-Hans": "现有软链", "zh-Hant": "現有軟連結"},
    "规范化管理": {"en": "Normalize", "zh-Hans": "规范化管理", "zh-Hant": "規範化管理"},
    "无法读取已链接目录的目标路径": {
        "en": "Unable to read the target path of the linked directory",
        "zh-Hans": "无法读取已链接目录的目标路径",
        "zh-Hant": "無法讀取已連結目錄的目標路徑"
    },
    "整理已链接目录": {"en": "Normalize Linked Directory", "zh-Hans": "整理已链接目录", "zh-Hant": "整理已連結目錄"},
    "当前路径已经符合 AppPorts 的规范路径。": {
        "en": "The current path already matches the AppPorts canonical path.",
        "zh-Hans": "当前路径已经符合 AppPorts 的规范路径。",
        "zh-Hant": "目前路徑已符合 AppPorts 的規範路徑。"
    },
    "当前路径与规范路径不同。本次操作会将外部数据移动到规范路径，并重建本地软链接。": {
        "en": "The current path differs from the AppPorts canonical path. This operation will move the external data to the canonical path and recreate the local symlink.",
        "zh-Hans": "当前路径与规范路径不同。本次操作会将外部数据移动到规范路径，并重建本地软链接。",
        "zh-Hant": "目前路徑與規範路徑不同。本次操作會將外部資料移動到規範路徑，並重建本地軟連結。"
    },
    "无法读取外部目录路径": {"en": "Unable to read the external directory path", "zh-Hans": "无法读取外部目录路径", "zh-Hant": "無法讀取外部目錄路徑"},
    "接回外部数据": {"en": "Relink External Data", "zh-Hans": "接回外部数据", "zh-Hant": "接回外部資料"},
    "开机自动重签名": {
        "en": "Auto Re-sign at Login", "zh-Hans": "开机自动重签名", "zh-Hant": "開機自動重簽名",
        "hi": "लॉगिन पर ऑटो री-साइन", "es": "Re-firmado al iniciar sesión", "ar": "إعادة التوقيع التلقائي عند تسجيل الدخول", "ru": "Автопереподпись при входе",
        "pt": "Re-assinatura ao fazer login", "fr": "Re-signature à la connexion", "it": "Firma automatica al login", "ja": "ログイン時自動再署名",
        "eo": "Aŭtomata resubskribo ĉe ensaluto", "de": "Automatische Neuzeichnung bei Anmeldung", "ko": "로그인 시 자동 재서명", "tr": "Girişte Otomatik Yeniden İmzalama",
        "vi": "Tự động ký lại khi đăng nhập", "th": "เซ็นใหม่อัตโนมัติเมื่อเข้าสู่ระบบ", "nl": "Auto-hertekening bij aanmelding", "pl": "Automatyczne podpisywanie przy logowaniu", "id": "Tanda Ulang Otomatis saat Login"
    },
    "macOS 重启后 Gatekeeper 可能使 Ad-hoc 签名失效。开启后每次登录自动对已迁移应用重新签名。": {
        "en": "Gatekeeper may invalidate Ad-hoc signatures after macOS restart. When enabled, automatically re-signs migrated apps each time you log in.",
        "zh-Hans": "macOS 重启后 Gatekeeper 可能使 Ad-hoc 签名失效。开启后每次登录自动对已迁移应用重新签名。",
        "zh-Hant": "macOS 重啟後 Gatekeeper 可能使 Ad-hoc 簽名失效。開啟後每次登入自動對已遷移應用重新簽名。",
        "hi": "macOS पुनरारंभ के बाद Gatekeeper Ad-hoc हस्ताक्षर अमान्य कर सकता है। सक्षम होने पर, लॉगिन करते समय माइग्रेट किए गए ऐप्स को स्वचालित रूप से फिर से साइन करता है।",
        "es": "Gatekeeper puede invalidar las firmas Ad-hoc después del reinicio de macOS. Cuando está activado, re-firma automáticamente las apps migradas cada vez que inicias sesión.",
        "ar": "قد يُلغي Gatekeeper توقيعات Ad-hoc بعد إعادة تشغيل macOS. عند التفعيل، يتم إعادة توقيع التطبيقات المُرحّلة تلقائياً عند كل تسجيل دخول.",
        "ru": "Gatekeeper может аннулировать Ad-hoc подписи после перезагрузки macOS. При включении автоматически переподписывает мигрированные приложения при каждом входе.",
        "pt": "O Gatekeeper pode invalidar assinaturas Ad-hoc após o reinício do macOS. Quando ativado, re-assina automaticamente os apps migrados cada vez que você faz login.",
        "fr": "Gatekeeper peut invalider les signatures Ad-hoc après le redémarrage de macOS. Lorsqu'activé, re-signe automatiquement les applications migrées à chaque connexion.",
        "it": "Gatekeeper potrebbe invalidare le firme Ad-hoc dopo il riavvio di macOS. Quando attivato, firma automaticamente le app migrate ad ogni accesso.",
        "ja": "macOSの再起動後、GatekeeperがAd-hoc署名を無効にする場合があります。有効にすると、ログインするたびに移行済みアプリを自動的に再署名します。",
        "eo": "Gatekeeper povas nuligi Ad-hoc subskribojn post macOS rekomenco. Kiam aktivigite, aŭtomate resubskribas migritajn aplikaĵojn ĉe ensaluto.",
        "de": "Gatekeeper kann Ad-hoc-Signaturen nach einem macOS-Neustart ungültig machen. Wenn aktiviert, werden migrierte Apps bei jeder Anmeldung automatisch neu signiert.",
        "ko": "macOS 재시작 후 Gatekeeper가 Ad-hoc 서명을 무효화할 수 있습니다. 활성화하면 로그인할 때마다 마이그레이션된 앱을 자동으로 재서명합니다.",
        "tr": "Gatekeeper, macOS yeniden başlatıldıktan sonra Ad-hoc imzaları geçersiz kılabilir. Etkinleştirildiğinde, her giriş yaptığınızda taşınan uygulamaları otomatik olarak yeniden imzalar.",
        "vi": "Gatekeeper có thể vô hiệu hóa chữ ký Ad-hoc sau khi macOS khởi động lại. Khi bật, tự động ký lại các ứng dụng đã di chuyển mỗi khi bạn đăng nhập.",
        "th": "Gatekeeper อาจทำให้ลายเซ็น Ad-hoc ไม่ถูกต้องหลังจากรีสตาร์ท macOS เมื่อเปิดใช้งาน จะเซ็นใหม่แอปที่ย้ายแล้วโดยอัตโนมัติทุกครั้งที่เข้าสู่ระบบ",
        "nl": "Gatekeeper kan Ad-hoc handtekeningen ongeldig maken na macOS herstart. Wanneer ingeschakeld, worden migreerde apps automatisch opnieuw ondertekend bij elke aanmelding.",
        "pl": "Gatekeeper może unieważnić podpisy Ad-hoc po ponownym uruchomieniu macOS. Po włączeniu automatycznie podpisuje migrowane aplikacje przy każdym logowaniu.",
        "id": "Gatekeeper dapat membatalkan tanda tangan Ad-hoc setelah macOS dimulai ulang. Saat diaktifkan, secara otomatis menandatangani ulang aplikasi yang dimigrasi setiap kali Anda login."
    },
    "找不到重签名脚本，安装失败": {
        "en": "Re-sign script not found, installation failed", "zh-Hans": "找不到重签名脚本，安装失败", "zh-Hant": "找不到重簽名腳本，安裝失敗",
        "hi": "री-साइन स्क्रिप्ट नहीं मिली, इंस्टॉलेशन विफल", "es": "Script de re-firmado no encontrado, instalación fallida", "ar": "نص إعادة التوقيع غير موجود، فشل التثبيت", "ru": "Скрипт переподписи не найден, установка не удалась",
        "pt": "Script de re-assinatura não encontrado, instalação falhou", "fr": "Script de re-signature introuvable, échec de l'installation", "it": "Script di ri-firma non trovato, installazione non riuscita", "ja": "再署名スクリプトが見つかりません、インストール失敗",
        "eo": "Resubskribo-skripto ne trovita, instalo malsukcesis", "de": "Neuzeichnungs-Skript nicht gefunden, Installation fehlgeschlagen", "ko": "재서명 스크립트를 찾을 수 없음, 설치 실패", "tr": "Yeniden imzalama betiği bulunamadı, yükleme başarısız",
        "vi": "Không tìm thấy script ký lại, cài đặt thất bại", "th": "ไม่พบสคริปต์เซ็นใหม่ การติดตั้งล้มเหลว", "nl": "Hertekeningscript niet gevonden, installatie mislukt", "pl": "Nie znaleziono skryptu ponownego podpisywania, instalacja nie powiodła się", "id": "Skrip tanda ulang tidak ditemukan, instalasi gagal"
    },
    "LaunchAgent 加载失败": {
        "en": "LaunchAgent failed to load", "zh-Hans": "LaunchAgent 加载失败", "zh-Hant": "LaunchAgent 載入失敗",
        "hi": "LaunchAgent लोड होने में विफल", "es": "Error al cargar LaunchAgent", "ar": "فشل تحميل LaunchAgent", "ru": "Ошибка загрузки LaunchAgent",
        "pt": "Falha ao carregar LaunchAgent", "fr": "Échec du chargement de LaunchAgent", "it": "Caricamento LaunchAgent non riuscito", "ja": "LaunchAgentの読み込みに失敗しました",
        "eo": "LaunchAgent malsukcesis ŝargi", "de": "LaunchAgent konnte nicht geladen werden", "ko": "LaunchAgent 로드 실패", "tr": "LaunchAgent yüklenemedi",
        "vi": "LaunchAgent tải thất bại", "th": "ไม่สามารถโหลด LaunchAgent ได้", "nl": "LaunchAgent laden mislukt", "pl": "Nie udało się załadować LaunchAgent", "id": "LaunchAgent gagal dimuat"
    },
}


# Braille logic
def to_braille(text):
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
    return "".join(mapping.get(char, char) for char in text)

def scan_swift_strings():
    strings = set()
    pattern = re.compile(r'"([^"]*[\u4e00-\u9fa5]+[^"]*)"')
    for root, _, files in os.walk(SWIFT_SCAN_DIR):
        for file in files:
            if file.endswith(".swift"):
                try:
                    with open(os.path.join(root, file), "r", encoding="utf-8") as f:
                        for line in f:
                            line = line.strip()
                            if line.startswith("//"): continue
                            if any(x in line for x in ["AppLogger", "print(", ".log(", "level:"]): continue
                            matches = pattern.findall(line)
                            for m in matches:
                                if "\\(" in m: continue
                                strings.add(m)
                except: continue
    return strings

def manage():
    if os.path.exists(XCSTRINGS_PATH):
        with open(XCSTRINGS_PATH, "r", encoding="utf-8") as f:
            data = json.load(f)
    else:
        data = {"sourceLanguage": "zh-Hans", "strings": {}, "version": "1.1"}
    
    found_strings = scan_swift_strings()
    all_keys = set(data["strings"].keys()) | found_strings | set(DICT.keys())
    
    for key in all_keys:
        if not key: continue
        entry = data["strings"].get(key, {"extractionState": "manual", "localizations": {}})
        locs = entry.get("localizations", {})
        
        has_chinese_key = bool(re.search(r'[\u4e00-\u9fa5]', key))
        
        for lang in LANGS:
            val = None
            # 1. Explicit DICT entry takes priority
            if key in DICT and lang in DICT[key]:
                val = DICT[key][lang]
            elif lang == "br":
                # Braille: use English from DICT, or existing English, or key
                source = DICT.get(key, {}).get("en") or locs.get("en", {}).get("stringUnit", {}).get("value") or key
                val = to_braille(source)
            elif lang == "zh-Hans":
                val = DICT.get(key, {}).get("zh-Hans", key)
            elif lang == "zh-Hant":
                if key in DICT and "zh-Hant" in DICT[key]:
                    val = DICT[key]["zh-Hant"]
                else:
                    # Preserve existing zh-Hant or generate from simplified
                    existing = locs.get(lang, {}).get("stringUnit", {}).get("value")
                    if existing and existing != key:
                        val = existing
                    else:
                        val = key.replace("数据", "資料").replace("缓存", "快取").replace("设置", "設定").replace("应用", "應用程式").replace("运行", "執行").replace("迁移", "遷移").replace("链接", "連結").replace("目录", "目錄").replace("还原", "還原")
            else:
                # For all other languages (en, ja, ko, etc.)
                existing = locs.get(lang, {}).get("stringUnit", {}).get("value")
                if existing:
                    # Keep existing if it's NOT Chinese (for non-CJK langs)
                    if lang not in ("zh-Hans", "zh-Hant") and has_chinese_key and re.search(r'[\u4e00-\u9fa5]', existing):
                        # Existing value is Chinese for a non-Chinese language - replace it
                        val = None
                    else:
                        val = existing
                
                # If still no value, use English fallback (from DICT or existing)
                if val is None:
                    en_val = DICT.get(key, {}).get("en") or locs.get("en", {}).get("stringUnit", {}).get("value")
                    if en_val and not (has_chinese_key and re.search(r'[\u4e00-\u9fa5]', en_val)):
                        val = en_val
                    elif not has_chinese_key:
                        val = key  # Non-Chinese key can safely be used as fallback
                    else:
                        # Last resort: keep key but only for zh-Hans/zh-Hant
                        val = key if lang in ("zh-Hans", "zh-Hant") else key
                        # If we really have nothing, use the key (at least it won't crash)
            
            locs[lang] = {"stringUnit": {"state": "translated", "value": val}}
        
        entry["localizations"] = locs
        data["strings"][key] = entry

    with open(XCSTRINGS_PATH, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
    print(f"Localization complete. {len(all_keys)} keys processed.")

if __name__ == "__main__":
    manage()
