//
//  ReaderTextView.swift
//  Aidoku
//
//  Created by skitty on 3/16/26.
//

import AidokuRunner
import SwiftUI
import ZIPFoundation

struct ReaderTextView: View {
   let source: AidokuRunner.Source?
   let text: String?
   let fontFamily: String
   let fontSize: Double
   let lineSpacing: Double
   let horizontalPadding: Double
   let topPadding: Double
   let bottomPadding: Double
   let paragraphSpacing: Double
   let firstLineIndent: Double
   let theme: TextReaderTheme

   init(
       source: AidokuRunner.Source?,
       page: Page?,
       fontFamily: String,
       fontSize: Double,
       lineSpacing: Double,
       horizontalPadding: Double,
       topPadding: Double,
       bottomPadding: Double,
       paragraphSpacing: Double,
       firstLineIndent: Double,
       theme: TextReaderTheme
   ) {
       self.source = source
       self.fontFamily = fontFamily
       self.fontSize = fontSize
       self.lineSpacing = lineSpacing
       self.horizontalPadding = horizontalPadding
       self.topPadding = topPadding
       self.bottomPadding = bottomPadding
       self.paragraphSpacing = paragraphSpacing
       self.firstLineIndent = firstLineIndent
       self.theme = theme

       func loadText(page: Page) -> String? {
           if let text = page.text {
               return text
           }
           guard
               let zipURL = page.zipURL.flatMap({ URL(string: $0) }),
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
               return String(data: data, encoding: .utf8)
           } catch {
               return nil
           }
       }
       self.text = page.flatMap(loadText)
   }

   var body: some View {
       if let text {
           MarkdownView(
               text,
               fontFamily: fontFamily,
               fontSize: fontSize,
               lineSpacing: lineSpacing,
               horizontalPadding: horizontalPadding,
               topPadding: topPadding,
               bottomPadding: bottomPadding,
               paragraphSpacing: paragraphSpacing,
               firstLineIndent: firstLineIndent,
               theme: theme
           )
           .frame(maxWidth: .infinity, alignment: .leading)
           .ignoresSafeArea()
       }
   }
}
