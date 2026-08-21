//
//  SearchFilterHeaderView.swift
//  Aidoku
//
//  Created by Skitty on 3/4/25.
//

import AidokuRunner
import SwiftUI

struct SearchFilterHeaderView: View {
    let source: AidokuRunner.Source

    @Binding var filters: [AidokuRunner.Filter]?
    @Binding var search: String
    @Binding var enabledFilters: [FilterValue]
    @Binding var filtersEmpty: Bool

    var onFilterButtonClick: (() -> Void)?

    @State private var error: Error?

    var body: some View {
        Group {
            if let error {
                let text = error.aidokuDescription()
                Label(text, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            } else if let filters {
                if filters.isEmpty {
                    EmptyView()
                } else {
                    FilterHeaderView(
                        sourceKey: source.key,
                        filters: filters,
                        search: $search,
                        enabledFilters: $enabledFilters,
                        onFilterButtonClick: onFilterButtonClick
                    )
                }
            } else {
                ProgressView().progressViewStyle(.circular)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("refresh-filters"))) { _ in
            error = nil
            Task {
                await loadFilters()
            }
        }
        .task {
            guard filters == nil else { return }
            await self.loadFilters()
        }
    }

    func loadFilters() async {
        do {
            let sourceFilters = try await source.getSearchFilters()
            filters = if source.id == PicaFilterAdapter.sourceId || source.key == PicaFilterAdapter.sourceId {
                PicaFilterAdapter.removingBlockedCategories(from: sourceFilters)
            } else {
                sourceFilters
            }
            filtersEmpty = filters?.isEmpty ?? true
        } catch {
            withAnimation {
                self.error = error
            }
        }
    }
}

private enum PicaFilterAdapter {
    static let sourceId = "zh.picacomic"

    private static let defaultBlockedCategories = [
        "CG雜圖", "Cosplay", "英語 ENG", "生肉", "性轉換", "耽美花園",
        "偽娘哲學", "扶他樂園", "重口地帶", "歐美", "WEBTOON", "百合花園"
    ]

    static func removingBlockedCategories(from filters: [AidokuRunner.Filter]) -> [AidokuRunner.Filter] {
        let blocked = blockedCategories()
        guard !blocked.isEmpty else { return filters }

        return filters.map { filter in
            guard filter.id == "category", case let .select(select) = filter.value else {
                return filter
            }

            var options: [String] = []
            var ids: [String]? = select.ids == nil ? nil : []
            for (index, option) in select.options.enumerated() {
                let value = select.ids?[safe: index] ?? option
                if index == 0 || !blocked.contains(normalize(value)) {
                    options.append(option)
                    ids?.append(value)
                }
            }

            return AidokuRunner.Filter(
                id: filter.id,
                title: filter.title,
                value: .select(.init(options: options, ids: ids))
            )
        }
    }

    private static func blockedCategories() -> Set<String> {
        let values = UserDefaults.standard.stringArray(forKey: "\(sourceId).blockCategories")
            ?? defaultBlockedCategories
        return Set(values.flatMap { value in
            value
                .replacingOccurrences(of: "，", with: ",")
                .components(separatedBy: CharacterSet(charactersIn: ",\n\r"))
                .map(normalize)
                .filter { !$0.isEmpty }
        })
    }

    private static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
