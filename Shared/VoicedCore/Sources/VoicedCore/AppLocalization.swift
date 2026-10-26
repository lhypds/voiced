import Foundation

public enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    // Declaration order is the order offered in Settings.
    case english
    case chinese
    case japanese
    case french
    case spanish
    case german

    public var id: String { rawValue }

    /// ISO 639-1 code of the language, used to match the system's preferred languages.
    public var code: String {
        switch self {
        case .english: "en"
        case .chinese: "zh"
        case .japanese: "ja"
        case .french: "fr"
        case .spanish: "es"
        case .german: "de"
        }
    }

    /// The interface language used until the user picks one: the first of the system's preferred
    /// languages the app is translated into, or English when none of them is.
    public static var systemDefault: AppLanguage {
        matching(preferredLanguages: Locale.preferredLanguages)
    }

    /// `preferredLanguages` holds BCP 47 tags in the user's order of preference, such as `zh-Hans-CN`.
    public static func matching(preferredLanguages: [String]) -> AppLanguage {
        for tag in preferredLanguages {
            let code = tag.split(separator: "-").first.map { $0.lowercased() }
            if let language = allCases.first(where: { $0.code == code }) {
                return language
            }
        }
        return .english
    }

    public var nativeName: String {
        switch self {
        case .english: "English"
        case .chinese: "中文"
        case .japanese: "日本語"
        case .french: "Français"
        case .spanish: "Español"
        case .german: "Deutsch"
        }
    }

    /// The language's name in English, for instructions written to an AI service.
    public var englishName: String {
        switch self {
        case .english: "English"
        case .chinese: "Chinese"
        case .japanese: "Japanese"
        case .french: "French"
        case .spanish: "Spanish"
        case .german: "German"
        }
    }
}

public struct AppStrings: Sendable {
    public init(language: AppLanguage) {
        self.language = language
    }
    public let language: AppLanguage

    public var subtitle: String { value("本地实时转写", "ローカルリアルタイム文字起こし", "Local live transcription", "Transcription locale en direct", "Transcripción local en directo", "Lokale Live-Transkription") }
    public var input: String { value("输入", "入力", "Input", "Entrée", "Entrada", "Eingang") }
    public var inputLevel: String { value("当前输入的音量", "現在の入力の音量", "Current input level", "Niveau d'entrée actuel", "Nivel de entrada actual", "Aktueller Eingangspegel") }
    public var denoisedLevel: String { value("降噪后的音量", "ノイズ除去後の音量", "Level after noise reduction", "Niveau après réduction du bruit", "Nivel tras la reducción de ruido", "Pegel nach Rauschunterdrückung") }
    public var inputHint: String { value("可选择 Loopback、BlackHole 或麦克风", "Loopback、BlackHole、マイクに対応", "Use Loopback, BlackHole, or a microphone", "Loopback, BlackHole ou micro", "Loopback, BlackHole o micrófono", "Loopback, BlackHole oder Mikrofon") }
    public var recognitionLanguage: String { value("识别语言", "認識言語", "Recognition language", "Langue de reconnaissance", "Idioma de reconocimiento", "Erkennungssprache") }
    public var recognitionLanguageHint: String { value("选定语言可提高识别精度", "言語を指定すると認識精度が上がります", "Picking a language improves accuracy", "Choisir une langue améliore la précision", "Elegir un idioma mejora la precisión", "Eine feste Sprache verbessert die Genauigkeit") }
    public var recognitionEngine: String { value("识别引擎", "認識エンジン", "Recognition engine", "Moteur de reconnaissance", "Motor de reconocimiento", "Erkennungsmodell") }
    public var engineHelp: String { value("如何选择识别引擎", "認識エンジンの選び方", "Choosing an engine", "Choisir un moteur", "Elegir un motor", "Modell auswählen") }
    public var engineDownloadHint: String { value("每个模型首次选择时下载一次，之后使用本地缓存。", "各モデルは初めて選んだときに一度だけダウンロードし、以降はローカルキャッシュを使います。", "Each model is downloaded once, the first time it is selected, then loaded from the local cache.", "Chaque modèle est téléchargé une fois, à sa première sélection, puis chargé depuis le cache local.", "Cada modelo se descarga una vez, la primera vez que se selecciona, y luego se carga desde la caché local.", "Jedes Modell wird beim ersten Auswählen einmal geladen und danach aus dem lokalen Cache geladen.") }

    public func engineDescription(_ engine: RecognitionEngine) -> String {
        switch engine {
        case .turbo:
            value("OpenAI 的通用模型，632 MB。响应最快，适合实时字幕和配置较低的 Mac。", "OpenAI の汎用モデル、632 MB。応答が最も速く、リアルタイム字幕や処理性能を抑えたい場合に。", "OpenAI's general model, 632 MB. Fastest responses, for live captions and lower-end Macs.", "Modèle généraliste d'OpenAI, 632 Mo. Réponses les plus rapides, pour les sous-titres en direct et les Mac modestes.", "Modelo general de OpenAI, 632 MB. Respuestas más rápidas, para subtítulos en directo y Macs modestos.", "Allgemeines Modell von OpenAI, 632 MB. Schnellste Antworten, für Live-Untertitel und schwächere Macs.")
        case .accurate:
            value("OpenAI 的完整 Large v3，626 MB。多语言识别更准确，但响应较慢。", "OpenAI の完全版 Large v3、626 MB。多言語の精度が高い分、応答は遅くなります。", "OpenAI's full Large v3, 626 MB. More accurate across languages, slower to respond.", "Large v3 complet d'OpenAI, 626 Mo. Plus précis dans toutes les langues, réponses plus lentes.", "Large v3 completo de OpenAI, 626 MB. Más preciso en todos los idiomas, respuestas más lentas.", "Vollständiges Large v3 von OpenAI, 626 MB. Genauer in allen Sprachen, langsamer.")
        case .belleTurbo:
            value("BELLE 团队用中文数据微调的 Large v3 Turbo，1.5 GB。中文词汇更准，英文术语较弱，只适合中文；社区转换的 Core ML 版本。", "BELLE チームが中国語データで微調整した Large v3 Turbo、1.5 GB。中国語の語彙に強く英語の用語には弱い、中国語専用。コミュニティによる Core ML 変換版。", "Large v3 Turbo fine-tuned on Mandarin by the BELLE team, 1.5 GB. Better Chinese vocabulary, weaker English terms; Chinese only. Community Core ML conversion.", "Large v3 Turbo affiné sur le mandarin par l'équipe BELLE, 1,5 Go. Meilleur vocabulaire chinois, termes anglais plus faibles ; chinois uniquement. Conversion Core ML communautaire.", "Large v3 Turbo ajustado para mandarín por el equipo BELLE, 1,5 GB. Mejor vocabulario chino, términos en inglés más débiles; solo chino. Conversión Core ML de la comunidad.", "Von BELLE auf Mandarin feinabgestimmtes Large v3 Turbo, 1,5 GB. Besserer chinesischer Wortschatz, schwächere englische Begriffe; nur Chinesisch. Core-ML-Konvertierung aus der Community.")
        case .kotoba:
            value("Kotoba Technologies 用日本电视语料蒸馏训练的模型，1.5 GB。电视、广播类日语更准、速度快，朗读类略逊于 Large v3；不输出标点，只适合日语；社区转换的 Core ML 版本。", "Kotoba Technologies が日本のテレビ音声で蒸留学習したモデル、1.5 GB。テレビ・放送系の日本語に強く高速ですが、朗読系では Large v3 にやや劣ります。句読点は出力されず、日本語専用。コミュニティによる Core ML 変換版。", "Distilled by Kotoba Technologies on Japanese television speech, 1.5 GB. Better and faster on broadcast Japanese, slightly behind Large v3 on read speech; no punctuation; Japanese only. Community Core ML conversion.", "Distillé par Kotoba Technologies sur de la parole télévisée japonaise, 1,5 Go. Meilleur et plus rapide sur le japonais de diffusion, légèrement derrière Large v3 en lecture ; sans ponctuation ; japonais uniquement. Conversion Core ML communautaire.", "Destilado por Kotoba Technologies con habla de televisión japonesa, 1,5 GB. Mejor y más rápido en japonés de emisiones, algo por detrás de Large v3 en lectura; sin puntuación; solo japonés. Conversión Core ML de la comunidad.", "Von Kotoba Technologies auf japanischer Fernsehsprache destilliert, 1,5 GB. Besser und schneller bei Sendungen, bei vorgelesener Sprache etwas hinter Large v3; keine Zeichensetzung; nur Japanisch. Core-ML-Konvertierung aus der Community.")
        }
    }
    public var interfaceLanguage: String { value("界面语言", "表示言語", "Interface language", "Langue de l'interface", "Idioma de la interfaz", "Sprache der Oberfläche") }
    /// Shown under the language row in English whatever language is active, so the row can
    /// always be found; nil when the interface is already in English.
    public var interfaceLanguageHint: String? { language == .english ? nil : "Language" }
    public var keepWindowOnTop: String { value("窗口置顶", "ウインドウを最前面に固定", "Keep window on top", "Fenêtre toujours visible", "Ventana siempre visible", "Fenster im Vordergrund") }
    public var keepWindowOnTopHint: String { value("切换到其他应用时窗口仍保持在最前面。", "他のアプリに切り替えてもウインドウを前面に表示し続けます。", "The window stays in front when you switch to other apps.", "La fenêtre reste au premier plan quand vous passez à d'autres apps.", "La ventana se mantiene delante al cambiar a otras apps.", "Das Fenster bleibt vorne, wenn du zu anderen Apps wechselst.") }
    public var lineClick: String { value("点击条目", "項目をクリック", "Clicking a row", "Clic sur une ligne", "Clic en una fila", "Klick auf eine Zeile") }
    public var lineClickHint: String { value("复制该条内容，或从那一刻起播放录音，播放中点击任意条目停止。识别过程中始终复制。", "その項目をコピーするか、その時点から録音を再生します。再生中はどの項目をクリックしても停止。認識中は常にコピーします。", "Copies the row's text, or plays the recording from that moment; while it plays, a click on any row stops it. While recognizing, it always copies.", "Copie le texte de la ligne, ou lit l'enregistrement à partir de ce moment ; pendant la lecture, un clic sur n'importe quelle ligne l'arrête. Pendant la reconnaissance, copie toujours.", "Copia el texto de la fila o reproduce la grabación desde ese momento; mientras suena, un clic en cualquier fila la detiene. Durante el reconocimiento siempre copia.", "Kopiert den Text der Zeile oder spielt die Aufnahme ab diesem Moment ab; während sie läuft, stoppt ein Klick auf eine beliebige Zeile. Während der Erkennung wird immer kopiert.") }
    public var copyText: String { value("复制内容", "内容をコピー", "Copy text", "Copier le texte", "Copiar texto", "Text kopieren") }
    public var playAudio: String { value("播放音频", "音声を再生", "Play audio", "Lire l'audio", "Reproducir audio", "Audio abspielen") }
    public var timestamp: String { value("时间戳", "タイムスタンプ", "Timestamp", "Horodatage", "Marca de tiempo", "Zeitstempel") }
    public var relativeTime: String { value("相对时间", "相対時間", "Relative", "Relatif", "Relativo", "Relativ") }
    public var currentTime: String { value("当前时间", "現在時刻", "Clock time", "Heure", "Hora", "Uhrzeit") }
    public var showDate: String { value("显示日期", "日付を表示", "Show date", "Afficher la date", "Mostrar fecha", "Datum anzeigen") }
    public var energyThreshold: String { value("能量阈值", "音量しきい値", "Energy threshold", "Seuil d'énergie", "Umbral de energía", "Energieschwelle") }
    public var energyThresholdHint: String { value("声音低于此值不会识别。调低可捕捉较小的声音，但更容易误触发。", "これより小さい音は認識しません。下げると小さな音も拾いますが誤検出が増えます。", "Sound below this is ignored. Lower it to catch quiet audio at the cost of false triggers.", "Les sons sous ce niveau sont ignorés. Baissez-le pour capter les sons faibles, au risque de faux déclenchements.", "El sonido por debajo de este nivel se ignora. Bájalo para captar audio débil, con más falsos positivos.", "Töne unter diesem Wert werden ignoriert. Senken, um leise Signale zu erfassen, mit mehr Fehlauslösungen.") }
    public var noiseReduction: String { value("降噪", "ノイズ低減", "Noise reduction", "Réduction du bruit", "Reducción de ruido", "Rauschunterdrückung") }
    public var noiseReductionHint: String { value("从输入中减去采集到的背景噪音，再送去识别。", "測定した背景ノイズを入力から差し引いてから認識します。", "Subtracts the measured background noise from the input before recognition.", "Soustrait le bruit de fond mesuré de l'entrée avant la reconnaissance.", "Resta el ruido de fondo medido de la entrada antes del reconocimiento.", "Zieht das gemessene Hintergrundgeräusch vor der Erkennung vom Eingang ab.") }
    public var voiceFilter: String { value("人声过滤", "音声フィルター", "Voice filter", "Filtre vocal", "Filtro de voz", "Stimmfilter") }
    public var voiceFilterHint: String { value("用语音检测模型分辨人声，忽略背景音乐等非语音的声音。首次开启时下载模型（约 1 MB）。", "音声検出モデルで人の声を見分け、BGM などの音声以外の音を無視します。初めてオンにしたときにモデル（約 1 MB）をダウンロードします。", "Tells speech from other sound with a speech detection model, so background music and other non-speech sound is ignored. The model (about 1 MB) is downloaded when first turned on.", "Distingue la parole des autres sons avec un modèle de détection vocale : la musique de fond et les autres sons non vocaux sont ignorés. Le modèle (environ 1 Mo) est téléchargé à la première activation.", "Distingue la voz de otros sonidos con un modelo de detección de voz, de modo que la música de fondo y otros sonidos sin habla se ignoran. El modelo (aprox. 1 MB) se descarga al activarlo por primera vez.", "Unterscheidet Sprache von anderen Geräuschen mit einem Sprachaktivitätsmodell; Hintergrundmusik und andere Nicht-Sprache werden ignoriert. Das Modell (etwa 1 MB) wird beim ersten Einschalten geladen.") }
    public var voiceFilterDownloading: String { value("正在下载语音检测模型…", "音声検出モデルをダウンロード中…", "Downloading the speech detection model…", "Téléchargement du modèle de détection vocale…", "Descargando el modelo de detección de voz…", "Sprachaktivitätsmodell wird geladen…") }
    public var noiseReductionNeedsProfile: String { value("先采集背景噪音。", "まず背景ノイズを測定してください。", "Measure the background noise first.", "Mesurez d'abord le bruit de fond.", "Mide primero el ruido de fondo.", "Zuerst das Hintergrundgeräusch messen.") }
    public var translation: String { value("翻译", "翻訳", "Translation", "Traduction", "Traducción", "Übersetzung") }
    public var translationHint: String { value("把每句话翻译成所选语言，由 macOS 在本机完成，不会上传。首次使用某种语言时系统会提示下载语言包。", "各文を選んだ言語に翻訳します。macOS がこの Mac 上で処理し、送信はしません。初めて使う言語では言語パックのダウンロードを求められます。", "Translates each sentence into the chosen language. macOS does it on this Mac; nothing is sent anywhere. The first use of a language asks to download its language pack.", "Traduit chaque phrase dans la langue choisie. macOS s'en charge sur ce Mac ; rien n'est envoyé. La première utilisation d'une langue demande de télécharger son pack linguistique.", "Traduce cada frase al idioma elegido. macOS lo hace en este Mac; no se envía nada. El primer uso de un idioma pide descargar su paquete de idioma.", "Übersetzt jeden Satz in die gewählte Sprache. macOS erledigt das auf diesem Mac; nichts wird gesendet. Beim ersten Gebrauch einer Sprache wird das Sprachpaket zum Download angeboten.") }
    public var translationUnavailable: String { value("需要 macOS 15 或更高版本。", "macOS 15 以降が必要です。", "Requires macOS 15 or later.", "Nécessite macOS 15 ou ultérieur.", "Requiere macOS 15 o posterior.", "Erfordert macOS 15 oder neuer.") }
    public var translationRules: String { value("翻译规则", "翻訳ルール", "Translation rules", "Règles de traduction", "Reglas de traducción", "Übersetzungsregeln") }
    public var translationRulesHint: String { value("识别到左边的语言时，翻译成右边的语言。从上往下找，用第一条符合的规则。", "左の言語を認識したら右の言語に翻訳します。上から順に、最初に当てはまるルールを使います。", "Speech in the language on the left is translated into the one on the right. The first rule that fits, from the top, is used.", "La parole dans la langue de gauche est traduite dans celle de droite. La première règle qui convient, depuis le haut, s'applique.", "El habla en el idioma de la izquierda se traduce al de la derecha. Se usa la primera regla que encaje, desde arriba.", "Sprache links wird in die Sprache rechts übersetzt. Es gilt die erste passende Regel von oben.") }
    public var anyOtherLanguage: String { value("其他语言", "その他の言語", "Any other", "Autre langue", "Otro idioma", "Andere Sprache") }
    public var addTranslationRule: String { value("添加规则", "ルールを追加", "Add rule", "Ajouter une règle", "Añadir regla", "Regel hinzufügen") }
    public var translationEmphasis: String { value("主要文字", "メインの文字", "Main text", "Texte principal", "Texto principal", "Haupttext") }
    public var translationEmphasisHint: String { value("主要文字用正常大小显示，另一种用灰色小字显示。", "メインの文字は通常の大きさ、もう一方は小さな灰色の文字で表示します。", "The main text is shown at full size, the other in small grey type.", "Le texte principal est affiché en taille normale, l'autre en petits caractères gris.", "El texto principal se muestra a tamaño normal; el otro en letra pequeña gris.", "Der Haupttext erscheint in voller Größe, der andere klein und grau.") }
    public var speakTranslation: String { value("朗读译文", "訳文を読み上げ", "Read translation aloud", "Lire la traduction", "Leer la traducción en voz alta", "Übersetzung vorlesen") }
    public var speakTranslationHint: String { value("用系统语音朗读新识别句子的译文。朗读时暂停识别，以免把朗读声当作输入。", "新しく認識した文の訳文をシステムの音声で読み上げます。読み上げ中は認識を止め、その声を入力として拾わないようにします。", "Reads the translation of each newly recognized sentence in the system voice. Recognition pauses while it speaks, so its voice is not taken as input.", "Lit la traduction de chaque nouvelle phrase avec la voix du système. La reconnaissance s'interrompt pendant la lecture, pour ne pas capter cette voix.", "Lee la traducción de cada frase nueva con la voz del sistema. El reconocimiento se pausa mientras habla, para no captar esa voz.", "Liest die Übersetzung jedes neu erkannten Satzes mit der Systemstimme vor. Während des Vorlesens pausiert die Erkennung, damit die Stimme nicht als Eingabe gilt.") }
    public var speechVoice: String { value("朗读声音", "読み上げの声", "Voice", "Voix", "Voz", "Stimme") }
    public var defaultVoice: String { value("默认", "デフォルト", "Default", "Par défaut", "Predeterminada", "Standard") }
    public var previewVoice: String { value("试听", "試聴", "Preview", "Écouter", "Probar", "Anhören") }
    /// Read in this language to try out a voice.
    public var speechSample: String { value("你好，这是朗读译文时使用的声音。", "こんにちは。訳文はこの声で読み上げます。", "Hello, this is the voice translations are read in.", "Bonjour, voici la voix qui lira les traductions.", "Hola, esta es la voz que leerá las traducciones.", "Hallo, mit dieser Stimme werden Übersetzungen vorgelesen.") }
    public var originalText: String { value("原文", "原文", "Original", "Original", "Original", "Original") }
    public var translatedText: String { value("译文", "訳文", "Translation", "Traduction", "Traducción", "Übersetzung") }
    public func translationFailed(_ detail: String) -> String {
        value("翻译失败：\(detail)", "翻訳に失敗：\(detail)", "Translation failed: \(detail)", "Échec de la traduction : \(detail)", "Error de traducción: \(detail)", "Übersetzung fehlgeschlagen: \(detail)")
    }
    public var recognitionPrompt: String { value("识别提示词", "認識プロンプト", "Recognition prompt", "Invite de reconnaissance", "Indicaciones de reconocimiento", "Erkennungshinweise") }
    public var recognitionPromptHint: String { value("提示词文件里的词会被优先识别：人名、产品名、术语等，每行一个。下一次识别生效。", "プロンプトファイルに書いた語が優先されます。人名、製品名、専門用語などを 1 行に 1 つ。次の認識から反映されます。", "Words in the prompt file are preferred: names, products, terms, one per line. Applies to the next recording.", "Les mots du fichier de prompt sont privilégiés : noms, produits, termes, un par ligne. Pris en compte à la prochaine reconnaissance.", "Las palabras del archivo de prompt tienen prioridad: nombres, productos, términos, uno por línea. Se aplica en el próximo reconocimiento.", "Wörter in der Prompt-Datei werden bevorzugt: Namen, Produkte, Begriffe, je Zeile eines. Gilt ab der nächsten Erkennung.") }
    public var editPromptFile: String { value("编辑文件", "ファイルを編集", "Edit file", "Modifier le fichier", "Editar archivo", "Datei bearbeiten") }
    public var editPromptFileHint: String { value("用默认文本编辑器打开 ~/.voiced/prompt.txt", "~/.voiced/prompt.txt をデフォルトのテキストエディタで開きます", "Opens ~/.voiced/prompt.txt in the default text editor", "Ouvre ~/.voiced/prompt.txt dans l'éditeur de texte par défaut", "Abre ~/.voiced/prompt.txt en el editor de texto predeterminado", "Öffnet ~/.voiced/prompt.txt im Standard-Texteditor") }
    public var calibrateNoise: String { value("采集背景噪音", "背景ノイズを測定", "Measure background noise", "Mesurer le bruit de fond", "Medir ruido de fondo", "Hintergrundgeräusch messen") }
    public var calibratingNoise: String { value("正在采集，请保持安静…", "測定中。静かにしてください…", "Measuring, please keep quiet…", "Mesure en cours, restez silencieux…", "Midiendo, guarda silencio…", "Messung läuft, bitte leise…") }
    public var calibrateNoiseHint: String { value("保持安静 2 秒：记录背景噪音用于降噪，并把阈值设到噪音之上。", "2 秒間静かにしてください。背景ノイズを記録してノイズ低減に使い、しきい値をノイズの少し上に設定します。", "Keep quiet for 2 seconds: the background noise is recorded for noise reduction and the threshold is set just above it.", "Restez silencieux 2 secondes : le bruit de fond est enregistré pour la réduction du bruit et le seuil placé juste au-dessus.", "Guarda silencio 2 segundos: se registra el ruido de fondo para la reducción de ruido y el umbral se fija justo por encima.", "2 Sekunden leise bleiben: Das Hintergrundgeräusch wird für die Rauschunterdrückung aufgenommen und die Schwelle knapp darüber gesetzt.") }
    public var resetToDefault: String { value("恢复默认", "デフォルトに戻す", "Reset", "Réinitialiser", "Restablecer", "Zurücksetzen") }
    public var recognitionPreview: String { value("识别预览", "認識プレビュー", "Recognition preview", "Aperçu de reconnaissance", "Vista previa", "Erkennungsvorschau") }
    public var recognitionPreviewHint: String { value("用当前设置试听识别效果，不会写入正文。", "現在の設定で認識を試します。本文には追加されません。", "Try recognition with the current settings; nothing is added to the transcript.", "Testez la reconnaissance avec les réglages actuels ; rien n'est ajouté à la transcription.", "Prueba el reconocimiento con los ajustes actuales; no se añade nada a la transcripción.", "Erkennung mit den aktuellen Einstellungen testen; nichts wird ins Transkript übernommen.") }
    public var startPreview: String { value("开始预览", "プレビュー開始", "Start preview", "Lancer l'aperçu", "Iniciar vista previa", "Vorschau starten") }
    public var stopPreview: String { value("停止预览", "プレビュー停止", "Stop preview", "Arrêter l'aperçu", "Detener vista previa", "Vorschau beenden") }
    public var previewListening: String { value("正在聆听，请播放或说话…", "聞き取り中。音声を流すか話してください…", "Listening. Play audio or speak…", "À l'écoute. Lancez un son ou parlez…", "Escuchando. Reproduce audio o habla…", "Höre zu. Audio abspielen oder sprechen…") }
    public var general: String { value("通用", "一般", "General", "Général", "General", "Allgemein") }
    public var audioInput: String { value("音频输入", "オーディオ入力", "Audio Input", "Entrée audio", "Entrada de audio", "Audioeingang") }
    public var recognition: String { value("识别", "認識", "Recognition", "Reconnaissance", "Reconocimiento", "Erkennung") }
    public var settings: String { value("设置", "設定", "Settings", "Réglages", "Ajustes", "Einstellungen") }
    public var close: String { value("关闭", "閉じる", "Close", "Fermer", "Cerrar", "Schließen") }
    public var installCommand: String { value("安装 voiced 命令…", "voiced コマンドをインストール…", "Install ‘voiced’ Command…", "Installer la commande « voiced »…", "Instalar el comando «voiced»…", "Befehl „voiced“ installieren…") }
    public func commandInstalled(at path: String) -> String {
        value("voiced 命令已安装到 \(path)。在终端输入 voiced 打开 Voiced，voiced stop 退出，voiced restart 重新启动。", "voiced コマンドを \(path) にインストールしました。ターミナルで voiced と入力すると Voiced が開き、voiced stop で終了、voiced restart で再起動します。", "The voiced command is installed at \(path). In a terminal, voiced opens Voiced, voiced stop quits it and voiced restart relaunches it.", "La commande voiced est installée dans \(path). Dans un terminal, voiced ouvre Voiced, voiced stop le quitte et voiced restart le relance.", "El comando voiced está instalado en \(path). En una terminal, voiced abre Voiced, voiced stop lo cierra y voiced restart lo reinicia.", "Der Befehl voiced ist unter \(path) installiert. Im Terminal öffnet voiced Voiced, voiced stop beendet es und voiced restart startet es neu.")
    }
    public var commandNeedsAppBundle: String { value("只能从 Voiced.app 安装命令。", "コマンドは Voiced.app からのみインストールできます。", "The command can only be installed from Voiced.app.", "La commande ne peut être installée que depuis Voiced.app.", "El comando solo se puede instalar desde Voiced.app.", "Der Befehl kann nur aus Voiced.app installiert werden.") }
    public func commandInstallFailed(_ detail: String) -> String {
        value("安装失败：\(detail)", "インストールに失敗：\(detail)", "Installation failed: \(detail)", "Échec de l'installation : \(detail)", "Error de instalación: \(detail)", "Installation fehlgeschlagen: \(detail)")
    }
    public func version(_ number: String) -> String {
        value("版本 \(number)", "バージョン \(number)", "Version \(number)", "Version \(number)", "Versión \(number)", "Version \(number)")
    }
    public var languageChangeHint: String { value("选择会立即生效并自动保存。", "選択内容はすぐに反映され、自動的に保存されます。", "Changes apply immediately and are saved automatically.", "Les changements s'appliquent immédiatement et sont enregistrés.", "Los cambios se aplican de inmediato y se guardan automáticamente.", "Änderungen gelten sofort und werden automatisch gespeichert.") }
    public var detectionLanguages: String { value("检测范围", "検出対象", "Detect among", "Détecter parmi", "Detectar entre", "Erkennen unter") }
    public var detectionLanguagesHint: String { value("自动检测只在这些语言中选择", "自動検出はこの中から言語を選びます", "Auto detect only picks from these", "La détection auto ne choisit que parmi celles-ci", "La detección automática solo elige entre estos", "Die automatische Erkennung wählt nur unter diesen") }
    public var allLanguages: String { value("全部语言", "すべての言語", "All languages", "Toutes les langues", "Todos los idiomas", "Alle Sprachen") }
    public var addDetectionLanguage: String { value("添加语言", "言語を追加", "Add language", "Ajouter une langue", "Añadir idioma", "Sprache hinzufügen") }
    public var automaticDetection: String { value("自动检测", "自動検出", "Auto detect", "Détection auto", "Detección automática", "Automatisch") }
    public var stopRecognition: String { value("停止识别", "認識を停止", "Stop recognition", "Arrêter la reconnaissance", "Detener reconocimiento", "Erkennung beenden") }
    public var startRecognition: String { value("开始识别", "認識を開始", "Start recognition", "Démarrer la reconnaissance", "Iniciar reconocimiento", "Erkennung starten") }
    public var loadingModel: String { value("正在加载模型", "モデルを読み込み中", "Loading model", "Chargement du modèle", "Cargando el modelo", "Modell wird geladen") }
    /// "Loading model 2/3: text decoder" once a component is known; the plain label before that.
    public func loadingModel(_ component: ModelComponent?) -> String {
        guard let component else { return loadingModel }
        let step = "\(component.rawValue + 1)/\(ModelComponent.allCases.count)"
        return value("正在加载模型 \(step)：\(componentName(component))", "モデルを読み込み中 \(step)：\(componentName(component))", "Loading model \(step): \(componentName(component))", "Chargement du modèle \(step) : \(componentName(component))", "Cargando el modelo \(step): \(componentName(component))", "Modell wird geladen \(step): \(componentName(component))")
    }
    public func componentName(_ component: ModelComponent) -> String {
        switch component {
        case .featureExtractor: value("特征提取器", "特徴抽出器", "feature extractor", "extracteur de caractéristiques", "extractor de características", "Merkmalsextraktor")
        case .textDecoder: value("文本解码器", "テキストデコーダー", "text decoder", "décodeur de texte", "decodificador de texto", "Textdecoder")
        case .audioEncoder: value("音频编码器", "音声エンコーダー", "audio encoder", "encodeur audio", "codificador de audio", "Audioencoder")
        }
    }
    /// Why a load can take minutes, shown under the loading bar.
    public var loadingModelHint: String { value("首次加载会为神经网络引擎编译模型，可能需要几分钟；之后再加载只需几秒。", "初回の読み込みでは Neural Engine 向けにモデルをコンパイルするため数分かかることがあります。2 回目以降は数秒です。", "The first load compiles the model for the Neural Engine and can take a few minutes; later loads take seconds.", "Le premier chargement compile le modèle pour le Neural Engine et peut prendre quelques minutes ; les suivants prennent quelques secondes.", "La primera carga compila el modelo para el Neural Engine y puede tardar unos minutos; las siguientes tardan segundos.", "Das erste Laden kompiliert das Modell für die Neural Engine und kann einige Minuten dauern; spätere Ladevorgänge dauern Sekunden.") }
    /// Under the engine menu while the other downloaded models compile in the background.
    public var compilingOtherModels: String { value("正在后台为神经网络引擎编译其他已下载的模型，之后切换到它们只需几秒。", "ダウンロード済みの他のモデルをバックグラウンドで Neural Engine 向けにコンパイルしています。以降の切り替えは数秒で済みます。", "Compiling the other downloaded models for the Neural Engine in the background; switching to them will then take seconds.", "Compilation en arrière-plan des autres modèles téléchargés pour le Neural Engine ; passer à l'un d'eux ne prendra ensuite que quelques secondes.", "Compilando en segundo plano los demás modelos descargados para el Neural Engine; después, cambiar a ellos tardará segundos.", "Die anderen heruntergeladenen Modelle werden im Hintergrund für die Neural Engine kompiliert; der Wechsel dauert danach nur Sekunden.") }
    public func elapsed(_ seconds: Int) -> String {
        let clock = String(format: "%d:%02d", seconds / 60, seconds % 60)
        return value("已用 \(clock)", "経過 \(clock)", "Elapsed \(clock)", "Écoulé \(clock)", "Transcurrido \(clock)", "Vergangen \(clock)")
    }
    public var ready: String { value("就绪", "準備完了", "Ready", "Prêt", "Listo", "Bereit") }
    public var recognizing: String { value("正在识别", "認識中", "Recognizing", "Reconnaissance", "Reconociendo", "Erkennung läuft") }
    public var retry: String { value("重试", "再試行", "Retry", "Réessayer", "Reintentar", "Erneut versuchen") }
    public var results: String { "Voiced" }
    public var copyAll: String { value("复制全部", "すべてコピー", "Copy all", "Tout copier", "Copiar todo", "Alles kopieren") }
    public var copied: String { value("已复制", "コピーしました", "Copied", "Copié", "Copiado", "Kopiert") }
    public var search: String { value("搜索", "検索", "Search", "Rechercher", "Buscar", "Suchen") }
    public var newRecord: String { value("新建", "新規", "New", "Nouveau", "Nuevo", "Neu") }
    public var history: String { value("历史记录", "履歴", "History", "Historique", "Historial", "Verlauf") }
    public var historyHint: String { value("选择一条记录后继续识别", "履歴を選ぶと続きから認識します", "Pick a transcript to keep recognizing into it", "Choisissez une transcription pour continuer à y reconnaître", "Elige una transcripción para seguir reconociendo en ella", "Transkript wählen, um darin weiter zu erkennen") }
    public var historyEmpty: String { value("暂无历史记录", "履歴はまだありません", "No history yet", "Aucun historique", "Sin historial", "Noch kein Verlauf") }
    public var currentRecord: String { value("当前", "現在", "Current", "Actuel", "Actual", "Aktuell") }
    public var openFolder: String { value("打开文件夹", "フォルダを開く", "Open folder", "Ouvrir le dossier", "Abrir carpeta", "Ordner öffnen") }
    public var resetAllSettings: String { value("重置所有设置", "すべての設定をリセット", "Reset all settings", "Réinitialiser tous les réglages", "Restablecer todos los ajustes", "Alle Einstellungen zurücksetzen") }
    public var resetAllSettingsHint: String { value("恢复为初次启动时的设置，历史记录和提示词文件不受影响", "初回起動時の設定に戻します。履歴とプロンプトファイルはそのままです", "Restores the first-launch settings; history and the prompt file are kept", "Rétablit les réglages du premier lancement ; l'historique et le fichier d'invite sont conservés", "Restaura los ajustes del primer inicio; el historial y el archivo de indicaciones se conservan", "Stellt die Einstellungen des ersten Starts wieder her; Verlauf und Prompt-Datei bleiben erhalten") }
    public var reset: String { value("重置", "リセット", "Reset", "Réinitialiser", "Restablecer", "Zurücksetzen") }
    public var resetAllSettingsConfirmation: String { value("重置所有设置？", "すべての設定をリセットしますか？", "Reset all settings?", "Réinitialiser tous les réglages ?", "¿Restablecer todos los ajustes?", "Alle Einstellungen zurücksetzen?") }
    public var cancel: String { value("取消", "キャンセル", "Cancel", "Annuler", "Cancelar", "Abbrechen") }
    public var delete: String { value("删除", "削除", "Delete", "Supprimer", "Eliminar", "Löschen") }
    public var ai: String { "AI" }
    public var openAIAPIKey: String { value("OpenAI API 密钥", "OpenAI API キー", "OpenAI API Key", "Clé API OpenAI", "Clave de API de OpenAI", "OpenAI-API-Schlüssel") }
    public var showAPIKey: String { value("显示密钥", "キーを表示", "Show key", "Afficher la clé", "Mostrar clave", "Schlüssel anzeigen") }
    public var hideAPIKey: String { value("隐藏密钥", "キーを隠す", "Hide key", "Masquer la clé", "Ocultar clave", "Schlüssel verbergen") }
    public var getAPIKey: String { value("获取密钥", "キーを取得", "Get a key", "Obtenir une clé", "Obtener una clave", "Schlüssel holen") }
    public var summarize: String { value("生成摘要", "要約する", "Summarize", "Résumer", "Resumir", "Zusammenfassen") }
    public var summarizing: String { value("正在生成摘要…", "要約中…", "Summarizing…", "Résumé en cours…", "Resumiendo…", "Zusammenfassung läuft…") }
    public var openSummary: String { value("打开摘要", "要約を開く", "Open summary", "Ouvrir le résumé", "Abrir resumen", "Zusammenfassung öffnen") }
    public func summaryFailed(_ detail: String) -> String {
        value("摘要失败：\(detail)", "要約に失敗：\(detail)", "Summary failed: \(detail)", "Échec du résumé : \(detail)", "Error al resumir: \(detail)", "Zusammenfassung fehlgeschlagen: \(detail)")
    }
    public var aiHints: String { value("AI 提示", "AI ヒント", "AI hints", "Indices IA", "Pistas de IA", "KI-Hinweise") }
    public var aiHintsHint: String { value("识别到生僻事物或问题时，在转写列表顶部显示一条 AI 行，读完的时间一到自动消失。只有像是问题或含有生僻词的句子才会发送给 OpenAI", "難しい事柄や質問を認識すると、文字起こしの先頭に AI 行を表示し、読み終わる頃に自動で消えます。質問や難しい語を含みそうな文だけが OpenAI に送信されます", "When a sentence mentions something obscure or asks a question, an AI row appears at the top of the transcript and goes away once it has had time to be read. Only sentences that look like a question or mention an unusual word are sent to OpenAI", "Quand une phrase mentionne un terme rare ou pose une question, une ligne IA apparaît en tête de la transcription et disparaît une fois lue. Seules les phrases qui semblent poser une question ou contenir un mot rare sont envoyées à OpenAI", "Cuando una frase menciona algo poco común o hace una pregunta, aparece una fila de IA al principio de la transcripción que desaparece tras el tiempo de lectura. Solo se envían a OpenAI las frases que parecen una pregunta o contienen una palabra poco común", "Erwähnt ein Satz etwas Ungewöhnliches oder stellt eine Frage, erscheint oben in der Transkription eine KI-Zeile, die nach der Lesezeit verschwindet. Nur Sätze, die nach einer Frage aussehen oder ein ungewöhnliches Wort enthalten, werden an OpenAI gesendet") }
    public var aiHintsNeedsKey: String { value("需要先填写 OpenAI API 密钥", "先に OpenAI API キーを入力してください", "Enter an OpenAI API key first", "Saisissez d'abord une clé API OpenAI", "Introduce primero una clave de API de OpenAI", "Zuerst einen OpenAI-API-Schlüssel eingeben") }
    public var aiModel: String { value("模型", "モデル", "Model", "Modèle", "Modelo", "Modell") }
    public var aiModelHint: String { value("使用的 OpenAI 模型", "使用する OpenAI のモデル", "The OpenAI model used", "Modèle OpenAI utilisé", "Modelo de OpenAI utilizado", "Verwendetes OpenAI-Modell") }
    public var aiSummary: String { value("AI 摘要", "AI 要約", "AI summaries", "Résumés IA", "Resúmenes de IA", "KI-Zusammenfassungen") }
    public var aiSummaryHint: String { value("在历史记录里提供“生成摘要”，整段转写会发送给 OpenAI", "履歴に「要約する」を表示します。文字起こし全体が OpenAI に送信されます", "Offers \"Summarize\" in History; the whole transcript is sent to OpenAI", "Propose « Résumer » dans l'historique ; toute la transcription est envoyée à OpenAI", "Ofrece \"Resumir\" en el historial; toda la transcripción se envía a OpenAI", "Bietet „Zusammenfassen“ im Verlauf an; das ganze Transkript wird an OpenAI gesendet") }
    public var aiHintWebSearch: String { value("联网搜索", "ウェブ検索", "Web search", "Recherche web", "Búsqueda web", "Websuche") }
    public var aiHintWebSearchHint: String { value("允许模型联网查证或查找最新信息。响应更慢、费用更高，且需要支持搜索的模型", "モデルがウェブで確認や最新情報の検索をできるようにします。応答が遅く、費用が高くなり、検索対応モデルが必要です", "Lets the model look things up on the web. Slower, costs more and needs a model with search", "Permet au modèle de chercher sur le web. Plus lent, plus coûteux et réservé aux modèles avec recherche", "Permite al modelo buscar en la web. Más lento, más caro y solo con modelos con búsqueda", "Lässt das Modell im Web nachschlagen. Langsamer, teurer und nur mit suchfähigen Modellen") }
    public var aiHintLanguage: String { value("AI 提示语言", "AI ヒントの言語", "AI hint language", "Langue des indices IA", "Idioma de las pistas de IA", "Sprache der KI-Hinweise") }
    public var aiHintLanguageHint: String { value("提示用哪种语言书写", "ヒントを書く言語", "The language the hints are written in", "Langue dans laquelle les indices sont rédigés", "Idioma en que se escriben las pistas", "Sprache, in der die Hinweise verfasst werden") }
    public var sameAsInterfaceLanguage: String { value("跟随界面语言", "表示言語と同じ", "Same as interface", "Comme l'interface", "Como la interfaz", "Wie die Oberfläche") }
    public func aiHintFailed(_ detail: String) -> String {
        value("AI 提示失败：\(detail)", "AI ヒントに失敗：\(detail)", "AI hint failed: \(detail)", "Échec de l'indice IA : \(detail)", "Error en la pista de IA: \(detail)", "KI-Hinweis fehlgeschlagen: \(detail)")
    }
    public var emptyTitle: String { value("点击麦克风开始识别", "マイクをクリックして認識を開始", "Click the microphone to start", "Cliquez sur le micro pour commencer", "Haz clic en el micrófono para empezar", "Auf das Mikrofon klicken, um zu starten") }
    public var noInput: String { value("未选择输入", "入力が未選択", "No input selected", "Aucune entrée sélectionnée", "Sin entrada seleccionada", "Kein Eingang gewählt") }
    public var chooseInput: String { value("请选择音频输入设备", "音声入力デバイスを選択してください", "Select an audio input device", "Sélectionnez un périphérique d'entrée audio", "Selecciona un dispositivo de entrada de audio", "Audioeingang auswählen") }

    public func lineCount(_ count: Int) -> String {
        value(
            "\(count) 句",
            "\(count) 文",
            count == 1 ? "1 sentence" : "\(count) sentences",
            count == 1 ? "1 phrase" : "\(count) phrases",
            count == 1 ? "1 frase" : "\(count) frases",
            count == 1 ? "1 Satz" : "\(count) Sätze"
        )
    }

    public func downloadingModel(_ progress: Double) -> String {
        let percent = Int(progress * 100)
        return value("正在下载模型 \(percent)%", "モデルをダウンロード中 \(percent)%", "Downloading model \(percent)%", "Téléchargement du modèle \(percent) %", "Descargando el modelo \(percent)%", "Modell wird heruntergeladen \(percent)%")
    }

    public func modelLoadFailed(_ detail: String) -> String {
        value("模型加载失败：\(detail)", "モデルの読み込みに失敗：\(detail)", "Model loading failed: \(detail)", "Échec du chargement du modèle : \(detail)", "Error al cargar el modelo: \(detail)", "Modell konnte nicht geladen werden: \(detail)")
    }

    public func recognitionFailed(_ detail: String) -> String {
        value("识别失败：\(detail)", "認識に失敗：\(detail)", "Recognition failed: \(detail)", "Échec de la reconnaissance : \(detail)", "Error de reconocimiento: \(detail)", "Erkennung fehlgeschlagen: \(detail)")
    }

    private func value(
        _ chinese: String, _ japanese: String, _ english: String,
        _ french: String, _ spanish: String, _ german: String
    ) -> String {
        switch language {
        case .chinese: chinese
        case .japanese: japanese
        case .english: english
        case .french: french
        case .spanish: spanish
        case .german: german
        }
    }
}
