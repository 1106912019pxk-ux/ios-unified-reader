//
//  EBookFontStore.swift
//  Aidoku
//

import CoreText
import Combine
import Foundation
import ReadiumNavigator
import ReadiumShared
import SwiftUI
import UIKit
import UniformTypeIdentifiers

@MainActor
final class EBookFontStore: ObservableObject {
    struct Font: Identifiable, Hashable {
        var id: String { fileName }
        let familyName: String
        let fileName: String
        let url: URL
    }

    static let shared = EBookFontStore()
    static let systemFontFamily = "system-ui"

    static var builtInFontFamilies: [String] {
        let available = Set(UIFont.familyNames)
        return [
            "PingFang SC",
            "PingFang TC",
            "Songti SC",
            "Songti TC",
            "Kaiti SC",
            "Kaiti TC",
            "Hiragino Sans",
            "Hiragino Mincho ProN",
            "Helvetica Neue",
        ].filter(available.contains)
    }

    @Published private(set) var fonts: [Font] = []

    let fontsDirectory: URL
    private let fileManager = FileManager.default
    private var allFontFiles: [Font] = []

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
        return allFontFiles.filter { importedNames.contains($0.fileName) }
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
        allFontFiles = normalizedURLs.compactMap { url in
            guard ["ttf", "otf"].contains(url.pathExtension.lowercased()) else { return nil }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor]
            let family = descriptors?.first.flatMap {
                CTFontDescriptorCopyAttribute($0, kCTFontFamilyNameAttribute) as? String
            } ?? url.deletingPathExtension().lastPathComponent
            return Font(familyName: family, fileName: url.lastPathComponent, url: url)
        }
        .sorted { $0.familyName.localizedCaseInsensitiveCompare($1.familyName) == .orderedAscending }

        var seenFamilies = Set<String>()
        fonts = allFontFiles.filter {
            seenFamilies.insert($0.familyName.lowercased()).inserted
        }
    }

    func deleteImportedFont(familyName: String) throws {
        let matchingFiles = allFontFiles.filter {
            $0.familyName.caseInsensitiveCompare(familyName) == .orderedSame
        }
        guard !matchingFiles.isEmpty else { return }

        defer { refresh() }
        for font in matchingFiles {
            CTFontManagerUnregisterFontsForURL(font.url as CFURL, .process, nil)
            try fileManager.removeItem(at: font.url)
        }
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

@MainActor
struct EBookDefaultFontSettingView: View {
    @State private var selectedFamily: String?

    init() {
        EBookPreferences.registerGlobalDefaults()
        let family = UserDefaults.standard.string(forKey: EBookPreferences.defaultFontFamilyKey)
        _selectedFamily = State(initialValue: family?.isEmpty == false ? family : nil)
    }

    var body: some View {
        NavigationLink {
            EBookFontManagementView(selectedFamily: $selectedFamily)
        } label: {
            HStack {
                Text(NSLocalizedString("EBOOK_DEFAULT_FONT", comment: "Default e-book font setting"))
                Spacer()
                Text(displayName(for: selectedFamily))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private func displayName(for familyName: String?) -> String {
        guard let familyName else {
            return NSLocalizedString("EBOOK_BOOK_DEFAULT_FONT", comment: "Use book default font option")
        }
        if familyName == EBookFontStore.systemFontFamily {
            return NSLocalizedString("EBOOK_SYSTEM_FONT", comment: "System e-book font")
        }
        return familyName
    }
}

@MainActor
private struct EBookFontManagementView: View {
    @ObservedObject private var fontStore = EBookFontStore.shared
    @Binding var selectedFamily: String?

    @State private var isImporting = false
    @State private var message: String?
    @State private var pendingDeletion: EBookFontStore.Font?

    var body: some View {
        List {
            Section {
                selectionButton(
                    title: NSLocalizedString("EBOOK_BOOK_DEFAULT_FONT", comment: "Use book default font option"),
                    familyName: nil
                )
                selectionButton(
                    title: NSLocalizedString("EBOOK_SYSTEM_FONT", comment: "System e-book font"),
                    familyName: EBookFontStore.systemFontFamily
                )
            }

            if !EBookFontStore.builtInFontFamilies.isEmpty {
                Section(NSLocalizedString("EBOOK_BUILT_IN_FONTS", comment: "Built-in e-book fonts")) {
                    ForEach(EBookFontStore.builtInFontFamilies, id: \.self) { family in
                        selectionButton(title: family, familyName: family)
                    }
                }
            }

            if !fontStore.fonts.isEmpty {
                Section(NSLocalizedString("EBOOK_IMPORTED_FONTS", comment: "Imported e-book fonts")) {
                    ForEach(fontStore.fonts) { font in
                        selectionButton(title: font.familyName, familyName: font.familyName)
                            .contextMenu {
                                Button(role: .destructive) {
                                    pendingDeletion = font
                                } label: {
                                    Label(
                                        NSLocalizedString("EBOOK_DELETE_FONT", comment: "Delete imported e-book font"),
                                        systemImage: "trash"
                                    )
                                }
                            }
                            .swipeActions {
                                Button(role: .destructive) {
                                    pendingDeletion = font
                                } label: {
                                    Label(
                                        NSLocalizedString("EBOOK_DELETE_FONT", comment: "Delete imported e-book font"),
                                        systemImage: "trash"
                                    )
                                }
                            }
                    }
                }
            }

            Section {
                Button {
                    isImporting = true
                } label: {
                    Label(
                        NSLocalizedString("EBOOK_IMPORT_FONT", comment: "Import e-book font action"),
                        systemImage: "text.badge.plus"
                    )
                }
            }
        }
        .navigationTitle(NSLocalizedString("EBOOK_DEFAULT_FONT", comment: "Default e-book font"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isImporting) {
            DocumentPickerView(
                allowedContentTypes: Self.fontContentTypes,
                allowsMultipleSelection: true
            ) { urls in
                isImporting = false
                guard !urls.isEmpty else { return }
                do {
                    let importedFonts = try fontStore.importFonts(urls)
                    if let firstFont = importedFonts.first {
                        select(firstFont.familyName)
                    }
                    message = NSLocalizedString("EBOOK_FONT_IMPORTED_AVAILABLE", comment: "Imported font available message")
                } catch {
                    message = error.localizedDescription
                }
            }
        }
        .alert(NSLocalizedString("EBOOK_FONT", comment: "E-book font setting"), isPresented: Binding(
            get: { message != nil },
            set: { if !$0 { message = nil } }
        )) {
            Button(NSLocalizedString("OK", comment: ""), role: .cancel) {}
        } message: {
            Text(message ?? "")
        }
        .confirmationDialog(
            NSLocalizedString("EBOOK_DELETE_FONT", comment: "Delete imported e-book font"),
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(NSLocalizedString("DELETE", comment: ""), role: .destructive) {
                deletePendingFont()
            }
            Button(NSLocalizedString("CANCEL", comment: ""), role: .cancel) {
                pendingDeletion = nil
            }
        } message: {
            Text(pendingDeletion?.familyName ?? "")
        }
    }

    private func selectionButton(title: String, familyName: String?) -> some View {
        Button {
            select(familyName)
        } label: {
            HStack {
                Text(title)
                    .foregroundStyle(.primary)
                Spacer()
                if selectedFamily == familyName {
                    Image(systemName: "checkmark")
                }
            }
        }
    }

    private func select(_ familyName: String?) {
        selectedFamily = familyName
        EBookPreferences.saveGlobalDefaultFontFamily(familyName)
    }

    private func deletePendingFont() {
        guard let font = pendingDeletion else { return }
        pendingDeletion = nil
        do {
            try fontStore.deleteImportedFont(familyName: font.familyName)
            if selectedFamily?.caseInsensitiveCompare(font.familyName) == .orderedSame {
                select(nil)
            }
        } catch {
            message = error.localizedDescription
        }
    }

    private static var fontContentTypes: [UTType] {
        ["ttf", "otf"].compactMap { UTType(filenameExtension: $0) }
    }
}
