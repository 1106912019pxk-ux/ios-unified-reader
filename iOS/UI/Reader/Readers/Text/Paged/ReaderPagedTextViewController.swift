//
//  ReaderPagedTextViewController.swift
//  Aidoku
//
//  Kindle-style paginated text reader with horizontal page flipping.
//  Supports single page and two-page spread layouts.
//

import AidokuRunner
import SwiftUI
import UIKit
import ZIPFoundation

class ReaderPagedTextViewController: BaseObservingViewController {
    // MARK: - Properties
    let viewModel: ReaderTextViewModel
    weak var delegate: ReaderHoldingDelegate?

    var chapter: AidokuRunner.Chapter?
    var readingMode: ReadingMode = .ltr {
        didSet {
            // For text content, always use LTR regardless of manga setting
            // (Western text reads left-to-right)
            if readingMode == .rtl {
                // Don't recursively trigger didSet
                return
            }
            guard readingMode != oldValue else { return }
            refreshPages()
        }
    }

    // Override to always return LTR for text
    private var effectiveReadingMode: ReadingMode {
        .ltr  // Text always reads left-to-right
    }

    private let paginator = TextPaginator()
    private var pages: [TextPage] = []
    private var currentPageIndex = 0
    private var currentCharacterOffset = 0  // Character offset for position restoration after repagination
    private var isLoadingChapter = false  // Prevent race conditions
    private var lastPaginationSize: CGSize = .zero  // Track size to avoid repagination loops

    // Always-visible reading status. This intentionally lives inside the text
    // reader rather than the navigation bar so it remains visible when the
    // reader chrome is hidden.
    private let readingStatusView = UIView()
    private let chapterStatusLabel = UILabel()
    private let timeStatusLabel = UILabel()
    private let pageStatusLabel = UILabel()
    private var readingStatusTimer: Timer?
    private var physicalSafeAreaInsets: UIEdgeInsets = .zero

    private let topStatusReserve: CGFloat = 28
    private let bottomStatusReserve: CGFloat = 26

    /// Fixed text insets used by child page view controllers.
    /// Computed once during pagination and kept constant so text doesn't shift
    /// when bars hide/show.
    private(set) var textInsets: UIEdgeInsets = .zero

    /// Insets for each physical page of a spread. Only the outer page edges
    /// receive the device's left/right safe-area inset, preventing the notch
    /// allowance from being applied twice at the center gutter in landscape.
    func textInsetsForDoublePage(isLeftPage: Bool) -> UIEdgeInsets {
        let horizontalPadding = paginator.currentConfig.horizontalPadding
        return UIEdgeInsets(
            top: textInsets.top,
            left: horizontalPadding + (isLeftPage ? physicalSafeAreaInsets.left : 0),
            bottom: textInsets.bottom,
            right: horizontalPadding + (isLeftPage ? 0 : physicalSafeAreaInsets.right)
        )
    }

    /// Indicates whether pagination has been performed for the current chapter.
    /// Used to distinguish between the pre-pagination placeholder and actual paginated content.
    private(set) var hasPaginated = false
    /// Tracks the requested start page (from reading history) so `repaginate()` can
    /// restore the correct position after the initial pagination completes.
    private var pendingStartPage: Int?

    // Double page support
    private var usesDoublePages = false
    private var usesAutoPageLayout = false

    deinit {
        readingStatusTimer?.invalidate()
    }

    // Page view controller
    private lazy var pageViewController: UIPageViewController = {
        // Scroll is more reliable than pageCurl
        UIPageViewController(
            transitionStyle: .scroll,
            navigationOrientation: .horizontal,
            options: nil
        )
    }()

    // Chapter navigation
    private var previousChapter: AidokuRunner.Chapter?
    private var nextChapter: AidokuRunner.Chapter?

    // MARK: - Initialization

    init(source: AidokuRunner.Source?, manga: AidokuRunner.Manga) {
        self.viewModel = ReaderTextViewModel(source: source, manga: manga)
        super.init()
    }

    // MARK: - Lifecycle

    override func configure() {
        pageViewController.delegate = self
        pageViewController.dataSource = self

        addChild(pageViewController)
        view.addSubview(pageViewController.view)
        pageViewController.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            pageViewController.view.topAnchor.constraint(equalTo: view.topAnchor),
            pageViewController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pageViewController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pageViewController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        pageViewController.didMove(toParent: self)

        configureReadingStatus()

        updatePageLayout()
        updateTextConfig()  // Apply saved text settings
    }

    override func observe() {
        addObserver(forName: "Reader.pagedPageLayout") { [weak self] _ in
            self?.updatePageLayout()
            self?.refreshPages()
        }

        // Text reader settings
        let textSettingChanged: (Notification) -> Void = { [weak self] _ in
            self?.updateTextConfig()
        }
        for key in [
            "Reader.textFontSize",
            "Reader.textLineSpacing",
            "Reader.textHorizontalPadding",
            "Reader.textTopPadding",
            "Reader.textBottomPadding",
            "Reader.textParagraphSpacing",
            "Reader.textFirstLineIndent",
            "Reader.textFontFamily",
            "Reader.textBackgroundColor"
        ] {
            addObserver(forName: key, using: textSettingChanged)
        }
    }

    private func updateTextConfig() {
        var config = PaginationConfig()

        // Load settings - PaginationConfig provides the defaults
        if let fontSize = UserDefaults.standard.object(forKey: "Reader.textFontSize") as? CGFloat {
            config.fontSize = fontSize
        }
        if let lineSpacing = UserDefaults.standard.object(forKey: "Reader.textLineSpacing") as? CGFloat {
            config.lineSpacing = lineSpacing
        }
        if let horizontalPadding = UserDefaults.standard.object(forKey: "Reader.textHorizontalPadding") as? CGFloat {
            config.horizontalPadding = horizontalPadding
        }
        if let topPadding = UserDefaults.standard.object(forKey: "Reader.textTopPadding") as? CGFloat {
            config.topPadding = topPadding
        }
        if let bottomPadding = UserDefaults.standard.object(forKey: "Reader.textBottomPadding") as? CGFloat {
            config.bottomPadding = bottomPadding
        }
        if let paragraphSpacing = UserDefaults.standard.object(forKey: "Reader.textParagraphSpacing") as? CGFloat {
            config.paragraphSpacing = paragraphSpacing
        }
        if let firstLineIndent = UserDefaults.standard.object(forKey: "Reader.textFirstLineIndent") as? CGFloat {
            config.firstLineIndent = firstLineIndent
        }
        if let fontFamily = UserDefaults.standard.string(forKey: "Reader.textFontFamily") {
            config.fontName = fontFamily
        }
        config.theme = .current

        view.backgroundColor = config.theme.backgroundColor
        pageViewController.view.backgroundColor = config.theme.backgroundColor

        paginator.updateConfig(config)
        updateReadingStatusAppearance()

        // Repaginate with new settings
        if !pages.isEmpty {
            repaginate()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        layoutReadingStatus()

        // Repaginate if view size changed significantly (e.g., rotation)
        let newSize = view.bounds.size
        if !pages.isEmpty && lastPaginationSize != .zero {
            let previousDoublePageState = usesDoublePages
            if usesAutoPageLayout {
                usesDoublePages = shouldUseDoublePages(for: newSize)
            }
            if previousDoublePageState != usesDoublePages ||
               abs(lastPaginationSize.width - newSize.width) > 10 ||
               abs(lastPaginationSize.height - newSize.height) > 10 {
                repaginate()
            }
        }
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)

        coordinator.animate(alongsideTransition: nil) { [weak self] _ in
            guard let self else { return }

            if self.usesAutoPageLayout {
                let newUsesDouble = self.shouldUseDoublePages(for: size)
                if newUsesDouble != self.usesDoublePages {
                    self.usesDoublePages = newUsesDouble
                }
            }

            self.repaginate()
        }
    }

    // Safe area changes from bar toggles are intentionally ignored.
    // We use the window's safe area (constant physical insets) for pagination.
    // Rotation is handled by viewWillTransition(to:with:) and viewDidLayoutSubviews.

    // MARK: - Layout

    private func updatePageLayout() {
        usesAutoPageLayout = false
        switch UserDefaults.standard.string(forKey: "Reader.pagedPageLayout") {
            case "single":
                usesDoublePages = false
            case "double":
                usesDoublePages = true
            case "auto":
                usesAutoPageLayout = true
                usesDoublePages = shouldUseDoublePages(for: view.bounds.size)
            default:
                usesDoublePages = false
        }
    }

    /// In automatic layout, landscape uses a spread on every device. iPad also
    /// uses a spread in portrait when there is enough width, while compact
    /// split-screen widths remain single-page.
    private func shouldUseDoublePages(for size: CGSize) -> Bool {
        guard size.width > 0, size.height > 0 else { return false }
        if size.width > size.height {
            return true
        }
        return traitCollection.userInterfaceIdiom == .pad && size.width >= 700
    }

    // MARK: - Reading Status

    private func configureReadingStatus() {
        readingStatusView.isUserInteractionEnabled = false
        readingStatusView.backgroundColor = .clear
        view.addSubview(readingStatusView)

        for label in [chapterStatusLabel, timeStatusLabel, pageStatusLabel] {
            label.font = .systemFont(ofSize: 12, weight: .regular)
            label.numberOfLines = 1
            label.adjustsFontSizeToFitWidth = true
            label.minimumScaleFactor = 0.8
            readingStatusView.addSubview(label)
        }
        chapterStatusLabel.textAlignment = .left
        timeStatusLabel.textAlignment = .right
        pageStatusLabel.textAlignment = .left

        UIDevice.current.isBatteryMonitoringEnabled = true
        updateReadingStatusAppearance()
        updateReadingStatus()
        readingStatusTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.updateReadingStatus()
        }
    }

    private func updateReadingStatusAppearance() {
        let color = TextReaderTheme.current.secondaryForegroundColor
        chapterStatusLabel.textColor = color
        timeStatusLabel.textColor = color
        pageStatusLabel.textColor = color
    }

    private func layoutReadingStatus() {
        readingStatusView.frame = view.bounds

        let safeArea = view.window?.safeAreaInsets ?? view.safeAreaInsets
        physicalSafeAreaInsets = safeArea
        let horizontalInset = max(16, safeArea.left + 16)
        let trailingInset = max(16, safeArea.right + 16)
        let availableWidth = max(0, view.bounds.width - horizontalInset - trailingInset)
        let topY = safeArea.top + 4
        let statusHeight: CGFloat = 18

        chapterStatusLabel.frame = CGRect(
            x: horizontalInset,
            y: topY,
            width: availableWidth * 0.62,
            height: statusHeight
        )
        timeStatusLabel.frame = CGRect(
            x: horizontalInset + availableWidth * 0.62,
            y: topY,
            width: availableWidth * 0.38,
            height: statusHeight
        )
        pageStatusLabel.frame = CGRect(
            x: horizontalInset,
            y: max(topY, view.bounds.height - safeArea.bottom - statusHeight - 4),
            width: availableWidth,
            height: statusHeight
        )
        view.bringSubviewToFront(readingStatusView)
    }

    private func updateReadingStatus() {
        chapterStatusLabel.text = chapterDisplayTitle

        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("HH:mm")
        let time = formatter.string(from: Date())
        let batteryLevel = UIDevice.current.batteryLevel
        if batteryLevel >= 0 {
            timeStatusLabel.text = "\(time)  \(Int((batteryLevel * 100).rounded()))%"
        } else {
            timeStatusLabel.text = time
        }

        guard !pages.isEmpty else {
            pageStatusLabel.text = nil
            return
        }
        let firstVisible = min(currentPageIndex + 1, pages.count)
        let lastVisible = usesDoublePages ? min(firstVisible + 1, pages.count) : firstVisible
        pageStatusLabel.text = firstVisible == lastVisible
            ? "\(firstVisible) / \(pages.count)"
            : "\(firstVisible)–\(lastVisible) / \(pages.count)"
    }

    private var chapterDisplayTitle: String {
        if let title = chapter?.title, !title.isEmpty {
            return title
        }
        if let chapterNumber = chapter?.chapterNumber {
            return String(format: NSLocalizedString("CHAPTER_X", comment: ""), chapterNumber)
        }
        return viewModel.manga.title
    }

    // MARK: - Pagination

    private func repaginate() {
        guard let text = getCurrentText(), !text.isEmpty else {
            return
        }

        // Wait for valid bounds — viewDidLayoutSubviews will trigger repagination
        guard view.bounds.width > 0 && view.bounds.height > 0 else {
            return
        }

        // Use the window's safe area (physical notch/home indicator) which stays
        // constant regardless of bar visibility. This prevents text from shifting
        // when bars are toggled.
        let windowSafeArea = view.window?.safeAreaInsets ?? view.safeAreaInsets
        physicalSafeAreaInsets = windowSafeArea
        let safeWidth = view.bounds.width - windowSafeArea.left - windowSafeArea.right
        let safeHeight = view.bounds.height
            - windowSafeArea.top
            - windowSafeArea.bottom
            - topStatusReserve
            - bottomStatusReserve

        // Compute fixed text insets for child page VCs (must match pagination geometry)
        let config = paginator.currentConfig
        textInsets = UIEdgeInsets(
            top: windowSafeArea.top + topStatusReserve + config.topPadding,
            left: windowSafeArea.left + config.horizontalPadding,
            bottom: windowSafeArea.bottom + bottomStatusReserve + config.bottomPadding,
            right: windowSafeArea.right + config.horizontalPadding
        )

        let pageSize: CGSize
        if usesDoublePages {
            // For double page, each page is half width
            pageSize = CGSize(width: safeWidth / 2, height: safeHeight)
        } else {
            pageSize = CGSize(width: safeWidth, height: safeHeight)
        }

        // Track size to prevent repagination loops
        lastPaginationSize = view.bounds.size

        pages = paginator.paginate(markdown: text, pageSize: pageSize)
        hasPaginated = true
        updateReadingStatus()

        // Pagination can produce no pages (e.g. a chapter whose only content is a
        // failed image reference); bail out before any indexing below
        guard !pages.isEmpty else { return }

        // Update toolbar with our paginated page count
        // ReaderViewController now knows to not switch away when we're already
        // in the paginated text reader with text pages
        if !pages.isEmpty {
            let sourceId = viewModel.source?.key ?? viewModel.manga.sourceKey
            let chapterId = chapter?.key ?? ""
            let language = chapter?.language ?? viewModel.source?.languages.first
            // Check if any source page has a description
            let sourceHasDescription = viewModel.pages.contains { $0.hasDescription }
            let placeholderPages: [Page] = pages.map { textPage in
                var page = Page(
                    sourceId: sourceId,
                    chapterId: chapterId,
                    language: language
                )
                page.index = textPage.id
                page.text = "page"  // Mark as text page
                // Carry description info so the info button appears on every page
                if sourceHasDescription {
                    page.hasDescription = true
                    // Copy the actual description from source pages if available
                    if let desc = viewModel.pages.compactMap({ $0.description }).first {
                        page.description = desc
                    }
                }
                return page
            }
            delegate?.setPages(placeholderPages)
        }

        // Determine which page to show
        let targetIndex: Int
        if let pending = pendingStartPage {
            pendingStartPage = nil  // Clear after using

            // If pending <= 0, this chapter is completed or has no history - start from beginning
            if pending <= 0 {
                targetIndex = 0
                currentCharacterOffset = 0
            } else if pending == Int.max {
                // Coming from next chapter (swiping back) — always go to last page
                targetIndex = pages.count - 1
                currentCharacterOffset = pages[targetIndex].range.location
            } else if let chapterKey = chapter?.key {
                Task {
                    let targetIndex: Int
                    if let progress = await loadReadingProgress(for: chapterKey), progress > 0 {
                        // Fall back to shared progress (e.g. from scroll reader)
                        let idx = Int(progress * Double(max(1, pages.count - 1)))
                        targetIndex = min(max(0, idx), pages.count - 1)
                    } else {
                        targetIndex = min(pending - 1, pages.count - 1)
                    }
                    currentCharacterOffset = pages[targetIndex].range.location
                    move(toPage: min(targetIndex, max(0, pages.count - 1)), animated: false)
                }
                return
            } else {
                // Fall back to page number from History (first open, no stored offset)
                targetIndex = min(pending - 1, pages.count - 1)
                currentCharacterOffset = pages[targetIndex].range.location
            }
        } else {
            // In-session repagination (font/size change) – use current character offset
            targetIndex = pages.lastIndex(where: { $0.range.location <= currentCharacterOffset }) ?? 0
        }

        move(toPage: min(targetIndex, max(0, pages.count - 1)), animated: false)
    }

    /// Load previously saved reading progress for a chapter.
    private func loadReadingProgress(for chapterKey: String) async -> CGFloat? {
        await CoreDataManager.shared.container.performBackgroundTask { [weak self] context in
            guard let self else { return nil }
            let object = CoreDataManager.shared.getHistory(
                sourceId: self.viewModel.manga.sourceKey,
                mangaId: self.viewModel.manga.key,
                chapterId: chapterKey,
                context: context
            )
            return object?.scrollPosition.map { CGFloat($0.doubleValue) }
        }
    }

    private func getCurrentText() -> String? {
        guard let page = viewModel.pages.first else {
            return nil
        }

        // Direct text content
        if let text = page.text {
            return text
        }

        // Load text from ZIP archive (for downloaded chapters)
        guard
            let zipURLString = page.zipURL,
            let zipURL = URL(string: zipURLString),
            let filePath = page.imageURL
        else {
            return nil
        }

        do {
            var data = Data()
            let archive = try Archive(url: zipURL, accessMode: .read)
            guard let entry = archive.entry(at: filePath) else {
                return nil
            }
            _ = try archive.extract(
                entry,
                consumer: { readData in
                    data.append(readData)
                }
            )
            let text = String(data: data, encoding: .utf8)
            return text
        } catch {
            return nil
        }
    }

    private func refreshPages() {
        repaginate()
    }

    // MARK: - Navigation

    func move(toPage index: Int, animated: Bool) {
        guard !pages.isEmpty else {
            return
        }

        let targetIndex = alignedPageIndex(min(max(0, index), pages.count - 1))

        let oldIndex = currentPageIndex
        currentPageIndex = targetIndex

        // Track character offset for position restoration after repagination
        if targetIndex < pages.count {
            currentCharacterOffset = pages[targetIndex].range.location
        }

        let viewController = createPageViewController(for: targetIndex)

        let direction: UIPageViewController.NavigationDirection
        if effectiveReadingMode == .rtl {
            direction = targetIndex < oldIndex ? .forward : .reverse
        } else {
            direction = targetIndex > oldIndex ? .forward : .reverse
        }

        pageViewController.setViewControllers(
            [viewController],
            direction: direction,
            animated: animated
        ) { [weak self] completed in
            if completed {
                self?.updateSliderPosition()
            }
        }

        // Update current page display (1-indexed for UI)
        reportCurrentPage(for: targetIndex)
        updateSliderPosition()
        updateReadingStatus()
    }

    /// Snap an index to the left page of its double-page spread so spreads always
    /// pair (0,1), (2,3), … — otherwise stepping by 2 skips the first/last page
    /// when navigation lands on an odd index (slider, history restore, chapter end).
    private func alignedPageIndex(_ index: Int) -> Int {
        usesDoublePages ? index - (index % 2) : index
    }

    /// Report the rightmost visible page of the spread at the given aligned index.
    /// The delegate marks the chapter completed when the reported page reaches the
    /// total page count, so the right page of the final spread must be reported —
    /// not just the (left) spread index.
    private func reportCurrentPage(for index: Int) {
        let visibleIndex = usesDoublePages ? min(index + 1, pages.count - 1) : index
        delegate?.setCurrentPage(visibleIndex + 1, position: normalizedPosition(for: visibleIndex))
    }

    private func createPageViewController(for index: Int) -> UIViewController {
        let index = alignedPageIndex(index)

        guard index >= 0 && index < pages.count else {
            // Return empty view controller as fallback
            let vc = UIViewController()
            vc.view.backgroundColor = TextReaderTheme.current.backgroundColor
            return vc
        }

        if usesDoublePages && index + 1 < pages.count {
            // Double page spread
            return TextDoublePageViewController(
                leftPage: pages[index],
                rightPage: pages[index + 1],
                direction: effectiveReadingMode == .rtl ? .rtl : .ltr,
                parentReader: self
            )
        } else {
            // Single page - pass parent reference so it can get live safe area updates
            return TextSinglePageViewController(page: pages[index], parentReader: self)
        }
    }

    /// Compute a normalized 0-1 position from the current page index.
    /// Both the scroll and paged text readers use this format so switching
    /// between them preserves the reading position.
    private func normalizedPosition(for pageIndex: Int) -> Double {
        guard pages.count > 1 else { return 0 }
        return Double(pageIndex) / Double(pages.count - 1)
    }

    private func updateSliderPosition() {
        guard !pages.isEmpty else { return }
        let offset = CGFloat(currentPageIndex) / CGFloat(max(1, pages.count - 1))
        delegate?.setSliderOffset(offset)
    }

    private func move(direction: UIPageViewController.NavigationDirection) {
        guard let currentViewController = pageViewController.viewControllers?.first else { return }

        let targetViewController = switch direction {
            case .reverse:
                pageViewController(pageViewController, viewControllerBefore: currentViewController)
            default:
                pageViewController(pageViewController, viewControllerAfter: currentViewController)
        }
        guard let targetViewController else { return }

        let animated = UserDefaults.standard.bool(forKey: "Reader.animatePageTransitions")
        pageViewController.setViewControllers(
            [targetViewController],
            direction: direction,
            animated: animated
        ) { [weak self] completed in
            guard let self else { return }
            self.pageViewController(
                self.pageViewController,
                didFinishAnimating: true,
                previousViewControllers: [currentViewController],
                transitionCompleted: completed
            )
        }
    }

    // MARK: - Chapter Loading

    func loadChapter(_ chapter: AidokuRunner.Chapter, startPage: Int = 0) async {
        isLoadingChapter = true
        hasPaginated = false
        self.chapter = chapter
        updateReadingStatus()

        await viewModel.loadPages(chapter: chapter)

        guard !viewModel.pages.isEmpty else {
            isLoadingChapter = false
            return
        }

        // Don't paginate non-text chapters — the reading mode would need to
        // switch. Inform the delegate about the pages and let the parent
        // controller handle the mode change.
        guard viewModel.pages.allSatisfy({ $0.isTextPage }) else {
            await MainActor.run {
                delegate?.setPages(viewModel.pages)
                isLoadingChapter = false
            }
            return
        }

        await MainActor.run {
            previousChapter = delegate?.getPreviousChapter()
            nextChapter = delegate?.getNextChapter()

            // Ensure view is laid out before paginating
            view.layoutIfNeeded()

            // Set pending start page before repaginate
            // startPage <= 0 means no history exists - start from beginning
            pendingStartPage = startPage

            repaginate()

            isLoadingChapter = false
        }
    }
}

// MARK: - Reader Delegate
extension ReaderPagedTextViewController: ReaderReaderDelegate {
    func moveLeft() {
        move(direction: .reverse)
    }

    func moveRight() {
        move(direction: .forward)
    }

    func sliderMoved(value: CGFloat) {
        let targetPage = Int(value * CGFloat(pages.count - 1))
        delegate?.displayPage(targetPage + 1)
    }

    func sliderStopped(value: CGFloat) {
        let targetPage = Int(value * CGFloat(pages.count - 1))
        move(toPage: targetPage, animated: false)
    }

    func setChapter(_ chapter: AidokuRunner.Chapter, startPage: Int) {

        // Prevent reloading if we're already loading
        if isLoadingChapter {
            return
        }

        // Prevent reloading the same chapter if we already have paginated pages
        if self.chapter?.key == chapter.key && !pages.isEmpty {
            if startPage > 0 && startPage <= pages.count {
                move(toPage: startPage - 1, animated: false)
            }
            return
        }

        // Check if viewModel already has the page loaded (from ReaderViewController's initial load)
        // This prevents double-fetching the chapter
        if !viewModel.pages.isEmpty {
            self.chapter = chapter
            isLoadingChapter = true
            hasPaginated = false
            // Store the requested start page - repaginate will use this
            // startPage <= 0 means no history exists - start from beginning
            pendingStartPage = startPage
            view.layoutIfNeeded()
            repaginate()
            isLoadingChapter = false
            return
        }

        Task {
            await loadChapter(chapter, startPage: startPage)
        }
    }

    func loadPreviousChapter() {
        guard let previousChapter else { return }
        Task {
            // Preload to check whether the chapter has text pages.
            await viewModel.preload(chapter: previousChapter)
            let preloaded = viewModel.preloadedPages
            guard !preloaded.isEmpty else {
                await MainActor.run { snapBackToTransitionPage() }
                return
            }
            guard preloaded.allSatisfy({ $0.isTextPage }) else {
                // Non-text chapter: hand off to the parent controller, which
                // switches to the appropriate reader and reloads the chapter.
                await MainActor.run {
                    delegate?.setChapter(previousChapter)
                    delegate?.setPages(preloaded)
                }
                return
            }
            delegate?.setChapter(previousChapter)
            await loadChapter(previousChapter, startPage: Int.max)
        }
    }

    func loadNextChapter() {
        guard let nextChapter else { return }
        Task {
            await viewModel.preload(chapter: nextChapter)
            let preloaded = viewModel.preloadedPages
            guard !preloaded.isEmpty else {
                await MainActor.run { snapBackToTransitionPage() }
                return
            }
            guard preloaded.allSatisfy({ $0.isTextPage }) else {
                // Non-text chapter: hand off to the parent controller, which
                // switches to the appropriate reader and reloads the chapter.
                await MainActor.run {
                    delegate?.setChapter(nextChapter)
                    delegate?.setPages(preloaded)
                }
                return
            }
            delegate?.setChapter(nextChapter)
            await loadChapter(nextChapter, startPage: 0)
        }
    }

    /// Navigate back from the blank trigger page to the visible transition page.
    private func snapBackToTransitionPage() {
        guard let currentVC = pageViewController.viewControllers?.first,
              let triggerVC = currentVC as? ChapterLoadTriggerViewController else { return }
        pageViewController.setViewControllers(
            [triggerVC.transitionVC],
            direction: .reverse,
            animated: true
        )
    }
}

// MARK: - Page View Controller Delegate
extension ReaderPagedTextViewController: UIPageViewControllerDelegate {
    func pageViewController(
        _ pageViewController: UIPageViewController,
        didFinishAnimating finished: Bool,
        previousViewControllers: [UIViewController],
        transitionCompleted completed: Bool
    ) {
        guard completed,
              let currentVC = pageViewController.viewControllers?.first else {
            return
        }

        // When user swipes past the transition page onto the trigger page, load the chapter
        if let triggerVC = currentVC as? ChapterLoadTriggerViewController {
            triggerVC.transitionVC.performTransition()
            return
        }

        // Transition info page itself — just display, no auto-navigation
        if currentVC is ChapterTransitionViewController {
            return
        }

        if let singlePage = currentVC as? TextSinglePageViewController {
            currentPageIndex = singlePage.page.id
            currentCharacterOffset = singlePage.page.range.location
        } else if let doublePage = currentVC as? TextDoublePageViewController {
            currentPageIndex = doublePage.leftPage.id
            currentCharacterOffset = doublePage.leftPage.range.location
        }

        reportCurrentPage(for: currentPageIndex)
        updateSliderPosition()
        updateReadingStatus()
    }

    func pageViewController(
        _ pageViewController: UIPageViewController,
        willTransitionTo pendingViewControllers: [UIViewController]
    ) {
        if UserDefaults.standard.bool(forKey: "Reader.hideBarsOnSwipe") {
            delegate?.hideBars()
        }
    }
}

// MARK: - Page View Controller Data Source
extension ReaderPagedTextViewController: UIPageViewControllerDataSource {
    func pageViewController(
        _ pageViewController: UIPageViewController,
        viewControllerAfter viewController: UIViewController
    ) -> UIViewController? {
        // Past the trigger page — nothing further
        if viewController is ChapterLoadTriggerViewController {
            return nil
        }

        // Transition info page
        if let transitionVC = viewController as? ChapterTransitionViewController {
            if transitionVC.direction == .next {
                // "Next chapter" transition: swiping forward = trigger load
                guard transitionVC.chapter != nil else { return nil }
                return ChapterLoadTriggerViewController(transitionVC: transitionVC)
            } else {
                // "Previous chapter" transition: swiping forward = back to first text page
                guard !pages.isEmpty else { return nil }
                return createPageViewController(for: 0)
            }
        }

        let currentIndex = getCurrentIndex(from: viewController)

        let nextIndex: Int
        switch effectiveReadingMode {
            case .rtl:
                nextIndex = currentIndex - (usesDoublePages ? 2 : 1)
            default:
                nextIndex = currentIndex + (usesDoublePages ? 2 : 1)
        }

        if nextIndex >= 0 && nextIndex < pages.count {
            return createPageViewController(for: nextIndex)
        } else if nextIndex >= pages.count {
            // Show chapter transition page (matching image reader style)
            let sourceId = viewModel.source?.key ?? viewModel.manga.sourceKey
            return ChapterTransitionViewController(
                direction: .next,
                chapter: nextChapter,
                currentChapter: chapter,
                sourceId: sourceId,
                mangaId: viewModel.manga.key,
                parentReader: self
            )
        }
        return nil
    }

    func pageViewController(
        _ pageViewController: UIPageViewController,
        viewControllerBefore viewController: UIViewController
    ) -> UIViewController? {
        // Past the trigger page — nothing further
        if viewController is ChapterLoadTriggerViewController {
            return nil
        }

        // Transition info page
        if let transitionVC = viewController as? ChapterTransitionViewController {
            if transitionVC.direction == .previous {
                // "Previous chapter" transition: swiping backward = trigger load
                guard transitionVC.chapter != nil else { return nil }
                return ChapterLoadTriggerViewController(transitionVC: transitionVC)
            } else {
                // "Next chapter" transition: swiping backward = back to last text page
                guard !pages.isEmpty else { return nil }
                return createPageViewController(for: pages.count - 1)
            }
        }

        let currentIndex = getCurrentIndex(from: viewController)

        let prevIndex: Int
        switch effectiveReadingMode {
            case .rtl:
                prevIndex = currentIndex + (usesDoublePages ? 2 : 1)
            default:
                prevIndex = currentIndex - (usesDoublePages ? 2 : 1)
        }

        if prevIndex >= 0 && prevIndex < pages.count {
            return createPageViewController(for: prevIndex)
        } else if prevIndex < 0 {
            // Show chapter transition page (matching image reader style)
            let sourceId = viewModel.source?.key ?? viewModel.manga.sourceKey
            return ChapterTransitionViewController(
                direction: .previous,
                chapter: previousChapter,
                currentChapter: chapter,
                sourceId: sourceId,
                mangaId: viewModel.manga.key,
                parentReader: self
            )
        }
        return nil
    }

    private func getCurrentIndex(from viewController: UIViewController) -> Int {
        if let singlePage = viewController as? TextSinglePageViewController {
            return singlePage.page.id
        } else if let doublePage = viewController as? TextDoublePageViewController {
            return doublePage.leftPage.id
        }
        return currentPageIndex
    }
}
