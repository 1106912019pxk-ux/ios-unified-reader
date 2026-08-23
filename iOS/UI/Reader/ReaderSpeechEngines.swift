//
//  ReaderSpeechEngines.swift
//  Aidoku (iOS)
//
//  Pluggable online/offline speech engines and local model package management.
//

import Foundation
import Combine
import SherpaOnnx
import ZIPFoundation

enum ReaderSpeechProvider: String, CaseIterable, Identifiable, Sendable {
    case microsoft
    case local

    var id: String { rawValue }

    var title: String {
        switch self {
            case .microsoft: readerSpeechLocalized("READER_TTS_PROVIDER_MICROSOFT", fallback: "微软在线语音")
            case .local: readerSpeechLocalized("READER_TTS_PROVIDER_LOCAL", fallback: "本地离线模型")
        }
    }
}

struct ReaderSpeechSynthesisRequest: Sendable {
    let text: String
    let rate: Double
    let speaker: Int
}

protocol ReaderSpeechEngine: Sendable {
    var cacheIdentifier: String { get }
    func synthesize(_ request: ReaderSpeechSynthesisRequest) async throws -> Data
}

struct ReaderMicrosoftSpeechEngine: ReaderSpeechEngine {
    let region: String
    let subscriptionKey: String
    let voice: MicrosoftSpeechVoice

    var cacheIdentifier: String { "microsoft|\(region)|\(voice.rawValue)" }

    func synthesize(_ request: ReaderSpeechSynthesisRequest) async throws -> Data {
        try await MicrosoftSpeechService.synthesize(
            text: request.text,
            region: region,
            subscriptionKey: subscriptionKey,
            voice: voice,
            rate: request.rate
        )
    }
}

struct ReaderSpeechModelManifest: Codable, Hashable, Sendable {
    enum Family: String, Codable, CaseIterable, Sendable {
        case vits
        case matcha
        case kokoro
    }

    var schemaVersion = 1
    var id: String
    var name: String
    var family: Family
    var language: String?
    var model: String?
    var acousticModel: String?
    var vocoder: String?
    var voices: String?
    var tokens: String
    var lexicons: [String]?
    var dataDirectory: String?
    var dictionaryDirectory: String?
    var ruleFsts: [String]?
    var ruleFars: [String]?
    var speakerCount: Int?
}

struct ReaderSpeechInstalledModel: Identifiable, Hashable, Sendable {
    let manifest: ReaderSpeechModelManifest
    let directoryURL: URL

    var id: String { manifest.id }
    var name: String { manifest.name }
    var family: ReaderSpeechModelManifest.Family { manifest.family }
    var speakerCount: Int { max(1, manifest.speakerCount ?? 1) }
}

@MainActor
final class ReaderSpeechModelManager: ObservableObject {
    static let shared = ReaderSpeechModelManager()

    @Published private(set) var models: [ReaderSpeechInstalledModel] = []
    @Published private(set) var isImporting = false
    @Published var importError: String?

    private nonisolated static let manifestFileName = "aidoku-tts-model.json"

    private init() {
        reload()
    }

    func model(id: String?) -> ReaderSpeechInstalledModel? {
        guard let id else { return nil }
        return models.first { $0.id == id }
    }

    func reload() {
        models = Self.loadInstalledModels()
    }

    func importModel(from sourceURL: URL) async {
        guard !isImporting else { return }
        isImporting = true
        importError = nil
        defer { isImporting = false }

        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer { if accessed { sourceURL.stopAccessingSecurityScopedResource() } }

        do {
            _ = try await Task.detached(priority: .userInitiated) {
                try Self.installModel(from: sourceURL)
            }.value
            reload()
        } catch {
            importError = error.localizedDescription
        }
    }

    func delete(_ model: ReaderSpeechInstalledModel) throws {
        try FileManager.default.removeItem(at: model.directoryURL)
        reload()
    }

    private nonisolated static var modelsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("ReaderSpeechModels", isDirectory: true)
    }

    private nonisolated static func loadInstalledModels() -> [ReaderSpeechInstalledModel] {
        let manager = FileManager.default
        try? manager.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        let directories = (try? manager.contentsOfDirectory(
            at: modelsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return directories.compactMap { directory in
            let manifestURL = directory.appendingPathComponent(manifestFileName)
            guard
                let data = try? Data(contentsOf: manifestURL),
                let manifest = try? JSONDecoder().decode(ReaderSpeechModelManifest.self, from: data),
                (try? validate(manifest: manifest, in: directory)) != nil
            else { return nil }
            return ReaderSpeechInstalledModel(manifest: manifest, directoryURL: directory)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private nonisolated static func installModel(from sourceURL: URL) throws -> ReaderSpeechInstalledModel {
        let manager = FileManager.default
        try manager.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)

        let staging = manager.temporaryDirectory
            .appendingPathComponent("AidokuTTS-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: staging) }

        if sourceURL.pathExtension.lowercased() == "zip" {
            try extractZip(sourceURL, to: staging)
        } else {
            let destination = staging.appendingPathComponent(sourceURL.lastPathComponent, isDirectory: true)
            try manager.copyItem(at: sourceURL, to: destination)
        }

        let packageRoot = normalizedPackageRoot(staging)
        var manifest: ReaderSpeechModelManifest
        let suppliedManifest = packageRoot.appendingPathComponent(manifestFileName)
        if manager.fileExists(atPath: suppliedManifest.path) {
            let data = try Data(contentsOf: suppliedManifest)
            manifest = try JSONDecoder().decode(ReaderSpeechModelManifest.self, from: data)
        } else {
            manifest = try inferManifest(in: packageRoot)
        }

        manifest.id = UUID().uuidString.lowercased()
        try validate(manifest: manifest, in: packageRoot)

        let destination = modelsDirectory.appendingPathComponent(manifest.id, isDirectory: true)
        try manager.copyItem(at: packageRoot, to: destination)
        let data = try JSONEncoder.prettyPrinted.encode(manifest)
        try data.write(to: destination.appendingPathComponent(manifestFileName), options: .atomic)
        return ReaderSpeechInstalledModel(manifest: manifest, directoryURL: destination)
    }

    private nonisolated static func extractZip(_ archiveURL: URL, to destination: URL) throws {
        let archive = try Archive(url: archiveURL, accessMode: .read)
        let rootPath = destination.standardizedFileURL.path + "/"
        for entry in archive {
            let relative = entry.path.replacingOccurrences(of: "\\", with: "/")
            guard
                !relative.hasPrefix("/"),
                !relative.split(separator: "/").contains(".."),
                entry.type != .symlink
            else { throw ReaderSpeechModelError.unsafeArchive }

            let target = destination.appendingPathComponent(relative).standardizedFileURL
            guard target.path.hasPrefix(rootPath) else { throw ReaderSpeechModelError.unsafeArchive }
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            _ = try archive.extract(entry, to: target)
        }
    }

    private nonisolated static func normalizedPackageRoot(_ directory: URL) -> URL {
        let visible = ((try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []).filter { $0.lastPathComponent != "__MACOSX" }
        guard visible.count == 1,
              (try? visible[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        else { return directory }
        return visible[0]
    }

    private nonisolated static func inferManifest(in root: URL) throws -> ReaderSpeechModelManifest {
        let files = recursiveFiles(in: root)
        func relative(_ url: URL) -> String {
            String(url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
                .replacingOccurrences(of: "\\", with: "/")
        }
        func named(_ exact: String) -> URL? {
            files.first { $0.lastPathComponent.lowercased() == exact.lowercased() }
        }

        guard let tokens = named("tokens.txt") else { throw ReaderSpeechModelError.missingTokens }
        let onnxFiles = files.filter { $0.pathExtension.lowercased() == "onnx" }
        guard !onnxFiles.isEmpty else { throw ReaderSpeechModelError.missingModel }

        let voices = named("voices.bin")
        let vocoder = onnxFiles.first {
            let name = $0.lastPathComponent.lowercased()
            return name.contains("vocos") || name.contains("vocoder")
        }
        let acoustic = onnxFiles.first { $0 != vocoder }
        let family: ReaderSpeechModelManifest.Family = voices != nil ? .kokoro : (vocoder != nil ? .matcha : .vits)

        let lexicons = files.filter {
            $0.pathExtension.lowercased() == "txt" && $0.lastPathComponent.lowercased().contains("lexicon")
        }.map(relative)
        let ruleFsts = files.filter { $0.pathExtension.lowercased() == "fst" }.map(relative)
        let ruleFars = files.filter { $0.pathExtension.lowercased() == "far" }.map(relative)
        let dataDirectory = recursiveDirectories(in: root).first {
            $0.lastPathComponent.lowercased() == "espeak-ng-data"
        }.map(relative)
        let dictionaryDirectory = recursiveDirectories(in: root).first {
            $0.lastPathComponent.lowercased() == "dict"
        }.map(relative)
        let packageName = root.lastPathComponent.lowercased()
        let speakerCount: Int
        if packageName.contains("aishell3") {
            speakerCount = 174
        } else if packageName.contains("vctk") {
            speakerCount = 109
        } else if packageName.contains("kokoro-multi-lang") {
            speakerCount = 103
        } else if packageName.contains("kokoro-en") {
            speakerCount = 11
        } else {
            speakerCount = 1
        }

        return ReaderSpeechModelManifest(
            id: UUID().uuidString.lowercased(),
            name: root.lastPathComponent,
            family: family,
            language: nil,
            model: family == .matcha ? nil : acoustic.map(relative),
            acousticModel: family == .matcha ? acoustic.map(relative) : nil,
            vocoder: vocoder.map(relative),
            voices: voices.map(relative),
            tokens: relative(tokens),
            lexicons: lexicons.isEmpty ? nil : lexicons,
            dataDirectory: dataDirectory,
            dictionaryDirectory: dictionaryDirectory,
            ruleFsts: ruleFsts.isEmpty ? nil : ruleFsts,
            ruleFars: ruleFars.isEmpty ? nil : ruleFars,
            speakerCount: speakerCount
        )
    }

    private nonisolated static func validate(manifest: ReaderSpeechModelManifest, in root: URL) throws {
        guard manifest.schemaVersion == 1 else { throw ReaderSpeechModelError.unsupportedManifest }
        _ = try resolved(manifest.tokens, in: root, directory: false)
        switch manifest.family {
            case .vits:
                guard let model = manifest.model else { throw ReaderSpeechModelError.missingModel }
                _ = try resolved(model, in: root, directory: false)
            case .matcha:
                guard let acoustic = manifest.acousticModel, let vocoder = manifest.vocoder else {
                    throw ReaderSpeechModelError.missingModel
                }
                _ = try resolved(acoustic, in: root, directory: false)
                _ = try resolved(vocoder, in: root, directory: false)
            case .kokoro:
                guard let model = manifest.model, let voices = manifest.voices else {
                    throw ReaderSpeechModelError.missingModel
                }
                _ = try resolved(model, in: root, directory: false)
                _ = try resolved(voices, in: root, directory: false)
        }
    }

    nonisolated static func resolved(_ relativePath: String?, in root: URL, directory: Bool? = nil) throws -> URL {
        guard let relativePath, !relativePath.isEmpty else { throw ReaderSpeechModelError.invalidPath }
        let normalizedRoot = root.standardizedFileURL.path + "/"
        let url = root.appendingPathComponent(relativePath).standardizedFileURL
        guard url.path.hasPrefix(normalizedRoot) else { throw ReaderSpeechModelError.invalidPath }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw ReaderSpeechModelError.missingFile(relativePath)
        }
        if let directory, directory != isDirectory.boolValue {
            throw ReaderSpeechModelError.missingFile(relativePath)
        }
        return url
    }

    private nonisolated static func recursiveFiles(in root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        return enumerator.compactMap { item in
            guard let url = item as? URL,
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            else { return nil }
            return url
        }
    }

    private nonisolated static func recursiveDirectories(in root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return enumerator.compactMap { item in
            guard let url = item as? URL,
                  (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            else { return nil }
            return url
        }
    }
}

struct ReaderLocalSpeechEngine: ReaderSpeechEngine {
    let model: ReaderSpeechInstalledModel

    var cacheIdentifier: String { "local|\(model.id)" }

    func synthesize(_ request: ReaderSpeechSynthesisRequest) async throws -> Data {
        try await ReaderLocalSpeechRuntime.shared.synthesize(model: model, request: request)
    }

    fileprivate static func makeTTS(_ installed: ReaderSpeechInstalledModel) throws -> SherpaOnnxOfflineTtsWrapper {
        let manifest = installed.manifest
        let root = installed.directoryURL
        func path(_ value: String?, directory: Bool? = nil) throws -> String {
            try ReaderSpeechModelManager.resolved(value, in: root, directory: directory).path
        }
        func paths(_ values: [String]?) throws -> String {
            try (values ?? []).map { try path($0) }.joined(separator: ",")
        }
        func optionalPath(_ value: String?, directory: Bool? = nil) throws -> String {
            guard let value else { return "" }
            return try path(value, directory: directory)
        }

        let modelConfig: SherpaOnnxOfflineTtsModelConfig
        switch manifest.family {
            case .vits:
                let config = sherpaOnnxOfflineTtsVitsModelConfig(
                    model: try path(manifest.model),
                    lexicon: try paths(manifest.lexicons),
                    tokens: try path(manifest.tokens),
                    dataDir: try optionalPath(manifest.dataDirectory, directory: true),
                    dictDir: try optionalPath(manifest.dictionaryDirectory, directory: true)
                )
                modelConfig = sherpaOnnxOfflineTtsModelConfig(vits: config, numThreads: 2)
            case .matcha:
                let config = sherpaOnnxOfflineTtsMatchaModelConfig(
                    acousticModel: try path(manifest.acousticModel),
                    vocoder: try path(manifest.vocoder),
                    lexicon: try paths(manifest.lexicons),
                    tokens: try path(manifest.tokens),
                    dataDir: try optionalPath(manifest.dataDirectory, directory: true),
                    dictDir: try optionalPath(manifest.dictionaryDirectory, directory: true)
                )
                modelConfig = sherpaOnnxOfflineTtsModelConfig(matcha: config, numThreads: 2)
            case .kokoro:
                let config = sherpaOnnxOfflineTtsKokoroModelConfig(
                    model: try path(manifest.model),
                    voices: try path(manifest.voices),
                    tokens: try path(manifest.tokens),
                    dataDir: try optionalPath(manifest.dataDirectory, directory: true),
                    dictDir: try optionalPath(manifest.dictionaryDirectory, directory: true),
                    lexicon: try paths(manifest.lexicons),
                    lang: manifest.language ?? ""
                )
                modelConfig = sherpaOnnxOfflineTtsModelConfig(kokoro: config, numThreads: 2)
        }

        var config = sherpaOnnxOfflineTtsConfig(
            model: modelConfig,
            ruleFsts: try paths(manifest.ruleFsts),
            ruleFars: try paths(manifest.ruleFars),
            maxNumSentences: 1
        )
        let tts = SherpaOnnxOfflineTtsWrapper(config: &config)
        guard tts.tts != nil else { throw ReaderSpeechModelError.invalidModel }
        return tts
    }

    fileprivate static func wavData(samples: [Float], sampleRate: Int) -> Data {
        var pcm = Data(capacity: samples.count * 2)
        for sample in samples {
            var value = Int16((max(-1, min(1, sample)) * Float(Int16.max)).rounded()).littleEndian
            withUnsafeBytes(of: &value) { pcm.append(contentsOf: $0) }
        }

        var data = Data("RIFF".utf8)
        append(UInt32(36 + pcm.count), to: &data)
        data.append(Data("WAVEfmt ".utf8))
        append(UInt32(16), to: &data)
        append(UInt16(1), to: &data)
        append(UInt16(1), to: &data)
        append(UInt32(sampleRate), to: &data)
        append(UInt32(sampleRate * 2), to: &data)
        append(UInt16(2), to: &data)
        append(UInt16(16), to: &data)
        data.append(Data("data".utf8))
        append(UInt32(pcm.count), to: &data)
        data.append(pcm)
        return data
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
}

private final class ReaderLocalSpeechRuntime: @unchecked Sendable {
    static let shared = ReaderLocalSpeechRuntime()

    private let queue = DispatchQueue(label: "app.aidoku.reader.local-tts", qos: .userInitiated)
    private var engines: [String: SherpaOnnxOfflineTtsWrapper] = [:]

    func synthesize(
        model: ReaderSpeechInstalledModel,
        request: ReaderSpeechSynthesisRequest
    ) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let tts: SherpaOnnxOfflineTtsWrapper
                    if let cached = self.engines[model.id] {
                        tts = cached
                    } else {
                        tts = try ReaderLocalSpeechEngine.makeTTS(model)
                        self.engines[model.id] = tts
                    }
                    let speaker = min(max(0, request.speaker), max(0, Int(tts.numSpeakers) - 1))
                    let audio = tts.generate(text: request.text, sid: speaker, speed: Float(request.rate))
                    guard !audio.samples.isEmpty, audio.sampleRate > 0 else {
                        throw ReaderSpeechModelError.generationFailed
                    }
                    continuation.resume(returning: ReaderLocalSpeechEngine.wavData(
                        samples: audio.samples,
                        sampleRate: Int(audio.sampleRate)
                    ))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

enum ReaderSpeechModelError: LocalizedError {
    case unsafeArchive
    case unsupportedManifest
    case invalidPath
    case missingTokens
    case missingModel
    case missingFile(String)
    case invalidModel
    case generationFailed

    var errorDescription: String? {
        switch self {
            case .unsafeArchive: "语音模型压缩包包含不安全路径或符号链接。"
            case .unsupportedManifest: "语音模型清单版本不受支持。"
            case .invalidPath: "语音模型清单包含无效路径。"
            case .missingTokens: "未找到 tokens.txt，无法识别该语音模型。"
            case .missingModel: "未找到完整的 ONNX 模型文件。"
            case let .missingFile(path): "语音模型缺少文件：\(path)"
            case .invalidModel: "无法初始化本地语音模型。"
            case .generationFailed: "本地语音模型没有生成有效音频。"
        }
    }
}

private extension JSONEncoder {
    static var prettyPrinted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
