//
//  ReaderSpeechController.swift
//  Aidoku (iOS)
//
//  Microsoft neural text-to-speech support for the native text reader.
//

import AVFoundation
import AidokuRunner
import Combine
import Security
import SwiftUI
import UniformTypeIdentifiers
import ZIPFoundation

struct ReaderSpeechSegment: Identifiable, Sendable {
    let id: String
    let chapterKey: String
    let pageIndex: Int
    let text: String
}

@MainActor
protocol ReaderSpeechTextProviding: AnyObject {
    func speechSegmentsFromCurrentPosition() -> [ReaderSpeechSegment]
    func revealSpeechSegment(_ segment: ReaderSpeechSegment)
}

enum ReaderSpeechTextExtractor {
    static func text(from page: Page) -> String? {
        if let text = page.text {
            return text
        }

        guard
            let zipURLString = page.zipURL,
            let zipURL = URL(string: zipURLString),
            let filePath = page.imageURL
        else {
            return nil
        }

        do {
            var data = Data()
            let archive = try Archive(url: zipURL, accessMode: .read)
            guard let entry = archive.entry(at: filePath) else { return nil }
            _ = try archive.extract(entry, consumer: { readData in
                data.append(readData)
            })
            return String(data: data, encoding: .utf8)
        } catch {
            LogManager.logger.error("Unable to load text for speech: \(error)")
            return nil
        }
    }

    static func text(from page: AidokuRunner.Page) -> String? {
        switch page.content {
            case let .text(text):
                return text
            case let .zipFile(url, filePath):
                return text(fromZip: url, filePath: filePath)
            case .url, .image:
                return nil
        }
    }

    private static func text(fromZip zipURL: URL, filePath: String) -> String? {
        do {
            var data = Data()
            let archive = try Archive(url: zipURL, accessMode: .read)
            guard let entry = archive.entry(at: filePath) else { return nil }
            _ = try archive.extract(entry, consumer: { readData in
                data.append(readData)
            })
            return String(data: data, encoding: .utf8)
        } catch {
            LogManager.logger.error("Unable to load text for speech: \(error)")
            return nil
        }
    }
}

enum MicrosoftSpeechVoice: String, CaseIterable, Identifiable, Sendable {
    case xiaoxiao = "zh-CN-XiaoxiaoNeural"
    case yunxi = "zh-CN-YunxiNeural"

    var id: String { rawValue }

    var title: String {
        switch self {
            case .xiaoxiao: readerSpeechLocalized("MICROSOFT_TTS_XIAOXIAO", fallback: "晓晓（女声）")
            case .yunxi: readerSpeechLocalized("MICROSOFT_TTS_YUNXI", fallback: "云希（男声）")
        }
    }
}

@MainActor
final class ReaderSpeechSettingsStore: ObservableObject {
    static let shared = ReaderSpeechSettingsStore()

    @Published var provider: ReaderSpeechProvider {
        didSet { UserDefaults.standard.set(provider.rawValue, forKey: Self.providerKey) }
    }
    @Published var region: String {
        didSet { UserDefaults.standard.set(region, forKey: Self.regionKey) }
    }
    @Published var voice: MicrosoftSpeechVoice {
        didSet { UserDefaults.standard.set(voice.rawValue, forKey: Self.voiceKey) }
    }
    @Published var rate: Double {
        didSet { UserDefaults.standard.set(rate, forKey: Self.rateKey) }
    }
    @Published var subscriptionKey: String {
        didSet { Self.storeSubscriptionKey(subscriptionKey) }
    }
    @Published var selectedModelId: String? {
        didSet { UserDefaults.standard.set(selectedModelId, forKey: Self.selectedModelKey) }
    }
    @Published var speaker: Int {
        didSet { UserDefaults.standard.set(speaker, forKey: Self.speakerKey) }
    }

    var isConfigured: Bool {
        switch provider {
            case .microsoft:
                !region.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && !subscriptionKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .local:
                ReaderSpeechModelManager.shared.model(id: selectedModelId) != nil
        }
    }

    private static let providerKey = "Reader.speechProvider"
    private static let regionKey = "Reader.microsoftSpeechRegion"
    private static let voiceKey = "Reader.microsoftSpeechVoice"
    private static let rateKey = "Reader.microsoftSpeechRate"
    private static let selectedModelKey = "Reader.localSpeechModel"
    private static let speakerKey = "Reader.localSpeechSpeaker"
    private static let keychainService = "app.aidoku.reader.microsoft-speech"
    private static let keychainAccount = "subscription-key"

    private init() {
        provider = UserDefaults.standard.string(forKey: Self.providerKey)
            .flatMap(ReaderSpeechProvider.init(rawValue:)) ?? .microsoft
        region = UserDefaults.standard.string(forKey: Self.regionKey) ?? ""
        voice = UserDefaults.standard.string(forKey: Self.voiceKey)
            .flatMap(MicrosoftSpeechVoice.init(rawValue:)) ?? .xiaoxiao
        let storedRate = UserDefaults.standard.object(forKey: Self.rateKey) as? Double
        rate = min(1.6, max(0.6, storedRate ?? 1.0))
        subscriptionKey = Self.loadSubscriptionKey()
        selectedModelId = UserDefaults.standard.string(forKey: Self.selectedModelKey)
        speaker = max(0, UserDefaults.standard.integer(forKey: Self.speakerKey))
    }

    func makeEngine() throws -> any ReaderSpeechEngine {
        switch provider {
            case .microsoft:
                return ReaderMicrosoftSpeechEngine(
                    region: region.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                    subscriptionKey: subscriptionKey.trimmingCharacters(in: .whitespacesAndNewlines),
                    voice: voice
                )
            case .local:
                guard let model = ReaderSpeechModelManager.shared.model(id: selectedModelId) else {
                    throw ReaderSpeechModelError.missingModel
                }
                return ReaderLocalSpeechEngine(model: model)
        }
    }

    private static func loadSubscriptionKey() -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard
            SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
            let data = result as? Data,
            let value = String(data: data, encoding: .utf8)
        else {
            return ""
        }
        return value
    }

    private static func storeSubscriptionKey(_ value: String) {
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        SecItemDelete(identity as CFDictionary)
        guard !value.isEmpty, let data = value.data(using: .utf8) else { return }

        var item = identity
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        if status != errSecSuccess {
            LogManager.logger.error("Unable to store Microsoft Speech key: \(status)")
        }
    }
}

@MainActor
final class ReaderSpeechController: NSObject, ObservableObject {
    enum State: Equatable {
        case idle
        case loading
        case playing
        case paused
        case failed(String)
    }

    @Published private(set) var state: State = .idle {
        didSet { onStateChange?(state) }
    }
    @Published private(set) var progressText = ""

    var onStateChange: ((State) -> Void)?
    var revealSegment: ((ReaderSpeechSegment) -> Void)?
    var loadMoreSegments: ((String) async -> [ReaderSpeechSegment])?

    private struct SpeechUnit {
        let segment: ReaderSpeechSegment
        let chunkIndex: Int
        let chunkCount: Int
        let text: String
    }

    private var units: [SpeechUnit] = []
    private var unitIndex = 0
    private var player: AVAudioPlayer?
    private var synthesisTask: Task<Void, Never>?
    private var audioCache: [String: Data] = [:]

    var isActive: Bool {
        switch state {
            case .idle, .failed: false
            case .loading, .playing, .paused: true
        }
    }

    func start(segments: [ReaderSpeechSegment], settings: ReaderSpeechSettingsStore) {
        stop()
        guard settings.isConfigured else {
            state = .failed(readerSpeechLocalized(
                "MICROSOFT_TTS_CONFIGURATION_REQUIRED",
                fallback: settings.provider == .microsoft
                    ? "请先填写 Azure Speech 区域和密钥。"
                    : "请先导入并选择一个本地语音模型。"
            ))
            return
        }

        units = Self.speechUnits(from: segments)
        guard !units.isEmpty else {
            state = .failed(readerSpeechLocalized(
                "MICROSOFT_TTS_NO_TEXT",
                fallback: "当前位置没有可朗读的文字。"
            ))
            return
        }

        unitIndex = 0
        playCurrentUnit(settings: settings)
    }

    private static func speechUnits(from segments: [ReaderSpeechSegment]) -> [SpeechUnit] {
        segments.flatMap { segment in
            let chunks = Self.chunks(from: segment.text)
            return chunks.enumerated().map { index, chunk in
                SpeechUnit(
                    segment: segment,
                    chunkIndex: index,
                    chunkCount: chunks.count,
                    text: chunk
                )
            }
        }
    }

    func pause() {
        guard state == .playing else { return }
        player?.pause()
        state = .paused
    }

    func resume(settings: ReaderSpeechSettingsStore) {
        guard state == .paused else { return }
        if let player {
            player.play()
            state = .playing
        } else {
            playCurrentUnit(settings: settings)
        }
    }

    func togglePlayback(
        segments: [ReaderSpeechSegment],
        settings: ReaderSpeechSettingsStore
    ) {
        switch state {
            case .playing: pause()
            case .paused: resume(settings: settings)
            case .idle, .failed: start(segments: segments, settings: settings)
            case .loading: break
        }
    }

    func stop() {
        synthesisTask?.cancel()
        synthesisTask = nil
        player?.stop()
        player = nil
        units = []
        unitIndex = 0
        progressText = ""
        state = .idle
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func playCurrentUnit(settings: ReaderSpeechSettingsStore) {
        guard units.indices.contains(unitIndex) else {
            loadNextBatch(settings: settings)
            return
        }

        let unit = units[unitIndex]
        if unitIndex == 0 || units[unitIndex - 1].segment.id != unit.segment.id {
            revealSegment?(unit.segment)
        }
        progressText = String(
            format: readerSpeechLocalized("MICROSOFT_TTS_PROGRESS", fallback: "第 %d/%d 段"),
            unitIndex + 1,
            units.count
        )
        state = .loading

        let rate = settings.rate
        let speaker = settings.speaker

        let engine: any ReaderSpeechEngine
        do {
            engine = try settings.makeEngine()
        } catch {
            state = .failed(error.localizedDescription)
            return
        }
        let cacheKey = "\(engine.cacheIdentifier)|\(speaker)|\(rate)|\(unit.text)"

        synthesisTask?.cancel()
        synthesisTask = Task { [weak self] in
            guard let self else { return }
            do {
                let data: Data
                if let cached = audioCache[cacheKey] {
                    data = cached
                } else {
                    data = try await engine.synthesize(.init(text: unit.text, rate: rate, speaker: speaker))
                    guard !Task.isCancelled else { return }
                    audioCache[cacheKey] = data
                }
                guard !Task.isCancelled else { return }
                try beginPlayback(data: data)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                state = .failed(error.localizedDescription)
                player = nil
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
        }
    }

    private func loadNextBatch(settings: ReaderSpeechSettingsStore) {
        guard let chapterKey = units.last?.segment.chapterKey, let loadMoreSegments else {
            finish()
            return
        }
        state = .loading
        progressText = readerSpeechLocalized("MICROSOFT_TTS_LOADING_NEXT", fallback: "正在读取下一章")
        synthesisTask?.cancel()
        synthesisTask = Task { [weak self] in
            guard let self else { return }
            let segments = await loadMoreSegments(chapterKey)
            guard !Task.isCancelled else { return }
            let additionalUnits = Self.speechUnits(from: segments)
            guard !additionalUnits.isEmpty else {
                finish()
                return
            }
            units.append(contentsOf: additionalUnits)
            synthesisTask = nil
            playCurrentUnit(settings: settings)
        }
    }

    private func beginPlayback(data: Data) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try session.setActive(true)

        let player = try AVAudioPlayer(data: data)
        player.delegate = self
        player.prepareToPlay()
        self.player = player
        guard player.play() else {
            throw ReaderSpeechError.playbackFailed
        }
        state = .playing
    }

    private func advance() {
        player = nil
        unitIndex += 1
        playCurrentUnit(settings: .shared)
    }

    private func finish() {
        player = nil
        progressText = readerSpeechLocalized("MICROSOFT_TTS_CHAPTER_FINISHED", fallback: "本章朗读完成")
        state = .idle
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private static func chunks(from markdown: String, limit: Int = 420) -> [String] {
        let plainText: String
        if let attributed = try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .full)
        ) {
            plainText = String(attributed.characters)
        } else {
            plainText = markdown
        }

        let normalized = plainText
            .replacingOccurrences(
                of: #"!\[[^\]]*\]\([^\)]*\)"#,
                with: " ",
                options: .regularExpression
            )
            .replacingOccurrences(of: "\u{FFFC}", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }

        var sentences: [String] = []
        normalized.enumerateSubstrings(
            in: normalized.startIndex..<normalized.endIndex,
            options: [.bySentences, .substringNotRequired]
        ) { _, range, _, _ in
            let sentence = String(normalized[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty { sentences.append(sentence) }
        }
        if sentences.isEmpty { sentences = [normalized] }

        var result: [String] = []
        var current = ""
        for sentence in sentences {
            if sentence.count > limit {
                if !current.isEmpty {
                    result.append(current)
                    current = ""
                }
                var remainder = sentence[...]
                while !remainder.isEmpty {
                    let end = remainder.index(remainder.startIndex, offsetBy: min(limit, remainder.count))
                    result.append(String(remainder[..<end]))
                    remainder = remainder[end...]
                }
            } else if current.count + sentence.count + 1 <= limit {
                current += current.isEmpty ? sentence : " \(sentence)"
            } else {
                result.append(current)
                current = sentence
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}

extension ReaderSpeechController: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if flag {
                advance()
            } else {
                state = .failed(ReaderSpeechError.playbackFailed.localizedDescription)
            }
        }
    }
}

enum MicrosoftSpeechService {
    static func synthesize(
        text: String,
        region: String,
        subscriptionKey: String,
        voice: MicrosoftSpeechVoice,
        rate: Double
    ) async throws -> Data {
        guard region.range(of: #"^[a-z0-9-]+$"#, options: .regularExpression) != nil else {
            throw ReaderSpeechError.invalidRegion
        }
        guard let url = URL(string: "https://\(region).tts.speech.microsoft.com/cognitiveservices/v1") else {
            throw ReaderSpeechError.invalidRegion
        }

        let ratePercent = Int(((rate - 1) * 100).rounded())
        let rateValue = ratePercent >= 0 ? "+\(ratePercent)%" : "\(ratePercent)%"
        let escapedText = text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
        let ssml = """
        <speak version="1.0" xmlns="http://www.w3.org/2001/10/synthesis" xml:lang="zh-CN">
          <voice name="\(voice.rawValue)"><prosody rate="\(rateValue)">\(escapedText)</prosody></voice>
        </speak>
        """

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data(ssml.utf8)
        request.setValue(subscriptionKey, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
        request.setValue("application/ssml+xml", forHTTPHeaderField: "Content-Type")
        request.setValue("audio-24khz-48kbitrate-mono-mp3", forHTTPHeaderField: "X-Microsoft-OutputFormat")
        request.setValue("Aidoku-Reader", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ReaderSpeechError.invalidResponse
        }
        guard http.statusCode == 200 else {
            let detail = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ReaderSpeechError.service(statusCode: http.statusCode, detail: detail)
        }
        guard !data.isEmpty else { throw ReaderSpeechError.invalidResponse }
        return data
    }
}

enum ReaderSpeechError: LocalizedError {
    case invalidRegion
    case invalidResponse
    case playbackFailed
    case service(statusCode: Int, detail: String?)

    var errorDescription: String? {
        switch self {
            case .invalidRegion:
                readerSpeechLocalized("MICROSOFT_TTS_INVALID_REGION", fallback: "Azure 区域格式不正确。")
            case .invalidResponse:
                readerSpeechLocalized("MICROSOFT_TTS_INVALID_RESPONSE", fallback: "微软语音返回了无效音频。")
            case .playbackFailed:
                readerSpeechLocalized("MICROSOFT_TTS_PLAYBACK_FAILED", fallback: "语音播放失败。")
            case let .service(statusCode, detail):
                switch statusCode {
                    case 401:
                        readerSpeechLocalized(
                            "MICROSOFT_TTS_UNAUTHORIZED",
                            fallback: "Azure 密钥或区域不匹配（401）。"
                        )
                    case 429:
                        readerSpeechLocalized(
                            "MICROSOFT_TTS_RATE_LIMITED",
                            fallback: "微软语音请求过多或额度不足（429），请稍后重试。"
                        )
                    default:
                        detail?.isEmpty == false
                            ? "Microsoft Speech \(statusCode): \(detail!)"
                            : "Microsoft Speech HTTP \(statusCode)"
                }
        }
    }
}

@MainActor
struct ReaderSpeechControlView: View {
    @ObservedObject var controller: ReaderSpeechController
    @ObservedObject private var settings = ReaderSpeechSettingsStore.shared
    @ObservedObject private var modelManager = ReaderSpeechModelManager.shared
    let segments: () async -> [ReaderSpeechSegment]

    @Environment(\.dismiss) private var dismiss
    @State private var showingModelImporter = false
    @State private var isLoadingSegments = false

    var body: some View {
        PlatformNavigationStack {
            Form {
                Section {
                    Picker("TTS", selection: $settings.provider) {
                        ForEach(ReaderSpeechProvider.allCases) { provider in
                            Text(provider.title).tag(provider)
                        }
                    }
                }

                if settings.provider == .microsoft {
                    microsoftSettings
                } else {
                    localModelSettings
                }

                Section {
                    if settings.provider == .microsoft {
                        Picker(readerSpeechLocalized("MICROSOFT_TTS_VOICE", fallback: "音色"), selection: $settings.voice) {
                            ForEach(MicrosoftSpeechVoice.allCases) { voice in
                                Text(voice.title).tag(voice)
                            }
                        }
                    } else if
                       let model = modelManager.model(id: settings.selectedModelId),
                       model.speakerCount > 1 {
                        Stepper(
                            "说话人 \(min(settings.speaker + 1, model.speakerCount))/\(model.speakerCount)",
                            value: $settings.speaker,
                            in: 0...(model.speakerCount - 1)
                        )
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(readerSpeechLocalized("MICROSOFT_TTS_RATE", fallback: "语速"))
                            Spacer()
                            Text(String(format: "%.1fx", settings.rate)).foregroundStyle(.secondary)
                        }
                        Slider(value: $settings.rate, in: 0.6...1.6, step: 0.1)
                    }
                }

                Section {
                    if !controller.progressText.isEmpty {
                        Text(controller.progressText).foregroundStyle(.secondary)
                    }
                    if case let .failed(message) = controller.state {
                        Text(message).foregroundStyle(.red)
                    }

                    HStack(spacing: 12) {
                        Button {
                            if controller.isActive {
                                controller.togglePlayback(segments: [], settings: settings)
                            } else {
                                isLoadingSegments = true
                                Task {
                                    let loadedSegments = await segments()
                                    controller.togglePlayback(segments: loadedSegments, settings: settings)
                                    isLoadingSegments = false
                                }
                            }
                        } label: {
                            Label(playButtonTitle, systemImage: playButtonImage)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(
                            isLoadingSegments
                                || controller.state == .loading
                                || (!settings.isConfigured && !controller.isActive)
                        )

                        Button(role: .destructive) {
                            controller.stop()
                        } label: {
                            Label(readerSpeechLocalized("MICROSOFT_TTS_STOP", fallback: "停止"), systemImage: "stop.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(!controller.isActive)
                    }
                } header: {
                    Text(readerSpeechLocalized("MICROSOFT_TTS_PLAYBACK", fallback: "播放"))
                } footer: {
                    Text(readerSpeechLocalized(
                        "MICROSOFT_TTS_FOREGROUND_ONLY",
                        fallback: "当前稳定版只支持前台播放，并从当前文字位置朗读到本章末尾。"
                    ))
                }
            }
            .navigationTitle(readerSpeechLocalized("MICROSOFT_TTS_TITLE", fallback: "语音读书"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(readerSpeechLocalized("DONE", fallback: "完成")) { dismiss() }
                }
            }
            .fileImporter(
                isPresented: $showingModelImporter,
                allowedContentTypes: [.zip, .folder],
                allowsMultipleSelection: false
            ) { result in
                guard case let .success(urls) = result, let url = urls.first else {
                    if case let .failure(error) = result { modelManager.importError = error.localizedDescription }
                    return
                }
                Task {
                    await modelManager.importModel(from: url)
                    if settings.selectedModelId == nil {
                        settings.selectedModelId = modelManager.models.last?.id
                    }
                }
            }
        }
    }

    private var microsoftSettings: some View {
        Section {
            TextField(
                readerSpeechLocalized("MICROSOFT_TTS_REGION", fallback: "Azure 区域，例如 eastasia"),
                text: $settings.region
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            SecureField(
                readerSpeechLocalized("MICROSOFT_TTS_KEY", fallback: "Azure Speech 密钥"),
                text: $settings.subscriptionKey
            )
            .textContentType(.password)
        } header: {
            Text(readerSpeechLocalized("MICROSOFT_TTS_SERVICE", fallback: "微软 Azure 语音"))
        } footer: {
            Text(readerSpeechLocalized(
                "MICROSOFT_TTS_KEY_INFO",
                fallback: "密钥只保存在本机钥匙串。正文会发送给微软在线合成。"
            ))
        }
    }

    private var localModelSettings: some View {
        Section {
            if modelManager.models.isEmpty {
                Text("尚未导入本地语音模型").foregroundStyle(.secondary)
            } else {
                Picker("模型", selection: $settings.selectedModelId) {
                    Text("请选择").tag(String?.none)
                    ForEach(modelManager.models) { model in
                        Text(model.name).tag(Optional(model.id))
                    }
                }
                if let selected = modelManager.model(id: settings.selectedModelId) {
                    Button(role: .destructive) {
                        try? modelManager.delete(selected)
                        settings.selectedModelId = modelManager.models.first?.id
                    } label: {
                        Label("删除当前模型", systemImage: "trash")
                    }
                }
            }
            Button {
                showingModelImporter = true
            } label: {
                Label(
                    modelManager.isImporting ? "正在导入…" : "导入本地模型包",
                    systemImage: "square.and.arrow.down"
                )
            }
            .disabled(modelManager.isImporting)

            if let error = modelManager.importError {
                Text(error).foregroundStyle(.red)
            }
        } header: {
            Text("本地离线语音")
        } footer: {
            Text("支持 sherpa-onnx 的 VITS、Matcha 和 Kokoro 模型目录或 ZIP。模型保存在本机，不会写入 IPA。")
        }
    }

    private var playButtonTitle: String {
        switch controller.state {
            case .playing:
                readerSpeechLocalized("MICROSOFT_TTS_PAUSE", fallback: "暂停")
            case .paused:
                readerSpeechLocalized("MICROSOFT_TTS_RESUME", fallback: "继续")
            case .loading:
                readerSpeechLocalized("MICROSOFT_TTS_LOADING", fallback: "正在合成")
            case .idle, .failed:
                isLoadingSegments
                    ? readerSpeechLocalized("MICROSOFT_TTS_LOADING_TEXT", fallback: "正在读取正文")
                    : readerSpeechLocalized("MICROSOFT_TTS_START", fallback: "开始朗读")
        }
    }

    private var playButtonImage: String {
        switch controller.state {
            case .playing: "pause.fill"
            case .loading: "waveform"
            case .paused, .idle, .failed: "play.fill"
        }
    }
}

func readerSpeechLocalized(_ key: String, fallback: String) -> String {
    NSLocalizedString(key, tableName: nil, bundle: .main, value: fallback, comment: "")
}
