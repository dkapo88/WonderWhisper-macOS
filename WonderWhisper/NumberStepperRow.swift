import SwiftUI

/// The one pattern for numeric settings: label on the left, "value unit" plus a stepper on
/// the right. Replaces the mix of steppers-with-sentences and bare text fields.
struct NumberStepperRow: View {
  let title: String
  var subtitle: String?
  @Binding var value: Double
  let range: ClosedRange<Double>
  var step: Double = 1
  let unit: String

  var body: some View {
    LabeledContent {
      Stepper(value: $value, in: range, step: step) {
        Text("\(Int(value)) \(unit)")
          .monospacedDigit()
      }
      .accessibilityLabel(title)
      .accessibilityValue("\(Int(value)) \(unit)")
    } label: {
      Text(title)
      if let subtitle {
        Text(subtitle)
      }
    }
  }
}
