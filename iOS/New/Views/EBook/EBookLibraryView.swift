//
//  EBookLibraryView.swift
//  Aidoku
//

import SwiftUI
import UniformTypeIdentifiers

final class EBookLibraryViewController: UIViewController {
    private let store = EBookLibraryStore.shared
    private var hostingController: UIHostingController<EBookLibraryView>?

    override func viewDidLoad() {
        super.viewDidLoad()
        title = NSLocalizedString("EBOOKS", value: "Books", comment: "E-book tab title")
        navigationItem.largeTitleDisplayMode = .always
        view.backgroundColor = .systemBackground

        let rootView = EBookLibraryView(store: store) { [weak self] book in
            guard let self else { return }
            navigationController?.pushViewController(
                EBookReaderViewController(bookID: book.id, store: store),
                animated: true
            )
        }
        let hostingController = UIHostingController(rootView: rootView)
        addChild(hostingController)
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hostingController.view)
        NSLayoutConstraint.activate([
            hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hostingController.view.topAnchor.constraint(equalTo: view.topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        hostingController.didMove(toParent: self)
        self.hostingController = hostingController
    }
}

struct EBookLibraryView: View {
    @ObservedObject var store: EBookLibraryStore
    let onOpen: (EBook) -> Void

    @State private var isImporting = false
    @State private var importError: String?

    private let columns = [
        GridItem(.adaptive(minimum: 136, maximum: 190), spacing: 18),
    ]

    var body: some View {
        Group {
            if store.books.isEmpty {
                emptyLibrary
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 24) {
                        ForEach(store.books) { book in
                            bookCell(book)
                                .contextMenu {
                                    Button(role: .destructive) {
                                        delete(book)
                                    } label: {
                                        Label(NSLocalizedString("DELETE", comment: ""), systemImage: "trash")
                                    }
                                }
                        }
                    }
                    .padding()
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Label(NSLocalizedString("EBOOK_LOCAL_FILES_ONLY", comment: "Local-only e-book library note"), systemImage: "iphone")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    isImporting = true
                } label: {
                    Label(NSLocalizedString("EBOOK_IMPORT", comment: "Import e-books action"), systemImage: "square.and.arrow.down")
                        .fontWeight(.semibold)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(.bar)
        }
        .sheet(isPresented: $isImporting) {
            DocumentPickerView(
                allowedContentTypes: Self.supportedContentTypes,
                allowsMultipleSelection: true
            ) { urls in
                isImporting = false
                guard !urls.isEmpty else { return }
                do {
                    try store.importFiles(urls)
                } catch {
                    importError = error.localizedDescription
                }
            }
        }
        .alert(NSLocalizedString("EBOOK_IMPORT_FAILED", comment: "E-book import error title"), isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button(NSLocalizedString("OK", comment: ""), role: .cancel) {}
        } message: {
            Text(importError ?? "")
        }
        .task {
            store.refresh()
        }
    }

    private var emptyLibrary: some View {
        VStack(spacing: 14) {
            Image(systemName: "text.book.closed")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(.secondary)
            Text(NSLocalizedString("EBOOK_EMPTY_LIBRARY_TITLE", comment: "Empty e-book library title"))
                .font(.title2.bold())
            Text(NSLocalizedString("EBOOK_EMPTY_LIBRARY_MESSAGE", comment: "Empty e-book library help text"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
            Button {
                isImporting = true
            } label: {
                Label(NSLocalizedString("EBOOK_IMPORT_LOCAL_FILES", comment: "Import local e-book files action"), systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func bookCell(_ book: EBook) -> some View {
        Button {
            onOpen(book)
        } label: {
            VStack(alignment: .leading, spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(coverGradient(for: book.format))
                    VStack(spacing: 10) {
                        Image(systemName: icon(for: book.format))
                            .font(.system(size: 36, weight: .light))
                        Text(book.format.displayName)
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    .foregroundStyle(.white)
                }
                .aspectRatio(0.69, contentMode: .fit)
                .shadow(color: .black.opacity(0.16), radius: 7, y: 4)

                Text(book.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                if let author = book.author {
                    Text(author)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(book.title), \(book.format.displayName)")
    }

    private func delete(_ book: EBook) {
        do {
            try store.delete(book)
        } catch {
            importError = error.localizedDescription
        }
    }

    private func icon(for format: EBookFormat) -> String {
        switch format {
        case .epub: "text.book.closed.fill"
        case .pdf: "doc.richtext.fill"
        case .text, .markdown: "text.alignleft"
        case .html: "chevron.left.forwardslash.chevron.right"
        }
    }

    private func coverGradient(for format: EBookFormat) -> LinearGradient {
        let colors: [Color]
        switch format {
        case .epub: colors = [.indigo, .purple]
        case .pdf: colors = [.red, .orange]
        case .text: colors = [.teal, .blue]
        case .markdown: colors = [.blue, .indigo]
        case .html: colors = [.green, .teal]
        }
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private static var supportedContentTypes: [UTType] {
        var types: [UTType] = [.pdf, .plainText, .html]
        if let epub = UTType(filenameExtension: "epub") {
            types.append(epub)
        }
        if let markdown = UTType(filenameExtension: "md") {
            types.append(markdown)
        }
        return types
    }
}
