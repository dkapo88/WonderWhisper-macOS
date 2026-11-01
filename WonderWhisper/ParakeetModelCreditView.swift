import SwiftUI

/// CC-BY-4.0 attribution for a Parakeet model: the chain, a link per work, and the licence.
struct ParakeetModelCreditView: View {
  let credit: ParakeetModelCredit

  var body: some View {
    LabeledContent {
      VStack(alignment: .trailing, spacing: DesignTokens.Spacing.xxSmall) {
        ForEach(credit.links, id: \.url) { link in
          Link(link.title, destination: link.url)
        }
        Link("Licence: \(credit.licenseName)", destination: credit.licenseURL)
      }
      .font(.caption)
    } label: {
      Text("Credit")
      Text(credit.summary)
    }
  }
}
