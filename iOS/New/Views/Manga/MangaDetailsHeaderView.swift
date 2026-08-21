//
//  MangaDetailsHeaderView.swift
//  Aidoku
//
//  Created by Skitty on 8/18/23.
//

import SwiftUI
import AidokuRunner
import MarkdownUI
import NukeUI
import SafariServices

struct MangaDetailsHeaderView: View {
    @Binding var source: AidokuRunner.Source?

    @Binding var manga: AidokuRunner.Manga
    @Binding var chapters: [AidokuRunner.Chapter]
    @Binding var nextChapter: AidokuRunner.Chapter?
    @Binding var readingInProgress: Bool
    @Binding var allChaptersLocked: Bool
    @Binding var allChaptersRead: Bool
    @Binding var initialDataLoaded: Bool

    @Binding var bookmarked: Bool
    @Binding var coverPressed: Bool
    @Binding var chapterSortOption: ChapterSortOption
    @Binding var chapterSortAscending: Bool

    @Binding var filters: [ChapterFilterOption]
    @Binding var langFilter: String?
    @Binding var scanlatorFilter: [String]

    @Binding var descriptionExpanded: Bool

    @Binding var chapterTitleDisplayMode: ChapterTitleDisplayMode

    var hasOtherDownloads: Bool
    var onTrackerButtonPressed: (() -> Void)?
    var onReadButtonPressed: (() -> Void)?

    @EnvironmentObject private var path: NavigationCoordinator

    @State private var readButtonText = NSLocalizedString("LOADING_ELLIPSIS")
    @State private var readButtonDisabled = true
    @State private var animationTrigger = false
    @State private var longHeldBookmark = false
    @State private var longHeldSafari = false
    @State private var isTracking = false
    @State private var hasAvailableTrackers = false
    @State private var showLibraryRemoveConfirm = false
    @State private var picaFavouriteLoading = false
    @State private var picaFavouriteOverride: Bool?
    @State private var picaFavouriteError = ""
    @State private var showPicaFavouriteError = false

    static let coverWidth: CGFloat = 114

    init(
        source: Binding<AidokuRunner.Source?>,
        manga: Binding<AidokuRunner.Manga>,
        chapters: Binding<[AidokuRunner.Chapter]>,
        nextChapter: Binding<AidokuRunner.Chapter?>,
        readingInProgress: Binding<Bool>,
        allChaptersLocked: Binding<Bool>,
        allChaptersRead: Binding<Bool>,
        initialDataLoaded: Binding<Bool>,
        bookmarked: Binding<Bool>,
        coverPressed: Binding<Bool>,
        chapterSortOption: Binding<ChapterSortOption>,
        chapterSortAscending: Binding<Bool>,
        filters: Binding<[ChapterFilterOption]>,
        langFilter: Binding<String?>,
        scanlatorFilter: Binding<[String]>,
        descriptionExpanded: Binding<Bool>,
        chapterTitleDisplayMode: Binding<ChapterTitleDisplayMode>,
        hasOtherDownloads: Bool,
        onTrackerButtonPressed: (() -> Void)? = nil,
        onReadButtonPressed: (() -> Void)? = nil
    ) {
        self._source = source
        self._manga = manga
        self._chapters = chapters
        self._nextChapter = nextChapter
        self._readingInProgress = readingInProgress
        self._allChaptersLocked = allChaptersLocked
        self._allChaptersRead = allChaptersRead
        self._initialDataLoaded = initialDataLoaded
        self._bookmarked = bookmarked
        self._coverPressed = coverPressed
        self._chapterSortOption = chapterSortOption
        self._chapterSortAscending = chapterSortAscending
        self._filters = filters
        self._langFilter = langFilter
        self._scanlatorFilter = scanlatorFilter
        self._descriptionExpanded = descriptionExpanded
        self._chapterTitleDisplayMode = chapterTitleDisplayMode
        self.hasOtherDownloads = hasOtherDownloads
        self.onTrackerButtonPressed = onTrackerButtonPressed
        self.onReadButtonPressed = onReadButtonPressed

        self._isTracking = State(initialValue: TrackerManager.shared.isTracking(
            sourceId: manga.wrappedValue.sourceKey,
            mangaId: manga.wrappedValue.key
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                VStack(spacing: 0) {
                    Spacer(minLength: 0)

                    Button {
                        coverPressed = true
                    } label: {
                        // 2:3 aspect ratio
                        MangaCoverView(
                            source: source,
                            coverImage: manga.cover ?? "",
                            width: Self.coverWidth,
                            height: Self.coverWidth * 3/2
                        )
                        .id(manga.cover ?? "")
                    }
                    .buttonStyle(DarkOverlayButtonStyle())
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                }

                VStack(alignment: .leading, spacing: 0) {
                    Spacer(minLength: 0)

                    Text(manga.title)
                        .lineLimit(4)
                        .font(.system(.title2).weight(.semibold))
                        .textSelection(.enabled)
                        .foregroundStyle(.primary)
                        .minimumScaleFactor(0.75)
                        .contentTransitionDisabledPlease()
                        .padding(.bottom, 4)

                    if let authors = manga.authors, !authors.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(authors, id: \.self) { author in
                                authorView(author)
                            }
                        }
                        .padding(.bottom, 6)
                        .transition(.opacity)
                    }

                    labelsView

                    buttonsView
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 174)
            .padding(.bottom, 14)
            .padding(.horizontal, 20)

            if let description = manga.description, !description.isEmpty {
                if manga.sourceKey == PicaDetailMetadata.sourceKey,
                   let metadata = PicaDetailMetadata(description: description)
                {
                    if let summary = metadata.summary {
                        ExpandableTextView(text: summary, expanded: $descriptionExpanded)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.bottom, 12)
                            .padding(.horizontal, 20)
                            .foregroundStyle(.secondary)
                    }
                    picaMetadataView(metadata)
                } else {
                    ExpandableTextView(text: description, expanded: $descriptionExpanded)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 12)
                        .padding(.horizontal, 20)
                        .foregroundStyle(.secondary)
                }
            }

            tagsView

            // read button
            Button {
                onReadButtonPressed?()
            } label: {
                Text(readButtonText)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .font(.system(size: 14, weight: .medium))
            .padding(11)
            .foregroundStyle(.white)
            .background(Color.accentColor)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.bottom, 20)
            .padding(.horizontal, 20)
            .allowsHitTesting(!readButtonDisabled)

            // hide the chapter list header if there are no chapters and the other downloads header is shown
            if !(manga.chapters ?? chapters).isEmpty || !hasOtherDownloads {
                ChapterListHeaderView(
                    allChapters: manga.chapters,
                    filteredChapters: manga.chapters != nil ? chapters : (initialDataLoaded ? [] : nil),
                    sortOption: $chapterSortOption,
                    sortAscending: $chapterSortAscending,
                    filters: $filters,
                    langFilter: $langFilter,
                    scanlatorFilter: $scanlatorFilter,
                    displayMode: $chapterTitleDisplayMode,
                    mangaUniqueKey: manga.uniqueKey
                )
                .padding(.horizontal, 20)
                .padding(.bottom, 10)
            }

            // separator
            if !chapters.isEmpty {
                ListDivider()
            }
        }
        .animation(.default, value: animationTrigger)
        .animation(.default, value: descriptionExpanded)
        .foregroundStyle(.primary)
        .textCase(.none)
        .padding(.top, 10)
        .onChange(of: manga) { _ in
            animationTrigger.toggle()
        }
        .onChange(of: manga.key) { _ in
            picaFavouriteOverride = nil
        }
        .onChange(of: nextChapter) { _ in
            updateReadButtonText()
        }
        .onChange(of: readingInProgress) { _ in
            updateReadButtonText()
        }
        .onChange(of: allChaptersLocked) { _ in
            updateReadButtonText()
        }
        .onChange(of: allChaptersRead) { _ in
            updateReadButtonText()
        }
        .onChange(of: source != nil) { _ in
            updateReadButtonText()
        }
        .onReceive(NotificationCenter.default.publisher(for: .updateTrackers)) { _ in
            isTracking = TrackerManager.shared.isTracking(
                sourceId: manga.sourceKey,
                mangaId: manga.key
            )
        }
        .task {
            updateReadButtonText()
            hasAvailableTrackers = await TrackerManager.shared.hasAvailableTrackers(sourceKey: manga.sourceKey, mangaKey: manga.key)
        }
    }

    @ViewBuilder
    func authorView(_ author: String) -> some View {
        let label = Text(author)
            .lineLimit(1)
            .foregroundStyle(.secondary)
            .font(.callout)
            .textSelection(.enabled)

        if let source, source.supportsAuthorSearch {
            Button {
                openAuthorSearch(author, source: source)
            } label: {
                label
            }
            .buttonStyle(.borderless)
            .contextMenu {
                Button(NSLocalizedString("COPY")) {
                    UIPasteboard.general.string = author
                }
            }
        } else {
            label
                .contextMenu {
                    Button(NSLocalizedString("COPY")) {
                        UIPasteboard.general.string = author
                    }
                }
        }
    }

    func openAuthorSearch(_ author: String, source: AidokuRunner.Source) {
        let viewController = MangaListViewController(source: source, title: author)
        viewController.getEntries = { page in
            try await source.getSearchMangaList(query: nil, page: page, filters: [
                .text(id: "author", value: author)
            ])
        }
        path.push(viewController)
    }

    @ViewBuilder
    private func picaMetadataView(_ metadata: PicaDetailMetadata) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(metadata.rows, id: \.self) { row in
                let value = if row.label == "哔咔收藏", let picaFavouriteOverride {
                    picaFavouriteOverride ? "已收藏" : "未收藏"
                } else {
                    row.value
                }

                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text("\(row.label)：")
                        .foregroundStyle(.secondary)
                    if row.label == "作者", let source, source.supportsAuthorSearch {
                        Button {
                            openAuthorSearch(value, source: source)
                        } label: {
                            Text(value)
                                .foregroundStyle(.tint)
                                .textSelection(.enabled)
                        }
                        .buttonStyle(.borderless)
                    } else {
                        Text(value)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
                .contextMenu {
                    Button(NSLocalizedString("COPY")) {
                        UIPasteboard.general.string = "\(row.label)：\(value)"
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 14)
    }

    @ViewBuilder
    var labelsView: some View {
        if manga.status != .unknown || (manga.contentRating != .unknown && manga.contentRating != .safe) || (bookmarked && source != nil) {
            HStack(spacing: 6) {
                if manga.status != .unknown {
                    LabelView(text: manga.status.title)
                }
                if manga.contentRating != .unknown && manga.contentRating != .safe {
                    LabelView(
                        text: manga.contentRating.title,
                        background: manga.contentRating == .suggestive
                            ? .orange.opacity(0.3)
                            : .red.opacity(0.3)
                    )
                }
                if let source, bookmarked {
                    LabelView(
                        text: source.name,
                        background: Color(red: 0.25, green: 0.55, blue: 1).opacity(0.3)
                    )
                }
            }
            .padding(.bottom, 8)
            .animation(.default, value: manga.status)
            .animation(.default, value: bookmarked)
        }
    }

    var buttonsView: some View {
        HStack(spacing: 8) {
            Button {
                // long holding also triggers a press on release, so cancel that
                if longHeldBookmark {
                    longHeldBookmark = false
                    return
                }
                if bookmarked && isTracking {
                    // show confirm prompt
                    showLibraryRemoveConfirm = true
                } else {
                    Task {
                        await toggleBookmarked()
                    }
                }
            } label: {
                Image(systemName: "bookmark.fill")
            }
            .buttonStyle(MangaActionButtonStyle(selected: bookmarked))
            .simultaneousGesture(
                // on long hold, show category select
                LongPressGesture()
                    .onEnded { _ in
                        if
                            bookmarked,
                            !CoreDataManager.shared.getCategoryTitles(sorted: false).isEmpty
                        {
                            longHeldBookmark = true
                            path.present(
                                UINavigationController(
                                    rootViewController: CategorySelectViewController(
                                        manga: manga
                                    )
                                )
                            )
                        }
                    }
            )
            .alert(NSLocalizedString("REMOVE_FROM_LIBRARY_CONFIRM"), isPresented: $showLibraryRemoveConfirm) {
                Button(NSLocalizedString("CANCEL"), role: .cancel) {}
                Button(NSLocalizedString("REMOVE"), role: .destructive) {
                    guard bookmarked else { return }
                    Task {
                        await toggleBookmarked()
                    }
                }
            } message: {
                Text(NSLocalizedString("REMOVE_FROM_LIBRARY_CONFIRM_TEXT"))
            }

            if hasAvailableTrackers {
                Button {
                    onTrackerButtonPressed?()
                } label: {
                    Image(systemName: "clock.arrow.2.circlepath")
                }
                .buttonStyle(MangaActionButtonStyle(selected: isTracking))
            }

            if let url = manga.url {
                Button {
                    guard url.scheme == "http" || url.scheme == "https" else { return }
                    path.present(SFSafariViewController(url: url))
                } label: {
                    Image(systemName: "safari")
                }
                .buttonStyle(MangaActionButtonStyle())
                .transition(.opacity)
                .simultaneousGesture(
                    LongPressGesture()
                        .onEnded { finished in
                            if finished {
                                UIPasteboard.general.string = url.absoluteString
                                longHeldSafari = true
                            }
                        }
                )
                .alert(
                    NSLocalizedString("LINK_COPIED"),
                    isPresented: $longHeldSafari
                ) {
                    Button(NSLocalizedString("OK"), role: .cancel) {}
                } message: {
                    Text(NSLocalizedString("LINK_COPIED_TEXT"))
                }
            }

            if manga.sourceKey == PicaDetailMetadata.sourceKey, source != nil {
                Button {
                    Task {
                        await togglePicaFavourite()
                    }
                } label: {
                    if picaFavouriteLoading {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: picaFavouriteState ? "heart.fill" : "heart")
                    }
                }
                .buttonStyle(MangaActionButtonStyle(selected: picaFavouriteState))
                .disabled(picaFavouriteLoading || !initialDataLoaded)
                .alert("哔咔收藏", isPresented: $showPicaFavouriteError) {
                    Button(NSLocalizedString("OK"), role: .cancel) {}
                } message: {
                    Text(picaFavouriteError)
                }
            }
        }
    }

    @ViewBuilder
    var tagsView: some View {
        if let tags = manga.tags, !tags.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(manga.tags ?? [], id: \.self) { tag in
                        let label = TagView(text: tag)
                        if let source, let filter = source.matchingGenreFilter(for: tag) {
                            Button {
                                let viewController = MangaListViewController(source: source, title: tag)
                                viewController.getEntries = { page in
                                    try await source.getSearchMangaList(query: nil, page: page, filters: [
                                        filter
                                    ])
                                }
                                path.push(viewController)
                            } label: {
                                label
                            }
                        } else {
                            label
                        }
                    }
                }
                .padding(.horizontal, 20)
            }
            .padding(.bottom, 16)
        }
    }

    var picaFavouriteState: Bool {
        if let picaFavouriteOverride {
            return picaFavouriteOverride
        }
        guard
            let description = manga.description,
            let metadata = PicaDetailMetadata(description: description),
            let value = metadata.rows.first(where: { $0.label == "哔咔收藏" })?.value
        else {
            return false
        }
        return value == "已收藏"
    }

    @MainActor
    func togglePicaFavourite() async {
        guard let source, source.key == PicaDetailMetadata.sourceKey else { return }
        let mangaId = manga.key
        let resultKey = "\(PicaDetailMetadata.sourceKey).favouriteActionResult"
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: resultKey)
        picaFavouriteLoading = true
        defer {
            picaFavouriteLoading = false
            defaults.removeObject(forKey: resultKey)
        }

        do {
            try await source.handleNotification(notification: "pica.favourite.toggle:\(mangaId)")
            guard let result = defaults.string(forKey: resultKey) else {
                throw PicaFavouriteError.missingResult
            }
            let fields = result.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3, String(fields[1]) == mangaId else {
                throw PicaFavouriteError.invalidResult
            }
            if fields[0] == "error" {
                throw PicaFavouriteError.remote(String(fields[2]))
            }

            let isFavourite: Bool
            switch fields[2] {
                case "favourite":
                    isFavourite = true
                case "un_favourite":
                    isFavourite = false
                default:
                    throw PicaFavouriteError.invalidResult
            }
            picaFavouriteOverride = isFavourite

            if let updatedManga = try? await source.getMangaUpdate(
                manga: manga,
                needsDetails: true,
                needsChapters: false
            ) {
                manga = updatedManga
            }
        } catch {
            picaFavouriteError = error.localizedDescription
            showPicaFavouriteError = true
        }
    }

    func toggleBookmarked() async {
        let sourceId = manga.sourceKey
        let mangaId = manga.key
        let inLibrary = await CoreDataManager.shared.container.performBackgroundTask { context in
            CoreDataManager.shared.hasLibraryManga(
                sourceId: sourceId,
                mangaId: mangaId,
                context: context
            )
        }
        if inLibrary {
            // remove from library
            await MangaManager.shared.removeFromLibrary(
                sourceId: sourceId,
                mangaId: mangaId
            )
            bookmarked = false
        } else {
            if MangaManager.shouldAskForCategories() { // open category select view
                let viewController = UINavigationController(rootViewController: CategorySelectViewController(manga: manga))
                path.present(viewController)
            } else { // add to library
                bookmarked = true
                await MangaManager.shared.addToLibrary(
                    manga: manga,
                    chapters: manga.chapters ?? []
                )
            }
        }
    }

    func updateReadButtonText() {
        var title = ""
        if allChaptersLocked {
            title = NSLocalizedString("ALL_CHAPTERS_LOCKED", comment: "")
            readButtonDisabled = true
        } else if allChaptersRead {
            title = NSLocalizedString("ALL_CHAPTERS_READ", comment: "")
            readButtonDisabled = true
        } else if source == nil {
            title = NSLocalizedString("UNAVAILABLE", comment: "")
            readButtonDisabled = true
        } else {
            if let chapter = nextChapter {
                if !readingInProgress {
                    title = NSLocalizedString("START_READING", comment: "")
                } else {
                    title = NSLocalizedString("CONTINUE_READING", comment: "")
                }
                switch chapterTitleDisplayMode {
                    case .volume:
                        if let volumeNum = chapter.volumeNumber {
                            title += " " + String(format: NSLocalizedString("VOL_X"), volumeNum)
                        } else if let chapterNum = chapter.chapterNumber {
                            // Force display as volume if no volume number
                            title += " " + String(format: NSLocalizedString("VOL_X"), chapterNum)
                        }
                    case .chapter:
                        if let chapterNum = chapter.chapterNumber {
                            title += " " + String(format: NSLocalizedString("CH_X"), chapterNum)
                        } else if let volumeNum = chapter.volumeNumber {
                            // Force display as chapter if no chapter number
                            title += " " + String(format: NSLocalizedString("CH_X"), volumeNum)
                        }
                    case .default:
                        if let volumeNum = chapter.volumeNumber {
                            title += " " + String(format: NSLocalizedString("VOL_X"), volumeNum)
                        }
                        if let chapterNum = chapter.chapterNumber {
                            title += " " + String(format: NSLocalizedString("CH_X"), chapterNum)
                        }
                }
            } else {
                title = NSLocalizedString("NO_CHAPTERS_AVAILABLE", comment: "")
            }
            readButtonDisabled = false
        }
        readButtonText = title
    }
}

struct LabelView: View {
    let text: String
    var background = Color(UIColor.tertiarySystemFill)

    var body: some View {
        Text(text)
            .lineLimit(1)
            .foregroundStyle(.secondary)
            .font(.caption2)
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

private struct PicaDetailMetadata {
    static let sourceKey = "zh.picacomic"
    private static let marker = "──── 漫画信息 ────"

    struct Row: Hashable {
        let label: String
        let value: String
    }

    let summary: String?
    let rows: [Row]

    init?(description: String) {
        guard let markerRange = description.range(of: Self.marker) else { return nil }

        let summary = String(description[..<markerRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.summary = summary.isEmpty ? nil : summary
        rows = description[markerRange.upperBound...]
            .split(whereSeparator: { $0.isNewline })
            .compactMap { line in
                let line = String(line).trimmingCharacters(in: .whitespaces)
                guard
                    !line.isEmpty,
                    let separator = line.firstIndex(of: "：")
                else {
                    return nil
                }
                let label = line[..<separator].trimmingCharacters(in: .whitespaces)
                let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
                guard !label.isEmpty, !value.isEmpty else { return nil }
                return Row(label: label, value: value)
            }
    }
}

private enum PicaFavouriteError: LocalizedError {
    case missingResult
    case invalidResult
    case remote(String)

    var errorDescription: String? {
        switch self {
            case .missingResult:
                "没有收到哔咔收藏操作结果。"
            case .invalidResult:
                "哔咔收藏返回了无法识别的状态。"
            case .remote(let message):
                "哔咔收藏操作失败：\(message)"
        }
    }
}

private struct TagView: View {
    let text: String

    var body: some View {
        Text(text)
            .lineLimit(1)
            .foregroundStyle(.secondary)
            .font(.footnote)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .textSelection(.enabled)
            .background(Color(UIColor.tertiarySystemFill))
            .clipShape(RoundedRectangle(cornerRadius: 100))
    }
}

private struct MangaActionButtonStyle: ButtonStyle {
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
//        Group {
//            if selected {
//                configuration.label
//                    .foregroundStyle(.white)
//            } else {
//                configuration.label
//                    .foregroundStyle(.tint)
//            }
//        }
        configuration.label
            .foregroundStyle(selected ? Color.white : Color.accentColor)
            .opacity(configuration.isPressed ? 0.4 : 1)
            .font(.system(size: 16, weight: .semibold))
            .frame(width: 40, height: 32)
            .background(selected ? Color.accentColor : Color(UIColor.secondarySystemFill))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

@available(iOS 17.0, macOS 14.0, *)
#Preview {
    @Previewable @State var bookmarked = false
    @Previewable @State var chapterSortOption = ChapterSortOption.sourceOrder
    @Previewable @State var chapterSortAscending = false

    @Previewable @State var filters: [ChapterFilterOption] = []
    @Previewable @State var langFilter: String?
    @Previewable @State var scanlatorFilter: [String] = []
    @Previewable @State var chapterTitleDisplayMode = ChapterTitleDisplayMode.default

    MangaDetailsHeaderView(
        source: Binding.constant(AidokuRunner.Source.demo()),
        manga: Binding.constant(AidokuRunner.Manga(
            sourceKey: "",
            key: "",
            title: "Manga",
            authors: ["Author"],
            description: "Description"
        )),
        chapters: Binding.constant([]),
        nextChapter: Binding.constant(nil),
        readingInProgress: Binding.constant(false),
        allChaptersLocked: Binding.constant(false),
        allChaptersRead: Binding.constant(false),
        initialDataLoaded: Binding.constant(true),
        bookmarked: $bookmarked,
        coverPressed: Binding.constant(false),
        chapterSortOption: $chapterSortOption,
        chapterSortAscending: $chapterSortAscending,
        filters: $filters,
        langFilter: $langFilter,
        scanlatorFilter: $scanlatorFilter,
        descriptionExpanded: Binding.constant(false),
        chapterTitleDisplayMode: $chapterTitleDisplayMode,
        hasOtherDownloads: false,
    )
}

