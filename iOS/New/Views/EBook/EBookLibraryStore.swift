//
//  EBookLibraryStore.swift
//  Aidoku
//

import Combine
import Foundation

@MainActor
final class EBookLibraryStore: ObservableObject {
    static let shared = EBookLibraryStore()

    @Published private(set) var books: [EBook] = []
    @Published private(set) var lastError: String?

    let booksDirectory: URL

    private let metadataDirectory: URL
    private let coversDirectory: URL
    private let metadataURL: URL
    private let fileManager: FileManager

    private init(fileManager: FileManager = .default) {
        self.fileManager = fileManager

        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        booksDirectory = documents.appendingPathComponent("EBooks", isDirectory: true)

        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        metadataDirectory = applicationSupport.appendingPathComponent("EBookReader", isDirectory: true)
        coversDirectory = metadataDirectory.appendingPathComponent("Covers", isDirectory: true)
        metadataURL = metadataDirectory.appendingPathComponent("library.json")

        EBookPreferences.registerGlobalDefaults()

        do {
            try prepareDirectories()
            try load()
            try reconcileFiles()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func refresh() {
        do {
            try reconcileFiles()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    @discardableResult
    func importFiles(_ urls: [URL]) async throws -> [EBook] {
        var imported: [EBook] = []

        for sourceURL in urls {
            guard let format = EBookFormat.detect(from: sourceURL) else {
                throw EBookLibraryError.unsupportedFormat(sourceURL.pathExtension)
            }

            let didStartAccess = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if didStartAccess {
                    sourceURL.stopAccessingSecurityScopedResource()
                }
            }

            if format == .epub {
                try EBookReadiumService.validateEPUBArchive(at: sourceURL)
            }

            let id = UUID()
            let ext = sourceURL.pathExtension.lowercased()
            let destinationURL = booksDirectory.appendingPathComponent(
                ext.isEmpty ? id.uuidString : "\(id.uuidString).\(ext)",
                isDirectory: false
            )
            try coordinatedCopy(from: sourceURL, to: destinationURL)

            do {
                let metadata: EBookPublicationMetadata?
                if format == .epub {
                    try EBookReadiumService.validateEPUBArchive(at: destinationURL)
                    metadata = try await EBookReadiumService.shared.inspectEPUB(at: destinationURL)
                } else {
                    metadata = nil
                }

                let coverFileName: String?
                if let coverData = metadata?.coverData {
                    coverFileName = try saveCover(coverData, for: id)
                } else {
                    coverFileName = nil
                }
                let fallbackTitle = sourceURL.deletingPathExtension().lastPathComponent
                let book = EBook(
                    id: id,
                    fileName: destinationURL.lastPathComponent,
                    format: format,
                    title: metadata?.title ?? fallbackTitle,
                    author: metadata?.author,
                    coverFileName: coverFileName,
                    preferences: EBookPreferences.globalDefaults
                )
                books.append(book)
                imported.append(book)
            } catch {
                try? fileManager.removeItem(at: destinationURL)
                throw error
            }
        }

        sortBooks()
        try save()
        lastError = nil
        return imported
    }

    func fileURL(for book: EBook) -> URL {
        booksDirectory.appendingPathComponent(book.fileName, isDirectory: false)
    }

    func coverURL(for book: EBook) -> URL? {
        guard let coverFileName = book.coverFileName else { return nil }
        let url = coversDirectory.appendingPathComponent(coverFileName, isDirectory: false)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    func refreshEPUBMetadata() async {
        let candidates = books.filter { $0.format == .epub && $0.coverFileName == nil }
        for book in candidates {
            do {
                let metadata = try await EBookReadiumService.shared.inspectEPUB(at: fileURL(for: book))
                updateMetadata(
                    for: book.id,
                    title: metadata.title,
                    author: metadata.author,
                    coverData: metadata.coverData
                )
            } catch {
                // Keep the book available so opening it can show the complete diagnostic.
            }
        }
    }

    func delete(_ book: EBook) throws {
        let url = fileURL(for: book)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        if let coverURL = coverURL(for: book) {
            try? fileManager.removeItem(at: coverURL)
        }
        books.removeAll { $0.id == book.id }
        try save()
    }

    func updateMetadata(for id: UUID, title: String?, author: String?, coverData: Data? = nil) {
        var coverFileName: String?
        if let coverData {
            do {
                coverFileName = try saveCover(coverData, for: id)
            } catch {
                lastError = error.localizedDescription
            }
        }

        mutateBook(id) { book in
            if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                book.title = title
            }
            if let author, !author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                book.author = author
            }
            if let coverFileName {
                book.coverFileName = coverFileName
            }
        }
    }

    func markOpened(_ id: UUID) {
        mutateBook(id) { $0.lastOpenedAt = Date() }
    }

    func saveLocator(_ locatorJSON: String, for id: UUID) {
        mutateBook(id) { $0.locatorJSON = locatorJSON }
    }

    func savePDFPage(_ pageIndex: Int, for id: UUID) {
        mutateBook(id) { $0.pdfPageIndex = pageIndex }
    }

    func effectivePreferences(for book: EBook) -> EBookPreferences {
        book.usesGlobalPreferences ? EBookPreferences.globalDefaults : book.preferences
    }

    func savePreferences(_ preferences: EBookPreferences, for id: UUID) {
        mutateBook(id) {
            $0.preferences = preferences
            $0.usesGlobalPreferences = false
        }
    }

    func resetPreferencesToGlobal(for id: UUID) {
        mutateBook(id) {
            $0.preferences = EBookPreferences.globalDefaults
            $0.usesGlobalPreferences = true
        }
    }

    func applyGlobalPreferences(_ preferences: EBookPreferences) {
        EBookPreferences.saveGlobalDefaults(preferences)
        for index in books.indices {
            books[index].preferences = preferences
            books[index].usesGlobalPreferences = true
        }
        sortBooks()
        do {
            try save()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func addBookmark(title: String, locatorJSON: String, to id: UUID) {
        mutateBook(id) { book in
            guard !book.bookmarks.contains(where: { $0.locatorJSON == locatorJSON }) else { return }
            book.bookmarks.append(EBookBookmark(title: title, locatorJSON: locatorJSON))
        }
    }

    func removeBookmark(locatorJSON: String, from id: UUID) {
        mutateBook(id) { book in
            book.bookmarks.removeAll { $0.locatorJSON == locatorJSON }
        }
    }

    func book(withID id: UUID) -> EBook? {
        books.first { $0.id == id }
    }

    private func coordinatedCopy(from sourceURL: URL, to destinationURL: URL) throws {
        var coordinationError: NSError?
        var copyError: Error?
        var coordinatedSourceURL: URL?

        NSFileCoordinator().coordinate(
            readingItemAt: sourceURL,
            options: .withoutChanges,
            error: &coordinationError
        ) { readableURL in
            coordinatedSourceURL = readableURL
            do {
                try fileManager.copyItem(at: readableURL, to: destinationURL)
            } catch {
                copyError = error
            }
        }

        if let coordinationError {
            try? fileManager.removeItem(at: destinationURL)
            throw coordinationError
        }
        if let copyError {
            try? fileManager.removeItem(at: destinationURL)
            throw copyError
        }
        guard let coordinatedSourceURL else {
            try? fileManager.removeItem(at: destinationURL)
            throw EBookLibraryError.copyFailed
        }

        let sourceSize = try fileSize(at: coordinatedSourceURL)
        let destinationSize = try fileSize(at: destinationURL)
        guard sourceSize > 0 else {
            try? fileManager.removeItem(at: destinationURL)
            throw EBookLibraryError.emptyFile
        }
        guard sourceSize == destinationSize else {
            try? fileManager.removeItem(at: destinationURL)
            throw EBookLibraryError.incompleteCopy(expected: sourceSize, actual: destinationSize)
        }
    }

    private func fileSize(at url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values.fileSize ?? 0)
    }

    private func prepareDirectories() throws {
        try fileManager.createDirectory(at: booksDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: metadataDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: coversDirectory, withIntermediateDirectories: true)
    }

    private func load() throws {
        guard fileManager.fileExists(atPath: metadataURL.path) else {
            books = []
            return
        }
        let data = try Data(contentsOf: metadataURL)
        books = try JSONDecoder().decode([EBook].self, from: data)
    }

    private func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(books)
        try data.write(to: metadataURL, options: .atomic)
    }

    private func reconcileFiles() throws {
        try migrateStoredFileNames()

        let urls = try fileManager.contentsOfDirectory(
            at: booksDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        let validFiles = urls.filter { url in
            guard EBookFormat.detect(from: url) != nil else { return false }
            return (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
        let validNames = Set(validFiles.map(\.lastPathComponent))

        books.removeAll { !validNames.contains($0.fileName) }
        let knownNames = Set(books.map(\.fileName))
        for url in validFiles where !knownNames.contains(url.lastPathComponent) {
            guard let format = EBookFormat.detect(from: url) else { continue }
            books.append(EBook(
                fileName: url.lastPathComponent,
                format: format,
                title: url.deletingPathExtension().lastPathComponent,
                preferences: EBookPreferences.globalDefaults
            ))
        }

        sortBooks()
        try save()
    }

    private func migrateStoredFileNames() throws {
        for index in books.indices {
            let currentURL = fileURL(for: books[index])
            guard fileManager.fileExists(atPath: currentURL.path) else { continue }

            let ext = currentURL.pathExtension.lowercased()
            let desiredName = ext.isEmpty
                ? books[index].id.uuidString
                : "\(books[index].id.uuidString).\(ext)"
            guard books[index].fileName != desiredName else { continue }

            let destinationURL = booksDirectory.appendingPathComponent(desiredName, isDirectory: false)
            guard !fileManager.fileExists(atPath: destinationURL.path) else { continue }
            try fileManager.moveItem(at: currentURL, to: destinationURL)
            books[index].fileName = desiredName
        }
    }

    private func saveCover(_ data: Data, for id: UUID) throws -> String {
        let fileName = "\(id.uuidString).png"
        let url = coversDirectory.appendingPathComponent(fileName, isDirectory: false)
        try data.write(to: url, options: .atomic)
        return fileName
    }

    private func sortBooks() {
        books.sort {
            ($0.lastOpenedAt ?? $0.addedAt) > ($1.lastOpenedAt ?? $1.addedAt)
        }
    }

    private func mutateBook(_ id: UUID, _ mutation: (inout EBook) -> Void) {
        guard let index = books.firstIndex(where: { $0.id == id }) else { return }
        mutation(&books[index])
        sortBooks()
        do {
            try save()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }
}

enum EBookLibraryError: LocalizedError {
    case unsupportedFormat(String)
    case copyFailed
    case emptyFile
    case incompleteCopy(expected: Int64, actual: Int64)

    var errorDescription: String? {
        switch self {
        case let .unsupportedFormat(extensionName):
            return extensionName.isEmpty
                ? NSLocalizedString("EBOOK_ERROR_UNSUPPORTED_FILE", comment: "Unsupported e-book file error")
                : String(
                    format: NSLocalizedString("EBOOK_ERROR_UNSUPPORTED_FORMAT", comment: "Unsupported e-book format error"),
                    extensionName
                )
        case .copyFailed:
            return NSLocalizedString("EBOOK_ERROR_COPY_FAILED", comment: "E-book coordinated copy failure")
        case .emptyFile:
            return NSLocalizedString("EBOOK_ERROR_EMPTY_FILE", comment: "Empty e-book file error")
        case let .incompleteCopy(expected, actual):
            return String(
                format: NSLocalizedString("EBOOK_ERROR_INCOMPLETE_COPY", comment: "Incomplete e-book copy error"),
                expected,
                actual
            )
        }
    }
}
