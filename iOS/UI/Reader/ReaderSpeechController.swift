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
import MediaPlayer
import SwiftUI
import UIKit
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
    func prepareSpeechSegments(for chapter: AidokuRunner.Chapter) async -> [ReaderSpeechSegment]
    @discardableResult func revealSpeechSegment(_ segment: ReaderSpeechSegment) -> Bool
    func setSpeechNavigationLocked(_ locked: Bool)
}

extension ReaderSpeechTextProviding {
    func prepareSpeechSegments(for chapter: AidokuRunner.Chapter) async -> [ReaderSpeechSegment] {
        []
    }
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
    case xiaoyi = "zh-CN-XiaoyiNeural"
    case xiaochen = "zh-CN-XiaochenNeural"
    case xiaohan = "zh-CN-XiaohanNeural"
    case yunxi = "zh-CN-YunxiNeural"
    case yunjian = "zh-CN-YunjianNeural"
    case yunyang = "zh-CN-YunyangNeural"
    case yunye = "zh-CN-YunyeNeural"

    var id: String { rawValue }

    var title: String {
        switch self {
            case .xiaoxiao: readerSpeechLocalized("MICROSOFT_TTS_XIAOXIAO", fallback: "晓晓（女声）")
            case .xiaoyi: readerSpeechLocalized("MICROSOFT_TTS_XIAOYI", fallback: "晓伊（女声）")
            case .xiaochen: readerSpeechLocalized("MICROSOFT_TTS_XIAOCHEN", fallback: "晓辰（女声）")
            case .xiaohan: readerSpeechLocalized("MICROSOFT_TTS_XIAOHAN", fallback: "晓涵（女声）")
            case .yunxi: readerSpeechLocalized("MICROSOFT_TTS_YUNXI", fallback: "云希（男声）")
            case .yunjian: readerSpeechLocalized("MICROSOFT_TTS_YUNJIAN", fallback: "云健（男声）")
            case .yunyang: readerSpeechLocalized("MICROSOFT_TTS_YUNYANG", fallback: "云扬（男声）")
            case .yunye: readerSpeechLocalized("MICROSOFT_TTS_YUNYE", fallback: "云野（男声）")
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
            case .microsoft, .system:
                true
            case .local:
                ReaderSpeechModelManager.shared.model(id: selectedModelId) != nil
        }
    }

    var configurationMessage: String {
        switch provider {
            case .microsoft, .system:
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
            case .system:
                throw ReaderSpeechError.systemVoiceUnavailable
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
        let text: String
    }

    private struct PrefetchedAudio {
        let cacheKey: String
        let data: Data
    }

    private var units: [SpeechUnit] = []
    private var unitIndex = 0
    private var player: AVAudioPlayer?
    private let systemSynthesizer = AVSpeechSynthesizer()
    private var synthesisTask: Task<Void, Never>?
    private var prefetchTask: Task<Void, Never>?
    private var prefetchedAudio: [Int: PrefetchedAudio] = [:]
    private var audioCache: [String: Data] = [:]
    private var notificationObservers: [NSObjectProtocol] = []
    private var remoteCommandTargets: [(command: MPRemoteCommand, target: Any)] = []
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid
    private var resumeAfterInterruption = false
    private var pauseRequested = false

    private static let speechUnitCharacterLimit = 420
    private static let prefetchUnitCount = 3

    override init() {
        super.init()
        systemSynthesizer.usesApplicationAudioSession = true
        systemSynthesizer.delegate = self
        observeAudioSession()
    }

    deinit {
        notificationObservers.forEach(NotificationCenter.default.removeObserver)
        remoteCommandTargets.forEach { $0.command.removeTarget($0.target) }
    }

    var isActive: Bool {
        switch state {
            case .idle, .failed: false
            case .loading, .playing, .paused: true
        }
    }

    var currentSegment: ReaderSpeechSegment? {
        guard units.indices.contains(unitIndex) else { return nil }
        return units[unitIndex].segment
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
        let fragments = segments.compactMap { segment -> (ReaderSpeechSegment, String)? in
            let text = normalizedSpeechText(from: segment.text)
            return text.isEmpty ? nil : (segment, text)
        }
        guard !fragments.isEmpty else { return [] }

        var combined = ""
        var anchors: [(offset: Int, segment: ReaderSpeechSegment)] = []
        for (segment, text) in fragments {
            if !combined.isEmpty {
                combined += boundarySeparator(previous: combined, next: text)
            }
            anchors.append((combined.count, segment))
            combined += text
        }

        var sentences: [(segment: ReaderSpeechSegment, text: String)] = []
        combined.enumerateSubstrings(
            in: combined.startIndex..<combined.endIndex,
            options: [.bySentences, .substringNotRequired]
        ) { _, range, _, _ in
            let text = String(combined[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            let offset = combined.distance(from: combined.startIndex, to: range.lowerBound)
            let segment = anchors.last(where: { $0.offset <= offset })?.segment ?? fragments[0].0
            sentences.append((segment, text))
        }
        if sentences.isEmpty {
            sentences = [(fragments[0].0, combined)]
        }

        var units: [SpeechUnit] = []
        var currentSegment: ReaderSpeechSegment?
        var currentText = ""

        func flushCurrentUnit() {
            guard let currentSegment, !currentText.isEmpty else { return }
            units.append(SpeechUnit(segment: currentSegment, text: currentText))
            currentText = ""
        }

        for sentence in sentences {
            for piece in splitLongText(sentence.text, limit: speechUnitCharacterLimit) {
                if currentText.isEmpty {
                    currentSegment = sentence.segment
                    currentText = piece
                } else if
                    currentSegment?.id != sentence.segment.id
                        || currentText.count + piece.count + 1 > speechUnitCharacterLimit {
                    flushCurrentUnit()
                    currentSegment = sentence.segment
                    currentText = piece
                } else {
                    currentText += " " + piece
                }
            }
        }
        flushCurrentUnit()
        return units
    }

    func pause() {
        guard state == .playing || state == .loading else { return }
        pauseRequested = true
        if systemSynthesizer.isSpeaking {
            systemSynthesizer.pauseSpeaking(at: .immediate)
        } else {
            player?.pause()
        }
        state = .paused
        updateNowPlayingPlaybackState()
    }

    func resume(settings: ReaderSpeechSettingsStore) {
        guard state == .paused else { return }
        pauseRequested = false
        do {
            try activateAudioSession()
        } catch {
            state = .failed(error.localizedDescription)
            clearRemoteControls()
            return
        }
        if systemSynthesizer.isPaused {
            systemSynthesizer.continueSpeaking()
            state = .playing
        } else if let player {
            if player.play() {
                state = .playing
            } else {
                state = .failed(ReaderSpeechError.playbackFailed.localizedDescription)
                clearRemoteControls()
                try? AVAudioSession.sharedInstance().setActive(
                    false,
                    options: .notifyOthersOnDeactivation
                )
            }
        } else if synthesisTask != nil {
            state = .loading
        } else {
            playCurrentUnit(settings: settings)
        }
        updateNowPlayingPlaybackState()
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
        systemSynthesizer.stopSpeaking(at: .immediate)
        pauseRequested = false
        units = []
        prefetchedAudio = [:]
        unitIndex = 0
        progressText = ""
        state = .idle
        endBackgroundTask()
        clearRemoteControls()
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

        if settings.provider == .system {
            do {
                try beginSystemPlayback(text: unit.text, rate: rate)
            } catch {
                state = .failed(error.localizedDescription)
                clearRemoteControls()
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
            return
        }

        let engine: any ReaderSpeechEngine
        do {
            engine = try settings.makeEngine()
        } catch {
            state = .failed(error.localizedDescription)
            clearRemoteControls()
            return
        }
        let cacheKey = "\(engine.cacheIdentifier)|\(speaker)|\(rate)|\(unit.text)"

        synthesisTask?.cancel()
        beginBackgroundTask()
        synthesisTask = Task { [weak self] in
            guard let self else { return }
            do {
                let data: Data
                if
                    let prefetched = prefetchedAudio.removeValue(forKey: unitIndex),
                    prefetched.cacheKey == cacheKey {
                    data = prefetched.data
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
                endBackgroundTask()
                prefetchUpcomingUnits(after: unitIndex, settings: settings)
            } catch is CancellationError {
                endBackgroundTask()
                return
            } catch {
                guard !Task.isCancelled else { return }
                endBackgroundTask()
                state = .failed(error.localizedDescription)
                player = nil
                clearRemoteControls()
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
        beginBackgroundTask()
        synthesisTask = Task { [weak self] in
            guard let self else { return }
            let segments = await loadMoreSegments(chapterKey)
            guard !Task.isCancelled else {
                endBackgroundTask()
                return
            }
            let additionalUnits = Self.speechUnits(from: segments)
            guard !additionalUnits.isEmpty else {
                finish()
                return
            }
            units.append(contentsOf: additionalUnits)
            synthesisTask = nil
            endBackgroundTask()
            playCurrentUnit(settings: settings)
        }
    }

    private func beginPlayback(data: Data) throws {
        try activateAudioSession()

        let player = try AVAudioPlayer(data: data)
        player.delegate = self
        player.prepareToPlay()
        self.player = player
        activateRemoteControls()
        if pauseRequested {
            state = .paused
        } else {
            guard player.play() else {
                throw ReaderSpeechError.playbackFailed
            }
            state = .playing
        }
        updateNowPlayingInfo(duration: player.duration, elapsed: player.currentTime)
    }

    private func beginSystemPlayback(text: String, rate: Double) throws {
        guard let voice = AVSpeechSynthesisVoice(language: "zh-CN") else {
            throw ReaderSpeechError.systemVoiceUnavailable
        }
        try activateAudioSession()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = min(
            AVSpeechUtteranceMaximumSpeechRate,
            max(AVSpeechUtteranceMinimumSpeechRate, AVSpeechUtteranceDefaultSpeechRate * Float(rate))
        )
        utterance.preUtteranceDelay = 0
        utterance.postUtteranceDelay = 0
        systemSynthesizer.speak(utterance)
        state = .playing
        activateRemoteControls()
        updateNowPlayingInfo(duration: nil, elapsed: 0)
    }

    private func activateAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playback,
            mode: .spokenAudio,
            policy: .longFormAudio,
            options: []
        )
        try session.setActive(true, options: [])
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
        endBackgroundTask()
        clearRemoteControls()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func prefetchUpcomingUnits(after currentIndex: Int, settings: ReaderSpeechSettingsStore) {
        guard settings.provider != .system else { return }
        let lastIndex = min(units.count - 1, currentIndex + Self.prefetchUnitCount)
        guard currentIndex < lastIndex else { return }
        let indices = Array((currentIndex + 1)...lastIndex)
        let rate = settings.rate
        let speaker = settings.speaker
        guard let engine = try? settings.makeEngine() else { return }

        prefetchTask?.cancel()
        prefetchTask = Task { [weak self] in
            guard let self else { return }
            for nextIndex in indices {
                guard !Task.isCancelled, units.indices.contains(nextIndex) else { return }
                let unit = units[nextIndex]
                let cacheKey = "\(engine.cacheIdentifier)|\(speaker)|\(rate)|\(unit.text)"
                if prefetchedAudio[nextIndex]?.cacheKey == cacheKey { continue }

                do {
                    let data: Data
                    if let cached = audioCache[cacheKey] {
                        data = cached
                    } else {
                        data = try await engine.synthesize(.init(text: unit.text, rate: rate, speaker: speaker))
                        guard !Task.isCancelled else { return }
                        audioCache[cacheKey] = data
                    }
                    guard
                        !Task.isCancelled,
                        units.indices.contains(nextIndex),
                        units[nextIndex].text == unit.text
                    else {
                        return
                    }
                    prefetchedAudio[nextIndex] = PrefetchedAudio(cacheKey: cacheKey, data: data)
                } catch {
                    // Prefetch is an optimization only. Normal playback will retry
                    // synthesis and surface an error if it also fails.
                }
            }
        }
    }

    private static func normalizedSpeechText(from markdown: String) -> String {
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
        return normalized
    }

    private static func boundarySeparator(previous: String, next: String) -> String {
        guard let previousCharacter = previous.last, let nextCharacter = next.first else { return "" }
        return isASCIIAlphaNumeric(previousCharacter) && isASCIIAlphaNumeric(nextCharacter) ? " " : ""
    }

    private static func isASCIIAlphaNumeric(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first else {
            return false
        }
        let value = scalar.value
        return (48...57).contains(value) || (65...90).contains(value) || (97...122).contains(value)
    }

    private static func splitLongText(_ text: String, limit: Int) -> [String] {
        guard text.count > limit else { return [text] }
        var result: [String] = []
        var remainder = text[...]
        while !remainder.isEmpty {
            let end = remainder.index(remainder.startIndex, offsetBy: min(limit, remainder.count))
            result.append(String(remainder[..<end]))
            remainder = remainder[end...]
        }
        return result
    }

    private func observeAudioSession() {
        let center = NotificationCenter.default
        notificationObservers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in self?.handleAudioInterruption(notification) }
        })
        notificationObservers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in self?.handleAudioRouteChange(notification) }
        })
    }

    private func handleAudioInterruption(_ notification: Notification) {
        guard
            let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: rawType)
        else { return }

        switch type {
            case .began:
                resumeAfterInterruption = state == .playing
                pause()
            case .ended:
                let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                let shouldResume = AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume)
                if resumeAfterInterruption && shouldResume {
                    try? activateAudioSession()
                    resume(settings: .shared)
                }
                resumeAfterInterruption = false
            @unknown default:
                break
        }
    }

    private func handleAudioRouteChange(_ notification: Notification) {
        guard
            let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
            AVAudioSession.RouteChangeReason(rawValue: rawReason) == .oldDeviceUnavailable
        else { return }
        pause()
    }

    private func activateRemoteControls() {
        guard remoteCommandTargets.isEmpty else {
            updateNowPlayingPlaybackState()
            return
        }
        UIApplication.shared.beginReceivingRemoteControlEvents()
        let commands = MPRemoteCommandCenter.shared()
        commands.playCommand.isEnabled = true
        commands.pauseCommand.isEnabled = true
        commands.togglePlayPauseCommand.isEnabled = true
        commands.stopCommand.isEnabled = true
        commands.nextTrackCommand.isEnabled = false
        commands.previousTrackCommand.isEnabled = false
        commands.skipForwardCommand.isEnabled = false
        commands.skipBackwardCommand.isEnabled = false
        commands.changePlaybackPositionCommand.isEnabled = false

        remoteCommandTargets = [
            (commands.playCommand, commands.playCommand.addTarget { [weak self] _ in
                Task { @MainActor [weak self] in self?.resume(settings: .shared) }
                return .success
            }),
            (commands.pauseCommand, commands.pauseCommand.addTarget { [weak self] _ in
                Task { @MainActor [weak self] in self?.pause() }
                return .success
            }),
            (commands.togglePlayPauseCommand, commands.togglePlayPauseCommand.addTarget { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if state == .playing { pause() }
                    else if state == .paused { resume(settings: .shared) }
                }
                return .success
            }),
            (commands.stopCommand, commands.stopCommand.addTarget { [weak self] _ in
                Task { @MainActor [weak self] in self?.stop() }
                return .success
            })
        ]
        updateNowPlayingPlaybackState()
    }

    private func clearRemoteControls() {
        remoteCommandTargets.forEach { $0.command.removeTarget($0.target) }
        remoteCommandTargets = []
        let commands = MPRemoteCommandCenter.shared()
        commands.playCommand.isEnabled = false
        commands.pauseCommand.isEnabled = false
        commands.togglePlayPauseCommand.isEnabled = false
        commands.stopCommand.isEnabled = false
        UIApplication.shared.endReceivingRemoteControlEvents()
        let center = MPNowPlayingInfoCenter.default()
        center.playbackState = .stopped
        center.nowPlayingInfo = nil
    }

    private func updateNowPlayingInfo(duration: TimeInterval?, elapsed: TimeInterval) {
        guard units.indices.contains(unitIndex) else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: readerSpeechLocalized("MICROSOFT_TTS_TITLE", fallback: "语音读书"),
            MPMediaItemPropertyArtist: String(units[unitIndex].text.prefix(80)),
            MPMediaItemPropertyAlbumTitle: "Aidoku",
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyIsLiveStream: false,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: nowPlayingPlaybackRate,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0
        ]
        if let duration { info[MPMediaItemPropertyPlaybackDuration] = duration }
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = info
        center.playbackState = nowPlayingPlaybackState
    }

    private func updateNowPlayingPlaybackState() {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        if let player {
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = player.currentTime
            info[MPMediaItemPropertyPlaybackDuration] = player.duration
        }
        info[MPNowPlayingInfoPropertyPlaybackRate] = nowPlayingPlaybackRate
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = info
        center.playbackState = nowPlayingPlaybackState
    }

    private var nowPlayingPlaybackState: MPNowPlayingPlaybackState {
        switch state {
            case .playing:
                .playing
            case .loading:
                pauseRequested ? .paused : .playing
            case .paused:
                .paused
            case .idle, .failed:
                .stopped
        }
    }

    private var nowPlayingPlaybackRate: Double {
        switch state {
            case .playing:
                1.0
            case .loading:
                pauseRequested ? 0.0 : 1.0
            case .paused, .idle, .failed:
                0.0
        }
    }

    private func beginBackgroundTask() {
        endBackgroundTask()
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Reader speech synthesis") { [weak self] in
            Task { @MainActor [weak self] in self?.endBackgroundTask() }
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
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
                clearRemoteControls()
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
        }
    }
}

extension ReaderSpeechController: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        Task { @MainActor [weak self] in self?.advance() }
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
    case systemVoiceUnavailable
    case freeServiceUnavailable(detail: String?)

    var errorDescription: String? {
        switch self {
            case .invalidResponse:
                return readerSpeechLocalized("MICROSOFT_TTS_INVALID_RESPONSE", fallback: "微软语音返回了无效音频。")
            case .playbackFailed:
                return readerSpeechLocalized("MICROSOFT_TTS_PLAYBACK_FAILED", fallback: "语音播放失败。")
            case .systemVoiceUnavailable:
                return readerSpeechLocalized("READER_TTS_SYSTEM_UNAVAILABLE", fallback: "当前设备没有可用的中文系统语音。")
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
                } else if settings.provider == .local {
                    localModelSettings
                } else {
                    systemVoiceSettings
                }

                Section {
                    if settings.provider == .microsoft {
                        Picker(readerSpeechLocalized("MICROSOFT_TTS_VOICE", fallback: "音色"), selection: $settings.voice) {
                            ForEach(MicrosoftSpeechVoice.allCases) { voice in
                                Text(voice.title).tag(voice)
                            }
                        }
                    } else if settings.provider == .local,
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
                        fallback: "支持锁屏、切换应用和耳机播放控制，并从当前文字位置连续朗读。"
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

    private var systemVoiceSettings: some View {
        Section {
            Label(
                readerSpeechLocalized("READER_TTS_SYSTEM_READY", fallback: "使用 iPhone 已安装的中文语音，无需联网"),
                systemImage: "iphone.and.arrow.forward"
            )
        } header: {
            Text(readerSpeechLocalized("READER_TTS_SYSTEM_TITLE", fallback: "苹果系统语音"))
        } footer: {
            Text(readerSpeechLocalized(
                "READER_TTS_SYSTEM_INFO",
                fallback: "系统语音用于网络不可用时的离线保底，音色由 iOS 的语音设置决定。"
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
