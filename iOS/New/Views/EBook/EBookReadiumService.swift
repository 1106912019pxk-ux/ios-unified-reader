//
//  EBookReadiumService.swift
//  Aidoku
//

import Foundation
import ReadiumShared
import ReadiumStreamer
import UIKit

struct EBookPublicationMetadata: Sendable {
    var title: String?
    var author: String?
    var coverData: Data?
}

final class EBookReadiumService {
    static let shared = EBookReadiumService()

    private let assetRetriever: AssetRetriever
    private let publicationOpener: PublicationOpener

    private init() {
        let httpClient = DefaultHTTPClient()
        let assetRetriever = AssetRetriever(httpClient: httpClient)
        self.assetRetriever = assetRetriever
        publicationOpener = PublicationOpener(
            parser: DefaultPublicationParser(
                httpClient: httpClient,
                assetRetriever: assetRetriever,
                pdfFactory: DefaultPDFDocumentFactory()
            ),
            contentProtections: []
        )
    }

    func inspectEPUB(at url: URL) async throws -> EBookPublicationMetadata {
        let publication = try await openEPUB(at: url, sender: nil)
        let coverData = try? await publication.cover().get()?.pngData()
        return EBookPublicationMetadata(
            title: publication.metadata.title,
            author: publication.metadata.authors.map(\.name).joined(separator: ", ").nilIfEmpty,
            coverData: coverData
        )
    }

    func openEPUB(at url: URL, sender: UIViewController?) async throws -> Publication {
        guard let fileURL = FileURL(url: url) else {
            throw EBookReaderError.invalidFileURL
        }

        let asset: Asset
        switch await assetRetriever.retrieve(url: fileURL, mediaType: .epub) {
        case let .success(value):
            asset = value
        case let .failure(error):
            throw EBookReaderError.assetRetrievalFailed(Self.describe(error))
        }

        let publication: Publication
        switch await publicationOpener.open(
            asset: asset,
            allowUserInteraction: false,
            sender: sender
        ) {
        case let .success(value):
            publication = value
        case let .failure(error):
            throw EBookReaderError.publicationOpenFailed(Self.describe(error))
        }

        guard !publication.isRestricted else {
            throw EBookReaderError.restrictedPublication
        }
        return publication
    }

    private static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return "\(String(describing: error)) — \(underlying.localizedDescription)"
        }
        return String(describing: error)
    }
}

enum EBookReaderError: LocalizedError {
    case invalidFileURL
    case missingFile
    case restrictedPublication
    case unsupportedReader(EBookFormat)
    case assetRetrievalFailed(String)
    case publicationOpenFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidFileURL:
            NSLocalizedString("EBOOK_ERROR_INVALID_FILE_URL", comment: "Invalid e-book file URL error")
        case .missingFile:
            NSLocalizedString("EBOOK_ERROR_MISSING_FILE", comment: "Missing e-book file error")
        case .restrictedPublication:
            NSLocalizedString("EBOOK_ERROR_RESTRICTED_PUBLICATION", comment: "Protected e-book error")
        case let .unsupportedReader(format):
            String(
                format: NSLocalizedString("EBOOK_ERROR_READER_UNAVAILABLE", comment: "Unavailable e-book reader error"),
                format.displayName
            )
        case let .assetRetrievalFailed(detail):
            String(
                format: NSLocalizedString("EBOOK_ERROR_EPUB_ARCHIVE", comment: "Unreadable EPUB archive error"),
                detail
            )
        case let .publicationOpenFailed(detail):
            String(
                format: NSLocalizedString("EBOOK_ERROR_EPUB_STRUCTURE", comment: "Invalid EPUB structure error"),
                detail
            )
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
