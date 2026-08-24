//
//  LocalModels.swift
//  Aidoku
//
//  Created by Skitty on 6/10/25.
//

import Foundation

enum LocalFileManagerError: Error {
    case invalidFileType
    case cannotReadArchive
    case noImagesFound
    case cannotReadText
    case invalidChapterPattern
    case tooManyChapters
    case fileCopyFailed
}

struct LocalSeriesInfo: Hashable {
    let coverUrl: String
    let name: String
    let chapterCount: Int
}

enum LocalFileType {
    case cbz
    case zip
    case epub
    case txt

    var localizedName: String {
        switch self {
            case .cbz: NSLocalizedString("CBZ_NAME")
            case .zip: NSLocalizedString("ZIP_NAME")
            case .epub: NSLocalizedString("EPUB_NAME")
            case .txt: NSLocalizedString("TXT_NAME")
        }
    }
}

struct ImportFileInfo: Hashable {
    let url: URL
    let previewImages: [PlatformImage]
    let name: String
    let pageCount: Int
    let fileType: LocalFileType
    let comicInfo: ComicInfo?
    let txtAnalysis: TxtAnalysis?

    init(
        url: URL,
        previewImages: [PlatformImage],
        name: String,
        pageCount: Int,
        fileType: LocalFileType,
        comicInfo: ComicInfo?,
        txtAnalysis: TxtAnalysis? = nil
    ) {
        self.url = url
        self.previewImages = previewImages
        self.name = name
        self.pageCount = pageCount
        self.fileType = fileType
        self.comicInfo = comicInfo
        self.txtAnalysis = txtAnalysis
    }
}
