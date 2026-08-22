//
//  EBookReadiumService.swift
//  Aidoku
//

import Foundation
import ReadiumShared
import ReadiumStreamer
import UIKit

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

    func openEPUB(at url: URL, sender: UIViewController) async throws -> Publication {
        guard let fileURL = FileURL(url: url) else {
            throw EBookReaderError.invalidFileURL
        }
        let asset = try await assetRetriever.retrieve(url: fileURL).get()
        let publication = try await publicationOpener.open(
            asset: asset,
            allowUserInteraction: false,
            sender: sender
        ).get()
        guard !publication.isRestricted else {
            throw EBookReaderError.restrictedPublication
        }
        return publication
    }
}

enum EBookReaderError: LocalizedError {
    case invalidFileURL
    case missingFile
    case restrictedPublication
    case unsupportedReader(EBookFormat)

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
        }
    }
}
