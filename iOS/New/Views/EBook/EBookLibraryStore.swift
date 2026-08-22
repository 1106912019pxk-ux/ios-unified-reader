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
    private let metadataURL: URL
    private let fileManager: FileManager

    private init(fileManager: FileManager = .default) {
        self.fileManager = fileManager

        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        booksDirectory = documents.appendingPathComponent("EBooks", isDirectory: true)

        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        metadataDirectory = applicationSupport.appendingPathComponent("EBookReader", isDirectory: true)
        metadataURL = metadataDirectory.appendingPathComponent("library.json")

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
    func importFiles(_ urls: [URL]) throws -> [EBook] {
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

            let destinationURL = uniqueDestination(for: sourceURL.lastPathComponent)
            try fileManager.copyItem(at: sourceURL, to: destinationURL)

            let book = EBook(
                fileName: destinationURL.lastPathComponent,
                format: format,
                title: destinationURL.deletingPathExtension().lastPathComponent
            )
            books.append(book)
            imported.append(book)
        }

        sortBooks()
        try save()
        lastError = nil
        return imported
    }

    func fileURL(for book: EBook) -> URL {
        booksDirectory.appendingPathComponent(book.fileName, isDirectory: false)
    }

    func delete(_ book: EBook) throws {
        let url = fileURL(for: book)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        books.removeAll { $0.id == book.id }
        try save()
    }

    func updateMetadata(for id: UUID, title: String?, author: String?) {
        mutateBook(id) { book in
            if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                book.title = title
            }
            if let author, !author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                book.author = author
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

    func savePreferences(_ preferences: EBookPreferences, for id: UUID) {
        mutateBook(id) { $0.preferences = preferences }
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

    private func prepareDirectories() throws {
        try fileManager.createDirectory(at: booksDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: metadataDirectory, withIntermediateDirectories: true)
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
                title: url.deletingPathExtension().lastPathComponent
            ))
        }

        sortBooks()
        try save()
    }

    private func uniqueDestination(for originalName: String) -> URL {
        let originalURL = URL(fileURLWithPath: originalName)
        let stem = originalURL.deletingPathExtension().lastPathComponent
        let ext = originalURL.pathExtension
        var candidate = booksDirectory.appendingPathComponent(originalName)
        var suffix = 2

        while fileManager.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(stem) \(suffix)" : "\(stem) \(suffix).\(ext)"
            candidate = booksDirectory.appendingPathComponent(name)
            suffix += 1
        }
        return candidate
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

    var errorDescription: String? {
        switch self {
        case let .unsupportedFormat(extensionName):
            return extensionName.isEmpty
                ? NSLocalizedString("EBOOK_ERROR_UNSUPPORTED_FILE", comment: "Unsupported e-book file error")
                : String(
                    format: NSLocalizedString("EBOOK_ERROR_UNSUPPORTED_FORMAT", comment: "Unsupported e-book format error"),
                    extensionName
                )
        }
    }
}
