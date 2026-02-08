//
//  ContentView.swift
//  Epub-Tr
//
//  Created by ThreeManager785 on 2026/2/8.
//

import FoundationModels
import ReadiumShared
import ReadiumStreamer
import ReadiumZIPFoundation
import SwiftUI
import Translation
import UniformTypeIdentifiers


// MARK: - EPUB IO Helpers
struct EpubIO {
    static func unzipEPUB(from sourceURL: URL, to destinationURL: URL) async throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destinationURL.path) {
            try fm.removeItem(at: destinationURL)
        }
        try fm.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        let archive = try await ReadiumZIPFoundation.Archive(url: sourceURL, accessMode: .read)
        for entry in try await archive.entries() {
            let outURL = destinationURL.appendingPathComponent(entry.path)
            let parent = outURL.deletingLastPathComponent()
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
            _ = try await archive.extract(entry, to: outURL)
        }
    }

    static func zipEPUB(from folderURL: URL, to outputURL: URL) async throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: outputURL.path) {
            try fm.removeItem(at: outputURL)
        }
        let archive = try await ReadiumZIPFoundation.Archive(url: outputURL, accessMode: .create)
        let enumerator = fm.enumerator(at: folderURL, includingPropertiesForKeys: [.isDirectoryKey])
        while let file = enumerator?.nextObject() as? URL {
            let relPath = file.path.replacingOccurrences(of: folderURL.path + "/", with: "")
            let isDir = (try? file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir { continue }
            try await archive.addEntry(with: relPath, relativeTo: folderURL)
        }
    }

    static func findOPFURL(in root: URL) -> URL? {
        // META-INF/container.xml -> rootfile full-path
        let containerURL = root.appendingPathComponent("META-INF/container.xml")
        guard let data = try? Data(contentsOf: containerURL),
              let xml = String(data: data, encoding: .utf8) else { return nil }
        let pattern = "full-path=\\\"(.*?)\\\""
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive]),
              let match = regex.firstMatch(in: xml, range: NSRange(location: 0, length: (xml as NSString).length)),
              match.numberOfRanges >= 2 else { return nil }
        let ns = xml as NSString
        let rel = ns.substring(with: match.range(at: 1))
        return root.appendingPathComponent(rel)
    }

    static func readTitle(from opfURL: URL) -> String? {
        guard let data = try? Data(contentsOf: opfURL), let xml = String(data: data, encoding: .utf8) else { return nil }
        // Try to capture first <dc:title>...</dc:title>
        let pattern = "(?is)<dc:title[^>]*>(.*?)</dc:title>"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: xml, range: NSRange(location: 0, length: (xml as NSString).length)),
              match.numberOfRanges >= 2 else { return nil }
        let ns = xml as NSString
        return ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func writeTitle(_ newTitle: String, to opfURL: URL) {
        guard let data = try? Data(contentsOf: opfURL), var xml = String(data: data, encoding: .utf8) else { return }
        let pattern = "(?is)(<dc:title[^>]*>)(.*?)(</dc:title>)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let ns = xml as NSString
        if let match = regex.firstMatch(in: xml, range: NSRange(location: 0, length: ns.length)), match.numberOfRanges >= 4 {
            let prefix = ns.substring(with: match.range(at: 1))
            let suffix = ns.substring(with: match.range(at: 3))
            let replaced = prefix + newTitle + suffix
            let fullRange = Range(match.range(at: 0), in: xml)!
            xml.replaceSubrange(fullRange, with: replaced)
        } else {
            // Fallback: insert one under <metadata>
            if let metaRange = xml.range(of: "<metadata", options: .caseInsensitive),
               let closeRange = xml.range(of: ">", range: metaRange.lowerBound..<xml.endIndex) {
                let insertIndex = xml.index(after: closeRange.lowerBound)
                xml.insert(contentsOf: "\n<dc:title>\(newTitle)</dc:title>", at: insertIndex)
            }
        }
        if let out = xml.data(using: .utf8) {
            try? out.write(to: opfURL)
        }
    }
    
    static func writeLanguage(_ newLanguage: String, to opfURL: URL) {
        guard let data = try? Data(contentsOf: opfURL), var xml = String(data: data, encoding: .utf8) else { return }
        let pattern = "(?is)(<dc:language[^>]*>)(.*?)(</dc:language>)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let ns = xml as NSString
        if let match = regex.firstMatch(in: xml, range: NSRange(location: 0, length: ns.length)), match.numberOfRanges >= 4 {
            let prefix = ns.substring(with: match.range(at: 1))
            let suffix = ns.substring(with: match.range(at: 3))
            let replaced = prefix + newLanguage + suffix
            let fullRange = Range(match.range(at: 0), in: xml)!
            xml.replaceSubrange(fullRange, with: replaced)
        } else {
            // Fallback: insert one under <metadata>
            if let metaRange = xml.range(of: "<metadata", options: .caseInsensitive),
               let closeRange = xml.range(of: ">", range: metaRange.lowerBound..<xml.endIndex) {
                let insertIndex = xml.index(after: closeRange.lowerBound)
                xml.insert(contentsOf: "\n<dc:language>\(newLanguage)</dc:language>", at: insertIndex)
            }
        }
        if let out = xml.data(using: .utf8) {
            try? out.write(to: opfURL)
        }
    }


    static func htmlFileURLs(in root: URL) -> [URL] {
        let fm = FileManager.default
        let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil)
        var urls: [URL] = []
        while let file = enumerator?.nextObject() as? URL {
            let ext = file.pathExtension.lowercased()
            if ext == "html" || ext == "xhtml" || ext == "htm" { urls.append(file) }
        }
        return urls
    }

//    static func extractParagraphsOld(from html: String) -> [(range: Range<String.Index>, text: String)] {
//        let pattern = "(?is)<p(.*?)>(.*?)</p>"
//        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
//        let ns = html as NSString
//        let matches = regex.matches(in: html, range: NSRange(location: 0, length: ns.length))
//        var result: [(Range<String.Index>, String)] = []
//        for m in matches {
//            if m.numberOfRanges >= 3 {
//                let full = m.range(at: 0)
//                let content = m.range(at: 2)
//                if let fullR = Range(full, in: html), let contentR = Range(content, in: html) {
//                    let text = String(html[contentR]).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
//                    result.append((fullR, text))
//                }
//            }
//        }
//        return result
//    }
    
    static func extractParagraphs(
        from html: String,
        wideMatch: Bool = false
    ) -> [(range: Range<String.Index>, text: String)] {

        let pattern = "(?is)<p\\b[^>]*>([\\s\\S]*?)</p>"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }

        let ns = html as NSString
        let matches = regex.matches(
            in: html,
            range: NSRange(location: 0, length: ns.length)
        )

        var paragraphs: [(range: Range<String.Index>, text: String)] = []

        for m in matches {
            guard m.numberOfRanges >= 2 else { continue }

            let fullRange = m.range(at: 0)
            let contentRange = m.range(at: 1)

            guard
                let full = Range(fullRange, in: html),
                let content = Range(contentRange, in: html)
            else { continue }

            var text = String(html[content])

            // 1️⃣ <br> → 换行
            text = text.replacingOccurrences(
                of: "(?i)<br\\s*/?>",
                with: "\n",
                options: .regularExpression
            )

            // 2️⃣ 移除其余 HTML 标签
            text = text.replacingOccurrences(
                of: "<[^>]+>",
                with: "",
                options: .regularExpression
            )

            // 3️⃣ 规范化空白
            text = text
                .replacingOccurrences(of: "\u{00a0}", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            paragraphs.append((range: full, text: text))
        }

        // 👉 wideMatch：每 20 个段落合并为 1 个
        guard wideMatch, paragraphs.count > 0 else {
            return paragraphs
        }

        var merged: [(range: Range<String.Index>, text: String)] = []
        let chunkSize = 20

        for start in stride(from: 0, to: paragraphs.count, by: chunkSize) {
            let end = min(start + chunkSize, paragraphs.count)
            let chunk = paragraphs[start..<end]

            let mergedRange = chunk.first!.range.lowerBound..<chunk.last!.range.upperBound
            let mergedText = chunk
                .map { $0.text }
                .joined(separator: "\n\n") // 保留段落感

            merged.append((range: mergedRange, text: mergedText))
        }

        return merged
    }


    
//    static func extractParagraphs(from html: String) -> [String] {
//        guard let data = html.data(using: .utf8) else { return [] }
//
//        let attr = try? NSAttributedString(
//            data: data,
//            options: [
//                .documentType: NSAttributedString.DocumentType.html,
//                .characterEncoding: String.Encoding.utf8.rawValue
//            ],
//            documentAttributes: nil
//        )
//
//        guard let string = attr?.string else { return [] }
//
//        return string
//            .components(separatedBy: "\n")
//            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
//            .filter { !$0.isEmpty }
//    }


    static func replaceParagraphs(in html: String, replacements: [Range<String.Index>: String]) -> String {
        var newHTML = html
        // Apply replacements from end to start to keep ranges valid
        let ordered = replacements.keys.sorted { $0.lowerBound > $1.lowerBound }
        for range in ordered {
            let original = String(newHTML[range])
            // Try to preserve attributes inside <p ...>
            let innerPattern = "(?is)^<p(.*?)>(.*?)</p>$"
            if let innerRegex = try? NSRegularExpression(pattern: innerPattern),
               let match = innerRegex.firstMatch(in: original, range: NSRange(location: 0, length: (original as NSString).length)),
               match.numberOfRanges >= 3 {
                let ns = original as NSString
                let attrs = ns.substring(with: match.range(at: 1))
                let replacement = "<p\(attrs)>\(replacements[range] ?? original)</p>"
                newHTML.replaceSubrange(range, with: replacement)
            } else {
                newHTML.replaceSubrange(range, with: "<p>\(replacements[range] ?? original)</p>")
            }
        }
        return newHTML
    }
}

struct ContentView: View {
    let languageCodes: [String] = ["ar", "zh-Hans", "zh-Hant", "nl", "en", "fr", "de", "hi", "id", "it", "ja", "ko", "pl", "pt", "ru", "es", "th", "tr", "uk", "vi"]
    let languageAvailability = LanguageAvailability()
//    @State var allAvailableLanguages: [Locale.Language] = []
    
    @State var importerIsPresented = false
    @State var importedFile: URL?
    @State var sourceLanguage: Locale.Language? = .init(identifier: "en")
    @State var targetLanguage: Locale.Language? = .init(identifier: "zh-Hans")

    @State private var isTranslating = false
    @State private var exportURL: URL?
    @State private var translationError: String?
    @State private var totalParagraphs: Int = 0
    @State private var translatedCount: Int = 0
    @State private var currentFileName: String = ""
    @State private var paragraphQueue: [String] = []
    @State private var paragraphResults: [Int: String] = [:]
    @State private var htmlFiles: [URL] = []
    @State private var workingFolder: URL?
    @State private var exporterIsPresented = false
    @State var translateIsReady = false
    @State var translateTaskToggle = false
    @State var livePreviewIndex = 1
    @State var useAppleIntelligence = false

    @State private var opfURL: URL?
    @State private var titleQueueIndex: Int? = nil

    @State private var translationStartTime: Date?
    @State private var averageSecondsPerItem: Double = 0
    
    @State private var currentLanguagePairIsAvailable: Bool? = nil

    var body: some View {
        List {
            Section(content: {
                if importedFile == nil {
                    Text("Welcome.prompt.initial")
                } else {
                    Text("Welcome.prompt.imported")
                }
            }, footer: {
                Text("Welcome.author")
            })
            Section {
                Group {
                    Picker(selection: $sourceLanguage, content: {
                        ForEach(languageCodes, id: \.self) { item in
                            Text(Locale.current.localizedString(forIdentifier: item) ?? item)
                                .tag(Locale.Language.init(identifier: item))
                        }
                    }, label: {
                        Text("Config.source-lang")
                    })
                    Picker(selection: $targetLanguage, content: {
                        ForEach(languageCodes, id: \.self) { item in
                            Text(Locale.current.localizedString(forIdentifier: item) ?? item)
                                .tag(Locale.Language.init(identifier: item))
                        }
                    }, label: {
                        Text("Config.target-lang")
                    })
                }
                .onChange(of: sourceLanguage, targetLanguage) {
                    currentLanguagePairIsAvailable = nil
                }
                Button(action: {
                    importerIsPresented = true
                }, label: {
                    Text(importedFile?.lastPathComponent ?? String(localized: "Config.select-epub"))
                })
                .onChange(of: importedFile, sourceLanguage, targetLanguage, useAppleIntelligence) {
                    guard let input = importedFile else { return }
                    translateIsReady = false
//                    isTranslating = true
                    translationError = nil
                    exportURL = nil
                    translatedCount = 0
                    totalParagraphs = 0
                    currentFileName = ""
                    paragraphQueue = []
                    paragraphResults = [:]
                    htmlFiles = []
                    workingFolder = nil

                    translationStartTime = Date()
                    averageSecondsPerItem = 0

                    Task {
                        do {
                            // Prepare workspace
                            let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                            try await EpubIO.unzipEPUB(from: input, to: temp)
                            await MainActor.run { self.workingFolder = temp }

                            let htmls = EpubIO.htmlFileURLs(in: temp)
                            await MainActor.run { self.htmlFiles = htmls }

                            // Locate OPF and read title
                            let opf = EpubIO.findOPFURL(in: temp)
                            await MainActor.run { self.opfURL = opf }

                            // Build a queue: title first (if any), then all paragraphs across HTML files
                            var queue: [String] = []
                            var titleIndex: Int? = nil
                            if let opf = opfURL, let title = EpubIO.readTitle(from: opf), !title.isEmpty {
                                titleIndex = 0
                                queue.append(title)
                            }
                            for file in htmls {
                                let data = try Data(contentsOf: file)
                                guard let html = String(data: data, encoding: .utf8) else { continue }
                                let paragraphs = EpubIO.extractParagraphs(from: html, wideMatch: useAppleIntelligence)
                                queue.append(contentsOf: paragraphs.map { $0.text })
                            }
                            await MainActor.run {
                                self.titleQueueIndex = titleIndex
                                self.paragraphQueue = queue.map { $0.replacingOccurrences(of: "\n", with: "") }
                                self.totalParagraphs = queue.count
                                
                                translateIsReady = true
                            }
                        } catch {
                            await MainActor.run {
                                self.translationError = String(describing: error)
                                self.isTranslating = false
                            }
                        }
                    }
                }
                Picker(selection: $livePreviewIndex, content: {
                    Text("Config.live-preview.off")
                        .tag(0)
                    Text("Config.live-preview.source")
                        .tag(1)
                    Text("Config.live-preview.target")
                        .tag(2)
                }, label: {
                    Text("Config.live-preview")
                })
                if SystemLanguageModel.default.isAvailable {
                    Toggle(isOn: $useAppleIntelligence, label: {
                        Text("Config.use-apple.intelligence")
                    })
                }
            }
            Section(content: {
                if !isTranslating && exportURL == nil {
                    Button(action: {
                        isTranslating = true
                        translateTaskToggle = true
                    }, label: {
                        Text("Translation.start")
                    })
                    .disabled(!translateIsReady)
                    .disabled(currentLanguagePairIsAvailable != true)
                    .onChange(of: currentLanguagePairIsAvailable) {
                        if currentLanguagePairIsAvailable == nil {
                            Task {
                                currentLanguagePairIsAvailable = await languageAvailability.status(from: sourceLanguage!, to: targetLanguage!) == .installed
                            }
                        }
                    }
                }
                if isTranslating {
                    Button(action: {
                        isTranslating = false
                        translateTaskToggle = false
                    }, label: {
                        Text("Translate.stop")
                    })
                }
                if translateTaskToggle {
                    Section {
                        TranslationTask(
                            sourceLanguage: sourceLanguage,
                            targetLanguage: targetLanguage,
                            isTranslating: $isTranslating,
                            exportURL: $exportURL,
                            translationError: $translationError,
                            totalParagraphs: $totalParagraphs,
                            translatedCount: $translatedCount,
                            paragraphQueue: $paragraphQueue,
                            paragraphResults: $paragraphResults,
                            htmlFiles: $htmlFiles,
                            workingFolder: $workingFolder,
                            opfURL: $opfURL,
                            titleQueueIndex: $titleQueueIndex,
                            averageSecondsPerItem: $averageSecondsPerItem,
                            useAppleIntelligence: $useAppleIntelligence)
                    }
                }
                if isTranslating {
                    HStack {
                        Text(verbatim: "\(translatedCount)/\(totalParagraphs)")
                        Spacer()
                        if let eta = estimatedTimeLeftString() {
                            Text("Translation.eta.\(eta)")
                                .foregroundStyle(.secondary)
                        }
                    }
                    ProgressView(value: totalParagraphs == 0 ? 0 : Double(translatedCount) / Double(totalParagraphs))
                    if livePreviewIndex == 1, let currentTranslatingContent = paragraphQueue.first {
                        Text(currentTranslatingContent)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    
                    if livePreviewIndex == 2, let currentContent = paragraphResults.sorted(by: { $0.key > $1.key }).first?.1 {
                        Text(currentContent)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } else if let exportURL {
                    Text("\(exportURL.lastPathComponent)")
                    Button("Translation.export") {
                        exporterIsPresented = true
                    }
                }
                if let translationError {
                    Text("Translation.error.\(translationError)")
                        .foregroundStyle(.red)
                }
            }, header: {
                Text("Translation")
            }, footer: {
                if !translateIsReady {
                    Text("Translation.start.error.select-epub")
                }
                if currentLanguagePairIsAvailable == false {
                    if targetLanguage?.languageCode == sourceLanguage?.languageCode {
                        Text("Translation.start.error.same-language")
                    } else {
                        Text("Translation.start.error.no-offline-translation")
                    }
                }
            })
        }
        .fileImporter(isPresented: $importerIsPresented, allowedContentTypes: [.epub], onCompletion: { result in
            if case .success(let url) = result {
                importedFile = url
            }
        })
        .fileExporter(isPresented: $exporterIsPresented, document: exportURL.map { URLDocument(url: $0) }, contentTypes: [.epub]) { _ in
        }
        .onAppear {
            Task {
                currentLanguagePairIsAvailable = await languageAvailability.status(from: sourceLanguage!, to: targetLanguage!) == .installed
            }
        }
    }

    private func estimatedTimeLeftString() -> String? {
        guard isTranslating, totalParagraphs > 0 else { return nil }
        let remaining = max(totalParagraphs - translatedCount, 0)
        let secondsLeft = Double(remaining) * max(averageSecondsPerItem, 0)
        guard secondsLeft.isFinite, secondsLeft > 0 else { return nil }
        let minutes = Int(secondsLeft) / 60
        let seconds = Int(secondsLeft) % 60
        if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        } else {
            return "\(seconds)s"
        }
    }
}

struct URLDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.epub] }
    var url: URL
    init(url: URL) { self.url = url }

    init(configuration: ReadConfiguration) throws {
        // Not used for export-only flow
        self.url = URL(fileURLWithPath: "/dev/null")
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        return try FileWrapper(url: url, options: .immediate)
    }
}

struct TranslationTask: View {
    var sourceLanguage: Locale.Language?
    var targetLanguage: Locale.Language?
    @Binding var isTranslating: Bool
    @Binding var exportURL: URL?
    @Binding var translationError: String?
    @Binding var totalParagraphs: Int
    @Binding var translatedCount: Int
    @Binding var paragraphQueue: [String]
    @Binding var paragraphResults: [Int: String]
    @Binding var htmlFiles: [URL]
    @Binding var workingFolder: URL?

    @Binding var opfURL: URL?
    @Binding var titleQueueIndex: Int?
    @Binding var averageSecondsPerItem: Double
    
    @Binding var useAppleIntelligence: Bool
    var body: some View {
        HStack {
            if isTranslating {
                ProgressView()
            } else {
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(.green)
            }
            Text(isTranslating ? "Translation.translating" : "Translation.complete")
            Spacer()
        }
            .translationTask(source: sourceLanguage, target: targetLanguage) { mtSession in
                print("Translate Task Start")
                
                let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
                let llmSession = LanguageModelSession(model: model)
//                    let options = GenerationOptions()
                
//                do {
//                        let response = try await session.respond(to: "\() Introduce this Chinese hanzi character about it's meaning in two sentences. Don't add anything unnecessary.")
//                        // Say about it's pronunciation, meaning and history. Explain it as Chinese character, and explain it in English.
//                        answer = response.content
                
                // Consume the queue in order
                while !paragraphQueue.isEmpty {
                    let index = translatedCount
                    let text = paragraphQueue.removeFirst()
                    let itemStart = Date()
                    do {
                        let response = try await {
                            if useAppleIntelligence {
                                return try await llmSession.respond(to: "Translate the following text from \(sourceLanguage?.languageCode ?? "") to \(targetLanguage?.languageCode ?? ""). Only output the input's translation, no other content. Input: \(text)").content
                            } else {
                                return try await mtSession.translate(text).targetText
                            }
                        }()
                        
                        paragraphResults[index] = response
                    } catch {
                        paragraphResults[index] = text // fallback keep original
                    }
                    let dt = Date().timeIntervalSince(itemStart)
                    // Update a simple running average
                    if translatedCount == 0 {
                        averageSecondsPerItem = dt
                    } else {
                        let n = Double(translatedCount)
                        averageSecondsPerItem = (averageSecondsPerItem * n + dt) / (n + 1)
                    }
                    translatedCount += 1
                }
                
                // Once done, rebuild HTML files from results and export EPUB
                guard translatedCount == totalParagraphs, let folder = workingFolder else { return }
                
                // Walk files again and apply replacements
                var resultIndex = 0
                for file in htmlFiles {
                    guard let data = try? Data(contentsOf: file), let html = String(data: data, encoding: .utf8) else { continue }
                    let paragraphs = EpubIO.extractParagraphs(from: html, wideMatch: useAppleIntelligence)
                    var replacements: [Range<String.Index>: String] = [:]
                    for p in paragraphs {
                        if let translated = paragraphResults[resultIndex] {
                            replacements[p.range] = translated
                        }
                        resultIndex += 1
                    }
                    let newHTML = EpubIO.replaceParagraphs(in: html, replacements: replacements)
                    if let newData = newHTML.data(using: .utf8) {
                        try? newData.write(to: file)
                    }
                }

                // Update OPF title with translated value if we queued it
                if let tIndex = titleQueueIndex, let opf = opfURL, let translatedTitle = paragraphResults[tIndex] {
                    EpubIO.writeTitle(translatedTitle, to: opf)
                    if let identifier = targetLanguage?.minimalIdentifier {
                        EpubIO.writeLanguage(identifier, to: opf)
                    }
                }
                
                // Zip to output
                let out = FileManager.default.temporaryDirectory.appendingPathComponent("translated-\(UUID().uuidString).epub")
                do {
                    await try EpubIO.zipEPUB(from: folder, to: out)
                    await MainActor.run {
                        self.exportURL = out
                        self.isTranslating = false
                    }
                } catch {
                    await MainActor.run {
                        self.translationError = String(describing: error)
                        self.isTranslating = false
                    }
                }
            }
    }
}

extension View {
    func onChange<each V: Equatable>(
        of value: repeat each V,
        initial: Bool = false,
        _ action: @escaping () -> Void
    ) -> some View {
        var result = AnyView(self)
        for v in repeat each value {
            result = AnyView(result.onChange(of: v, initial: initial, action))
        }
        return result
    }
}
