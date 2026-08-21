//
//  AidokuRunner.swift
//  Aidoku
//
//  Created by Skitty on 8/24/23.
//

import AidokuRunner
import CFNetwork
import Foundation
import Network
import Security

extension InterpreterConfiguration {
    static func defaultConfig(for sourceId: String) -> Self {
        .init(
            printHandler: { message in
                LogManager.logger.log("[\(sourceId)] \(message)")
            },
            requestHandler: { originalRequest in
                let request = if let url = originalRequest.url {
                    await AidokuRunner.Source.modify(url: url, request: originalRequest)
                } else {
                    originalRequest
                }

                do {
                    let (data, response) = if sourceId == PicaNetworkRouting.sourceId {
                        try await PicaNetworkRouting.data(for: request)
                    } else {
                        try await URLSession.shared.data(for: request)
                    }

                    let httpResponse = response as? HTTPURLResponse
                    if let httpResponse {
                        // check if cloudflare blocked the request
                        if CloudflareHandler.shared.shouldHandle(response: httpResponse, data: data) {
                            do {
                                return try await CloudflareHandler.shared.handle(request: request)
                            } catch let error as CloudflareHandler.HandleError {
                                LogManager.logger.error("Failed to handle CloudFlare: \(error)")
                                return (data, response)
                            }
                        }
                    }

                    return (data, response)
                } catch {
                    LogManager.logger.error("Error performing network request for \(sourceId): \(error)")
                    throw error
                }
            }
        )
    }
}

enum PicaNetworkRouting {
    static let sourceId = "zh.picacomic"

    static func shouldRoute(_ request: URLRequest) -> Bool {
        guard let host = request.url?.host?.lowercased() else { return false }
        let isPicaHost = host == "picacomic.com" || host.hasSuffix(".picacomic.com")
        let channel = UserDefaults.standard.string(forKey: "\(sourceId).appChannel") ?? "2"
        return isPicaHost && channel != "1"
    }

    static func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        guard shouldRoute(request) else {
            return try await URLSession.shared.data(for: request)
        }

        do {
            return try await PicaRoutedSession.shared.data(for: request)
        } catch {
            LogManager.logger.warn("Pica channel route failed, falling back to system networking: \(error)")
            return try await URLSession.shared.data(for: request)
        }
    }
}

private actor PicaRoutedSession {
    static let shared = PicaRoutedSession()

    private var session: URLSession?

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let activeSession: URLSession
        if let session {
            activeSession = session
        } else {
            let port = try await PicaTunnelProxy.shared.start()
            let configuration = URLSessionConfiguration.default
            configuration.connectionProxyDictionary = [
                kCFNetworkProxiesHTTPSEnable as String: true,
                kCFNetworkProxiesHTTPSProxy as String: "127.0.0.1",
                kCFNetworkProxiesHTTPSPort as String: Int(port)
            ]
            configuration.httpMaximumConnectionsPerHost = 6
            configuration.timeoutIntervalForRequest = 30
            let newSession = URLSession(configuration: configuration)
            session = newSession
            activeSession = newSession
        }
        return try await activeSession.data(for: request)
    }
}

private final class PicaTunnelProxy: @unchecked Sendable {
    static let shared = PicaTunnelProxy()

    private let queue = DispatchQueue(label: "app.aidoku.pica-channel-proxy", qos: .userInitiated)
    private let lock = NSLock()
    private var listener: NWListener?
    private var port: UInt16?
    private var waiters: [CheckedContinuation<UInt16, any Error>] = []

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let port {
                lock.unlock()
                continuation.resume(returning: port)
                return
            }

            waiters.append(continuation)
            guard listener == nil else {
                lock.unlock()
                return
            }

            do {
                let parameters = NWParameters.tcp
                parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
                let newListener = try NWListener(using: parameters, on: .any)
                listener = newListener
                lock.unlock()

                newListener.newConnectionHandler = { connection in
                    PicaProxyTunnel(connection: connection, queue: self.queue).start()
                }
                newListener.stateUpdateHandler = { state in
                    switch state {
                        case .ready:
                            guard let port = newListener.port?.rawValue else {
                                self.finishStart(.failure(PicaNetworkError.missingListenerPort))
                                return
                            }
                            self.finishStart(.success(port))
                        case .failed(let error):
                            self.finishStart(.failure(error))
                        default:
                            break
                    }
                }
                newListener.start(queue: queue)
            } catch {
                listener = nil
                lock.unlock()
                finishStart(.failure(error))
            }
        }
    }

    private func finishStart(_ result: Result<UInt16, any Error>) {
        lock.lock()
        if case .success(let port) = result {
            self.port = port
        } else {
            listener = nil
        }
        let waiters = waiters
        self.waiters.removeAll()
        lock.unlock()

        for waiter in waiters {
            waiter.resume(with: result)
        }
    }
}

private final class PicaProxyTunnel: @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private var connectBuffer = Data()
    private var remoteConnection: NWConnection?
    private var finished = false

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    func start() {
        // Keep the tunnel alive for as long as the client connection is active.
        // finish() clears this handler to break the temporary retain cycle.
        connection.stateUpdateHandler = { state in
            switch state {
                case .ready:
                    self.receiveConnectRequest()
                case .failed, .cancelled:
                    self.finish()
                default:
                    break
            }
        }
        connection.start(queue: queue)
    }

    private func receiveConnectRequest() {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 16 * 1024
        ) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data {
                connectBuffer.append(data)
            }

            guard let headerRange = connectBuffer.range(of: Data("\r\n\r\n".utf8)) else {
                if error != nil || isComplete || connectBuffer.count >= 64 * 1024 {
                    sendProxyErrorAndFinish(status: "400 Bad Request")
                } else {
                    receiveConnectRequest()
                }
                return
            }

            let headerData = connectBuffer[..<headerRange.lowerBound]
            let trailingData = connectBuffer[headerRange.upperBound...]
            guard
                let header = String(data: headerData, encoding: .utf8),
                let firstLine = header.components(separatedBy: "\r\n").first,
                let authority = parseConnectAuthority(firstLine)
            else {
                sendProxyErrorAndFinish(status: "400 Bad Request")
                return
            }

            Task {
                let targetHost = await PicaChannelResolver.shared.targetHost(for: authority.host)
                queue.async {
                    self.connectRemote(
                        targetHost: targetHost,
                        originalHost: authority.host,
                        port: authority.port,
                        trailingData: Data(trailingData),
                        hasRetriedSystemHost: false
                    )
                }
            }
        }
    }

    private func parseConnectAuthority(_ firstLine: String) -> (host: String, port: UInt16)? {
        let fields = firstLine.split(separator: " ")
        guard fields.count >= 2, fields[0].uppercased() == "CONNECT" else { return nil }
        let authority = String(fields[1])

        if authority.hasPrefix("["), let bracket = authority.firstIndex(of: "]") {
            let host = String(authority[authority.index(after: authority.startIndex)..<bracket])
            let portStart = authority.index(after: bracket)
            let portText = portStart < authority.endIndex && authority[portStart] == ":"
                ? String(authority[authority.index(after: portStart)...])
                : "443"
            return UInt16(portText).map { (host, $0) }
        }

        if let separator = authority.lastIndex(of: ":") {
            let host = String(authority[..<separator])
            let portText = String(authority[authority.index(after: separator)...])
            return UInt16(portText).map { (host, $0) }
        }
        return (authority, 443)
    }

    private func connectRemote(
        targetHost: String,
        originalHost: String,
        port: UInt16,
        trailingData: Data,
        hasRetriedSystemHost: Bool
    ) {
        guard let networkPort = NWEndpoint.Port(rawValue: port) else {
            sendProxyErrorAndFinish(status: "400 Bad Request")
            return
        }

        let remote = NWConnection(
            to: .hostPort(host: NWEndpoint.Host(targetHost), port: networkPort),
            using: .tcp
        )
        remoteConnection = remote
        remote.stateUpdateHandler = { [weak self, weak remote] state in
            guard let self, let remote else { return }
            switch state {
                case .ready:
                    establishTunnel(remote: remote, trailingData: trailingData)
                case .failed:
                    remote.cancel()
                    if targetHost != originalHost && !hasRetriedSystemHost {
                        connectRemote(
                            targetHost: originalHost,
                            originalHost: originalHost,
                            port: port,
                            trailingData: trailingData,
                            hasRetriedSystemHost: true
                        )
                    } else {
                        sendProxyErrorAndFinish(status: "502 Bad Gateway")
                    }
                case .cancelled:
                    if !finished && remoteConnection === remote {
                        finish()
                    }
                default:
                    break
            }
        }
        remote.start(queue: queue)
    }

    private func establishTunnel(remote: NWConnection, trailingData: Data) {
        let response = Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8)
        connection.send(content: response, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if error != nil {
                finish()
                return
            }

            let startPumps = {
                self.pipe(from: self.connection, to: remote)
                self.pipe(from: remote, to: self.connection)
            }
            if trailingData.isEmpty {
                startPumps()
            } else {
                remote.send(content: trailingData, completion: .contentProcessed { error in
                    if error == nil {
                        startPumps()
                    } else {
                        self.finish()
                    }
                })
            }
        })
    }

    private func pipe(from source: NWConnection, to destination: NWConnection) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !finished else { return }
            if let data, !data.isEmpty {
                destination.send(content: data, completion: .contentProcessed { sendError in
                    if sendError != nil || error != nil || isComplete {
                        self.finish()
                    } else {
                        self.pipe(from: source, to: destination)
                    }
                })
            } else if error != nil || isComplete {
                finish()
            } else {
                pipe(from: source, to: destination)
            }
        }
    }

    private func sendProxyErrorAndFinish(status: String) {
        let response = Data("HTTP/1.1 \(status)\r\nConnection: close\r\n\r\n".utf8)
        connection.send(content: response, completion: .contentProcessed { [weak self] _ in
            self?.finish()
        })
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        connection.stateUpdateHandler = nil
        remoteConnection?.stateUpdateHandler = nil
        connection.cancel()
        remoteConnection?.cancel()
        remoteConnection = nil
    }
}

private actor PicaChannelResolver {
    static let shared = PicaChannelResolver()

    private static let initURL = URL(string: "http://68.183.234.72/init")
    private static let cacheAddressesKey = "PicaChannel.addresses"
    private static let cacheDateKey = "PicaChannel.updatedAt"
    private static let cacheLifetime: TimeInterval = 24 * 60 * 60

    private var addresses: [String]?
    private var loadTask: Task<[String], Never>?

    func targetHost(for originalHost: String) async -> String {
        let host = originalHost.lowercased()
        guard host == "picacomic.com" || host.hasSuffix(".picacomic.com") else {
            return originalHost
        }

        let channel = UserDefaults.standard.string(forKey: "\(PicaNetworkRouting.sourceId).appChannel") ?? "2"
        guard channel != "1" else { return originalHost }

        let addresses = await loadAddresses()
        guard !addresses.isEmpty else { return originalHost }
        let preferredIndex = channel == "3" ? 1 : 0
        let target = addresses.indices.contains(preferredIndex) ? addresses[preferredIndex] : addresses[0]
        LogManager.logger.log("Pica channel \(channel): \(originalHost) -> \(target)")
        return target
    }

    private func loadAddresses() async -> [String] {
        if let addresses {
            return addresses
        }

        let defaults = UserDefaults.standard
        let cachedAddresses = defaults.stringArray(forKey: Self.cacheAddressesKey) ?? []
        let cacheDate = defaults.double(forKey: Self.cacheDateKey)
        if !cachedAddresses.isEmpty, Date().timeIntervalSince1970 - cacheDate < Self.cacheLifetime {
            addresses = cachedAddresses
            return cachedAddresses
        }

        if let loadTask {
            return await loadTask.value
        }

        let task = Task { await Self.fetchAddresses() }
        loadTask = task
        let fetchedAddresses = await task.value
        loadTask = nil

        if !fetchedAddresses.isEmpty {
            defaults.set(fetchedAddresses, forKey: Self.cacheAddressesKey)
            defaults.set(Date().timeIntervalSince1970, forKey: Self.cacheDateKey)
            addresses = fetchedAddresses
            return fetchedAddresses
        }

        addresses = cachedAddresses
        return cachedAddresses
    }

    private static func fetchAddresses() async -> [String] {
        guard let initURL else { return [] }
        var request = URLRequest(url: initURL)
        request.timeoutInterval = 8
        request.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("okhttp/3.8.1", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard
                let response = response as? HTTPURLResponse,
                (200..<300).contains(response.statusCode),
                let payload = try? JSONDecoder().decode(PicaChannelResponse.self, from: data),
                payload.status == "ok"
            else {
                return []
            }
            return payload.addresses.filter { address in
                IPv4Address(address) != nil || IPv6Address(address) != nil
            }
        } catch {
            LogManager.logger.warn("Unable to update Pica channel addresses: \(error)")
            return []
        }
    }
}

private struct PicaChannelResponse: Decodable {
    let status: String
    let addresses: [String]
}

private enum PicaNetworkError: LocalizedError {
    case missingListenerPort

    var errorDescription: String? {
        switch self {
            case .missingListenerPort:
                "Pica channel proxy did not receive a local port"
        }
    }
}

private final class URLSessionUnsecureDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        if let trust = challenge.protectionSpace.serverTrust {
            return (.useCredential, URLCredential(trust: trust))
        }
        return (.performDefaultHandling, nil)
    }
}

extension AidokuRunner.Source {
    convenience init(id: String, url: URL) async throws {
        try await self.init(
            url: url,
            interpreterConfig: .defaultConfig(for: id)
        )
    }

    var isExternal: Bool {
        runner is Interpreter
    }

    func toInfo() -> SourceInfo2 {
        SourceInfo2(
            sourceId: key,
            iconUrl: imageUrl,
            name: name,
            languages: languages,
            version: version,
            contentRating: contentRating,
            external: isExternal
        )
    }

    func getModifiedImageRequest(url: URL, context: PageContext?) async -> URLRequest {
        var result: URLRequest
        do {
            result = try await getImageRequest(url: url.absoluteString, context: context)
        } catch {
            result = .init(url: url)
        }
        return await Self.modify(url: url, request: result)
    }

    static func modify(url: URL, request: URLRequest) async -> URLRequest {
        var request = request
        // add user-agent and stored cookies if not provided (for cloudflare)
        if request.value(forHTTPHeaderField: "User-Agent") == nil {
            request.setValue(
                await UserAgentProvider.shared.getUserAgent(),
                forHTTPHeaderField: "User-Agent"
            )
        }
        let cookies = HTTPCookie.requestHeaderFields(with: HTTPCookieStorage.shared.allCookies(for: url) ?? [])
        for (key, value) in cookies {
            if key == "Cookie" {
                var cookieString = value
                // keep cookies in original request
                if let oldCookie = request.value(forHTTPHeaderField: "Cookie") {
                    cookieString += "; " + oldCookie
                }
                request.setValue(cookieString, forHTTPHeaderField: "Cookie")
            } else {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }
        return request
    }

    /// Attempt to get a custom Home-like layout for listings.
    /// Returns nil if source doesn't provide custom Home-like layout.
    /// For now, only used internally by KomgaSourceRunner
    func getListingHome(listing: AidokuRunner.Listing) async throws -> Home? {
        if let runner = runner as? KomgaSourceRunner {
            try await runner.getListingHome(listing: listing)
        } else {
            nil
        }
    }

    func getSelectedLanguages() -> [String] {
        if languages.count > 1 {
            if config?.languageSelectType == .single {
                let selectedLanguage = UserDefaults.standard.string(forKey: "\(key).language")
                if let selectedLanguage {
                    return [selectedLanguage]
                } else {
                    return []
                }
            } else {
                let selectedLanguages = UserDefaults.standard.stringArray(forKey: "\(key).languages")
                return selectedLanguages ?? []
            }
        } else {
            return languages
        }
    }
}

extension AidokuRunner.Manga {
    func toOld() -> Manga {
        Manga(
            sourceId: sourceKey,
            id: key,
            title: title,
            author: authors.flatMap { $0.isEmpty ? nil : $0.joined(separator: ", ") },
            artist: artists.flatMap { $0.isEmpty ? nil : $0.joined(separator: ", ") },
            description: description,
            tags: tags,
            coverUrl: cover.flatMap({ URL(string: $0) }),
            url: url,
            status: {
                switch status {
                    case .unknown: .unknown
                    case .ongoing: .ongoing
                    case .completed: .completed
                    case .cancelled: .cancelled
                    case .hiatus: .hiatus
                }
            }(),
            nsfw: {
                switch contentRating {
                    case .unknown: .safe
                    case .safe: .safe
                    case .suggestive: .suggestive
                    case .nsfw: .nsfw
                }
            }(),
            viewer: {
                switch viewer {
                    case .unknown: .defaultViewer
                    case .rightToLeft: .rtl
                    case .leftToRight: .ltr
                    case .vertical: .vertical
                    case .webtoon: .scroll
                }
            }(),
            updateStrategy: updateStrategy,
            nextUpdateTime: nextUpdateTime.flatMap { Date(timeIntervalSince1970: TimeInterval($0)) },
        )
    }

    func isLocal() -> Bool {
        sourceKey == LocalSourceRunner.sourceKey
    }

    var uniqueKey: String {
        "\(sourceKey).\(key)"
    }

    var identifier: MangaIdentifier {
        .init(sourceKey: sourceKey, mangaKey: key)
    }
}

extension AidokuRunner.PublishingStatus {
    var title: String {
        switch self {
            case .unknown: NSLocalizedString("UNKNOWN")
            case .ongoing: NSLocalizedString("STATUS_ONGOING")
            case .completed: NSLocalizedString("STATUS_COMPLETED")
            case .cancelled: NSLocalizedString("STATUS_CANCELLED")
            case .hiatus: NSLocalizedString("STATUS_HIATUS")
        }
    }
}

extension AidokuRunner.ContentRating {
    var title: String {
        switch self {
            case .unknown: NSLocalizedString("UNKNOWN")
            case .safe: NSLocalizedString("SAFE")
            case .suggestive: NSLocalizedString("SUGGESTIVE")
            case .nsfw: NSLocalizedString("NSFW")
        }
    }
}

extension AidokuRunner.SourceContentRating {
    var title: String {
        switch self {
            case .safe: NSLocalizedString("SAFE")
            case .containsNsfw: NSLocalizedString("CONTAINS_NSFW")
            case .primarilyNsfw: NSLocalizedString("PRIMARILY_NSFW")
        }
    }

    var stringValue: String {
        switch self {
            case .safe: "safe"
            case .containsNsfw: "containsNsfw"
            case .primarilyNsfw: "primarilyNsfw"
        }
    }

    init?(stringValue: String) {
        switch stringValue {
            case "safe": self = .safe
            case "containsNsfw": self = .containsNsfw
            case "primarilyNsfw": self = .primarilyNsfw
            default: return nil
        }
    }
}

extension AidokuRunner.Chapter {
    func formattedTitle(forceMode: ChapterTitleDisplayMode = .default) -> String {
        if forceMode == .default {
            if volumeNumber == nil && (title?.isEmpty ?? true) {
                // Chapter X
                return if let chapterNumber {
                    String(format: NSLocalizedString("CHAPTER_X"), chapterNumber)
                } else {
                    NSLocalizedString("UNTITLED")
                }
            } else if let volumeNumber, chapterNumber == nil && title == nil {
                return String(format: NSLocalizedString("VOLUME_X"), volumeNumber)
            } else {
                var components: [String] = []
                // Vol.X
                if let volumeNumber {
                    components.append(
                        String(format: NSLocalizedString("VOL_X"), volumeNumber)
                    )
                }
                // Ch.X
                if let chapterNumber {
                    components.append(
                        String(format: NSLocalizedString("CH_X"), chapterNumber)
                    )
                }
                // title
                if let title, !title.isEmpty {
                    if !components.isEmpty {
                        components.append("-")
                    }
                    components.append(title)
                }
                return components.joined(separator: " ")
            }
        } else {
            var components: [String] = []
            if forceMode == .chapter {
                if let chapterNumber {
                    components.append(String(format: NSLocalizedString("CHAPTER_X"), chapterNumber))
                } else if let volumeNumber {
                    components.append(String(format: NSLocalizedString("CHAPTER_X"), volumeNumber))
                }
            } else {
                if let volumeNumber {
                    components.append(String(format: NSLocalizedString("VOLUME_X"), volumeNumber))
                } else if let chapterNumber {
                    components.append(String(format: NSLocalizedString("VOLUME_X"), chapterNumber))
                }
            }
            if let title, !title.isEmpty {
                if !components.isEmpty {
                    components.append("-")
                }
                components.append(title)
            }
            return components.joined(separator: " ")
        }
    }

    func formattedSubtitle(page: Int?, sourceKey: String) -> String? {
        var components: [String] = []
        // date
        if let dateUploaded {
            components.append(makeRelativeDate(for: dateUploaded))
        }
        // page (if reading in progress)
        if let page, page > 0 {
            components.append(String(format: NSLocalizedString("PAGE_X"), page))
        }
        // scanlator
        if let scanlators, !scanlators.isEmpty {
            components.append(scanlators.joined(separator: ", "))
        }
        // language (if source has multiple enabled)
        if
            let language,
            let languageCount = UserDefaults.standard.array(forKey: "\(sourceKey).languages")?.count,
            languageCount > 1
        {
            components.append(language)
        }
        return components.isEmpty ? nil : components.joined(separator: " • ")
    }

    private func makeRelativeDate(for date: Date) -> String {
        let endOfDay = Date.endOfDay()
        let isInFuture = date > endOfDay
        let endDate = if isInFuture {
            // if the date is in the future, compare the difference to the start of the day instead of end
            Date.startOfDay()
        } else {
            endOfDay
        }
        let difference = Calendar.autoupdatingCurrent.dateComponents(
            Set([Calendar.Component.day]),
            from: date,
            to: endDate
        )
        let days = difference.day ?? 0

        if days <= 1 {
            // today or yesterday
            let formatter = DateFormatter()
            formatter.locale = Locale.autoupdatingCurrent
            formatter.dateStyle = .medium
            formatter.doesRelativeDateFormatting = true
            return formatter.string(from: date)
        } else if days < 7 {
            // n days ago
            let formatter = DateComponentsFormatter()
            formatter.unitsStyle = .short
            formatter.allowedUnits = .day
            guard let timePhrase = formatter.string(from: difference) else { return "" }
            return String(format: NSLocalizedString("%@_AGO", comment: ""), timePhrase)
        } else {
            return DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .none)
        }
    }

    func toOld(
        sourceId: String,
        mangaId: String,
        sourceOrder: Int? = nil
    ) -> Chapter {
        Chapter(
            sourceId: sourceId,
            id: key,
            mangaId: mangaId,
            title: title,
            scanlator: scanlators.flatMap { $0.isEmpty ? nil : $0.joined(separator: ", ") },
            url: url?.absoluteString,
            lang: language ?? "en",
            chapterNum: chapterNumber,
            volumeNum: volumeNumber,
            dateUploaded: dateUploaded,
            thumbnail: thumbnail,
            locked: locked,
            sourceOrder: sourceOrder ?? 0
        )
    }
}

extension AidokuRunner.Page {
    func toOld(sourceId: String, chapterId: String, language: String?) -> Page {
        switch content {
            case let .url(url, context):
                Page(
                    sourceId: sourceId,
                    chapterId: chapterId,
                    imageURL: url.absoluteString,
                    language: language,
                    context: context,
                    hasDescription: hasDescription,
                    description: description
                )
            case let .text(text):
                Page(
                    sourceId: sourceId,
                    chapterId: chapterId,
                    text: text,
                    language: language,
                    hasDescription: hasDescription,
                    description: description
                )
            case let .image(image):
                Page(
                    sourceId: sourceId,
                    chapterId: chapterId,
                    image: image.image,
                    language: language,
                    hasDescription: hasDescription,
                    description: description
                )
            case let .zipFile(url, filePath):
                Page(
                    sourceId: sourceId,
                    chapterId: chapterId,
                    imageURL: filePath,
                    zipURL: url.absoluteString,
                    language: language,
                    hasDescription: hasDescription,
                    description: description
                )
        }
    }
}

extension AidokuRunner.SelectFilter {
    var resolvedDefaultValue: String {
        defaultValue ?? ids?.first ?? options.first ?? ""
    }
}
