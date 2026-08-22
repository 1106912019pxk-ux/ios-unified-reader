//
//  ReaderTextViewController.swift
//  Aidoku
//
//  Created by Skitty on 5/13/25.
//

import AidokuRunner
import SwiftUI
import ZIPFoundation

private final class TextAutoScrollDisplayLinkProxy {
    weak var owner: ReaderTextViewController?

    init(owner: ReaderTextViewController) {
        self.owner = owner
    }

    @objc func step(_ displayLink: CADisplayLink) {
        owner?.handleAutoScrollFrame(displayLink)
    }
}

class ReaderTextViewController: BaseViewController {
    let viewModel: ReaderTextViewModel

    var readingMode: ReadingMode = .rtl
    var delegate: (any ReaderHoldingDelegate)?

    // MARK: - Multi-chapter section tracking for infinite scroll

    /// A section of content in the scroll view representing one chapter.
    private struct ChapterSection {
        let chapter: AidokuRunner.Chapter
        let pages: [Page]
        var hostingControllers: [UIHostingController<ReaderTextView>]
        /// Transition view shown after this section's content (between chapters).
        var transitionView: ReaderInfoPageView?
        var transitionHeightConstraint: NSLayoutConstraint?
    }

    /// All loaded chapter sections in scroll order (top to bottom).
    private var sections: [ChapterSection] = []

    /// The chapter currently being read (based on scroll position).
    private var chapter: AidokuRunner.Chapter?
    /// The chapter before the first loaded section (for the top transition).
    private var previousChapter: AidokuRunner.Chapter?
    /// The chapter after the last loaded section (for the bottom transition).
    private var nextChapter: AidokuRunner.Chapter?

    private var isLoadingChapter = false
    private var loadingNext = false
    private var loadingPrevious = false
    private var hasReachedEnd = false

    private var isSliding = false
    private var estimatedPageCount = 1
    private var pendingScrollRestore = false
    private var isReportingProgress = false
    private var lastReportedPage = 0
    private var needsPageCountUpdate = false

    // MARK: - Auto Reading

    private let autoScrollBasePointsPerSecond: CGFloat = 28
    private var autoScrollDisplayLink: CADisplayLink?
    private var autoScrollDisplayLinkProxy: TextAutoScrollDisplayLinkProxy?
    private var autoScrollLastTimestamp: CFTimeInterval = 0
    private var isAutoScrollPaused = false

    /// Tracks the last known safe area insets so we can compensate content offset
    /// when bars show/hide with `contentInsetAdjustmentBehavior = .never`.
    private var lastSafeAreaInsets: UIEdgeInsets?
    /// When true, suppresses hosting controller size invalidation to prevent
    /// layout passes from undoing offset compensation during bar transitions.
    private var isSafeAreaTransitioning = false

    // MARK: - Scroll Position Persistence

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

    // MARK: - Views

    private lazy var scrollView: UIScrollView = {
        let scrollView = UIScrollView()
        scrollView.backgroundColor = TextReaderTheme.current.backgroundColor
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.delegate = self
        scrollView.alwaysBounceVertical = true
        scrollView.contentInsetAdjustmentBehavior = .never
        return scrollView
    }()

    private lazy var contentStackView: UIStackView = {
        let sv = UIStackView()
        sv.axis = .vertical
        sv.spacing = 0
        return sv
    }()

    private lazy var autoScrollControlView: UIVisualEffectView = {
        let control = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
        control.layer.cornerRadius = 22
        control.clipsToBounds = true
        control.isHidden = true

        let stack = UIStackView(arrangedSubviews: [
            autoScrollPlayPauseButton,
            makeAutoScrollButton(systemName: "minus", action: #selector(decreaseAutoScrollSpeed)),
            autoScrollSpeedLabel,
            makeAutoScrollButton(systemName: "plus", action: #selector(increaseAutoScrollSpeed)),
            makeAutoScrollButton(systemName: "xmark", action: #selector(stopAutoScroll))
        ])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.distribution = .fill
        stack.spacing = 4
        control.contentView.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: control.contentView.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: control.contentView.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: control.contentView.topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: control.contentView.bottomAnchor, constant: -4)
        ])
        return control
    }()

    private lazy var autoScrollPlayPauseButton: UIButton = {
        makeAutoScrollButton(systemName: "pause.fill", action: #selector(toggleAutoScrollPause))
    }()

    private lazy var autoScrollSpeedLabel: UILabel = {
        let label = UILabel()
        label.font = .monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
        label.textAlignment = .center
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.widthAnchor.constraint(equalToConstant: 54).isActive = true
        return label
    }()

    /// Flat list of all hosting controllers across all sections (for invalidation).
    private var allHostingControllers: [UIHostingController<ReaderTextView>] {
        sections.flatMap { $0.hostingControllers }
    }

    private var currentFontFamily: String {
        UserDefaults.standard.string(forKey: "Reader.textFontFamily") ?? "System"
    }
    private var currentFontSize: Double {
        UserDefaults.standard.object(forKey: "Reader.textFontSize") as? Double ?? 18
    }
    private var currentLineSpacing: Double {
        UserDefaults.standard.object(forKey: "Reader.textLineSpacing") as? Double ?? 8
    }
    private var currentHorizontalPadding: Double {
        UserDefaults.standard.object(forKey: "Reader.textHorizontalPadding") as? Double ?? 24
    }
    private var currentTopPadding: Double {
        UserDefaults.standard.object(forKey: "Reader.textTopPadding") as? Double ?? 32
    }
    private var currentBottomPadding: Double {
        UserDefaults.standard.object(forKey: "Reader.textBottomPadding") as? Double ?? 32
    }
    private var currentParagraphSpacing: Double {
        UserDefaults.standard.object(forKey: "Reader.textParagraphSpacing") as? Double ?? 12
    }
    private var currentFirstLineIndent: Double {
        UserDefaults.standard.object(forKey: "Reader.textFirstLineIndent") as? Double ?? 0
    }

    private func createHostingController(page: Page?) -> UIHostingController<ReaderTextView> {
        let hc = HostingController(
            rootView: ReaderTextView(
                source: viewModel.source, page: page,
                fontFamily: currentFontFamily, fontSize: currentFontSize,
                lineSpacing: currentLineSpacing, horizontalPadding: currentHorizontalPadding,
                topPadding: currentTopPadding, bottomPadding: currentBottomPadding,
                paragraphSpacing: currentParagraphSpacing, firstLineIndent: currentFirstLineIndent,
                theme: .current
            )
        )
        if #available(iOS 16.0, *) {
            hc.sizingOptions = .intrinsicContentSize
        }
        if #available(iOS 16.4, *) {
            hc.safeAreaRegions = []
        }
        hc.view.backgroundColor = .clear
        return hc
    }

    // Top/bottom boundary transition views (outside the content stack).
    private var previousTransitionView: ReaderInfoPageView?
    private var nextTransitionView: ReaderInfoPageView?
    private var prevHeightConstraint: NSLayoutConstraint?
    private var nextHeightConstraint: NSLayoutConstraint?

    private var showsPreviousTransition = false
    private var showsNextTransition = false

    private var transitionPageHeight: CGFloat {
        // Use the full view height so transition pages stay a stable size
        // regardless of bar visibility (scrollView.frame changes with safe area).
        view.bounds.height
    }

    init(source: AidokuRunner.Source?, manga: AidokuRunner.Manga) {
        self.viewModel = .init(source: source, manga: manga)
        super.init()
    }

    deinit {
        autoScrollDisplayLink?.invalidate()
    }

    // MARK: - Helpers

    private var sourceId: String {
        viewModel.source?.key ?? viewModel.manga.sourceKey
    }

    private var mangaId: String {
        viewModel.manga.key
    }

    /// Create a full-screen-height transition view to be placed between sections.
    private func createInlineTransitionView(
        finishedChapter: AidokuRunner.Chapter,
        nextChapter: AidokuRunner.Chapter?
    ) -> ReaderInfoPageView {
        let tv = ReaderInfoPageView(type: .next)
        tv.translatesAutoresizingMaskIntoConstraints = false
        tv.currentChapter = finishedChapter.toOld(sourceId: sourceId, mangaId: mangaId)
        tv.nextChapter = nextChapter?.toOld(sourceId: sourceId, mangaId: mangaId)
        return tv
    }

    /// Refreshes all hosting controllers with updated text style values.
    private func refreshTextViews() {
        for section in sections {
            for (index, hc) in section.hostingControllers.enumerated() {
                let page = section.pages[safe: index]
                hc.rootView = ReaderTextView(
                    source: viewModel.source, page: page,
                    fontFamily: currentFontFamily, fontSize: currentFontSize,
                    lineSpacing: currentLineSpacing, horizontalPadding: currentHorizontalPadding,
                    topPadding: currentTopPadding, bottomPadding: currentBottomPadding,
                    paragraphSpacing: currentParagraphSpacing, firstLineIndent: currentFirstLineIndent,
                    theme: .current
                )
                hc.view.invalidateIntrinsicContentSize()
            }
        }
    }

    // MARK: - Configure

    override func configure() {
        let styleKeys = [
            "Reader.textFontFamily",
            "Reader.textFontSize",
            "Reader.textLineSpacing",
            "Reader.textHorizontalPadding",
            "Reader.textTopPadding",
            "Reader.textBottomPadding",
            "Reader.textParagraphSpacing",
            "Reader.textFirstLineIndent",
            "Reader.textBackgroundColor"
        ]
        for key in styleKeys {
            NotificationCenter.default.addObserver(
                self, selector: #selector(textStyleChanged),
                name: .init(key), object: nil
            )
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(autoScrollEnabledChanged),
            name: .init("Reader.textAutoScrollEnabled"), object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(autoScrollSpeedChanged),
            name: .init("Reader.textAutoScrollSpeed"), object: nil
        )

        scrollView.addSubview(contentStackView)

        // Boundary transition views (direct scroll view children)
        let prevView = ReaderInfoPageView(type: .previous)
        prevView.translatesAutoresizingMaskIntoConstraints = false
        prevView.isHidden = true
        scrollView.addSubview(prevView)
        previousTransitionView = prevView

        let nextView = ReaderInfoPageView(type: .next)
        nextView.translatesAutoresizingMaskIntoConstraints = false
        nextView.isHidden = true
        scrollView.addSubview(nextView)
        nextTransitionView = nextView

        // Build the initial section from viewModel.pages
        var hostingControllers: [UIHostingController<ReaderTextView>] = []
        let pagesToUse = viewModel.pages.isEmpty ? [viewModel.pages.first].compactMap { $0 } : viewModel.pages
        for page in pagesToUse {
            let hc = createHostingController(page: page)
            addChild(hc)
            hc.didMove(toParent: self)
            hostingControllers.append(hc)
            contentStackView.addArrangedSubview(hc.view)
        }
        // Ensure at least one hosting controller
        if hostingControllers.isEmpty {
            let hc = createHostingController(page: nil)
            addChild(hc)
            hc.didMove(toParent: self)
            hostingControllers.append(hc)
            contentStackView.addArrangedSubview(hc.view)
        }

        if let ch = chapter ?? viewModel.chapter {
            sections.append(ChapterSection(
                chapter: ch, pages: pagesToUse,
                hostingControllers: hostingControllers
            ))
        }

        view.addSubview(scrollView)
        view.addSubview(autoScrollControlView)
        applyAutoScrollState()
    }

    // MARK: - Constraints

    override func constrain() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        contentStackView.translatesAutoresizingMaskIntoConstraints = false
        autoScrollControlView.translatesAutoresizingMaskIntoConstraints = false
        for hc in allHostingControllers {
            hc.view.translatesAutoresizingMaskIntoConstraints = false
        }

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            contentStackView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            autoScrollControlView.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
            autoScrollControlView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
            autoScrollControlView.heightAnchor.constraint(equalToConstant: 44)
        ])

        if let prevView = previousTransitionView {
            let h = prevView.heightAnchor.constraint(equalToConstant: 0)
            prevHeightConstraint = h
            NSLayoutConstraint.activate([
                prevView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
                prevView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
                prevView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
                h,
                contentStackView.topAnchor.constraint(equalTo: prevView.bottomAnchor),
                contentStackView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
                contentStackView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor)
            ])
        } else {
            NSLayoutConstraint.activate([
                contentStackView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
                contentStackView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
                contentStackView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor)
            ])
        }

        if let nextView = nextTransitionView {
            let h = nextView.heightAnchor.constraint(equalToConstant: 0)
            nextHeightConstraint = h
            NSLayoutConstraint.activate([
                nextView.topAnchor.constraint(equalTo: contentStackView.bottomAnchor),
                nextView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
                nextView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
                nextView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
                h
            ])
        } else {
            contentStackView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor).isActive = true
        }
    }

    // MARK: - Layout

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        let newInsets = view.safeAreaInsets
        defer { lastSafeAreaInsets = newInsets }

        // Keep content inset in sync so the scroll view allows scrolling
        // past the content top (text starts below the navigation bar).
        scrollView.contentInset = UIEdgeInsets(top: newInsets.top, left: 0, bottom: newInsets.bottom, right: 0)
        scrollView.verticalScrollIndicatorInsets = scrollView.contentInset

        guard let lastInsets = lastSafeAreaInsets else { return }
        let topDelta = newInsets.top - lastInsets.top
        guard topDelta != 0 else { return }

        // On iOS 16.4+, safeAreaRegions = [] on the hosting controllers prevents
        // them from resizing when bars show/hide — no compensation needed.
        // On older iOS, suppress invalidation and compensate the offset manually.
        if #unavailable(iOS 16.4) {
            isSafeAreaTransitioning = true
            setHostingControllerInvalidation(suppressed: true)
            scrollView.contentOffset.y += topDelta
        }
    }

    private func setHostingControllerInvalidation(suppressed: Bool) {
        for hc in allHostingControllers {
            (hc as? HostingController<ReaderTextView>)?.suppressInvalidation = suppressed
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        // During bar show/hide on iOS < 16.4, skip layout updates to prevent
        // content shifting, then clear the suppression flags for the next pass.
        if isSafeAreaTransitioning {
            isSafeAreaTransitioning = false
            setHostingControllerInvalidation(suppressed: false)
            return
        }

        for hc in allHostingControllers {
            hc.view.invalidateIntrinsicContentSize()
        }

        let transHeight = transitionPageHeight
        if showsPreviousTransition {
            prevHeightConstraint?.constant = transHeight
        }
        if showsNextTransition {
            nextHeightConstraint?.constant = transHeight
        }
        // Keep inline transition views in sync
        for section in sections where section.transitionView != nil {
            section.transitionHeightConstraint?.constant = transHeight
        }

        if needsPageCountUpdate {
            updateEstimatedPageCount()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        applyAutoScrollState()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        invalidateAutoScrollDisplayLink()
    }
}

// MARK: - Auto Reading
extension ReaderTextViewController {
    private var autoScrollEnabled: Bool {
        UserDefaults.standard.bool(forKey: "Reader.textAutoScrollEnabled")
    }

    private var autoScrollSpeed: Double {
        let value = UserDefaults.standard.object(forKey: "Reader.textAutoScrollSpeed") as? Double ?? 1
        return min(4, max(0.5, value))
    }

    private func makeAutoScrollButton(systemName: String, action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: systemName), for: .normal)
        button.tintColor = .label
        button.addTarget(self, action: action, for: .touchUpInside)
        button.widthAnchor.constraint(equalToConstant: 36).isActive = true
        button.heightAnchor.constraint(equalToConstant: 36).isActive = true
        return button
    }

    @objc private func autoScrollEnabledChanged() {
        isAutoScrollPaused = false
        applyAutoScrollState()
    }

    @objc private func autoScrollSpeedChanged() {
        updateAutoScrollControls()
        autoScrollLastTimestamp = 0
    }

    private func applyAutoScrollState() {
        autoScrollControlView.isHidden = !autoScrollEnabled
        updateAutoScrollControls()
        if autoScrollEnabled && !isAutoScrollPaused {
            startAutoScrollDisplayLink()
        } else {
            invalidateAutoScrollDisplayLink()
        }
    }

    private func startAutoScrollDisplayLink() {
        guard autoScrollDisplayLink == nil else { return }
        let proxy = TextAutoScrollDisplayLinkProxy(owner: self)
        let displayLink = CADisplayLink(target: proxy, selector: #selector(TextAutoScrollDisplayLinkProxy.step(_:)))
        displayLink.add(to: .main, forMode: .common)
        autoScrollDisplayLinkProxy = proxy
        autoScrollDisplayLink = displayLink
        autoScrollLastTimestamp = 0
    }

    private func invalidateAutoScrollDisplayLink() {
        autoScrollDisplayLink?.invalidate()
        autoScrollDisplayLink = nil
        autoScrollDisplayLinkProxy = nil
        autoScrollLastTimestamp = 0
    }

    fileprivate func handleAutoScrollFrame(_ displayLink: CADisplayLink) {
        guard autoScrollEnabled, !isAutoScrollPaused else {
            invalidateAutoScrollDisplayLink()
            return
        }
        guard !scrollView.isDragging, !scrollView.isDecelerating, !isSliding else {
            autoScrollLastTimestamp = displayLink.timestamp
            return
        }

        guard autoScrollLastTimestamp > 0 else {
            autoScrollLastTimestamp = displayLink.timestamp
            return
        }
        let elapsed = min(0.1, displayLink.timestamp - autoScrollLastTimestamp)
        autoScrollLastTimestamp = displayLink.timestamp

        checkInfiniteLoad()
        let maximumOffset = max(
            -scrollView.adjustedContentInset.top,
            scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom
        )
        let distance = autoScrollBasePointsPerSecond * CGFloat(autoScrollSpeed) * CGFloat(elapsed)
        let target = min(maximumOffset, scrollView.contentOffset.y + distance)
        scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: target), animated: false)

        if target >= maximumOffset - 0.5, nextChapter == nil, !loadingNext {
            setAutoScrollPaused(true)
        }
    }

    private func setAutoScrollPaused(_ paused: Bool) {
        guard autoScrollEnabled else { return }
        isAutoScrollPaused = paused
        if paused {
            invalidateAutoScrollDisplayLink()
        } else {
            startAutoScrollDisplayLink()
        }
        updateAutoScrollControls()
    }

    private func updateAutoScrollControls() {
        let iconName = isAutoScrollPaused ? "play.fill" : "pause.fill"
        autoScrollPlayPauseButton.setImage(UIImage(systemName: iconName), for: .normal)
        autoScrollPlayPauseButton.accessibilityLabel = isAutoScrollPaused
            ? NSLocalizedString("PLAY")
            : NSLocalizedString("PAUSE")
        autoScrollSpeedLabel.text = String(format: "%.2f×", autoScrollSpeed)
        autoScrollControlView.accessibilityLabel = isAutoScrollPaused
            ? textReaderLocalized("TEXT_AUTO_SCROLL_PAUSED", fallback: "Auto Reading Paused")
            : textReaderLocalized("TEXT_AUTO_SCROLL", fallback: "Auto Reading")
    }

    @objc private func toggleAutoScrollPause() {
        setAutoScrollPaused(!isAutoScrollPaused)
    }

    @objc private func decreaseAutoScrollSpeed() {
        changeAutoScrollSpeed(by: -0.25)
    }

    @objc private func increaseAutoScrollSpeed() {
        changeAutoScrollSpeed(by: 0.25)
    }

    private func changeAutoScrollSpeed(by amount: Double) {
        let newSpeed = min(4, max(0.5, (autoScrollSpeed + amount) * 4).rounded() / 4)
        UserDefaults.standard.set(newSpeed, forKey: "Reader.textAutoScrollSpeed")
        NotificationCenter.default.post(name: .init("Reader.textAutoScrollSpeed"), object: newSpeed)
    }

    @objc private func stopAutoScroll() {
        UserDefaults.standard.set(false, forKey: "Reader.textAutoScrollEnabled")
        NotificationCenter.default.post(name: .init("Reader.textAutoScrollEnabled"), object: false)
    }
}

// MARK: - Section Helpers & Chapter Loading
extension ReaderTextViewController {

    /// Recalculate estimated page count for the current chapter's section.
    private func updateEstimatedPageCount() {
        guard let sectionIndex = currentSectionIndex else { return }
        let section = sections[sectionIndex]
        let screenHeight = scrollView.frame.height
        guard screenHeight > 0 else { return }

        // Sum up the heights of hosting controllers in this section
        var sectionHeight: CGFloat = 0
        for hc in section.hostingControllers {
            sectionHeight += hc.view.frame.height
        }
        guard sectionHeight > 0 else { return }

        needsPageCountUpdate = false
        let newCount = max(1, Int(ceil(sectionHeight / screenHeight)))
        if newCount != estimatedPageCount, let firstPage = section.pages.first {
            estimatedPageCount = newCount
            let virtualPages = Array(repeating: firstPage, count: newCount)
            delegate?.setPages(virtualPages)
        }
    }

    // MARK: - Boundary Transition Views

    private func updateBoundaryTransitionViews() {
        let screenHeight = transitionPageHeight

        // Previous transition (top) — shows info about the chapter before sections[0]
        if let prevView = previousTransitionView, let firstSection = sections.first {
            let currentOld = firstSection.chapter.toOld(sourceId: sourceId, mangaId: mangaId)
            prevView.currentChapter = currentOld
            prevView.previousChapter = previousChapter?.toOld(sourceId: sourceId, mangaId: mangaId)
            prevView.isHidden = false
            showsPreviousTransition = true
            prevHeightConstraint?.constant = screenHeight
        }

        // Next transition (bottom) — shows info about the chapter after sections.last
        if let nextView = nextTransitionView, let lastSection = sections.last {
            let currentOld = lastSection.chapter.toOld(sourceId: sourceId, mangaId: mangaId)
            nextView.currentChapter = currentOld
            nextView.nextChapter = nextChapter?.toOld(sourceId: sourceId, mangaId: mangaId)
            nextView.isHidden = false
            showsNextTransition = true
            nextHeightConstraint?.constant = screenHeight
        }
    }

    @objc private func textStyleChanged() {
        scrollView.backgroundColor = TextReaderTheme.current.backgroundColor
        refreshTextViews()
    }

    // MARK: - Chapter Section Index from Scroll Position

    /// Index of the section whose content is currently at the center of the viewport.
    private var currentSectionIndex: Int? {
        guard !sections.isEmpty else { return nil }
        let viewportCenter = scrollView.contentOffset.y + scrollView.frame.height / 2
        let prevHeight = showsPreviousTransition ? transitionPageHeight : 0

        var offset = prevHeight
        for (index, section) in sections.enumerated() {
            var sectionHeight: CGFloat = 0
            for hc in section.hostingControllers {
                sectionHeight += hc.view.frame.height
            }
            let transitionHeight = section.transitionHeightConstraint?.constant ?? 0
            let totalSectionHeight = sectionHeight + transitionHeight

            if viewportCenter < offset + totalSectionHeight || index == sections.count - 1 {
                return index
            }
            offset += totalSectionHeight
        }
        return sections.count - 1
    }

    /// The Y offset where a given section's text content starts.
    private func sectionContentStartY(at sectionIndex: Int) -> CGFloat {
        let prevHeight = showsPreviousTransition ? transitionPageHeight : 0
        var offset = prevHeight
        for i in 0..<sectionIndex {
            let section = sections[i]
            for hc in section.hostingControllers {
                offset += hc.view.frame.height
            }
            offset += section.transitionHeightConstraint?.constant ?? 0
        }
        return offset
    }

    /// The total text content height for a section (excluding transitions).
    private func sectionContentHeight(at sectionIndex: Int) -> CGFloat {
        sections[sectionIndex].hostingControllers.reduce(0) { $0 + $1.view.frame.height }
    }

    // MARK: - Initial Chapter Load

    func loadInitialChapter(_ chapter: AidokuRunner.Chapter, restorePosition: Bool = true) async {
        isLoadingChapter = true
        hasReachedEnd = false
        self.chapter = chapter

        await viewModel.loadPages(chapter: chapter)
        delegate?.setPages(viewModel.pages)

        await MainActor.run {
            previousChapter = delegate?.getPreviousChapter()
            nextChapter = delegate?.getNextChapter()

            // Clear existing sections
            removeAllSections()

            // Build the initial section
            let pages = viewModel.pages
            var hostingControllers: [UIHostingController<ReaderTextView>] = []
            for page in pages {
                let hc = createHostingController(page: page)
                addChild(hc)
                hc.didMove(toParent: self)
                contentStackView.addArrangedSubview(hc.view)
                hc.view.translatesAutoresizingMaskIntoConstraints = false
                hostingControllers.append(hc)
            }

            sections.append(ChapterSection(
                chapter: chapter, pages: pages,
                hostingControllers: hostingControllers
            ))

            updateBoundaryTransitionViews()
            view.layoutIfNeeded()
            needsPageCountUpdate = true

            let prevHeight = showsPreviousTransition ? transitionPageHeight : 0
            let safeTop = scrollView.contentInset.top

            if restorePosition {
                pendingScrollRestore = true
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let savedProgress = await self.loadReadingProgress(for: chapter.key) {
                        self.updateEstimatedPageCount()
                        let sectionHeight = self.sectionContentHeight(at: 0)
                        let screenHeight = self.scrollView.frame.size.height
                        let insetTop = self.scrollView.contentInset.top
                        if sectionHeight > 0, screenHeight > 0 {
                            let scrollStart = prevHeight - insetTop
                            let scrollableRange = sectionHeight - screenHeight + insetTop
                            let targetOffset = scrollStart + scrollableRange * savedProgress
                            self.scrollView.setContentOffset(
                                CGPoint(x: 0, y: max(prevHeight - insetTop, targetOffset)),
                                animated: false
                            )
                            let currentPage = min(self.estimatedPageCount, Int(savedProgress * CGFloat(self.estimatedPageCount)) + 1)
                            self.lastReportedPage = currentPage
                            self.delegate?.setCurrentPage(currentPage, position: savedProgress)
                        }
                    }
                    self.pendingScrollRestore = false
                }
            } else {
                scrollView.setContentOffset(.init(x: 0, y: prevHeight - safeTop), animated: false)
            }

            isLoadingChapter = false
        }
    }

    /// Remove all sections and their views from the stack.
    private func removeAllSections() {
        for section in sections {
            for hc in section.hostingControllers {
                hc.view.removeFromSuperview()
                hc.removeFromParent()
            }
            section.transitionView?.removeFromSuperview()
        }
        sections.removeAll()
    }

    // MARK: - Infinite Scroll: Append Next Chapter

    private func appendNextChapter() {
        guard let nextCh = nextChapter, !loadingNext else { return }
        loadingNext = true

        Task {
            // Preload the next chapter's pages
            await viewModel.preload(chapter: nextCh)
            let newPages = viewModel.preloadedPages
            guard !newPages.isEmpty else {
                loadingNext = false
                return
            }

            // Non-text chapter: hand off to the parent controller, which
            // switches to the appropriate reader and reloads the chapter.
            guard newPages.allSatisfy({ $0.isTextPage }) else {
                await MainActor.run {
                    delegate?.setChapter(nextCh)
                    delegate?.setPages(newPages)
                }
                loadingNext = false
                return
            }

            await MainActor.run {
                // Add an inline transition view after the last section
                guard let lastSection = sections.last else {
                    loadingNext = false
                    return
                }
                let screenHeight = transitionPageHeight
                let tv = createInlineTransitionView(
                    finishedChapter: lastSection.chapter,
                    nextChapter: nextCh
                )
                contentStackView.addArrangedSubview(tv)
                let tvHeight = tv.heightAnchor.constraint(equalToConstant: screenHeight)
                tvHeight.isActive = true
                sections[sections.count - 1].transitionView = tv
                sections[sections.count - 1].transitionHeightConstraint = tvHeight

                // Create hosting controllers for the new chapter
                var newHCs: [UIHostingController<ReaderTextView>] = []
                for page in newPages {
                    let hc = createHostingController(page: page)
                    addChild(hc)
                    hc.didMove(toParent: self)
                    contentStackView.addArrangedSubview(hc.view)
                    hc.view.translatesAutoresizingMaskIntoConstraints = false
                    newHCs.append(hc)
                }

                sections.append(ChapterSection(
                    chapter: nextCh, pages: newPages,
                    hostingControllers: newHCs
                ))

                // Update chapter navigation pointers
                // Tell the delegate about the new chapter so it can update its internal state
                delegate?.setChapter(nextCh)
                nextChapter = delegate?.getNextChapter()
                // Switch back to the original current chapter in the delegate
                if let currentCh = chapter {
                    delegate?.setChapter(currentCh)
                }

                // Update the bottom boundary transition view
                updateBoundaryTransitionViews()
                view.layoutIfNeeded()

                loadingNext = false
            }
        }
    }

    // MARK: - Infinite Scroll: Prepend Previous Chapter

    private func prependPreviousChapter() {
        guard let prevCh = previousChapter, !loadingPrevious else { return }
        loadingPrevious = true

        Task {
            await viewModel.preload(chapter: prevCh)
            let newPages = viewModel.preloadedPages
            guard !newPages.isEmpty else {
                loadingPrevious = false
                return
            }

            // Non-text chapter: hand off to the parent controller, which
            // switches to the appropriate reader and reloads the chapter.
            guard newPages.allSatisfy({ $0.isTextPage }) else {
                await MainActor.run {
                    delegate?.setChapter(prevCh)
                    delegate?.setPages(newPages)
                }
                loadingPrevious = false
                return
            }

            await MainActor.run {
                let screenHeight = transitionPageHeight
                let oldContentHeight = scrollView.contentSize.height
                let oldOffset = scrollView.contentOffset.y

                // Create hosting controllers for the new chapter
                var newHCs: [UIHostingController<ReaderTextView>] = []
                for page in newPages {
                    let hc = createHostingController(page: page)
                    addChild(hc)
                    hc.didMove(toParent: self)
                    hc.view.translatesAutoresizingMaskIntoConstraints = false
                    newHCs.append(hc)
                }

                // Create an inline transition view after the prepended section
                let tv = createInlineTransitionView(
                    finishedChapter: prevCh,
                    nextChapter: sections.first?.chapter
                )
                let tvHeight = tv.heightAnchor.constraint(equalToConstant: screenHeight)
                tvHeight.isActive = true

                // Insert hosting controller views at the beginning of the stack view
                // (in reverse order so they end up in the correct order)
                for hc in newHCs.reversed() {
                    contentStackView.insertArrangedSubview(hc.view, at: 0)
                }
                // Insert transition view after the new chapter's hosting controllers
                contentStackView.insertArrangedSubview(tv, at: newHCs.count)

                let newSection = ChapterSection(
                    chapter: prevCh, pages: newPages,
                    hostingControllers: newHCs,
                    transitionView: tv,
                    transitionHeightConstraint: tvHeight
                )
                sections.insert(newSection, at: 0)

                // Update chapter navigation pointers
                delegate?.setChapter(prevCh)
                previousChapter = delegate?.getPreviousChapter()
                if let currentCh = chapter {
                    delegate?.setChapter(currentCh)
                }

                updateBoundaryTransitionViews()
                view.layoutIfNeeded()

                // Preserve scroll position: offset by the height of newly inserted content
                let newContentHeight = scrollView.contentSize.height
                let heightDelta = newContentHeight - oldContentHeight
                scrollView.contentOffset.y = oldOffset + heightDelta

                loadingPrevious = false
            }
        }
    }

    // MARK: - Chapter Switch Detection

    /// Update the "current chapter" when the user scrolls into a different section.
    private func updateCurrentChapterFromScroll() {
        guard let index = currentSectionIndex else { return }
        let sectionChapter = sections[index].chapter
        guard sectionChapter != chapter else { return }

        chapter = sectionChapter
        delegate?.setChapter(sectionChapter)

        // Refresh navigation pointers
        previousChapter = delegate?.getPreviousChapter()
        nextChapter = delegate?.getNextChapter()

        hasReachedEnd = false
        lastReportedPage = 0

        // Recalculate virtual pages for the new section and report to toolbar.
        // Use a deferred update so hosting controller frames are finalized first.
        needsPageCountUpdate = true
        view.setNeedsLayout()
    }
}

// MARK: - Reader Delegate
extension ReaderTextViewController: ReaderReaderDelegate {
    func moveLeft() {
        setAutoScrollPaused(true)
        let animated = UserDefaults.standard.bool(forKey: "Reader.animatePageTransitions")
        let prevHeight = showsPreviousTransition ? transitionPageHeight : 0

        // Already scrolled into the previous transition area
        if scrollView.contentOffset.y <= prevHeight {
            if scrollView.contentOffset.y <= 0 {
                // Fully at top — trigger chapter load on second press
                checkInfiniteLoad()
            } else {
                // Scroll to show the full transition view
                scrollView.setContentOffset(.init(x: 0, y: 0), animated: animated)
            }
            return
        }

        let target = max(0, scrollView.contentOffset.y - scrollView.bounds.height * 2 / 3)
        scrollView.setContentOffset(.init(x: 0, y: target), animated: animated)
    }

    func moveRight() {
        setAutoScrollPaused(true)
        let animated = UserDefaults.standard.bool(forKey: "Reader.animatePageTransitions")
        let maxOffset = scrollView.contentSize.height - scrollView.bounds.height

        // Check if we're already in the next transition area
        if showsNextTransition {
            // Calculate where the last section's content ends
            let lastSectionEnd: CGFloat
            if let lastIndex = sections.indices.last {
                lastSectionEnd = sectionContentStartY(at: lastIndex) + sectionContentHeight(at: lastIndex)
            } else {
                lastSectionEnd = 0
            }
            let transitionStart = lastSectionEnd
            if scrollView.contentOffset.y + scrollView.bounds.height >= transitionStart {
                // Already seeing the transition — trigger chapter load
                checkInfiniteLoad()
                return
            }
        }

        let target = min(maxOffset, scrollView.contentOffset.y + scrollView.bounds.height * 2 / 3)
        scrollView.setContentOffset(.init(x: 0, y: target), animated: animated)
    }

    func sliderMoved(value: CGFloat) {
        setAutoScrollPaused(true)
        isSliding = true

        // Slider operates on the current chapter's section only
        guard let index = currentSectionIndex else { return }
        let startY = sectionContentStartY(at: index)
        let height = sectionContentHeight(at: index)
        let screenHeight = scrollView.frame.size.height
        guard height > screenHeight else { return }

        let offset = startY + (height - screenHeight) * value
        scrollView.setContentOffset(CGPoint(x: 0, y: offset), animated: false)

        let page = max(1, min(Int(value * CGFloat(estimatedPageCount - 1)) + 1, estimatedPageCount))
        delegate?.displayPage(page)
    }

    func sliderStopped(value: CGFloat) {
        isSliding = false

        guard let index = currentSectionIndex else { return }
        let startY = sectionContentStartY(at: index)
        let height = sectionContentHeight(at: index)
        let screenHeight = scrollView.frame.size.height
        guard height > screenHeight else { return }

        let offsetInSection = scrollView.contentOffset.y - startY
        let progress = min(1, max(0, offsetInSection / (height - screenHeight)))
        let page = min(estimatedPageCount, Int(progress * CGFloat(estimatedPageCount)) + 1)
        delegate?.setCurrentPage(page, position: nil)
    }

    func setChapter(_ chapter: AidokuRunner.Chapter, startPage: Int) {
        guard chapter != viewModel.chapter else { return }

        Task {
            await loadInitialChapter(chapter, restorePosition: startPage > 0)
        }
    }
}

// MARK: - Scroll View Delegate
extension ReaderTextViewController: UIScrollViewDelegate {
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        setAutoScrollPaused(true)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !isSliding, !pendingScrollRestore, !isReportingProgress else { return }

        // Detect if current chapter changed due to scrolling
        updateCurrentChapterFromScroll()

        guard let index = currentSectionIndex else { return }
        let startY = sectionContentStartY(at: index)
        let height = sectionContentHeight(at: index)
        let screenHeight = scrollView.frame.size.height
        guard height > 0, screenHeight > 0 else { return }

        let offsetInSection = scrollView.contentOffset.y - startY
        let scrollableHeight = max(1, height - screenHeight)
        let progress = min(1, max(0, offsetInSection / scrollableHeight))

        let currentPage = min(estimatedPageCount, Int(progress * CGFloat(estimatedPageCount)) + 1)

        // Mark as completed when reaching the end of a section
        let sectionEndY = startY + height
        if scrollView.contentOffset.y + screenHeight >= sectionEndY - 50 && !hasReachedEnd {
            hasReachedEnd = true
            delegate?.setCurrentPage(currentPage, position: Double(progress))
            delegate?.setCompleted()
        } else {
            delegate?.setCurrentPage(currentPage, position: Double(progress))
        }
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if UserDefaults.standard.bool(forKey: "Reader.hideBarsOnSwipe") {
            delegate?.hideBars()
        }

        if !decelerate {
            checkInfiniteLoad()
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        checkInfiniteLoad()
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        checkInfiniteLoad()
    }

    /// Trigger infinite loading of previous/next chapters when the user
    /// scrolls near the boundary transition views.
    private func checkInfiniteLoad() {
        let offset = scrollView.contentOffset.y
        let prevHeight = showsPreviousTransition ? transitionPageHeight : 0

        // Near the top boundary → prepend previous chapter
        if !loadingPrevious && prevHeight > 0 && offset < prevHeight / 2 && previousChapter != nil {
            prependPreviousChapter()
        }

        // Near the bottom boundary → append next chapter
        if !loadingNext && nextChapter != nil {
            let nextHeight = showsNextTransition ? transitionPageHeight : 0
            let maxOffset = scrollView.contentSize.height - scrollView.frame.size.height
            if nextHeight > 0 && offset > maxOffset - nextHeight / 2 {
                appendNextChapter()
            }
        }
    }
}
