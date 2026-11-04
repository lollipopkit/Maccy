import Foundation

extension String {
  nonisolated private static let htmlBlockElements: Set<String> = [
    "address", "article", "aside", "blockquote", "dd", "div", "dl", "dt", "figcaption", "figure",
    "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hr", "li", "main", "nav",
    "ol", "p", "pre", "section", "table", "tbody", "tfoot", "thead", "tr", "ul"
  ]
  nonisolated private static let htmlCellElements: Set<String> = ["td", "th"]
  // Rendered as U+FFFC like NSAttributedString does, so a clip with only an image still has content.
  nonisolated private static let htmlReplacedElements: Set<String> = [
    "canvas", "embed", "iframe", "img", "object", "svg", "video"
  ]
  nonisolated private static let htmlSkippedElements: Set<String> = ["head", "noscript", "script", "style", "template"]

  /// Extracts the text of an HTML document in-process.
  ///
  /// `NSAttributedString(html:)` renders the document with WebKit, out of process on macOS 26+,
  /// and waits for every `<img>` to load. A slow or unreachable image host blocks the caller,
  /// and merely recording a clip makes network requests.
  /// See https://github.com/p0deje/Maccy/issues/1610.
  nonisolated init?(html data: Data) {
    // Pasteboard HTML is UTF-8 in practice, and libxml2 misses some charset declarations.
    guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) else {
      return nil
    }

    // Control characters such as a trailing NUL are not allowed in XML and make parsing fail.
    let sanitized = String(String.UnicodeScalarView(html.unicodeScalars.filter {
      $0.value >= 0x20 || $0 == "\t" || $0 == "\n" || $0 == "\r"
    }))
    guard let root = try? XMLDocument(xmlString: sanitized, options: [.documentTidyHTML]).rootElement() else {
      return nil
    }

    var text = ""
    Self.appendText(of: root, to: &text, preservingWhitespace: false)
    self = text.replacing(/\ +(?=[\n\t])|\ +$/, with: "")
  }

  nonisolated private static func appendText(of node: XMLNode, to text: inout String, preservingWhitespace: Bool) {
    guard node.kind != .text else {
      appendTextNode(node.stringValue ?? "", to: &text, preservingWhitespace: preservingWhitespace)
      return
    }

    let name = node.name?.lowercased() ?? ""
    if htmlSkippedElements.contains(name) {
      return
    }
    if name == "br" {
      text += "\n"
      return
    }
    if htmlReplacedElements.contains(name) {
      text += "\u{FFFC}"
      return
    }

    let isBlock = htmlBlockElements.contains(name)
    if isBlock, !text.isEmpty, !text.hasSuffix("\n") {
      text += "\n"
    }
    if htmlCellElements.contains(name), !text.isEmpty, !text.hasSuffix("\n") {
      text += "\t"
    }
    node.children?.forEach {
      appendText(of: $0, to: &text, preservingWhitespace: preservingWhitespace || name == "pre")
    }
    if isBlock, !text.hasSuffix("\n") {
      text += "\n"
    }
  }

  // Collapses whitespace like a browser does outside of <pre>.
  nonisolated private static func appendTextNode(_ string: String, to text: inout String, preservingWhitespace: Bool) {
    guard !preservingWhitespace else {
      text += string
      return
    }

    var collapsed = string.replacing(/[ \t\n\r\f]+/, with: " ")
    if text.isEmpty || text.hasSuffix("\n") || text.hasSuffix("\t") || text.hasSuffix(" ") {
      collapsed = String(collapsed.drop { $0 == " " })
    }
    text += collapsed
  }
}
