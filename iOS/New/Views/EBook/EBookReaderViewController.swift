//
//  EBookReaderViewController.swift
//  Aidoku
//

import Combine
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
    private var webTapGesture: UITapGestureRecognizer?
    private var webIsPaginated = false
    private var pageChangeObserver: NSObjectProtocol?
    private var bookmarkButton: UIBarButtonItem?
    private var readerBarsHidden = false
    private var previousIdleTimerDisabled: Bool?

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

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        previousIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = EBookPreferences.keepsScreenAwake
        setReaderBars(hidden: false, animated: false)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        navigationController?.setNavigationBarHidden(false, animated: false)
        navigationController?.setToolbarHidden(true, animated: false)
        if let previousIdleTimerDisabled {
            UIApplication.shared.isIdleTimerDisabled = previousIdleTimerDisabled
            self.previousIdleTimerDisabled = nil
        }
    }

    override var prefersStatusBarHidden: Bool {
        readerBarsHidden
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
        guard !publication.readingOrder.isEmpty else {
            throw EBookReaderError.emptyReadingOrder
        }
        let initialLocation = book.locatorJSON.flatMap { try? Locator(jsonString: $0) }
        let effectivePreferences = store.effectivePreferences(for: book)
        let preferences = Self.readiumPreferences(from: effectivePreferences)
        let navigator = try EPUBNavigatorViewController(
            publication: publication,
            initialLocation: initialLocation,
            config: .init(
                preferences: preferences,
                disablePageTurnsWhileScrolling: true,
                contentInset: [
                    .compact: (
                        top: CGFloat(effectivePreferences.topMargin),
                        bottom: CGFloat(effectivePreferences.bottomMargin)
                    ),
                    .regular: (
                        top: CGFloat(effectivePreferences.topMargin),
                        bottom: CGFloat(effectivePreferences.bottomMargin)
                    ),
                ],
                fontFamilyDeclarations: EBookFontStore.shared.readiumDeclarations(for: effectivePreferences.fontFamily)
            )
        )
        navigator.delegate = self

        self.publication = publication
        epubNavigator = navigator
        var coverData: Data?
        if book.coverFileName == nil {
            coverData = try? await publication.cover().get()?.pngData()
        }
        store.updateMetadata(
            for: book.id,
            title: publication.metadata.title,
            author: publication.metadata.authors.map(\.name).joined(separator: ", "),
            coverData: coverData
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
        webView.navigationDelegate = self
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.isDirectionalLockEnabled = true

        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleWebTap(_:)))
        tapGesture.cancelsTouchesInView = false
        tapGesture.delegate = self
        webView.addGestureRecognizer(tapGesture)
        webTapGesture = tapGesture

        installContentView(webView)
        self.webView = webView
        loadWebDocument(book, at: url)
        configureWebButtons()
    }

    private func loadWebDocument(_ book: EBook, at url: URL) {
        guard let webView else { return }
        let preferences = store.effectivePreferences(for: book)
        let css = webCSS(for: preferences)
        webIsPaginated = !preferences.isScrollEnabled
        webView.scrollView.isPagingEnabled = webIsPaginated
        webView.scrollView.alwaysBounceHorizontal = webIsPaginated
        webView.scrollView.alwaysBounceVertical = !webIsPaginated
        webView.scrollView.showsHorizontalScrollIndicator = false
        webView.scrollView.showsVerticalScrollIndicator = !webIsPaginated
        webView.scrollView.setContentOffset(.zero, animated: false)

        switch preferences.theme {
        case .dark:
            webView.overrideUserInterfaceStyle = .dark
            webView.backgroundColor = UIColor(red: 0.067, green: 0.067, blue: 0.067, alpha: 1)
        case .sepia:
            webView.overrideUserInterfaceStyle = .light
            webView.backgroundColor = UIColor(red: 0.98, green: 0.957, blue: 0.91, alpha: 1)
        case .light:
            webView.overrideUserInterfaceStyle = .light
            webView.backgroundColor = .white
        case .system:
            webView.overrideUserInterfaceStyle = .unspecified
            webView.backgroundColor = .systemBackground
        }
        webView.scrollView.backgroundColor = webView.backgroundColor

        if book.format == .html {
            let script = """
            const previous = document.getElementById('aidoku-ebook-style');
            if (previous) previous.remove();
            const style = document.createElement('style');
            style.id = 'aidoku-ebook-style';
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
            let html = """
            <!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
            <style>\(css)</style></head><body><article>\(plainTextHTML(text))</article></body></html>
            """
            webView.loadHTMLString(html, baseURL: EBookFontStore.shared.fontsDirectory)
        }
    }

    private func webCSS(for preferences: EBookPreferences) -> String {
        let colors: (foreground: String, background: String, scheme: String)
        switch preferences.theme {
        case .dark: colors = ("#f3f3f3", "#111111", "dark")
        case .sepia: colors = ("#3b3126", "#faf4e8", "light")
        case .light: colors = ("#151515", "#ffffff", "light")
        case .system: colors = ("CanvasText", "Canvas", "light dark")
        }
        let familyName = preferences.fontFamily?.replacingOccurrences(of: "'", with: "\\'")
        let family = familyName.map { "'\($0)'" } ?? "-apple-system"
        let horizontalMargin = 18 + preferences.pageMargins * 12
        let fontFace = webFontFaceCSS(for: preferences.fontFamily)
        let layout: String
        if preferences.isScrollEnabled {
            layout = """
            html, body { min-height: 100%; overflow-x: hidden !important; overflow-y: auto !important; }
            body { padding: \(preferences.topMargin)px \(horizontalMargin)px \(preferences.bottomMargin)px; }
            article { max-width: 48rem; margin: 0 auto; }
            """
        } else {
            layout = """
            html, body { width: 100%; height: 100%; overflow: hidden !important; }
            body {
                height: 100vh;
                padding: \(preferences.topMargin)px \(horizontalMargin)px \(preferences.bottomMargin)px;
                column-width: calc(100vw - \(horizontalMargin * 2)px);
                column-gap: \(horizontalMargin * 2)px;
                column-fill: auto;
            }
            article { width: auto; max-width: none; margin: 0; }
            """
        }
        return """
        \(fontFace)
        :root { color-scheme: \(colors.scheme); }
        * { box-sizing: border-box; -webkit-text-size-adjust: 100%; }
        html, body {
            margin: 0 !important;
            background: \(colors.background) !important;
            color: \(colors.foreground) !important;
        }
        body {
            font-family: \(family) !important;
            font-size: \(preferences.fontSize)em !important;
            line-height: \(preferences.lineHeight) !important;
            overflow-wrap: anywhere;
        }
        p {
            text-indent: \(preferences.paragraphIndent)em;
            margin: 0 0 \(preferences.paragraphSpacing)em;
        }
        img, svg, video { max-width: 100%; height: auto; }
        \(layout)
        """
    }

    private func webFontFaceCSS(for familyName: String?) -> String {
        guard let font = EBookFontStore.shared.font(named: familyName),
              let data = try? Data(contentsOf: font.url)
        else { return "" }
        let format = font.url.pathExtension.lowercased() == "otf" ? "opentype" : "truetype"
        let escapedFamily = font.familyName.replacingOccurrences(of: "'", with: "\\'")
        return """
        @font-face {
            font-family: '\(escapedFamily)';
            src: url(data:font/\(font.url.pathExtension.lowercased());base64,\(data.base64EncodedString())) format('\(format)');
            font-weight: normal;
            font-style: normal;
        }
        """
    }

    private func plainTextHTML(_ text: String) -> String {
        text.components(separatedBy: .newlines).map { line in
            let escaped = line
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
            return escaped.isEmpty ? "<p>&nbsp;</p>" : "<p>\(escaped)</p>"
        }.joined()
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
        messageLabel.lineBreakMode = .byCharWrapping

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
        let contentsButton = UIBarButtonItem(
            image: UIImage(systemName: "list.bullet"),
            style: .plain,
            target: self,
            action: #selector(presentContents)
        )
        let bookmarkButton = UIBarButtonItem(
            image: UIImage(systemName: "bookmark"),
            style: .plain,
            target: self,
            action: #selector(toggleBookmark)
        )
        let preferencesButton = UIBarButtonItem(
            image: UIImage(systemName: "textformat.size"),
            style: .plain,
            target: self,
            action: #selector(presentPreferences)
        )
        self.bookmarkButton = bookmarkButton
        navigationItem.rightBarButtonItems = []
        toolbarItems = [
            contentsButton,
            UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil),
            bookmarkButton,
            UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil),
            preferencesButton,
        ]
        navigationController?.setToolbarHidden(false, animated: false)
        updateBookmarkButton()
    }

    private func configureWebButtons() {
        let preferencesButton = UIBarButtonItem(
            image: UIImage(systemName: "textformat.size"),
            style: .plain,
            target: self,
            action: #selector(presentPreferences)
        )
        navigationItem.rightBarButtonItems = []
        toolbarItems = [
            UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil),
            preferencesButton,
            UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil),
        ]
        navigationController?.setToolbarHidden(false, animated: false)
    }

    private func setReaderBars(hidden: Bool, animated: Bool) {
        readerBarsHidden = hidden
        navigationController?.setNavigationBarHidden(hidden, animated: animated)
        let hasReaderToolbar = epubNavigator != nil || webView != nil
        navigationController?.setToolbarHidden(hidden || !hasReaderToolbar, animated: animated)
        setNeedsStatusBarAppearanceUpdate()
    }

    @objc private func handleWebTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended, let webView else { return }
        let point = gesture.location(in: webView)
        let relativeX = point.x / max(webView.bounds.width, 1)
        if (0.28 ... 0.72).contains(relativeX) {
            setReaderBars(hidden: !readerBarsHidden, animated: true)
            return
        }
        guard webIsPaginated else { return }
        turnWebPage(forward: relativeX > 0.5)
    }

    private func turnWebPage(forward: Bool) {
        guard let webView else { return }
        let pageWidth = max(webView.bounds.width, 1)
        let maximumOffset = max(webView.scrollView.contentSize.width - pageWidth, 0)
        let delta = forward ? pageWidth : -pageWidth
        let target = min(max(webView.scrollView.contentOffset.x + delta, 0), maximumOffset)
        webView.scrollView.setContentOffset(CGPoint(x: target, y: 0), animated: true)
    }

    private func turnPage(forward: Bool) {
        guard let navigator = epubNavigator else { return }
        Task {
            if forward {
                await navigator.goForward(options: .animated)
            } else {
                await navigator.goBackward(options: .animated)
            }
        }
    }

    @objc private func toggleBookmark() {
        guard let locator = epubNavigator?.currentLocation,
              let json = locator.jsonString,
              var book = store.book(withID: bookID)
        else { return }
        if book.bookmarks.contains(where: { $0.locatorJSON == json }) {
            store.removeBookmark(locatorJSON: json, from: bookID)
        } else {
            store.addBookmark(
                title: locator.title ?? NSLocalizedString("EBOOK_BOOKMARK", comment: "Default e-book bookmark title"),
                locatorJSON: json,
                to: bookID
            )
        }
        book = store.book(withID: bookID) ?? book
        updateBookmarkButton(book: book)
    }

    private func updateBookmarkButton(book: EBook? = nil) {
        guard let button = bookmarkButton,
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
                let view = EBookContentsView(
                    publication: publication,
                    entries: entries,
                    bookmarks: bookmarks
                ) { [weak self] entry in
                    self?.dismiss(animated: true)
                    Task { await self?.epubNavigator?.go(to: entry.link, options: .animated) }
                } onSearchResult: { [weak self] locator in
                    self?.dismiss(animated: true)
                    Task { await self?.epubNavigator?.go(to: locator, options: .animated) }
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
                showAlert(
                    title: NSLocalizedString("EBOOK_CONTENTS_UNAVAILABLE", comment: "E-book contents unavailable error title"),
                    message: error.localizedDescription
                )
            }
        }
    }

    @objc private func presentPreferences() {
        guard let book = store.book(withID: bookID) else { return }
        let effectivePreferences = store.effectivePreferences(for: book)
        let view = EBookPreferencesView(
            format: book.format,
            preferences: effectivePreferences
        ) { [weak self] preferences in
            guard let self else { return }
            store.savePreferences(preferences, for: bookID)
            apply(preferences)
        } onApplyGlobally: { [weak self] preferences in
            guard let self else { return }
            store.applyGlobalPreferences(preferences)
            apply(preferences)
        } onReset: { [weak self] in
            guard let self else { return }
            store.resetPreferencesToGlobal(for: bookID)
            apply(EBookPreferences.globalDefaults)
        }
        let controller = UIHostingController(rootView: view)
        present(controller, animated: true)
    }

    private func apply(_ preferences: EBookPreferences) {
        epubNavigator?.submitPreferences(Self.readiumPreferences(from: preferences))
        epubNavigator?.view.setNeedsLayout()
        epubNavigator?.view.layoutIfNeeded()
        if let updatedBook = store.book(withID: bookID) {
            loadWebDocument(updatedBook, at: store.fileURL(for: updatedBook))
        }
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
            paragraphIndent: preferences.paragraphIndent,
            paragraphSpacing: preferences.paragraphSpacing,
            publisherStyles: preferences.usesPublisherStyles,
            scroll: preferences.isScrollEnabled,
            theme: theme
        )
    }

    private static func flatten(_ links: [ReadiumShared.Link], depth: Int = 0) -> [EBookContentsEntry] {
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
    func navigatorContentInset(_ navigator: VisualNavigator) -> UIEdgeInsets? {
        guard let book = store.book(withID: bookID) else { return nil }
        let preferences = store.effectivePreferences(for: book)
        return UIEdgeInsets(
            top: CGFloat(preferences.topMargin),
            left: 0,
            bottom: CGFloat(preferences.bottomMargin),
            right: 0
        )
    }

    func navigator(_ navigator: VisualNavigator, didTapAt point: CGPoint) {
        guard let book = store.book(withID: bookID) else { return }
        let preferences = store.effectivePreferences(for: book)
        let relativeX = point.x / max(view.bounds.width, 1)

        if (0.28 ... 0.72).contains(relativeX) {
            setReaderBars(hidden: !readerBarsHidden, animated: true)
            return
        }

        guard !preferences.isScrollEnabled else { return }
        let isRTL = publication?.metadata.readingProgression == .rtl
        if relativeX < 0.28 {
            turnPage(forward: isRTL)
        } else {
            turnPage(forward: !isRTL)
        }
    }

    func navigator(_ navigator: Navigator, locationDidChange locator: Locator) {
        guard let json = locator.jsonString else { return }
        store.saveLocator(json, for: bookID)
        updateBookmarkButton()
    }

    func navigator(_ navigator: Navigator, presentError error: NavigatorError) {
        showAlert(
            title: NSLocalizedString("EBOOK_READER_ERROR", comment: "E-book reader error title"),
            message: error.localizedDescription
        )
    }
}

struct EBookContentsEntry: Identifiable {
    let id = UUID()
    let link: ReadiumShared.Link
    let depth: Int
}

private final class EBookSearchModel: ObservableObject {
    @Published var query = ""
    @Published private(set) var results: [Locator] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private var searchTask: Task<Void, Never>?

    deinit {
        searchTask?.cancel()
    }

    func search(in publication: Publication) {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        searchTask?.cancel()
        results = []
        errorMessage = nil

        guard !query.isEmpty else {
            isLoading = false
            return
        }

        isLoading = true
        searchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            switch await publication.search(query: query) {
            case let .failure(error):
                errorMessage = String(describing: error)
                isLoading = false

            case let .success(iterator):
                while !Task.isCancelled {
                    switch await iterator.next() {
                    case let .success(collection):
                        guard let collection else {
                            isLoading = false
                            return
                        }
                        results.append(contentsOf: collection.locators)

                    case let .failure(error):
                        errorMessage = String(describing: error)
                        isLoading = false
                        return
                    }
                }
                isLoading = false
            }
        }
    }
}

private struct EBookContentsView: View {
    enum Pane: CaseIterable {
        case contents
        case search
        case bookmarks

        var title: String {
            switch self {
            case .contents:
                NSLocalizedString("EBOOK_CONTENTS", comment: "E-book table of contents title")
            case .search:
                NSLocalizedString("SEARCH", comment: "E-book search tab")
            case .bookmarks:
                NSLocalizedString("EBOOK_BOOKMARKS", comment: "E-book bookmarks title")
            }
        }
    }

    let publication: Publication
    let entries: [EBookContentsEntry]
    let bookmarks: [EBookBookmark]
    let onEntry: (EBookContentsEntry) -> Void
    let onSearchResult: (Locator) -> Void
    let onBookmark: (EBookBookmark) -> Void

    @State private var section: Pane = .contents
    @StateObject private var searchModel = EBookSearchModel()

    var body: some View {
        VStack(spacing: 0) {
            Picker(NSLocalizedString("EBOOK_SECTION", comment: "E-book contents picker label"), selection: $section) {
                ForEach(Pane.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding()

            switch section {
            case .contents:
                List(entries) { entry in
                    Button {
                        onEntry(entry)
                    } label: {
                        Text(entry.link.title ?? NSLocalizedString("EBOOK_UNTITLED_SECTION", comment: "Untitled table of contents entry"))
                            .foregroundStyle(.primary)
                            .padding(.leading, CGFloat(entry.depth) * 16)
                    }
                }
                .listStyle(.plain)

            case .search:
                searchResults

            case .bookmarks:
                List {
                    if bookmarks.isEmpty {
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

    private var searchResults: some View {
        List {
            Section {
                HStack {
                    TextField(NSLocalizedString("EBOOK_SEARCH_PLACEHOLDER", comment: "Search inside e-book placeholder"), text: $searchModel.query)
                        .submitLabel(.search)
                        .onSubmit {
                            searchModel.search(in: publication)
                        }
                    Button(NSLocalizedString("SEARCH", comment: "")) {
                        searchModel.search(in: publication)
                    }
                    .disabled(searchModel.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            if searchModel.isLoading {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            }

            if let errorMessage = searchModel.errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if !searchModel.query.isEmpty && !searchModel.isLoading && searchModel.results.isEmpty {
                Text(NSLocalizedString("EBOOK_NO_SEARCH_RESULTS", comment: "No e-book search results"))
                    .foregroundStyle(.secondary)
            }

            ForEach(Array(searchModel.results.enumerated()), id: \.offset) { _, locator in
                Button {
                    onSearchResult(locator)
                } label: {
                    let text = locator.text.sanitized()
                    VStack(alignment: .leading, spacing: 5) {
                        Text(locator.title ?? text.highlight ?? NSLocalizedString("EBOOK_SEARCH_RESULT", comment: "E-book search result"))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text([text.before, text.highlight, text.after].compactMap { $0 }.joined(separator: " "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                }
            }
        }
        .listStyle(.plain)
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

    let format: EBookFormat
    @State var preferences: EBookPreferences
    let onSave: (EBookPreferences) -> Void
    let onApplyGlobally: (EBookPreferences) -> Void
    let onReset: () -> Void

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
                    valueSlider(NSLocalizedString("EBOOK_HORIZONTAL_MARGINS", comment: "E-book horizontal margins setting"), value: $preferences.pageMargins, range: 0 ... 2, step: 0.1)
                    valueSlider(NSLocalizedString("EBOOK_TOP_MARGIN", comment: "E-book top margin setting"), value: $preferences.topMargin, range: 0 ... 100, step: 2)
                    valueSlider(NSLocalizedString("EBOOK_BOTTOM_MARGIN", comment: "E-book bottom margin setting"), value: $preferences.bottomMargin, range: 0 ... 100, step: 2)
                    valueSlider(NSLocalizedString("EBOOK_PARAGRAPH_INDENT", comment: "E-book paragraph indent setting"), value: $preferences.paragraphIndent, range: 0 ... 4, step: 0.1)
                    valueSlider(NSLocalizedString("EBOOK_PARAGRAPH_SPACING", comment: "E-book paragraph spacing setting"), value: $preferences.paragraphSpacing, range: 0 ... 2, step: 0.1)
                }

                Section(NSLocalizedString("EBOOK_LAYOUT", comment: "E-book layout settings section")) {
                    Picker(NSLocalizedString("EBOOK_READING_MODE", comment: "E-book reading mode"), selection: $preferences.isScrollEnabled) {
                        Text(NSLocalizedString("EBOOK_PAGED_READING", comment: "Paginated e-book reading")).tag(false)
                        Text(NSLocalizedString("EBOOK_SCROLL_READING", comment: "Scrolling e-book reading")).tag(true)
                    }
                    if format == .epub || format == .html {
                        Toggle(NSLocalizedString("EBOOK_USE_PUBLISHER_STYLES", comment: "Use publisher styles setting"), isOn: $preferences.usesPublisherStyles)
                    }
                }

                Section {
                    Button(NSLocalizedString("EBOOK_APPLY_TO_ALL_BOOKS", comment: "Apply e-book settings to all books")) {
                        onApplyGlobally(preferences)
                        dismiss()
                    }
                    Button(NSLocalizedString("EBOOK_RESET_TO_GLOBAL", comment: "Reset e-book settings to global defaults"), role: .destructive) {
                        onReset()
                        dismiss()
                    }
                } footer: {
                    Text(NSLocalizedString("EBOOK_APPLY_TO_ALL_BOOKS_INFO", comment: "Apply e-book settings to all books explanation"))
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
                    let importedFonts = try fontStore.importFonts(urls)
                    if let font = importedFonts.first {
                        preferences.fontFamily = font.familyName
                        onApplyGlobally(preferences)
                        fontMessage = format == .epub
                            ? NSLocalizedString("EBOOK_FONT_IMPORTED_GLOBAL_REOPEN", comment: "Global font import success requiring EPUB reopen")
                            : NSLocalizedString("EBOOK_FONT_IMPORTED_GLOBAL", comment: "Global font import success")
                    } else {
                        fontMessage = NSLocalizedString("EBOOK_FONT_IMPORTED_GLOBAL", comment: "Global font import success")
                    }
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


extension EBookReaderViewController: WKNavigationDelegate {}

extension EBookReaderViewController: UIGestureRecognizerDelegate {
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }
}
