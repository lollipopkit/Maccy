import SwiftUI

/// A number text field with a stepper.
///
/// A formatter-based `TextField` silently drops out-of-range input on blur and loses
/// edits when the window closes while it is focused. This field commits on submit,
/// focus loss and disappearance, clamping the value into `range`.
/// See https://github.com/p0deje/Maccy/issues/1292 and https://github.com/p0deje/Maccy/issues/1516.
struct NumberField: View {
  @Binding var value: Int
  let range: ClosedRange<Int>
  let width: CGFloat
  let label: Text

  @State private var text = ""
  @FocusState private var isFocused: Bool

  var body: some View {
    HStack {
      TextField("", text: $text)
        .frame(width: width)
        .accessibilityLabel(label)
        .focused($isFocused)
        .onSubmit(commit)
        .onChange(of: isFocused) { _, isFocused in
          if !isFocused {
            commit()
          }
        }
      Stepper("", value: $value, in: range)
        .labelsHidden()
        .accessibilityLabel(label)
    }
    .onAppear { text = String(value) }
    .onDisappear(perform: commit)
    .onChange(of: value) { _, value in
      text = String(value)
    }
  }

  private func commit() {
    let input = text
      .trimmingCharacters(in: .whitespaces)
      .replacingOccurrences(of: Locale.current.groupingSeparator ?? ",", with: "")
    // Parsed as Double so that out-of-range input of any size clamps instead of being dropped.
    if let number = Double(input), !number.isNaN {
      let clamped = min(max(number.rounded(), Double(range.lowerBound)), Double(range.upperBound))
      value = Int(clamped)
    }
    // Show the committed value, also when the input was invalid or clamped.
    text = String(value)
  }
}
