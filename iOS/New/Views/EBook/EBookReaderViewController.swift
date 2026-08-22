//
//  EBookReaderViewController.swift
//  Aidoku
//

import PDFKit
import ReadiumNavigator
import ReadiumShared
import SwiftUI
import UniformTypeIdentifiers
import WebKit

@MainActor
final class EBookReaderViewController: UIViewController {
    private let bookID: UUID
    private let store: EBookLibraryStore

    private var loadingTask: Task<Void, Never>?
    private var publication: Publication?
    private var epubNavigator: EPUBNavigatorViewController?
    private var pdfView: PDFView?
    private var webView: WKWebView?
    private var pageChangeObserver: NSObjectProtocol?

    init(bookID: UUID, store: EBookLibraryStore = .shared) {
        self.bookID = bookID
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        loadingTask?.cancel()
        if let pageChangeObserver {
            NotificationCenter.default.removeObserver(pageChangeObserver)
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        navigationItem.largeTitleDisplayMode = .never
        showLoadingView()

        loadingTask = Task { [weak self] in
            guard let self else { return }
            await self.openBook()
        }
    }

    private func openBook() async {
        guard let book = store.book(withID: bookID) else {
            showError(EBookReaderError.missingFile)
            return
        }
        title = book.title
        store.markOpened(book.id)

        let url = store.fileURL(for: book)
        guard FileManager.default.fileExists(atPath: url.path) else {
            showError(EBookReaderError.missingFile)
            return
        }

        do {
            switch book.format {
            case .epub:
                try await openEPUB(book, at: url)
            case .pdf:
                try openPDF(book, at: url)
            case .text, .markdown, .html:
                try openWebDocument(book, at: url)
            }
        } catch is CancellationError {
            return
        } catch {
            showError(error)
        }
    }

    private func openEPUB(_ book: EBook, at url: URL) async throws {
        let publication = try await EBookReadiumService.shared.openEPUB(at: url, sender: self)
        let initialLocation = book.locatorJSON.flatMap { try? Locator(jsonString: $0) }
        let preferences = Self.readiumPreferences(from: book.preferences)
        let navigator = try EPUBNavigatorViewController(
            publication: publication,
            initialLocation: initialLocation,
            config: .init(
                preferences: preferences,
                fontFamilyDeclarations: EBookFontStore.shared.readiumDeclarations()
            )
        )
        navigator.delegate = self

        self.publication = publication
        epubNavigator = navigator
        store.updateMetadata(
            for: book.id,
            title: publication.metadata.title,
            author: publication.metadata.authors.map(\.name).joined(separator: ", ")
        )
        title = publication.metadata.title ?? book.title
        installChild(navigator)
        configureEPUBButtons()
    }

    private func openPDF(_ book: EBook, at url: URL) throws {
        guard let document = PDFDocument(url: url) else {
            throw EBookReaderError.invalidFileURL
        }
        let pdfView = PDFView()
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.backgroundColor = .systemBackground
        pdfView.document = document
        if let pageIndex = book.pdfPageIndex,
           let page = document.page(at: pageIndex) {
            pdfView.go(to: page)
        }
        installContentView(pdfView)
        self.pdfView = pdfView
        pageChangeObserver = NotificationCenter.default.addObserver(
            forName: .PDFViewPageChanged,
            object: pdfView,
            queue: .main
        ) { [weak self, weak pdfView] _ in
            guard let self, let pdfView,
                  let page = pdfView.currentPage,
                  let index = pdfView.document?.index(for: page)
            else { return }
            Task { @MainActor in
                self.store.savePDFPage(index, for: self.bookID)
            }
        }
        navigationItem.rightBarButtonItems = []
    }

    private func openWebDocument(_ book: EBook, at url: URL) throws {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .systemBackground
        installContentView(webView)
        self.webView = webView
        loadWebDocument(book, at: url)
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(
                image: UIImage(systemName: "textformat.size"),
                style: .plain,
                target: self,
                action: #selector(presentPreferences)
            ),
        ]
    }

    private func loadWebDocument(_ book: EBook, at url: URL) {
        guard let webView else { return }
        let css = webCSS(for: book.preferences)
        if book.format == .html {
            let script = """
            const style = document.createElement('style');
            style.textContent = \(Self.javascriptString(css));
            document.head.appendChild(style);
            """
            webView.configuration.userContentController.removeAllUserScripts()
            webView.configuration.userContentController.addUserScript(WKUserScript(
                source: script,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            ))
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            let text = (try? String(contentsOf: url)) ?? ""
            let escaped = text
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
            let html = """
            <!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1">
            <style>\(css)</style></head><body><article>\(escaped)</article></body></html>
            """
            webView.loadHTMLString(html, baseURL: url.deletingLastPathComponent())
        }
    }

    private func webCSS(for preferences: EBookPreferences) -> String {
        let colors: (foreground: String, background: String)
        switch preferences.theme {
        case .dark: colors = ("#f3f3f3", "#111111")
        case .sepia: colors = ("#3b3126", "#faf4e8")
        case .light: colors = ("#151515", "#ffffff")
        case .system: colors = ("CanvasText", "Canvas")
        }
        let family = preferences.fontFamily.map { "'\($0.replacingOccurrences(of: "'", with: "\\'"))'" } ?? "-apple-system"
        return """
        :root { color-scheme: light dark; }
        html, body { margin: 0; padding: 0; background: \(colors.background); color: \(colors.foreground); }
        body { font-family: \(family); font-size: \(preferences.fontSize)em; line-height: \(preferences.lineHeight); }
        article { white-space: pre-wrap; overflow-wrap: anywhere; max-width: 48rem; margin: auto; padding: 2.2rem \(1.2 * preferences.pageMargins)rem 5rem; }
        img, svg, video { max-width: 100%; height: auto; }
        """
    }

    private func showLoadingView() {
        let spinner = UIActivityIndicatorView(style: .large)
        spinner.startAnimating()
        installContentView(spinner)
    }

    private func showError(_ error: Error) {
        clearContent()
        let imageView = UIImageView(image: UIImage(systemName: "exclamationmark.triangle"))
        imageView.tintColor = .secondaryLabel
        imageView.contentMode = .scaleAspectFit
        imageView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 42, weight: .light)

        let titleLabel = UILabel()
        titleLabel.text = NSLocalizedString("EBOOK_OPEN_FAILED", comment: "E-book open failure title")
        titleLabel.font = .preferredFont(forTextStyle: .title2)
        titleLabel.textAlignment = .center

        let messageLabel = UILabel()
        messageLabel.text = error.localizedDescription
        messageLabel.font = .preferredFont(forTextStyle: .subheadline)
        messageLabel.textColor = .secondaryLabel
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [imageView, titleLabel, messageLabel])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            imageView.widthAnchor.constraint(equalToConstant: 56),
            imageView.heightAnchor.constraint(equalToConstant: 56),
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -28),
        ])
    }

    private func clearContent() {
        children.forEach {
            $0.willMove(toParent: nil)
            $0.view.removeFromSuperview()
            $0.removeFromParent()
        }
        view.subviews.forEach { $0.removeFromSuperview() }
    }

    private func installChild(_ child: UIViewController) {
        clearContent()
        addChild(child)
        child.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(child.view)
        NSLayoutConstraint.activate([
            child.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            child.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            child.view.topAnchor.constraint(equalTo: view.topAnchor),
            child.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        child.didMove(toParent: self)
    }

    private func installContentView(_ contentView: UIView) {
        clearContent()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(contentView)
        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentView.topAnchor.constraint(equalTo: view.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func configureEPUBButtons() {
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(
                image: UIImage(systemName: "textformat.size"),
                style: .plain,
                target: self,
                action: #selector(presentPreferences)
            ),
            UIBarButtonItem(
                image: UIImage(systemName: "bookmark"),
                style: .plain,
                target: self,
                action: #selector(toggleBookmark)
            ),
            UIBarButtonItem(
                image: UIImage(systemName: "list.bullet"),
                style: .plain,
                target: self,
                action: #selector(presentContents)
            ),
        ]
        updateBookmarkButton()
    }

    @objc private func toggleBookmark() {
        guard let locator = epubNavigator?.currentLocation,
              let json = locator.jsonString,
              var book = store.book(withID: bookID)
        else { return }
        if book.bookmarks.contains(where: { $0.locatorJSON == json }) {
            store.removeBookmark(locatorJSON: json, from: bookID)
        } else {
            store.addBookmark(\n                title: locator.title ?? NSLocalizedString("EBOOK_BOOKMARK", comment: "Default e-book bookmark title"),\n                locatorJSON: json,\n                to: bookID\n            )
        }
        book = store.book(withID: bookID) ?? book
        updateBookmarkButton(book: book)
    }

    private func updateBookmarkButton(book: EBook? = nil) {
        guard let button = navigationItem.rightBarButtonItems?.dropFirst().first,
              let json = epubNavigator?.currentLocation?.jsonString
        else { return }
        let book = book ?? store.book(withID: bookID)
        let isBookmarked = book?.bookmarks.contains(where: { $0.locatorJSON == json }) == true
        button.image = UIImage(systemName: isBookmarked ? "bookmark.fill" : "bookmark")
    }

    @objc private func presentContents() {
        guard let publication else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let links = try await publication.tableOfContents().get()
                let entries = Self.flatten(links)
                let bookmarks = store.book(withID: bookID)?.bookmarks ?? []
                let view = EBookContentsView(entries: entries, bookmarks: bookmarks) { [weak self] entry in
                    self?.dismiss(animated: true)
                    Task { await self?.epubNavigator?.go(to: entry.link, options: .animated) }
                } onBookmark: { [weak self] bookmark in
                    self?.dismiss(animated: true)
                    guard let locator = try? Locator(jsonString: bookmark.locatorJSON) else { return }
                    Task { await self?.epubNavigator?.go(to: locator, options: .animated) }
                }
                let controller = UIHostingController(rootView: view)
                controller.title = NSLocalizedString("EBOOK_CONTENTS", comment: "E-book table of contents title")
                let navigationController = UINavigationController(rootViewController: controller)
                controller.navigationItem.rightBarButtonItem = UIBarButtonItem(
                    barButtonSystemItem: .done,
                    target: self,
                    action: #selector(dismissPresentedController)
                )
                present(navigationController, animated: true)
            } catch {
                showAlert(\n                    title: NSLocalizedString("EBOOK_CONTENTS_UNAVAILABLE", comment: "E-book contents unavailable error title"),\n                    message: error.localizedDescription\n                )
            }
        }
    }

    @objc private func presentPreferences() {
        guard let book = store.book(withID: bookID) else { return }
        let view = EBookPreferencesView(preferences: book.preferences) { [weak self] preferences in
            guard let self else { return }
            store.savePreferences(preferences, for: bookID)
            epubNavigator?.submitPreferences(Self.readiumPreferences(from: preferences))
            if let updatedBook = store.book(withID: bookID) {
                loadWebDocument(updatedBook, at: store.fileURL(for: updatedBook))
            }
        }
        let controller = UIHostingController(rootView: view)
        present(controller, animated: true)
    }

    @objc private func dismissPresentedController() {
        dismiss(animated: true)
    }

    private func showAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: ""), style: .default))
        present(alert, animated: true)
    }

    private static func readiumPreferences(from preferences: EBookPreferences) -> EPUBPreferences {
        let theme: ReadiumNavigator.Theme?
        switch preferences.theme {
        case .system: theme = nil
        case .light: theme = .light
        case .sepia: theme = .sepia
        case .dark: theme = .dark
        }
        return EPUBPreferences(
            fontFamily: preferences.fontFamily.map(FontFamily.init(rawValue:)),
            fontSize: preferences.fontSize,
            lineHeight: preferences.lineHeight,
            pageMargins: preferences.pageMargins,
            paragraphSpacing: preferences.paragraphSpacing,
            publisherStyles: preferences.usesPublisherStyles,
            scroll: preferences.isScrollEnabled,
            theme: theme
        )
    }

    private static func flatten(_ links: [Link], depth: Int = 0) -> [EBookContentsEntry] {
        links.flatMap { link in
            [EBookContentsEntry(link: link, depth: depth)] + flatten(link.children, depth: depth + 1)
        }
    }

    private static func javascriptString(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let json = String(data: data, encoding: .utf8)
        else { return "''" }
        return String(json.dropFirst().dropLast())
    }
}

extension EBookReaderViewController: EPUBNavigatorDelegate {
    func navigator(_ navigator: Navigator, locationDidChange locator: Locator) {
        guard let json = locator.jsonString else { return }
        store.saveLocator(json, for: bookID)
        updateBookmarkButton()
    }

    func navigator(_ navigator: Navigator, presentError error: NavigatorError) {
        showAlert(\n            title: NSLocalizedString("EBOOK_READER_ERROR", comment: "E-book reader error title"),\n            message: error.localizedDescription\n        )
    }
}

struct EBookContentsEntry: Identifiable {
    let id = UUID()
    let link: Link
    let depth: Int
}

private struct EBookContentsView: View {
    enum Section: CaseIterable {
        case contents
        case bookmarks

        var title: String {
            switch self {
            case .contents:
                NSLocalizedString("EBOOK_CONTENTS", comment: "E-book table of contents title")
            case .bookmarks:
                NSLocalizedString("EBOOK_BOOKMARKS", comment: "E-book bookmarks title")
            }
        }
    }

    let entries: [EBookContentsEntry]
    let bookmarks: [EBookBookmark]
    let onEntry: (EBookContentsEntry) -> Void
    let onBookmark: (EBookBookmark) -> Void

    @State private var section: Section = .contents

    var body: some View {
        VStack(spacing: 0) {
            Picker(NSLocalizedString("EBOOK_SECTION", comment: "E-book contents picker label"), selection: $section) {
                ForEach(Section.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding()

            List {
                if section == .contents {
                    ForEach(entries) { entry in
                        Button {
                            onEntry(entry)
                        } label: {
                            Text(entry.link.title ?? NSLocalizedString("EBOOK_UNTITLED_SECTION", comment: "Untitled table of contents entry"))
                                .foregroundStyle(.primary)
                                .padding(.leading, CGFloat(entry.depth) * 16)
                        }
                    }
                } else if bookmarks.isEmpty {
                    Text(NSLocalizedString("EBOOK_NO_BOOKMARKS", comment: "Empty e-book bookmarks message"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(bookmarks) { bookmark in
                        Button {
                            onBookmark(bookmark)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(bookmark.title)
                                    .foregroundStyle(.primary)
                                Text(bookmark.createdAt, style: .date)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
        }
    }
}

private extension EBookPreferences.Theme {
    var localizedName: String {
        switch self {
        case .system:
            NSLocalizedString("EBOOK_THEME_SYSTEM", comment: "System e-book theme")
        case .light:
            NSLocalizedString("EBOOK_THEME_LIGHT", comment: "Light e-book theme")
        case .sepia:
            NSLocalizedString("EBOOK_THEME_SEPIA", comment: "Sepia e-book theme")
        case .dark:
            NSLocalizedString("EBOOK_THEME_DARK", comment: "Dark e-book theme")
        }
    }
}

private struct EBookPreferencesView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var fontStore = EBookFontStore.shared

    @State var preferences: EBookPreferences
    let onSave: (EBookPreferences) -> Void

    @State private var isImportingFont = false
    @State private var fontMessage: String?

    var body: some View {
        NavigationView {
            Form {
                Section(NSLocalizedString("EBOOK_APPEARANCE", comment: "E-book appearance settings section")) {
                    Picker(NSLocalizedString("EBOOK_THEME", comment: "E-book theme setting"), selection: $preferences.theme) {
                        ForEach(EBookPreferences.Theme.allCases, id: \.self) {
                            Text($0.localizedName).tag($0)
                        }
                    }
                    Picker(NSLocalizedString("EBOOK_FONT", comment: "E-book font setting"), selection: $preferences.fontFamily) {
                        Text(NSLocalizedString("EBOOK_BOOK_DEFAULT_FONT", comment: "Use book default font option")).tag(String?.none)
                        Text("Iowan Old Style").tag(String?.some("Iowan Old Style"))
                        Text("Athelas").tag(String?.some("Athelas"))
                        Text("Georgia").tag(String?.some("Georgia"))
                        Text("Helvetica Neue").tag(String?.some("Helvetica Neue"))
                        ForEach(fontStore.fonts) { font in
                            Text(font.familyName).tag(String?.some(font.familyName))
                        }
                    }
                    Button {
                        isImportingFont = true
                    } label: {
                        Label(NSLocalizedString("EBOOK_IMPORT_FONT", comment: "Import e-book font action"), systemImage: "text.badge.plus")
                    }
                }

                Section(NSLocalizedString("EBOOK_TYPOGRAPHY", comment: "E-book typography settings section")) {
                    valueSlider(NSLocalizedString("EBOOK_FONT_SIZE", comment: "E-book font size setting"), value: $preferences.fontSize, range: 0.7 ... 2, step: 0.05)
                    valueSlider(NSLocalizedString("EBOOK_LINE_HEIGHT", comment: "E-book line height setting"), value: $preferences.lineHeight, range: 1 ... 2.4, step: 0.05)
                    valueSlider(NSLocalizedString("EBOOK_PAGE_MARGINS", comment: "E-book page margins setting"), value: $preferences.pageMargins, range: 0 ... 2, step: 0.1)
                    valueSlider(NSLocalizedString("EBOOK_PARAGRAPH_SPACING", comment: "E-book paragraph spacing setting"), value: $preferences.paragraphSpacing, range: 0 ... 2, step: 0.1)
                }

                Section(NSLocalizedString("EBOOK_LAYOUT", comment: "E-book layout settings section")) {
                    Toggle(NSLocalizedString("EBOOK_SCROLLING", comment: "E-book scrolling setting"), isOn: $preferences.isScrollEnabled)
                    Toggle(NSLocalizedString("EBOOK_USE_PUBLISHER_STYLES", comment: "Use publisher styles setting"), isOn: $preferences.usesPublisherStyles)
                }

                if let fontMessage {
                    Section {
                        Text(fontMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(NSLocalizedString("EBOOK_READING_SETTINGS", comment: "E-book reading settings title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("CANCEL", comment: "")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("SAVE", comment: "")) {
                        onSave(preferences)
                        dismiss()
                    }
                }
            }
        }
        .sheet(isPresented: $isImportingFont) {
            DocumentPickerView(
                allowedContentTypes: Self.fontContentTypes,
                allowsMultipleSelection: true
            ) { urls in
                isImportingFont = false
                guard !urls.isEmpty else { return }
                do {
                    try fontStore.importFonts(urls)
                    fontMessage = NSLocalizedString("EBOOK_FONT_IMPORTED_REOPEN", comment: "Font import success message")
                } catch {
                    fontMessage = error.localizedDescription
                }
            }
        }
    }

    @ViewBuilder
    private func valueSlider(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text(value.wrappedValue.formatted(.number.precision(.fractionLength(1))))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: value, in: range, step: step)
        }
    }

    private static var fontContentTypes: [UTType] {
        ["ttf", "otf"].compactMap { UTType(filenameExtension: $0) }
    }
}
