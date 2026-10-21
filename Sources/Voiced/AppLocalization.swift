import Foundation

enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    // Declaration order is the order offered in Settings.
    case english
    case chinese
    case japanese
    case french
    case spanish
    case german

    var id: String { rawValue }

    /// ISO 639-1 code of the language, used to match the system's preferred languages.
    var code: String {
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
    static var systemDefault: AppLanguage {
        matching(preferredLanguages: Locale.preferredLanguages)
    }

    /// `preferredLanguages` holds BCP 47 tags in the user's order of preference, such as `zh-Hans-CN`.
    static func matching(preferredLanguages: [String]) -> AppLanguage {
        for tag in preferredLanguages {
            let code = tag.split(separator: "-").first.map { $0.lowercased() }
            if let language = allCases.first(where: { $0.code == code }) {
                return language
            }
        }
        return .english
    }

    var nativeName: String {
        switch self {
        case .english: "English"
        case .chinese: "中文"
        case .japanese: "日本語"
        case .french: "Français"
        case .spanish: "Español"
        case .german: "Deutsch"
        }
    }
}

struct AppStrings: Sendable {
    let language: AppLanguage

    var subtitle: String { value("本地实时转写", "ローカルリアルタイム文字起こし", "Local live transcription", "Transcription locale en direct", "Transcripción local en directo", "Lokale Live-Transkription") }
    var input: String { value("输入", "入力", "Input", "Entrée", "Entrada", "Eingang") }
    var inputLevel: String { value("当前输入的音量", "現在の入力の音量", "Current input level", "Niveau d'entrée actuel", "Nivel de entrada actual", "Aktueller Eingangspegel") }
    var denoisedLevel: String { value("降噪后的音量", "ノイズ除去後の音量", "Level after noise reduction", "Niveau après réduction du bruit", "Nivel tras la reducción de ruido", "Pegel nach Rauschunterdrückung") }
    var inputHint: String { value("可选择 Loopback、BlackHole 或麦克风", "Loopback、BlackHole、マイクに対応", "Use Loopback, BlackHole, or a microphone", "Loopback, BlackHole ou micro", "Loopback, BlackHole o micrófono", "Loopback, BlackHole oder Mikrofon") }
    var recognitionLanguage: String { value("识别语言", "認識言語", "Recognition language", "Langue de reconnaissance", "Idioma de reconocimiento", "Erkennungssprache") }
    var recognitionLanguageHint: String { value("选定语言可提高识别精度", "言語を指定すると認識精度が上がります", "Picking a language improves accuracy", "Choisir une langue améliore la précision", "Elegir un idioma mejora la precisión", "Eine feste Sprache verbessert die Genauigkeit") }
    var recognitionEngine: String { value("识别引擎", "認識エンジン", "Recognition engine", "Moteur de reconnaissance", "Motor de reconocimiento", "Erkennungsmodell") }
    var engineHelp: String { value("如何选择识别引擎", "認識エンジンの選び方", "Choosing an engine", "Choisir un moteur", "Elegir un motor", "Modell auswählen") }
    var engineDownloadHint: String { value("每个模型首次选择时下载一次，之后使用本地缓存。", "各モデルは初めて選んだときに一度だけダウンロードし、以降はローカルキャッシュを使います。", "Each model is downloaded once, the first time it is selected, then loaded from the local cache.", "Chaque modèle est téléchargé une fois, à sa première sélection, puis chargé depuis le cache local.", "Cada modelo se descarga una vez, la primera vez que se selecciona, y luego se carga desde la caché local.", "Jedes Modell wird beim ersten Auswählen einmal geladen und danach aus dem lokalen Cache geladen.") }

    func engineDescription(_ engine: RecognitionEngine) -> String {
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
    var interfaceLanguage: String { value("界面语言", "表示言語", "Interface language", "Langue de l'interface", "Idioma de la interfaz", "Sprache der Oberfläche") }
    /// Shown under the language row in English whatever language is active, so the row can
    /// always be found; nil when the interface is already in English.
    var interfaceLanguageHint: String? { language == .english ? nil : "Language" }
    var keepWindowOnTop: String { value("窗口置顶", "ウインドウを最前面に固定", "Keep window on top", "Fenêtre toujours visible", "Ventana siempre visible", "Fenster im Vordergrund") }
    var keepWindowOnTopHint: String { value("切换到其他应用时窗口仍保持在最前面。", "他のアプリに切り替えてもウインドウを前面に表示し続けます。", "The window stays in front when you switch to other apps.", "La fenêtre reste au premier plan quand vous passez à d'autres apps.", "La ventana se mantiene delante al cambiar a otras apps.", "Das Fenster bleibt vorne, wenn du zu anderen Apps wechselst.") }
    var timestamp: String { value("时间戳", "タイムスタンプ", "Timestamp", "Horodatage", "Marca de tiempo", "Zeitstempel") }
    var relativeTime: String { value("相对时间", "相対時間", "Relative", "Relatif", "Relativo", "Relativ") }
    var currentTime: String { value("当前时间", "現在時刻", "Clock time", "Heure", "Hora", "Uhrzeit") }
    var showDate: String { value("显示日期", "日付を表示", "Show date", "Afficher la date", "Mostrar fecha", "Datum anzeigen") }
    var energyThreshold: String { value("能量阈值", "音量しきい値", "Energy threshold", "Seuil d'énergie", "Umbral de energía", "Energieschwelle") }
    var energyThresholdHint: String { value("声音低于此值不会识别。调低可捕捉较小的声音，但更容易误触发。", "これより小さい音は認識しません。下げると小さな音も拾いますが誤検出が増えます。", "Sound below this is ignored. Lower it to catch quiet audio at the cost of false triggers.", "Les sons sous ce niveau sont ignorés. Baissez-le pour capter les sons faibles, au risque de faux déclenchements.", "El sonido por debajo de este nivel se ignora. Bájalo para captar audio débil, con más falsos positivos.", "Töne unter diesem Wert werden ignoriert. Senken, um leise Signale zu erfassen, mit mehr Fehlauslösungen.") }
    var noiseReduction: String { value("降噪", "ノイズ低減", "Noise reduction", "Réduction du bruit", "Reducción de ruido", "Rauschunterdrückung") }
    var noiseReductionHint: String { value("从输入中减去采集到的背景噪音，再送去识别。", "測定した背景ノイズを入力から差し引いてから認識します。", "Subtracts the measured background noise from the input before recognition.", "Soustrait le bruit de fond mesuré de l'entrée avant la reconnaissance.", "Resta el ruido de fondo medido de la entrada antes del reconocimiento.", "Zieht das gemessene Hintergrundgeräusch vor der Erkennung vom Eingang ab.") }
    var voiceFilter: String { value("人声过滤", "音声フィルター", "Voice filter", "Filtre vocal", "Filtro de voz", "Stimmfilter") }
    var voiceFilterHint: String { value("用语音检测模型分辨人声，忽略背景音乐等非语音的声音。首次开启时下载模型（约 1 MB）。", "音声検出モデルで人の声を見分け、BGM などの音声以外の音を無視します。初めてオンにしたときにモデル（約 1 MB）をダウンロードします。", "Tells speech from other sound with a speech detection model, so background music and other non-speech sound is ignored. The model (about 1 MB) is downloaded when first turned on.", "Distingue la parole des autres sons avec un modèle de détection vocale : la musique de fond et les autres sons non vocaux sont ignorés. Le modèle (environ 1 Mo) est téléchargé à la première activation.", "Distingue la voz de otros sonidos con un modelo de detección de voz, de modo que la música de fondo y otros sonidos sin habla se ignoran. El modelo (aprox. 1 MB) se descarga al activarlo por primera vez.", "Unterscheidet Sprache von anderen Geräuschen mit einem Sprachaktivitätsmodell; Hintergrundmusik und andere Nicht-Sprache werden ignoriert. Das Modell (etwa 1 MB) wird beim ersten Einschalten geladen.") }
    var voiceFilterDownloading: String { value("正在下载语音检测模型…", "音声検出モデルをダウンロード中…", "Downloading the speech detection model…", "Téléchargement du modèle de détection vocale…", "Descargando el modelo de detección de voz…", "Sprachaktivitätsmodell wird geladen…") }
    var noiseReductionNeedsProfile: String { value("先采集背景噪音。", "まず背景ノイズを測定してください。", "Measure the background noise first.", "Mesurez d'abord le bruit de fond.", "Mide primero el ruido de fondo.", "Zuerst das Hintergrundgeräusch messen.") }
    var recognitionPrompt: String { value("识别提示词", "認識プロンプト", "Recognition prompt", "Invite de reconnaissance", "Indicaciones de reconocimiento", "Erkennungshinweise") }
    var recognitionPromptHint: String { value("提示词文件里的词会被优先识别：人名、产品名、术语等，每行一个。下一次识别生效。", "プロンプトファイルに書いた語が優先されます。人名、製品名、専門用語などを 1 行に 1 つ。次の認識から反映されます。", "Words in the prompt file are preferred: names, products, terms, one per line. Applies to the next recording.", "Les mots du fichier de prompt sont privilégiés : noms, produits, termes, un par ligne. Pris en compte à la prochaine reconnaissance.", "Las palabras del archivo de prompt tienen prioridad: nombres, productos, términos, uno por línea. Se aplica en el próximo reconocimiento.", "Wörter in der Prompt-Datei werden bevorzugt: Namen, Produkte, Begriffe, je Zeile eines. Gilt ab der nächsten Erkennung.") }
    var editPromptFile: String { value("编辑文件", "ファイルを編集", "Edit file", "Modifier le fichier", "Editar archivo", "Datei bearbeiten") }
    var editPromptFileHint: String { value("用默认文本编辑器打开 ~/.voiced/prompt.txt", "~/.voiced/prompt.txt をデフォルトのテキストエディタで開きます", "Opens ~/.voiced/prompt.txt in the default text editor", "Ouvre ~/.voiced/prompt.txt dans l'éditeur de texte par défaut", "Abre ~/.voiced/prompt.txt en el editor de texto predeterminado", "Öffnet ~/.voiced/prompt.txt im Standard-Texteditor") }
    var calibrateNoise: String { value("采集背景噪音", "背景ノイズを測定", "Measure background noise", "Mesurer le bruit de fond", "Medir ruido de fondo", "Hintergrundgeräusch messen") }
    var calibratingNoise: String { value("正在采集，请保持安静…", "測定中。静かにしてください…", "Measuring, please keep quiet…", "Mesure en cours, restez silencieux…", "Midiendo, guarda silencio…", "Messung läuft, bitte leise…") }
    var calibrateNoiseHint: String { value("保持安静 2 秒：记录背景噪音用于降噪，并把阈值设到噪音之上。", "2 秒間静かにしてください。背景ノイズを記録してノイズ低減に使い、しきい値をノイズの少し上に設定します。", "Keep quiet for 2 seconds: the background noise is recorded for noise reduction and the threshold is set just above it.", "Restez silencieux 2 secondes : le bruit de fond est enregistré pour la réduction du bruit et le seuil placé juste au-dessus.", "Guarda silencio 2 segundos: se registra el ruido de fondo para la reducción de ruido y el umbral se fija justo por encima.", "2 Sekunden leise bleiben: Das Hintergrundgeräusch wird für die Rauschunterdrückung aufgenommen und die Schwelle knapp darüber gesetzt.") }
    var resetToDefault: String { value("恢复默认", "デフォルトに戻す", "Reset", "Réinitialiser", "Restablecer", "Zurücksetzen") }
    var recognitionPreview: String { value("识别预览", "認識プレビュー", "Recognition preview", "Aperçu de reconnaissance", "Vista previa", "Erkennungsvorschau") }
    var recognitionPreviewHint: String { value("用当前设置试听识别效果，不会写入正文。", "現在の設定で認識を試します。本文には追加されません。", "Try recognition with the current settings; nothing is added to the transcript.", "Testez la reconnaissance avec les réglages actuels ; rien n'est ajouté à la transcription.", "Prueba el reconocimiento con los ajustes actuales; no se añade nada a la transcripción.", "Erkennung mit den aktuellen Einstellungen testen; nichts wird ins Transkript übernommen.") }
    var startPreview: String { value("开始预览", "プレビュー開始", "Start preview", "Lancer l'aperçu", "Iniciar vista previa", "Vorschau starten") }
    var stopPreview: String { value("停止预览", "プレビュー停止", "Stop preview", "Arrêter l'aperçu", "Detener vista previa", "Vorschau beenden") }
    var previewListening: String { value("正在聆听，请播放或说话…", "聞き取り中。音声を流すか話してください…", "Listening. Play audio or speak…", "À l'écoute. Lancez un son ou parlez…", "Escuchando. Reproduce audio o habla…", "Höre zu. Audio abspielen oder sprechen…") }
    var settings: String { value("设置", "設定", "Settings", "Réglages", "Ajustes", "Einstellungen") }
    var close: String { value("关闭", "閉じる", "Close", "Fermer", "Cerrar", "Schließen") }
    var languageChangeHint: String { value("选择会立即生效并自动保存。", "選択内容はすぐに反映され、自動的に保存されます。", "Changes apply immediately and are saved automatically.", "Les changements s'appliquent immédiatement et sont enregistrés.", "Los cambios se aplican de inmediato y se guardan automáticamente.", "Änderungen gelten sofort und werden automatisch gespeichert.") }
    var automaticDetection: String { value("自动检测", "自動検出", "Auto detect", "Détection auto", "Detección automática", "Automatisch") }
    var stopRecognition: String { value("停止识别", "認識を停止", "Stop recognition", "Arrêter la reconnaissance", "Detener reconocimiento", "Erkennung beenden") }
    var startRecognition: String { value("开始识别", "認識を開始", "Start recognition", "Démarrer la reconnaissance", "Iniciar reconocimiento", "Erkennung starten") }
    var loadingModel: String { value("正在加载模型", "モデルを読み込み中", "Loading model", "Chargement du modèle", "Cargando el modelo", "Modell wird geladen") }
    /// "Loading model 2/3: text decoder" once a component is known; the plain label before that.
    func loadingModel(_ component: ModelComponent?) -> String {
        guard let component else { return loadingModel }
        let step = "\(component.rawValue + 1)/\(ModelComponent.allCases.count)"
        return value("正在加载模型 \(step)：\(componentName(component))", "モデルを読み込み中 \(step)：\(componentName(component))", "Loading model \(step): \(componentName(component))", "Chargement du modèle \(step) : \(componentName(component))", "Cargando el modelo \(step): \(componentName(component))", "Modell wird geladen \(step): \(componentName(component))")
    }
    func componentName(_ component: ModelComponent) -> String {
        switch component {
        case .featureExtractor: value("特征提取器", "特徴抽出器", "feature extractor", "extracteur de caractéristiques", "extractor de características", "Merkmalsextraktor")
        case .textDecoder: value("文本解码器", "テキストデコーダー", "text decoder", "décodeur de texte", "decodificador de texto", "Textdecoder")
        case .audioEncoder: value("音频编码器", "音声エンコーダー", "audio encoder", "encodeur audio", "codificador de audio", "Audioencoder")
        }
    }
    /// Why a load can take minutes, shown under the loading bar.
    var loadingModelHint: String { value("首次加载会为神经网络引擎编译模型，可能需要几分钟；之后再加载只需几秒。", "初回の読み込みでは Neural Engine 向けにモデルをコンパイルするため数分かかることがあります。2 回目以降は数秒です。", "The first load compiles the model for the Neural Engine and can take a few minutes; later loads take seconds.", "Le premier chargement compile le modèle pour le Neural Engine et peut prendre quelques minutes ; les suivants prennent quelques secondes.", "La primera carga compila el modelo para el Neural Engine y puede tardar unos minutos; las siguientes tardan segundos.", "Das erste Laden kompiliert das Modell für die Neural Engine und kann einige Minuten dauern; spätere Ladevorgänge dauern Sekunden.") }
    func elapsed(_ seconds: Int) -> String {
        let clock = String(format: "%d:%02d", seconds / 60, seconds % 60)
        return value("已用 \(clock)", "経過 \(clock)", "Elapsed \(clock)", "Écoulé \(clock)", "Transcurrido \(clock)", "Vergangen \(clock)")
    }
    var ready: String { value("就绪", "準備完了", "Ready", "Prêt", "Listo", "Bereit") }
    var recognizing: String { value("正在识别", "認識中", "Recognizing", "Reconnaissance", "Reconociendo", "Erkennung läuft") }
    var retry: String { value("重试", "再試行", "Retry", "Réessayer", "Reintentar", "Erneut versuchen") }
    var results: String { "Voiced" }
    var copyAll: String { value("复制全部", "すべてコピー", "Copy all", "Tout copier", "Copiar todo", "Alles kopieren") }
    var copied: String { value("已复制", "コピーしました", "Copied", "Copié", "Copiado", "Kopiert") }
    var newRecord: String { value("新建", "新規", "New", "Nouveau", "Nuevo", "Neu") }
    var history: String { value("历史记录", "履歴", "History", "Historique", "Historial", "Verlauf") }
    var historyHint: String { value("选择一条记录后继续识别", "履歴を選ぶと続きから認識します", "Pick a transcript to keep recognizing into it", "Choisissez une transcription pour continuer à y reconnaître", "Elige una transcripción para seguir reconociendo en ella", "Transkript wählen, um darin weiter zu erkennen") }
    var historyEmpty: String { value("暂无历史记录", "履歴はまだありません", "No history yet", "Aucun historique", "Sin historial", "Noch kein Verlauf") }
    var currentRecord: String { value("当前", "現在", "Current", "Actuel", "Actual", "Aktuell") }
    var openFolder: String { value("打开文件夹", "フォルダを開く", "Open folder", "Ouvrir le dossier", "Abrir carpeta", "Ordner öffnen") }
    var delete: String { value("删除", "削除", "Delete", "Supprimer", "Eliminar", "Löschen") }
    var emptyTitle: String { value("点击麦克风开始识别", "マイクをクリックして認識を開始", "Click the microphone to start", "Cliquez sur le micro pour commencer", "Haz clic en el micrófono para empezar", "Auf das Mikrofon klicken, um zu starten") }
    var noInput: String { value("未选择输入", "入力が未選択", "No input selected", "Aucune entrée sélectionnée", "Sin entrada seleccionada", "Kein Eingang gewählt") }
    var chooseInput: String { value("请选择音频输入设备", "音声入力デバイスを選択してください", "Select an audio input device", "Sélectionnez un périphérique d'entrée audio", "Selecciona un dispositivo de entrada de audio", "Audioeingang auswählen") }

    func lineCount(_ count: Int) -> String {
        value(
            "\(count) 句",
            "\(count) 文",
            count == 1 ? "1 sentence" : "\(count) sentences",
            count == 1 ? "1 phrase" : "\(count) phrases",
            count == 1 ? "1 frase" : "\(count) frases",
            count == 1 ? "1 Satz" : "\(count) Sätze"
        )
    }

    func downloadingModel(_ progress: Double) -> String {
        let percent = Int(progress * 100)
        return value("正在下载模型 \(percent)%", "モデルをダウンロード中 \(percent)%", "Downloading model \(percent)%", "Téléchargement du modèle \(percent) %", "Descargando el modelo \(percent)%", "Modell wird heruntergeladen \(percent)%")
    }

    func modelLoadFailed(_ detail: String) -> String {
        value("模型加载失败：\(detail)", "モデルの読み込みに失敗：\(detail)", "Model loading failed: \(detail)", "Échec du chargement du modèle : \(detail)", "Error al cargar el modelo: \(detail)", "Modell konnte nicht geladen werden: \(detail)")
    }

    func recognitionFailed(_ detail: String) -> String {
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
