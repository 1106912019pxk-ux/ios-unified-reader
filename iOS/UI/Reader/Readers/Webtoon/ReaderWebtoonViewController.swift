//
//  ReaderWebtoonViewController.swift
//  Aidoku (iOS)
//
//  Created by Skitty on 9/27/22.
//

import AidokuRunner
import AsyncDisplayKit
import Nuke
import UIKit

private final class WebtoonAutoScrollDisplayLinkProxy {
    weak var owner: ReaderWebtoonViewController?

    init(owner: ReaderWebtoonViewController) {
        self.owner = owner
    }

    @objc func step(_ displayLink: CADisplayLink) {
        owner?.handleAutoScrollFrame(displayLink)
    }
}

class ReaderWebtoonViewController: ZoomableCollectionViewController {

    let viewModel: ReaderWebtoonViewModel
    weak var delegate: ReaderHoldingDelegate?

    var chapter: AidokuRunner.Chapter?
    var readingMode: ReadingMode = .webtoon {
        didSet {
            let layout = collectionNode.collectionViewLayout as? VerticalContentOffsetPreservingLayout
            layout?.spacing = readingMode == .webtoon ? 0 : 15
            collectionNode.invalidateCalculatedLayout()
        }
    }

//    private let prefetcher = ImagePrefetcher()

    // Indicates if infinite scroll is enabled
    private lazy var infinite = UserDefaults.standard.bool(forKey: "Reader.verticalInfiniteScroll")
    private var loadingPrevious = false
    private var loadingNext = false

    // The chapters currently shown in the reader view
    private var chapters: [AidokuRunner.Chapter] = []
    // The pages corresponding to the `chapters` variable
    private var pages: [[Page]] = []
    private var dictionaryOverlayTapHandler: ((String, String, CGRect, [CGRect]) -> Void)?
    private var dictionaryOverlayInteractionMode: DictionaryOverlayInteractionMode = .none

    // Indicates if the page slider is currently in use
    private var isSliding = false
    // Indicates if a zoom gesture is in progress
    var isZooming = false
    // Indicates if a scroll is in progress
    private var isScrolling = false
    // Indicates if an info refresh should be done if info pages are off screen
    private var needsInfoRefresh = false

    // Stores the last calculated page number
    private var previousPage = 0

    // MARK: - Auto Reading

    private let autoScrollBasePointsPerSecond: CGFloat = 28
    private var autoScrollDisplayLink: CADisplayLink?
    private var autoScrollDisplayLinkProxy: WebtoonAutoScrollDisplayLinkProxy?
    private var autoScrollLastTimestamp: CFTimeInterval = 0
    private var isAutoScrollPaused = false
    private var isAutoScrollAdvancing = false

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
        label.widthAnchor.constraint(equalToConstant: 54).isActive = true
        return label
    }()

    init(source: AidokuRunner.Source?, manga: AidokuRunner.Manga) {
        self.viewModel = ReaderWebtoonViewModel(source: source, manga: manga)
        super.init(layout: VerticalContentOffsetPreservingLayout())
    }

    deinit {
        autoScrollDisplayLink?.invalidate()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.addSubview(autoScrollControlView)
        autoScrollControlView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            autoScrollControlView.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
            autoScrollControlView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
            autoScrollControlView.heightAnchor.constraint(equalToConstant: 44)
        ])
        applyAutoScrollState()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        applyAutoScrollState()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        invalidateAutoScrollDisplayLink()
    }

    override func configure() {
        super.configure()

        collectionNode.delegate = self
        collectionNode.dataSource = self
//        collectionNode.view.prefetchDataSource = self
//        collectionNode.isPrefetchingEnabled = true

        // override texture's automatic decreased preloading range
        collectionNode.setTuningParameters(collectionNode.tuningParameters(for: .display), for: .minimum, rangeType: .display)
        collectionNode.setTuningParameters(collectionNode.tuningParameters(for: .preload), for: .minimum, rangeType: .preload)
        collectionNode.setTuningParameters(collectionNode.tuningParameters(for: .display), for: .lowMemory, rangeType: .display)
        collectionNode.setTuningParameters(collectionNode.tuningParameters(for: .preload), for: .lowMemory, rangeType: .preload)

        scrollView.contentInset = .zero
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.bounces = false // bouncing can cause issues with page appending
        scrollView.scrollsToTop = false // dont want status bar tap to work
        scrollNode.insetsLayoutMarginsFromSafeArea = false

        if #available(iOS 27.0, *) {
            scrollView.topEdgeEffect.style = .soft
            scrollView.bottomEdgeEffect.style = .soft
            collectionNode.view.topEdgeEffect.isHidden = true
            collectionNode.view.bottomEdgeEffect.isHidden = true
        }

        collectionNode.contentInset = .zero
        collectionNode.showsVerticalScrollIndicator = false
        collectionNode.showsHorizontalScrollIndicator = false
        collectionNode.view.contentInsetAdjustmentBehavior = .never
        collectionNode.view.bounces = false
        collectionNode.view.scrollsToTop = false

        collectionNode.automaticallyManagesSubnodes = true
        collectionNode.shouldAnimateSizeChanges = false
        collectionNode.insetsLayoutMarginsFromSafeArea = false

        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 5
        updateDoubleTapZoomSetting()

        zoomView.onZoomScaleChanged = { [weak self] scale in
            self?.setLiveTextButtonHidden(scale != 1)
            if scale != 1 {
                self?.setAutoScrollPaused(true)
            }
        }
    }

    override func observe() {
        addObserver(forName: "Reader.verticalInfiniteScroll") { [weak self] notification in
            self?.infinite = notification.object as? Bool ?? UserDefaults.standard.bool(forKey: "Reader.verticalInfiniteScroll")
        }
        for key in [
            "Reader.disableDoubleTap",
            AppSettings.dictionary.enable.key,
            AppSettings.dictionary.lookupGesture.key,
            AppSettings.dictionary.restrictOCRLanguages.key,
            AppSettings.dictionary.restrictedOCRLanguages.key
        ] {
            addObserver(forName: key) { [weak self] _ in
                self?.updateDoubleTapZoomSetting()
            }
        }
        addObserver(forName: .readerShowingBars) { [weak self] _ in
            self?.setLiveTextButtonHidden(false)
        }
        addObserver(forName: .readerHidingBars) { [weak self] _ in
            self?.setLiveTextButtonHidden(true)
        }
        addObserver(forName: "Reader.webtoonAutoScrollEnabled") { [weak self] _ in
            self?.isAutoScrollPaused = false
            self?.applyAutoScrollState()
        }
        addObserver(forName: "Reader.webtoonAutoScrollSpeed") { [weak self] _ in
            self?.autoScrollLastTimestamp = 0
            self?.updateAutoScrollControls()
        }

        addObserver(forName: UIApplication.didReceiveMemoryWarningNotification.rawValue) { [weak self] _ in
            // clear live text analysis
            LogManager.logger.warn("Received memory warning")

            if #available(iOS 16.0, *) {
                self?.collectionNode.visibleNodes.forEach { node in
                    guard let node = node as? ReaderWebtoonPageNode else { return }
                    node.imageNode.imageAnalaysisInteraction = nil
                }
            }
        }
    }

    enum ScreenPosition {
        case top
        case middle
        case bottom
    }

    /// Get the current row of the page view at `pos`
    func getCurrentPagePath(pos: ScreenPosition = .middle) -> IndexPath? {
        let additional: CGFloat
        switch pos {
            case .top: additional = 0
            case .middle: additional = collectionNode.bounds.height / 2
            case .bottom: additional = collectionNode.bounds.height
        }
        let currentPoint = CGPoint(x: collectionNode.contentOffset.x, y: collectionNode.contentOffset.y + additional)
        return collectionNode.indexPathForItem(at: currentPoint)
    }

    func getCurrentPage() -> Int {
        guard
            let chapter = chapter,
            let chapterIndex = chapters.firstIndex(of: chapter),
            let currentPages = pages[safe: chapterIndex]
        else { return 0 }
        let pageRow = getCurrentPagePath()?.row ?? 0
        let hasStartInfo = currentPages.first?.type != .imagePage
        return min(
            max(pageRow + (hasStartInfo ? 0 : 1), 0),
            currentPages.count - (hasStartInfo ? 1 : 0)
        )
    }

    private func setLiveTextButtonHidden(_ hidden: Bool) {
        collectionNode.visibleNodes.forEach {
            guard let pageNode = $0 as? ReaderWebtoonPageNode else { return }
            if hidden || delegate?.barsHidden == true {
                pageNode.setLiveTextHidden(true)
            } else {
                let scale = zoomView.scrollNode.view.zoomScale
                pageNode.setLiveTextHidden(scale != 1)
            }
        }
    }

    private func updateDoubleTapZoomSetting() {
        let language = chapter?.language ?? viewModel.source?.languages.first
        zoomView.doubleTapEnabled = !AppSettings.dictionary.isReaderDoubleTapDisabled(language: language)
    }
}

// MARK: - Scroll View Delegate
extension ReaderWebtoonViewController {
    override func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        super.scrollViewWillBeginDragging(scrollView)
        setAutoScrollPaused(true)
        setLiveTextButtonHidden(true)
    }

    // Update current page when scrolling
    override func scrollViewDidScroll(_ scrollView: UIScrollView) {
        super.scrollViewDidScroll(scrollView)

        if !isAutoScrollAdvancing {
            isScrolling = true
        }

        // ignore if page slider is being used
        guard !isSliding && !isZooming else { return }

        guard
            let chapter = chapter,
            let chapterIndex = chapters.firstIndex(of: chapter)
        else { return }

        let pagePath = getCurrentPagePath()
        let pageSection = pagePath?.section ?? 0

        if infinite {
            // check if we need to switch chapters
            if chapterIndex > 0 && pageSection < chapterIndex {
                movePreviousChapter()
                needsInfoRefresh = true
            } else if chapterIndex < chapters.count - 1 {
                if pageSection > chapterIndex {
                    moveNextChapter()
                    needsInfoRefresh = true
                }
            }
        }

        // update page number
        let page = getCurrentPage()
        if previousPage != page {
            previousPage = page
            delegate?.setCurrentPage(page, position: nil)
        }
    }

    // disable slider movement while zooming
    // zooming sometimes causes page count to jitter between two pages
    func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
        isZooming = true
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        isZooming = false
        scrollViewDidScroll(scrollView)
    }

    // fix content size when rotating
    // TODO: fix scroll offset when rotating
    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate { _ in
            self.zoomView.adjustContentSize()
        }
    }
}

// MARK: - Auto Reading
extension ReaderWebtoonViewController {
    private var autoScrollEnabled: Bool {
        UserDefaults.standard.bool(forKey: "Reader.webtoonAutoScrollEnabled")
    }

    private var autoScrollSpeed: Double {
        let value = UserDefaults.standard.object(forKey: "Reader.webtoonAutoScrollSpeed") as? Double ?? 1
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
        let proxy = WebtoonAutoScrollDisplayLinkProxy(owner: self)
        let displayLink = CADisplayLink(target: proxy, selector: #selector(WebtoonAutoScrollDisplayLinkProxy.step(_:)))
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
        guard
            !scrollView.isDragging,
            !scrollView.isDecelerating,
            !isSliding,
            !isZooming,
            scrollView.zoomScale == 1
        else {
            autoScrollLastTimestamp = displayLink.timestamp
            return
        }

        guard autoScrollLastTimestamp > 0 else {
            autoScrollLastTimestamp = displayLink.timestamp
            return
        }
        let elapsed = min(0.1, displayLink.timestamp - autoScrollLastTimestamp)
        autoScrollLastTimestamp = displayLink.timestamp

        guard !pages.isEmpty, scrollView.contentSize.height > 0 else { return }
        let maximumOffset = max(0, scrollView.contentSize.height - scrollView.bounds.height)
        let distance = autoScrollBasePointsPerSecond * CGFloat(autoScrollSpeed) * CGFloat(elapsed)
        let target = min(maximumOffset, scrollView.contentOffset.y + distance)
        isScrolling = false
        isAutoScrollAdvancing = true
        scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: target), animated: false)
        isAutoScrollAdvancing = false

        if infinite {
            checkAutoScrollNextChapter()
        }

        let canContinue = infinite && delegate?.getNextChapter() != nil
        if target >= maximumOffset - 0.5, !loadingNext, !canContinue {
            setAutoScrollPaused(true)
        }
    }

    private func checkAutoScrollNextChapter() {
        guard !loadingNext, !pages.isEmpty else { return }
        let bottomPath = getCurrentPagePath(pos: .bottom)
        let isAtBottom = bottomPath == nil
            || (bottomPath?.section == pages.count - 1
                && bottomPath?.item == pages[pages.count - 1].count - 1)
        guard isAtBottom else { return }

        let previousSectionCount = pages.count
        loadingNext = true
        delegate?.setCompleted()
        Task {
            await appendNextChapter()
            loadingNext = false
            if pages.count == previousSectionCount {
                setAutoScrollPaused(true)
            }
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
            ? textReaderLocalized("WEBTOON_AUTO_SCROLL_PAUSED", fallback: "Webtoon Auto Reading Paused")
            : textReaderLocalized("WEBTOON_AUTO_SCROLL", fallback: "Webtoon Auto Reading")
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
        UserDefaults.standard.set(newSpeed, forKey: "Reader.webtoonAutoScrollSpeed")
        NotificationCenter.default.post(name: .init("Reader.webtoonAutoScrollSpeed"), object: newSpeed)
    }

    @objc private func stopAutoScroll() {
        UserDefaults.standard.set(false, forKey: "Reader.webtoonAutoScrollEnabled")
        NotificationCenter.default.post(name: .init("Reader.webtoonAutoScrollEnabled"), object: false)
    }
}

// MARK: - Context Menu
extension ReaderWebtoonViewController: UIContextMenuInteractionDelegate {
    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard
            case let point = interaction.location(in: collectionNode.view),
            let indexPath = collectionNode.indexPathForItem(at: point),
            let node = collectionNode.nodeForItem(at: indexPath) as? ReaderWebtoonPageNode,
            let image = node.imageNode.image,
            !AppSettings.dictionary.isReaderQuickActionsDisabled(language: node.page.language)
        else {
            return nil
        }
        // disable when live text highlighting is active
        if
            #available(iOS 16.0, *),
            let imageAnalaysisInteraction = node.imageNode.imageAnalaysisInteraction,
            imageAnalaysisInteraction.selectableItemsHighlighted
        {
            return nil
        }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil, actionProvider: { [weak self] _ in
            guard let self else { return nil }

            let shareAction = UIAction(
                title: NSLocalizedString("SHARE"),
                image: UIImage(systemName: "square.and.arrow.up")
            ) { _ in
                let items = [image]
                let activityController = UIActivityViewController(activityItems: items, applicationActivities: nil)

                activityController.popoverPresentationController?.sourceView = self.view
                activityController.popoverPresentationController?.sourceRect = CGRect(origin: location, size: .zero)

                self.present(activityController, animated: true)
            }

            let saveToPhotosAction = UIAction(
                title: NSLocalizedString("SAVE_TO_PHOTOS"),
                image: UIImage(systemName: "square.and.arrow.down")
            ) { _ in
                image.saveToAlbum(viewController: self)
            }

            let reloadAction = UIAction(
                title: NSLocalizedString("RELOAD"),
                image: UIImage(systemName: "arrow.clockwise")
            ) { _ in
                Task { @MainActor in
                    await self.reloadPageImage(for: node)
                }
            }

            return UIMenu(title: "", children: [shareAction, saveToPhotosAction, reloadAction])
        })
    }

    /// Reloads the page image for the given webtoon page node
    @MainActor
    private func reloadPageImage(for node: ReaderWebtoonPageNode) async {
        let success = await node.reloadCurrentImage()
        if !success {
            // Show error feedback if reload failed
            showReloadError()
        }
    }

    /// Shows an error message when image reload fails
    private func showReloadError() {
        let alert = UIAlertController(
            title: NSLocalizedString("RELOAD_FAILED"),
            message: NSLocalizedString("RELOAD_FAILED_TEXT"),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: NSLocalizedString("OK"), style: .default))
        present(alert, animated: true)
    }
}

// MARK: - Dictionary Lookup
@available(iOS 18.0, *)
extension ReaderWebtoonViewController: ReaderDictionaryReader {
    func recognizedText(at point: CGPoint) -> TextRecognizer.Result? {
        let collectionPoint = view.convert(point, to: collectionNode.view)
        guard
            let indexPath = collectionNode.indexPathForItem(at: collectionPoint),
            let node = collectionNode.nodeForItem(at: indexPath) as? ReaderWebtoonPageNode,
            let image = node.image,
            let recognizer = node.textRecognizer,
            let imageView = node.imageNode.imageView
        else {
            return nil
        }

        let localPoint = collectionNode.view.convert(collectionPoint, to: imageView)
        guard imageView.bounds.contains(localPoint) else { return nil }

        if var result = recognizer.findText(at: localPoint, in: imageView, imageSize: image.size) {
            result.charRect = imageView.convert(result.charRect, to: view)
            result.charRects = result.charRects.map { imageView.convert($0, to: view) }
            return result
        }
        return nil
    }

    func setDictionaryOverlayTapHandler(_ handler: ((String, String, CGRect, [CGRect]) -> Void)?) {
        dictionaryOverlayTapHandler = handler
    }

    func setDictionaryOverlayInteractionMode(_ mode: DictionaryOverlayInteractionMode) {
        dictionaryOverlayInteractionMode = mode
        for case let cell as ReaderWebtoonPageNode in collectionNode.visibleNodes {
            cell.setDictionaryOverlayInteractionMode(mode)
        }
    }

    func dismissActiveDictionaryOverlay() -> Bool {
        for case let node as ReaderWebtoonPageNode in collectionNode.visibleNodes where node.dismissActiveDictionaryOverlay() {
            return true
        }
        return false
    }

    private func forwardDictionaryOverlayTap(
        text: String,
        contextText: String,
        rect: CGRect,
        charRects: [CGRect],
        from imageView: UIImageView
    ) {
        let rectInView = imageView.convert(rect, to: view)
        let rectsInView = charRects.map { imageView.convert($0, to: view) }
        dictionaryOverlayTapHandler?(text, contextText, rectInView, rectsInView)
    }

    private func bindDictionaryOverlayTap(to cell: ReaderWebtoonPageNode) {
        cell.setDictionaryOverlayInteractionMode(dictionaryOverlayInteractionMode)
        cell.onDictionaryOverlayTap = { [weak self, weak cell] text, contextText, rect, charRects in
            guard let self, let imageView = cell?.imageNode.imageView else { return }
            self.forwardDictionaryOverlayTap(text: text, contextText: contextText, rect: rect, charRects: charRects, from: imageView)
        }
    }
}

// MARK: - Infinite Scroll
extension ReaderWebtoonViewController {

    // check for infinite load when deceleration stops
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if UserDefaults.standard.bool(forKey: "Reader.hideBarsOnSwipe") {
            delegate?.hideBars()
        }

        guard !decelerate else {
            return
        }
        setLiveTextButtonHidden(false)

        if infinite {
            isScrolling = false
            checkInfiniteLoad()
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        setLiveTextButtonHidden(false)
        if infinite {
            isScrolling = false
            checkInfiniteLoad()
        }
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        setLiveTextButtonHidden(false)
        if infinite {
            isScrolling = false
            checkInfiniteLoad()
        }
    }

    // check if at the top or bottom to append the next/prev chapter
    func checkInfiniteLoad() {
        // prepend previous chapter
        if !loadingPrevious {
            let topPath = getCurrentPagePath(pos: .top)
            if topPath == nil || (topPath?.section == 0 && topPath?.row == 0) {
                loadingPrevious = true
                Task {
                    await prependPreviousChapter()
                    loadingPrevious = false
                }
            }
        }
        if !loadingNext {
            let bottomPath = getCurrentPagePath(pos: .bottom)
            // append next chapter
            if bottomPath == nil || (bottomPath?.section == pages.count - 1 && bottomPath?.item == pages[pages.count - 1].count - 1) {
                loadingNext = true
                delegate?.setCompleted()
                Task {
                    await appendNextChapter()
                    loadingNext = false
                }
            }
        }
    }

    /// Prepend the previous chapter's pages
    func prependPreviousChapter() async {
        guard let prevChapter = delegate?.getPreviousChapter() else { return }
        await viewModel.preload(chapter: prevChapter)

        // check if pages failed to load
        if viewModel.preloadedPages.isEmpty {
            return
        }

        // wait until zooming and scrolling stops
        while isZooming || isScrolling {
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        // queue remove last section if we have three already
//        let removeLast = chapters.count >= 3

        chapters.insert(prevChapter, at: 0)
        pages.insert(
            [Page(
                type: .prevInfoPage,
                sourceId: viewModel.source?.key ?? viewModel.manga.sourceKey,
                chapterId: prevChapter.key,
                index: -1
            )]  + viewModel.preloadedPages,
            at: 0
        )

        let layout = collectionNode.collectionViewLayout as? VerticalContentOffsetPreservingLayout
        layout?.isInsertingCellsAbove = true

        // disable animations and adjust offset before re-enabling
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setAnimationDuration(0)
        await collectionNode.performBatch(animated: false) {
            collectionNode.insertSections(IndexSet(integer: 0))
        }
//        if removeLast {
//            chapters.removeLast()
//            pages.removeLast()
//
//            // remove last section
//            await collectionNode.performBatchUpdates {
//                self.collectionNode.deleteSections(IndexSet(integer: self.pages.count - 1))
//            }
//        }
        self.scrollView.contentOffset = self.collectionNode.contentOffset
        self.zoomView.adjustContentSize()
        CATransaction.commit()
    }

    /// Append the next chapter's pages
    func appendNextChapter() async {
        guard let nextChapter = delegate?.getNextChapter() else { return }
        await viewModel.preload(chapter: nextChapter)

        // check if pages failed to load
        if viewModel.preloadedPages.isEmpty {
            return
        }

        // wait until zooming and scrolling stops
        while isZooming || isScrolling {
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        // queue remove first section if we have three already
//        let removeFirst = chapters.count >= 3

        chapters.append(nextChapter)
        pages.append(viewModel.preloadedPages + [Page(
            type: .nextInfoPage,
            sourceId: viewModel.source?.key ?? viewModel.manga.sourceKey,
            chapterId: nextChapter.id,
            index: -2
        )])

        // disable animations and adjust offset before re-enabling
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setAnimationDuration(0)
        await collectionNode.performBatch(animated: false) {
            collectionNode.insertSections(IndexSet(integer: pages.count - 1))
        }
//        if removeFirst {
//            chapters.removeFirst()
//            pages.removeFirst()
//            await collectionNode.performBatchUpdates {
//                collectionNode.deleteSections(IndexSet(integer: 0))
//            }
//        }
        scrollView.contentOffset = self.collectionNode.contentOffset
        zoomView.adjustContentSize()
        CATransaction.commit()
    }

    /// Switch current chapter to previous
    func movePreviousChapter() {
        guard
            let currChapter = chapter,
            let chapterIndex = chapters.firstIndex(of: currChapter),
            let chapter = chapters[safe: chapterIndex - 1],
            let pages = pages[safe: chapterIndex - 1]
        else { return }
        self.chapter = chapter
        updateDoubleTapZoomSetting()
        delegate?.setChapter(chapter)
        delegate?.setPages(pages.filter({ $0.type == .imagePage }))
        viewModel.setPages(chapter: chapter, pages: pages)
    }

    /// Switch current chapter to next
    func moveNextChapter() {
        guard
            let currChapter = chapter,
            let chapterIndex = chapters.firstIndex(of: currChapter),
            let chapter = chapters[safe: chapterIndex + 1],
            let pages = pages[safe: chapterIndex + 1]
        else { return }
        self.chapter = chapter
        updateDoubleTapZoomSetting()
        delegate?.setChapter(chapter)
        delegate?.setPages(pages.filter({ $0.type == .imagePage }))
        viewModel.setPages(chapter: chapter, pages: pages)
    }

    /// Refresh info page chapter info
    func refreshInfoPages() {
        let paths = pages.enumerated().flatMap { section, pages in
            pages.enumerated().compactMap { item, page in
                if page.type != .imagePage {
                    return IndexPath(item: item, section: section)
                } else {
                    return nil
                }
            }
        }
        collectionNode.performBatchUpdates {
            collectionNode.reloadItems(at: paths)
        } completion: { finished in
            if finished {
                Task { @MainActor in
                    self.zoomView.adjustContentSize()
                }
            }
        }
    }
}

// MARK: - Reader Delegate
extension ReaderWebtoonViewController: ReaderReaderDelegate {
    func moveLeft() {
        setAutoScrollPaused(true)
        let offset = CGPoint(
            x: collectionNode.contentOffset.x,
            y: max(
                0,
                collectionNode.contentOffset.y - collectionNode.bounds.height * 2/3
            )
        )
        scrollView.setContentOffset(
            offset,
            animated: UserDefaults.standard.bool(forKey: "Reader.animatePageTransitions")
        )
    }

    func moveRight() {
        setAutoScrollPaused(true)
        let offset = CGPoint(
            x: collectionNode.contentOffset.x,
            y: min(
                scrollView.contentSize.height - scrollView.bounds.height,
                collectionNode.contentOffset.y + collectionNode.bounds.height * 2/3
            )
        )
        scrollView.setContentOffset(
            offset,
            animated: UserDefaults.standard.bool(forKey: "Reader.animatePageTransitions")
        )
    }

    func sliderMoved(value: CGFloat) {
        setAutoScrollPaused(true)
        isSliding = true

        // get slider area
        guard
            let chapter = chapter,
            let chapterIndex = chapters.firstIndex(of: chapter),
            let layout = self.collectionNode.collectionViewLayout as? VerticalContentOffsetPreservingLayout,
            let currentPages = pages[safe: chapterIndex]
        else { return }

        var offset: CGFloat = 0
        for idx in 0..<chapterIndex {
            offset += layout.getHeightFor(section: idx)
        }

        let hasStartInfo = currentPages.first?.type != .imagePage
        let hasEndInfo = currentPages.last?.type != .imagePage

        if hasStartInfo {
            offset += layout.getHeightFor(section: chapterIndex, range: 0..<1)
        }

        let height = layout.getHeightFor(
            section: chapterIndex,
            range: (hasStartInfo ? 1 : 0)..<currentPages.count - (hasEndInfo ? 1 : 0)
        ) - collectionNode.bounds.height

        scrollView.setContentOffset(
            CGPoint(x: collectionNode.contentOffset.x, y: offset + height * value),
            animated: false
        )

        let page = getCurrentPage()
        delegate?.displayPage(page)
    }

    func sliderStopped(value: CGFloat) {
        isSliding = false
        scrollViewDidScroll(collectionNode.view)
    }

    func setChapter(_ chapter: AidokuRunner.Chapter, startPage: Int) {
        self.chapter = chapter
        updateDoubleTapZoomSetting()
        chapters = [chapter]

        Task {
            await viewModel.loadPages(chapter: chapter)
            delegate?.setPages(viewModel.pages)
            if viewModel.pages.isEmpty {
                pages = []
                await collectionNode.reloadData()
                return
            }
            let sourceId = viewModel.source?.key ?? viewModel.manga.sourceKey
            pages = [[
                Page(
                    type: .prevInfoPage,
                    sourceId: sourceId,
                    chapterId: chapter.key,
                    index: -1
                )
            ] + viewModel.pages + [
                Page(
                    type: .nextInfoPage,
                    sourceId: sourceId,
                    chapterId: chapter.key,
                    index: -2
                )
            ]]

            var startPage = startPage
            if startPage < 1 {
                startPage = 1
            } else if startPage > viewModel.pages.count {
                startPage = viewModel.pages.count
            }

            await collectionNode.reloadData()
            zoomView.adjustContentSize()

            // scroll to first page
            collectionNode.scrollToItem(
                at: IndexPath(row: startPage, section: 0),
                at: .top,
                animated: false
            )
            scrollView.contentOffset = collectionNode.contentOffset
        }
    }
}

// MARK: - Collection View Delegate
extension ReaderWebtoonViewController: ASCollectionDelegate {

    // Refresh info pages after they move off screen
    func collectionNode(_ collectionNode: ASCollectionNode, didEndDisplayingItemWith node: ASCellNode) {
        guard needsInfoRefresh else { return }
        if node is ReaderWebtoonTransitionNode {
            needsInfoRefresh = false
            refreshInfoPages()
        }
    }
}

// MARK: - Data Source
extension ReaderWebtoonViewController: ASCollectionDataSource {

    func numberOfSections(in collectionNode: ASCollectionNode) -> Int {
        pages.count
    }

    func collectionNode(
        _ collectionNode: ASCollectionNode,
        numberOfItemsInSection section: Int
    ) -> Int {
        pages[section].count
    }

    func collectionNode(
        _ collectionNode: ASCollectionNode,
        nodeBlockForItemAt indexPath: IndexPath
    ) -> ASCellNodeBlock {
        guard let chapter else { return { ASCellNode() } }
        var page = pages[indexPath.section][indexPath.item]
        if page.type == .imagePage {
            // image page
            return { [weak self] in
                guard let self else { return ASCellNode() }
                let cell = ReaderWebtoonPageNode(source: self.viewModel.source, page: page)
                cell.delegate = self
                if #available(iOS 18.0, *) {
                    self.bindDictionaryOverlayTap(to: cell)
                }
                return cell
            }
        } else {
            // transition page
            let chapterIndex = chapters.firstIndex(of: chapter) ?? 0

            // determine page type
            if (indexPath.section == chapterIndex && indexPath.item == 0)
                || (indexPath.section == chapterIndex - 1 && indexPath.item > 0) {
                page.type = .prevInfoPage
            } else {
                page.type = .nextInfoPage
            }

            let to = page.type == .prevInfoPage
                ? self.delegate?.getPreviousChapter()
                : self.delegate?.getNextChapter()
            return { [weak self] in
                guard let self else { return ASCellNode() }
                return ReaderWebtoonTransitionNode(transition: .init(
                    type: page.type == .prevInfoPage ? .prev : .next,
                    from: chapter.toOld(
                        sourceId: self.viewModel.source?.key ?? self.viewModel.manga.sourceKey,
                        mangaId: self.viewModel.manga.key
                    ),
                    to: to?.toOld(
                        sourceId: self.viewModel.source?.key ?? self.viewModel.manga.sourceKey,
                        mangaId: self.viewModel.manga.key
                    )
                ))
            }
        }
    }
}
