// About window (App menu → Über Tapedeck) and the manual (Help menu → Tapedeck Handbuch).
import SwiftUI

struct AboutView: View {
    private static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"

    private func text(_ s: String, size: CGFloat = 12, color: Color = Deck.ink) -> some View {
        Text(s).font(.system(size: size)).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text("tapedeck").font(.system(size: 15, weight: .bold)).tracking(-0.2).foregroundStyle(Deck.ink)
                    text("Version \(Self.version)", color: Deck.label)
                    text("© 2026 Moritz Poth", color: Deck.label)
                }
            }
            text("Tapedeck ist freie Software: Du darfst es unter den Bedingungen der GNU General Public License, Version 3 oder später, weitergeben und verändern.")
            text("Es kommt OHNE JEDE GEWÄHRLEISTUNG – die Nutzung erfolgt auf eigene Gefahr.")
            HStack(alignment: .top, spacing: 18) {
                VStack(spacing: 8) {
                    KeyTray {
                        Button("Quellcode") { NSWorkspace.shared.open(URL(string: "https://github.com/moritz-poth/Tapedeck")!) }
                            .buttonStyle(DeckKeyStyle()).help("Quellcode auf GitHub öffnen")
                        Button("Lizenz") {
                            if let url = Bundle.main.url(forResource: "LICENSE", withExtension: "txt") { NSWorkspace.shared.open(url) }
                            else { NSWorkspace.shared.open(URL(string: "https://www.gnu.org/licenses/gpl-3.0.html")!) }
                        }
                        .buttonStyle(DeckKeyStyle()).help("Lizenztext (GPL 3) öffnen")
                    }
                    KeyLabels(texts: ["quellcode", "lizenz"])
                }
                VStack(spacing: 8) {
                    KeyTray {
                        Button("Kaffee spendieren") { NSWorkspace.shared.open(URL(string: "https://buymeacoffee.com/moritzpoth")!) }
                            .buttonStyle(DeckKeyStyle()).help("buymeacoffee.com/moritzpoth öffnen")
                    }
                    KeyLabels(texts: ["kaffee"])
                }
            }
            .padding(.top, 4)
            Rectangle().fill(Deck.rgb(0xb5b7ba)).frame(height: 1)
            text("Gefällt dir Tapedeck? Dann freue ich mich, wenn du mir einen Kaffee spendierst.", size: 11, color: Deck.label)
            text("Tapedeck sammelt keine Daten. Es fragt nur bei GitHub nach, ob es eine neue Version gibt.", size: 11, color: Deck.label)
        }
        .padding(28)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .background(Deck.panel)
        .environment(\.colorScheme, .light)
    }
}

/// The manual: `help/de.md` in the app bundle, shown with a small Markdown renderer
/// (title, headings, paragraphs, bullet lists, inline bold/code, screenshots from `help/images/`).
struct ManualView: View {
    /// Text to show instead of the bundled manual (tests).
    var text: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    switch block {
                    case .title(let s):
                        Text(inline(s)).font(.custom("HelveticaNeue-Light", size: 26)).foregroundStyle(Deck.ink).padding(.bottom, 6)
                    case .heading(let s):
                        Text(inline(s)).font(.system(size: 14, weight: .bold)).foregroundStyle(Deck.ink).padding(.top, 14)
                    case .bullet(let s):
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("•").font(.system(size: 12)).foregroundStyle(Deck.label)
                            Text(inline(s)).font(.system(size: 12)).foregroundStyle(Deck.label).fixedSize(horizontal: false, vertical: true)
                        }
                    case .paragraph(let s):
                        Text(inline(s)).font(.system(size: 12)).foregroundStyle(Deck.label).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                    case .image(let file):
                        if let url = Bundle.main.url(forResource: file, withExtension: nil, subdirectory: "help/images"),
                           let img = NSImage(contentsOf: url) {
                            // 2x screenshots: shown at their point size, never wider than the text
                            Image(nsImage: img).resizable().aspectRatio(contentMode: .fit).frame(maxWidth: img.size.width).padding(.vertical, 6)
                        }
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
        .background(Deck.panel)
        .environment(\.colorScheme, .light)
    }

    enum Block: Equatable { case title(String), heading(String), bullet(String), paragraph(String), image(String) }

    private var blocks: [Block] {
        if let text { return Self.parse(text) }
        let url = Bundle.main.url(forResource: "de", withExtension: "md", subdirectory: "help")
        return Self.parse(url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "Das Handbuch fehlt in dieser Kopie der App.")
    }

    static func parse(_ text: String) -> [Block] {
        var out: [Block] = []
        var para: [String] = []
        func flush() { if !para.isEmpty { out.append(.paragraph(para.joined(separator: " "))); para = [] } }
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush() }
            else if line.hasPrefix("## ") { flush(); out.append(.heading(String(line.dropFirst(3)))) }
            else if line.hasPrefix("# ") { flush(); out.append(.title(String(line.dropFirst(2)))) }
            else if line.hasPrefix("- ") { flush(); out.append(.bullet(String(line.dropFirst(2)))) }
            else if line.hasPrefix("!["), let open = line.lastIndex(of: "("), line.hasSuffix(")") {
                flush(); out.append(.image(String(line[line.index(after: open)..<line.index(before: line.endIndex)])))
            }
            else { para.append(line) }
        }
        flush()
        return out
    }

    private func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s)) ?? AttributedString(s)
    }
}
