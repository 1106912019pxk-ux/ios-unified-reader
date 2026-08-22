//
//  EBookFontStore.swift
//  Aidoku
//

import CoreText
import Combine
import Foundation
import ReadiumNavigator
import ReadiumShared

@MainActor
final class EBookFontStore: ObservableObject {
    struct Font: Identifiable, Hashable {
        var id: String { fileName }
        let familyName: String
        let fileName: String
        let url: URL
    }

    static let shared = EBookFontStore()

    @Published private(set) var fonts: [Font] = []

    let fontsDirectory: URL
    private let fileManager = FileManager.default

    private init() {
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        fontsDirectory = documents
            .appendingPathComponent("EBooks", isDirectory: true)
            .appendingPathComponent("Fonts", isDirectory: true)
        try? fileManager.createDirectory(at: fontsDirectory, withIntermediateDirectories: true)
        refresh()
    }

    func importFonts(_ urls: [URL]) throws {
        for sourceURL in urls {
            let ext = sourceURL.pathExtension.lowercased()
            guard ext == "ttf" || ext == "otf" else {
                throw EBookLibraryError.unsupportedFormat(ext)
            }
            let didStartAccess = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if didStartAccess {
                    sourceURL.stopAccessingSecurityScopedResource()
                }
            }
            let destinationURL = uniqueDestination(for: sourceURL.lastPathComponent)
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
        }
        refresh()
    }

    func refresh() {
        let urls = (try? fileManager.contentsOfDirectory(
            at: fontsDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        fonts = urls.compactMap { url in
            guard ["ttf", "otf"].contains(url.pathExtension.lowercased()) else { return nil }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor]
            let family = descriptors?.first.flatMap {
                CTFontDescriptorCopyAttribute($0, kCTFontFamilyNameAttribute) as? String
            } ?? url.deletingPathExtension().lastPathComponent
            return Font(familyName: family, fileName: url.lastPathComponent, url: url)
        }
        .sorted { $0.familyName.localizedCaseInsensitiveCompare($1.familyName) == .orderedAscending }
    }

    func readiumDeclarations() -> [AnyHTMLFontFamilyDeclaration] {
        fonts.compactMap { font in
            guard let url = FileURL(url: font.url) else { return nil }
            return CSSFontFamilyDeclaration(
                fontFamily: FontFamily(rawValue: font.familyName),
                fontFaces: [CSSFontFace(file: url)]
            ).eraseToAnyHTMLFontFamilyDeclaration()
        }
    }

    private func uniqueDestination(for originalName: String) -> URL {
        let originalURL = URL(fileURLWithPath: originalName)
        let stem = originalURL.deletingPathExtension().lastPathComponent
        let ext = originalURL.pathExtension
        var candidate = fontsDirectory.appendingPathComponent(originalName)
        var suffix = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = fontsDirectory.appendingPathComponent("\(stem) \(suffix).\(ext)")
            suffix += 1
        }
        return candidate
    }
}
