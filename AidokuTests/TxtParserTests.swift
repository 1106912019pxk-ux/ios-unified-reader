//
//  TxtParserTests.swift
//  AidokuTests
//

import Foundation
import Testing
@testable import Aidoku

@Suite struct TxtParserTests {
    @Test("UTF-8 TXT detects preface and common chapter headings")
    func detectsCommonHeadings() throws {
        let text = """
        这是开头内容。

        第一章 初见
        这是第一章正文。

        第二章 重逢
        这是第二章正文。

        Chapter 3 Ending
        English body.
        """
        let prepared = try TxtParser.prepare(
            data: Data(text.utf8),
            sourceFileName: "book.txt"
        )

        #expect(prepared.analysis.encoding == .utf8)
        #expect(prepared.analysis.index.chapters.count == 4)
        #expect(prepared.analysis.index.chapters[1].title == "第一章 初见")
        #expect(prepared.analysis.index.chapters[3].title == "Chapter 3 Ending")
    }

    @Test("Chapter detection can be disabled")
    func disablesChapterDetection() throws {
        let text = "第一章\n正文\n第二章\n正文"
        let prepared = try TxtParser.prepare(
            data: Data(text.utf8),
            sourceFileName: "book.txt",
            options: TxtImportOptions(
                encoding: .utf8,
                splitsChapters: false,
                customChapterPattern: nil
            )
        )

        #expect(prepared.analysis.index.chapters.count == 1)
        #expect(prepared.analysis.index.chapters[0].startOffset == 0)
        #expect(prepared.analysis.index.chapters[0].endOffset == UInt64(prepared.normalizedData.count))
    }

    @Test("Custom regular expression controls chapter detection")
    func customChapterRule() throws {
        let text = "开头\n@@ A\n内容一\n@@ B\n内容二"
        let prepared = try TxtParser.prepare(
            data: Data(text.utf8),
            sourceFileName: "custom.txt",
            options: TxtImportOptions(
                encoding: .utf8,
                splitsChapters: true,
                customChapterPattern: #"^@@\s+.+$"#
            )
        )

        #expect(prepared.analysis.index.chapters.count == 3)
        #expect(prepared.analysis.index.chapters[1].title == "@@ A")
        #expect(prepared.analysis.index.chapters[2].title == "@@ B")
    }

    @Test("Indexed chapters are read by UTF-8 byte range")
    func readsIndexedChapter() throws {
        let text = "序言内容\n第一章\n包含中文和 emoji 😀\n第二章\n结束"
        let prepared = try TxtParser.prepare(
            data: Data(text.utf8),
            sourceFileName: "ranges.txt"
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TxtParserTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let textURL = directory.appendingPathComponent("ranges.txt")
        try prepared.normalizedData.write(to: textURL)
        try prepared.analysis.index.save(for: textURL)

        let chapter = prepared.analysis.index.chapters[1]
        let result = try TxtParser.readChapter(from: textURL, chapterId: "ranges.txt/\(chapter.id)")
        #expect(result.hasPrefix("第一章"))
        #expect(result.contains("emoji 😀"))
        #expect(!result.contains("第二章"))
    }

    @Test("UTF BOMs are detected")
    func detectsByteOrderMarks() {
        #expect(TxtParser.detectEncoding(data: Data([0xEF, 0xBB, 0xBF, 0x41])) == .utf8)
        #expect(TxtParser.detectEncoding(data: Data([0xFF, 0xFE, 0x41, 0x00])) == .utf16LittleEndian)
        #expect(TxtParser.detectEncoding(data: Data([0xFE, 0xFF, 0x00, 0x41])) == .utf16BigEndian)
    }

    @Test("Invalid custom regular expression is rejected")
    func rejectsInvalidRule() {
        #expect(!TxtParser.validateChapterPattern("["))
    }
}
