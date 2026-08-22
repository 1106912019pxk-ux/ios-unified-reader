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

    @discardableResult
    func importFonts(_ urls: [URL]) throws -> [Font] {
        var importedFileNames: [String] = []
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
            let destinationURL = safeDestination(forExtension: ext)
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
            importedFileNames.append(destinationURL.lastPathComponent)
        }
        refresh()
        let importedNames = Set(importedFileNames)
        return fonts.filter { importedNames.contains($0.fileName) }
    }

    func font(named familyName: String?) -> Font? {
        guard let familyName else { return nil }
        return fonts.first { $0.familyName == familyName }
    }

    func refresh() {
        let urls = (try? fileManager.contentsOfDirectory(
            at: fontsDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        let normalizedURLs = urls.map(normalizeFontFileName)
        fonts = normalizedURLs.compactMap { url in
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

    func readiumDeclarations(for familyName: String?) -> [AnyHTMLFontFamilyDeclaration] {
        guard let font = font(named: familyName),
              let url = FileURL(url: font.url)
        else { return [] }
        return [
            CSSFontFamilyDeclaration(
                fontFamily: FontFamily(rawValue: font.familyName),
                fontFaces: [CSSFontFace(file: url)]
            ).eraseToAnyHTMLFontFamilyDeclaration(),
        ]
    }

    private func normalizeFontFileName(_ url: URL) -> URL {
        let stem = url.deletingPathExtension().lastPathComponent
        guard UUID(uuidString: stem) == nil else { return url }

        let destinationURL = safeDestination(forExtension: url.pathExtension.lowercased())
        do {
            try fileManager.moveItem(at: url, to: destinationURL)
            return destinationURL
        } catch {
            return url
        }
    }

    private func safeDestination(forExtension ext: String) -> URL {
        var candidate: URL
        repeat {
            candidate = fontsDirectory.appendingPathComponent("\(UUID().uuidString).\(ext)")
        } while fileManager.fileExists(atPath: candidate.path)
        return candidate
    }
}
