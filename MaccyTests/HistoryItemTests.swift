import AppKit
import Testing
import Defaults
@testable import Maccy

private final class BundleToken {}

private func textImage(_ text: String) -> NSImage {
  let string = NSAttributedString(string: text, attributes: [
    .font: NSFont.boldSystemFont(ofSize: 48),
    .foregroundColor: NSColor.black
  ])
  let size = NSSize(width: string.size().width + 40, height: string.size().height + 40)
  return NSImage(size: size, flipped: false) { rect in
    NSColor.white.setFill()
    rect.fill()
    string.draw(at: NSPoint(x: 20, y: 20))
    return true
  }
}

private let stringTitleCases: [(input: String, title: String)] = [
  ("foo", "foo"),
  ("   foo bar   ", "···foo bar···"),
  ("\nfoo\nbar\n", "⏎foo⏎bar⏎"),
  ("\tfoo\tbar\t", "⇥foo⇥bar⇥")
]

private let objectReplacementTitleCases: [(input: String, title: String)] = [
  ("\u{FFFC}foo\u{FFFC}bar\u{FFFC}", "foobar"),
  ("\u{FFFC}\u{FFFC}", "")
]

extension SharedStateTests {
  @MainActor
  struct HistoryItemTests {
    @Test("Sorted pins place letters before symbols")
    func sortedPinsPlacesLettersBeforeSymbols() {
      #expect(
        HistoryItem.sortedPins(["/", "c", "[", "b", "-", "\\", "y"]) ==
        ["b", "c", "y", "-", "/", "[", "\\"]
      )
    }

    @Test("Title for string", arguments: stringTitleCases)
    func titleForString(input: String, title: String) {
      #expect(historyItem(input).title == title)
    }

    // U+FFFC arrives from rich text with inline attachments and hangs CoreText
    // on macOS 26. See https://github.com/p0deje/Maccy/issues/1520.
    @Test("Title without object replacement characters", arguments: objectReplacementTitleCases)
    func titleWithObjectReplacementCharacters(input: String, title: String) {
      #expect(historyItem(input).title == title)
    }

    @Test("Title for RTF")
    func titleWithRTF() {
      let rtf = NSAttributedString(string: "foo").rtf(
        from: NSRange(0...2),
        documentAttributes: [:]
      )
      #expect(historyItem(rtf, .rtf).title == "foo")
    }

    @Test("Title for HTML")
    func titleWithHTML() {
      let html = "<a href='#'>foo</a>".data(using: .utf8)
      #expect(historyItem(html, .html).title == "foo")
    }

    @Test("Image has an empty title")
    func image() throws {
      let image = try #require(NSImage(named: "NSBluetoothTemplate"))
      #expect(historyItem(image).title == "")
    }

    @Test("Image title becomes the recognized text")
    func imageTitleBecomesRecognizedText() async throws {
      let item = historyItem(textImage("Hello Maccy"))
      let deadline = ContinuousClock.now + .seconds(10)
      while item.title.isEmpty && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(100))
      }
      #expect(item.title == "Hello Maccy")
    }

    @Test("Title for file", arguments: ["/tmp/foo.bar", "/tmp/产品培训/产品培训.txt"])
    func file(path: String) {
      let url = URL(fileURLWithPath: path)
      #expect(historyItem(url).title == "file://\(path)")
    }

    @Test("Text from Universal Clipboard")
    func textFromUniversalClipboard() {
      let url = URL(fileURLWithPath: "/tmp/foo.bar")
      let fileURLContent = HistoryItemContent(
        type: NSPasteboard.PasteboardType.fileURL.rawValue,
        value: url.dataRepresentation
      )
      let textContent = HistoryItemContent(
        type: NSPasteboard.PasteboardType.string.rawValue,
        value: url.lastPathComponent.data(using: .utf8)
      )
      let universalClipboardContent = HistoryItemContent(
        type: NSPasteboard.PasteboardType.universalClipboard.rawValue,
        value: "".data(using: .utf8)
      )
      let item = HistoryItem()
      Storage.shared.context.insert(item)
      item.contents = [fileURLContent, textContent, universalClipboardContent]
      item.title = item.generateTitle()
      #expect(item.title == "foo.bar")
    }

    @Test("Image from Universal Clipboard")
    func imageFromUniversalClipboard() throws {
      let url = try #require(Bundle(for: BundleToken.self).url(forResource: "guy", withExtension: "jpeg"))
      let fileURLContent = HistoryItemContent(
        type: NSPasteboard.PasteboardType.fileURL.rawValue,
        value: url.dataRepresentation
      )
      let universalClipboardContent = HistoryItemContent(
        type: NSPasteboard.PasteboardType.universalClipboard.rawValue,
        value: "".data(using: .utf8)
      )
      let item = HistoryItem()
      Storage.shared.context.insert(item)
      item.contents = [fileURLContent, universalClipboardContent]
      #expect(item.hasImage)
      #expect(item.imageData == (try Data(contentsOf: url)))
    }

    @Test("File from Universal Clipboard")
    func fileFromUniversalClipboard() {
      let url = URL(fileURLWithPath: "/tmp/foo.bar")
      let fileURLContent = HistoryItemContent(
        type: NSPasteboard.PasteboardType.fileURL.rawValue,
        value: url.dataRepresentation
      )
      let universalClipboardContent = HistoryItemContent(
        type: NSPasteboard.PasteboardType.universalClipboard.rawValue,
        value: "".data(using: .utf8)
      )
      let item = HistoryItem()
      Storage.shared.context.insert(item)
      item.contents = [fileURLContent, universalClipboardContent]
      item.title = item.generateTitle()
      #expect(item.title == "file:///tmp/foo.bar")
    }

    @Test("Item without data has an empty title")
    func itemWithoutData() {
      #expect(historyItem(nil).title == "")
    }

    @Test("Several items can have an empty pin")
    func severalItemsCanHaveEmptyPin() {
      let item1 = historyItem("foo")
      item1.pin = ""
      let item2 = historyItem("bar")
      item2.pin = ""
      #expect(throws: Never.self) {
        try Storage.shared.context.save()
      }
      #expect(item1.pin == "")
      #expect(item2.pin == "")
    }

    @Test("Text is extracted from HTML in-process", arguments: [
      // 192.0.2.1 never answers, so loading the image would hang.
      ("<meta charset=\"utf-8\"><img src=\"https://192.0.2.1/x.png\">", "\u{FFFC}"),
      (
        "<meta charset='utf-8'><span>你好 &amp; world</span><p>a</p><p>b<br>c</p><script>x()</script>",
        "你好 & world\na\nb\nc\n"
      ),
      ("<head><title>t</title></head><ul><li>one</li><li>two</li></ul>", "one\ntwo\n"),
      ("<table><tr><td> Name </td><td>Price</td></tr><tr><td>a</td><td>1</td></tr></table>", "Name\tPrice\na\t1\n"),
      ("<p>\n    hello\n    world\n</p><pre>  x\n  y</pre>", "hello world\n  x\n  y\n"),
      ("<b>foo</b>\u{0}", "foo")
    ])
    func htmlText(html: String, text: String) {
      let start = Date.now
      #expect(historyItem(html.data(using: .utf8), .html).htmlText == text)
      #expect(Date.now.timeIntervalSince(start) < 1)
    }

    @Test("Uncached value reads saved and unsaved values")
    func uncachedValue() throws {
      let type = NSPasteboard.PasteboardType.string.rawValue
      let content = HistoryItemContent(type: type, value: Data("foo".utf8))
      #expect(content.uncachedValue == Data("foo".utf8))

      let item = HistoryItem()
      Storage.shared.context.insert(item)
      item.contents = [content]
      #expect(content.uncachedValue == Data("foo".utf8))
      try Storage.shared.context.save()
      #expect(content.uncachedValue == Data("foo".utf8))

      content.update(value: Data("bar".utf8))
      #expect(content.uncachedValue == Data("bar".utf8))
      try Storage.shared.context.save()
      #expect(content.uncachedValue == Data("bar".utf8))
    }

    @Test("Content values are compared by digest")
    func hasSameValue() {
      let type = NSPasteboard.PasteboardType.string.rawValue
      let foo = HistoryItemContent(type: type, value: Data("foo".utf8))
      #expect(foo.hasSameValue(as: HistoryItemContent(type: type, value: Data("foo".utf8))))
      #expect(!foo.hasSameValue(as: HistoryItemContent(type: type, value: Data("bar".utf8))))
      let empty = HistoryItemContent(type: type, value: Data())
      #expect(!HistoryItemContent(type: type, value: nil).hasSameValue(as: empty))

      let edited = HistoryItemContent(type: type, value: Data("bar".utf8))
      edited.update(value: Data("foo".utf8))
      #expect(foo.hasSameValue(as: edited))
    }

    @Test("Image is detected without decoding")
    func hasImage() throws {
      let image = try #require(NSImage(named: "NSApplicationIcon"))
      #expect(historyItem(image).hasImage)
      #expect(!historyItem("foo").hasImage)
      #expect(!historyItem(nil, .tiff).hasImage)
    }

    private func historyItem(_ value: String?) -> HistoryItem {
      let contents = [
        HistoryItemContent(
          type: NSPasteboard.PasteboardType.string.rawValue,
          value: value?.data(using: .utf8)
        )
      ]
      let item = HistoryItem()
      Storage.shared.context.insert(item)
      item.contents = contents
      item.title = item.generateTitle()

      return item
    }

    private func historyItem(_ data: Data?, _ type: NSPasteboard.PasteboardType) -> HistoryItem {
      let contents = [
        HistoryItemContent(
          type: type.rawValue,
          value: data
        )
      ]
      let item = HistoryItem()
      Storage.shared.context.insert(item)
      item.contents = contents
      item.title = item.generateTitle()

      return item
    }

    private func historyItem(_ value: NSImage) -> HistoryItem {
      let contents = [
        HistoryItemContent(
          type: NSPasteboard.PasteboardType.tiff.rawValue,
          value: value.tiffRepresentation
        )
      ]
      let item = HistoryItem()
      Storage.shared.context.insert(item)
      item.contents = contents
      item.title = item.generateTitle()

      return item
    }

    private func historyItem(_ value: URL) -> HistoryItem {
      let contents = [
        HistoryItemContent(
          type: NSPasteboard.PasteboardType.fileURL.rawValue,
          value: value.dataRepresentation
        ),
        HistoryItemContent(
          type: NSPasteboard.PasteboardType.string.rawValue,
          value: value.lastPathComponent.data(using: .utf8)
        )
      ]
      let item = HistoryItem()
      Storage.shared.context.insert(item)
      item.contents = contents
      item.title = item.generateTitle()

      return item
    }
  }
}
