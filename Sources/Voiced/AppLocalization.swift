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
    var inputHint: String { value("可选择 Loopback、BlackHole 或麦克风", "Loopback、BlackHole、マイクに対応", "Use Loopback, BlackHole, or a microphone", "Loopback, BlackHole ou micro", "Loopback, BlackHole o micrófono", "Loopback, BlackHole oder Mikrofon") }
    var recognitionLanguage: String { value("识别语言", "認識言語", "Recognition language", "Langue de reconnaissance", "Idioma de reconocimiento", "Erkennungssprache") }
    var recognitionEngine: String { value("识别引擎", "認識エンジン", "Recognition engine", "Moteur de reconnaissance", "Motor de reconocimiento", "Erkennungsmodell") }
    var engineHelp: String { value("如何选择识别引擎", "認識エンジンの選び方", "Choosing an engine", "Choisir un moteur", "Elegir un motor", "Modell auswählen") }
    var fastEngine: String { value("高速", "高速", "Fast", "Rapide", "Rápido", "Schnell") }
    var accurateEngine: String { value("高精度", "高精度", "Accurate", "Précis", "Preciso", "Genau") }
    var fastEngineDescription: String { value("Large v3 Turbo。响应更快，适合实时字幕和配置较低的 Mac。", "Large v3 Turbo。応答が速く、リアルタイム字幕や処理性能を抑えたい場合に適しています。", "Large v3 Turbo. Faster responses for live captions and lower processing load.", "Large v3 Turbo. Réponses plus rapides pour les sous-titres en direct et une charge réduite.", "Large v3 Turbo. Respuestas más rápidas para subtítulos en directo y menor carga.", "Large v3 Turbo. Schnellere Antworten für Live-Untertitel bei geringerer Last.") }
    var accurateEngineDescription: String { value("完整 Large v3。中日英识别更准确，但响应较慢、资源占用更高。", "完全版 Large v3。中国語・日本語・英語の精度を優先しますが、処理は遅くなります。", "Full Large v3. Better Chinese, Japanese, and English accuracy at the cost of speed.", "Large v3 complet. Meilleure précision en chinois, japonais et anglais, au prix de la vitesse.", "Large v3 completo. Mayor precisión en chino, japonés e inglés a costa de la velocidad.", "Vollständiges Large v3. Höhere Genauigkeit für Chinesisch, Japanisch und Englisch, dafür langsamer.") }
    var engineDownloadHint: String { value("首次选择高精度时需要下载约 626 MB，之后会使用本地缓存。", "高精度を初めて選ぶと約626 MBをダウンロードし、以降はローカルキャッシュを使用します。", "Accurate mode downloads about 626 MB once, then uses the local cache.", "Le mode précis télécharge environ 626 Mo une fois, puis utilise le cache local.", "El modo preciso descarga unos 626 MB una vez y luego usa la caché local.", "Der genaue Modus lädt einmalig etwa 626 MB und nutzt danach den lokalen Cache.") }
    var interfaceLanguage: String { value("界面语言", "表示言語", "Interface language", "Langue de l'interface", "Idioma de la interfaz", "Sprache der Oberfläche") }
    /// Shown under the language row in English whatever language is active, so the row can
    /// always be found; nil when the interface is already in English.
    var interfaceLanguageHint: String? { language == .english ? nil : "Language" }
    var timestamp: String { value("时间戳", "タイムスタンプ", "Timestamp", "Horodatage", "Marca de tiempo", "Zeitstempel") }
    var relativeTime: String { value("相对时间", "相対時間", "Relative", "Relatif", "Relativo", "Relativ") }
    var currentTime: String { value("当前时间", "現在時刻", "Clock time", "Heure", "Hora", "Uhrzeit") }
    var showDate: String { value("显示日期", "日付を表示", "Show date", "Afficher la date", "Mostrar fecha", "Datum anzeigen") }
    var energyThreshold: String { value("能量阈值", "音量しきい値", "Energy threshold", "Seuil d'énergie", "Umbral de energía", "Energieschwelle") }
    var energyThresholdHint: String { value("声音低于此值不会识别。调低可捕捉较小的声音，但更容易误触发。", "これより小さい音は認識しません。下げると小さな音も拾いますが誤検出が増えます。", "Sound below this is ignored. Lower it to catch quiet audio at the cost of false triggers.", "Les sons sous ce niveau sont ignorés. Baissez-le pour capter les sons faibles, au risque de faux déclenchements.", "El sonido por debajo de este nivel se ignora. Bájalo para captar audio débil, con más falsos positivos.", "Töne unter diesem Wert werden ignoriert. Senken, um leise Signale zu erfassen, mit mehr Fehlauslösungen.") }
    var noiseReduction: String { value("降噪", "ノイズ低減", "Noise reduction", "Réduction du bruit", "Reducción de ruido", "Rauschunterdrückung") }
    var noiseReductionHint: String { value("从输入中减去采集到的背景噪音，再送去识别。", "測定した背景ノイズを入力から差し引いてから認識します。", "Subtracts the measured background noise from the input before recognition.", "Soustrait le bruit de fond mesuré de l'entrée avant la reconnaissance.", "Resta el ruido de fondo medido de la entrada antes del reconocimiento.", "Zieht das gemessene Hintergrundgeräusch vor der Erkennung vom Eingang ab.") }
    var noiseReductionNeedsProfile: String { value("先采集背景噪音。", "まず背景ノイズを測定してください。", "Measure the background noise first.", "Mesurez d'abord le bruit de fond.", "Mide primero el ruido de fondo.", "Zuerst das Hintergrundgeräusch messen.") }
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
    var ready: String { value("就绪", "準備完了", "Ready", "Prêt", "Listo", "Bereit") }
    var recognizing: String { value("正在识别", "認識中", "Recognizing", "Reconnaissance", "Reconociendo", "Erkennung läuft") }
    var retry: String { value("重试", "再試行", "Retry", "Réessayer", "Reintentar", "Erneut versuchen") }
    var results: String { "Voiced" }
    var copyAll: String { value("复制全部", "すべてコピー", "Copy all", "Tout copier", "Copiar todo", "Alles kopieren") }
    var copied: String { value("已复制", "コピーしました", "Copied", "Copié", "Copiado", "Kopiert") }
    var clear: String { value("清空", "消去", "Clear", "Effacer", "Borrar", "Leeren") }
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
