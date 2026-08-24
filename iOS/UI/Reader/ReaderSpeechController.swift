//
//  ReaderSpeechController.swift
//  Aidoku (iOS)
//
//  Microsoft neural text-to-speech support for the native text reader.
//

import AVFoundation
import AidokuRunner
import Combine
import CryptoKit
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
    @Published var voice: MicrosoftSpeechVoice {
        didSet { UserDefaults.standard.set(voice.rawValue, forKey: Self.voiceKey) }
    }
    @Published var rate: Double {
        didSet { UserDefaults.standard.set(rate, forKey: Self.rateKey) }
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
                true
            case .local:
                ReaderSpeechModelManager.shared.model(id: selectedModelId) != nil
        }
    }

    var configurationMessage: String {
        switch provider {
            case .microsoft:
                ""
            case .local:
                readerSpeechLocalized(
                    "LOCAL_TTS_CONFIGURATION_REQUIRED",
                    fallback: "请先导入并选择一个本地语音模型。"
                )
        }
    }

    private static let providerKey = "Reader.speechProvider"
    private static let voiceKey = "Reader.microsoftSpeechVoice"
    private static let rateKey = "Reader.microsoftSpeechRate"
    private static let selectedModelKey = "Reader.localSpeechModel"
    private static let speakerKey = "Reader.localSpeechSpeaker"

    private init() {
        provider = UserDefaults.standard.string(forKey: Self.providerKey)
            .flatMap(ReaderSpeechProvider.init(rawValue:)) ?? .microsoft
        voice = UserDefaults.standard.string(forKey: Self.voiceKey)
            .flatMap(MicrosoftSpeechVoice.init(rawValue:)) ?? .xiaoxiao
        let storedRate = UserDefaults.standard.object(forKey: Self.rateKey) as? Double
        rate = min(1.6, max(0.6, storedRate ?? 1.0))
        selectedModelId = UserDefaults.standard.string(forKey: Self.selectedModelKey)
        speaker = max(0, UserDefaults.standard.integer(forKey: Self.speakerKey))
    }

    func makeEngine() throws -> any ReaderSpeechEngine {
        switch provider {
            case .microsoft:
                return ReaderMicrosoftSpeechEngine(voice: voice)
            case .local:
                guard let model = ReaderSpeechModelManager.shared.model(id: selectedModelId) else {
                    throw ReaderSpeechModelError.missingModel
                }
                return ReaderLocalSpeechEngine(model: model)
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
    private var prefetchTask: Task<Void, Never>?
    private var prefetchedAudio: [Int: Data] = [:]
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
            state = .failed(settings.configurationMessage)
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
        prefetchTask?.cancel()
        prefetchTask = nil
        player?.stop()
        player = nil
        units = []
        prefetchedAudio = [:]
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
        // The reader is already showing the position used to create the first
        // speech segment. Revealing it again can move a scrolling text page back
        // to the beginning, so only follow the reader after playback advances.
        if unitIndex > 0, units[unitIndex - 1].segment.id != unit.segment.id {
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
                if let prefetched = prefetchedAudio.removeValue(forKey: unitIndex) {
                    data = prefetched
                } else if let cached = audioCache[cacheKey] {
                    data = cached
                } else {
                    prefetchTask?.cancel()
                    prefetchTask = nil
                    data = try await engine.synthesize(.init(text: unit.text, rate: rate, speaker: speaker))
                    guard !Task.isCancelled else { return }
                    audioCache[cacheKey] = data
                }
                guard !Task.isCancelled else { return }
                try beginPlayback(data: data)
                prefetchNextUnit(after: unitIndex, settings: settings)
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

    private func prefetchNextUnit(after currentIndex: Int, settings: ReaderSpeechSettingsStore) {
        let nextIndex = currentIndex + 1
        guard units.indices.contains(nextIndex), prefetchedAudio[nextIndex] == nil else { return }
        let unit = units[nextIndex]
        let rate = settings.rate
        let speaker = settings.speaker
        guard let engine = try? settings.makeEngine() else { return }
        let cacheKey = "\(engine.cacheIdentifier)|\(speaker)|\(rate)|\(unit.text)"

        prefetchTask?.cancel()
        prefetchTask = Task { [weak self] in
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
                guard !Task.isCancelled, units.indices.contains(nextIndex), units[nextIndex].text == unit.text else {
                    return
                }
                prefetchedAudio[nextIndex] = data
            } catch {
                // Prefetch is an optimization only. Normal playback will retry
                // synthesis and surface an error if it also fails.
            }
        }
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
    private static let trustedClientToken = "6A5AA1D4EAFF4E9FB37E23D68491D6F4"
    private static let chromiumVersion = "143.0.3650.75"
    private static let gecVersion = "1-143.0.3650.75"
    private static let endpoint = "wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1"

    static func synthesize(
        text: String,
        voice: MicrosoftSpeechVoice,
        rate: Double
    ) async throws -> Data {
        let connectionId = identifier()
        let requestId = identifier()
        var components = URLComponents(string: endpoint)
        components?.queryItems = [
            URLQueryItem(name: "TrustedClientToken", value: trustedClientToken),
            URLQueryItem(name: "ConnectionId", value: connectionId),
            URLQueryItem(name: "Sec-MS-GEC", value: securityToken()),
            URLQueryItem(name: "Sec-MS-GEC-Version", value: gecVersion)
        ]
        guard let url = components?.url else { throw ReaderSpeechError.invalidResponse }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue(
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
                + "(KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36 Edg/\(chromiumVersion)",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        request.setValue("chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold", forHTTPHeaderField: "Origin")
        request.setValue("muid=\(identifier().uppercased())", forHTTPHeaderField: "Cookie")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        let session = URLSession(configuration: configuration)
        let socket = session.webSocketTask(with: request)
        socket.resume()
        defer {
            socket.cancel(with: .normalClosure, reason: nil)
            session.invalidateAndCancel()
        }

        let ratePercent = Int(((rate - 1) * 100).rounded())
        let rateValue = ratePercent >= 0 ? "+\(ratePercent)%" : "\(ratePercent)%"
        let requestTimestamp = timestamp()
        let speechConfig = """
        X-Timestamp:\(requestTimestamp)\r
        Content-Type:application/json; charset=utf-8\r
        Path:speech.config\r
        \r
        {"context":{"synthesis":{"audio":{"metadataoptions":{"sentenceBoundaryEnabled":"false","wordBoundaryEnabled":"false"},"outputFormat":"audio-24khz-48kbitrate-mono-mp3"}}}}
        """
        let ssmlBody = "<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='zh-CN'>"
            + "<voice name='\(voice.rawValue)'><prosody pitch='+0Hz' rate='\(rateValue)' volume='+0%'>"
            + "\(xmlEscaped(text))</prosody></voice></speak>"
        let ssml = """
        X-RequestId:\(requestId)\r
        Content-Type:application/ssml+xml\r
        X-Timestamp:\(requestTimestamp)Z\r
        Path:ssml\r
        \r
        \(ssmlBody)
        """

        do {
            try await socket.send(.string(speechConfig))
            try await socket.send(.string(ssml))
        } catch {
            throw ReaderSpeechError.freeServiceUnavailable(detail: error.localizedDescription)
        }

        var audio = Data()
        while !Task.isCancelled {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await socket.receive()
            } catch {
                throw ReaderSpeechError.freeServiceUnavailable(detail: error.localizedDescription)
            }

            switch message {
                case let .data(data):
                    if let chunk = audioPayload(from: data) {
                        audio.append(chunk)
                    }
                case let .string(text):
                    if messagePath(in: text) == "turn.end" {
                        guard !audio.isEmpty else { throw ReaderSpeechError.invalidResponse }
                        return audio
                    }
                @unknown default:
                    break
            }
        }
        throw CancellationError()
    }

    private static func identifier() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    private static func securityToken(date: Date = Date()) -> String {
        let windowsEpochOffset: Int64 = 11_644_473_600
        let unixSeconds = Int64(date.timeIntervalSince1970)
        let roundedSeconds = ((unixSeconds + windowsEpochOffset) / 300) * 300
        let ticks = roundedSeconds * 10_000_000
        let input = Data("\(ticks)\(trustedClientToken)".utf8)
        return SHA256.hash(data: input).map { String(format: "%02X", $0) }.joined()
    }

    private static func timestamp(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE MMM dd yyyy HH:mm:ss 'GMT+0000 (Coordinated Universal Time)'"
        return formatter.string(from: date)
    }

    private static func xmlEscaped(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private static func audioPayload(from data: Data) -> Data? {
        guard data.count >= 2 else { return nil }
        let headerLength = (Int(data[data.startIndex]) << 8) | Int(data[data.startIndex + 1])
        let headerStart = data.startIndex + 2
        let payloadStart = headerStart + headerLength
        guard payloadStart <= data.endIndex else { return nil }
        let headerData = data[headerStart..<payloadStart]
        guard
            let headers = String(data: headerData, encoding: .utf8),
            messagePath(in: headers) == "audio"
        else {
            return nil
        }
        return Data(data[payloadStart...])
    }

    private static func messagePath(in headers: String) -> String? {
        guard let line = headers
            .components(separatedBy: "\r\n")
            .first(where: { $0.lowercased().hasPrefix("path:") })
        else {
            return nil
        }
        return String(line.dropFirst("path:".count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}

enum ReaderSpeechError: LocalizedError {
    case invalidResponse
    case playbackFailed
    case freeServiceUnavailable(detail: String?)

    var errorDescription: String? {
        switch self {
            case .invalidResponse:
                return readerSpeechLocalized("MICROSOFT_TTS_INVALID_RESPONSE", fallback: "微软语音返回了无效音频。")
            case .playbackFailed:
                return readerSpeechLocalized("MICROSOFT_TTS_PLAYBACK_FAILED", fallback: "语音播放失败。")
            case let .freeServiceUnavailable(detail):
                let message = readerSpeechLocalized(
                    "MICROSOFT_TTS_FREE_UNAVAILABLE",
                    fallback: "微软免费在线语音暂时不可用，请检查网络后重试。"
                )
                return detail?.isEmpty == false ? "\(message)（\(detail!)）" : message
        }
    }
}

@MainActor
struct ReaderSpeechControlView: View {
    @ObservedObject var controller: ReaderSpeechController
    @ObservedObject private var settings = ReaderSpeechSettingsStore.shared
    @ObservedObject private var modelManager = ReaderSpeechModelManager.shared
    let segments: () async -> [ReaderSpeechSegment]
    let onDone: () -> Void

    @State private var showingModelImporter = false
    @State private var isLoadingSegments = false

    var body: some View {
        PlatformNavigationStack {
            Form {
                Section {
                    Picker(readerSpeechLocalized("READER_TTS_ENGINE", fallback: "语音引擎"), selection: $settings.provider) {
                        ForEach(ReaderSpeechProvider.allCases) { provider in
                            Text(provider.title).tag(provider)
                        }
                    }
                }

                if settings.provider == .microsoft {
                    microsoftOnlineSettings
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
                    } else if !settings.isConfigured {
                        Text(settings.configurationMessage).foregroundStyle(.orange)
                    }

                    HStack(spacing: 12) {
                        Button {
                            if controller.isActive {
                                controller.togglePlayback(segments: [], settings: settings)
                            } else if !settings.isConfigured {
                                // Let the controller publish a visible, localized configuration error
                                // instead of presenting a button that silently appears to do nothing.
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
                    Button(readerSpeechLocalized("DONE", fallback: "完成"), action: onDone)
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

    private var microsoftOnlineSettings: some View {
        Section {
            Label(
                readerSpeechLocalized("MICROSOFT_TTS_FREE_READY", fallback: "无需账号或密钥，联网即可使用"),
                systemImage: "network"
            )
        } header: {
            Text(readerSpeechLocalized("MICROSOFT_TTS_SERVICE", fallback: "微软免费在线语音"))
        } footer: {
            Text(readerSpeechLocalized(
                "MICROSOFT_TTS_FREE_INFO",
                fallback: "正文会发送到微软 Edge 在线朗读服务生成语音；该免费接口可能随微软调整而变化。"
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
    // Aidoku's NSLocalizedString compatibility helper intentionally ignores the `value`
    // parameter, so missing keys otherwise leak into the UI as raw identifiers.
    let englishFallback = fallbackBundle?.localizedString(
        forKey: key,
        value: fallback,
        table: nil
    ) ?? fallback
    return Bundle.main.localizedString(
        forKey: key,
        value: englishFallback,
        table: nil
    )
}
