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
        case .invalidFileURL: "The e-book file URL is invalid."
        case .missingFile: "The e-book file no longer exists."
        case .restrictedPublication: "This protected publication cannot be opened."
        case let .unsupportedReader(format): "The \(format.displayName) reader is not available."
        }
    }
}
