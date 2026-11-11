import SwiftUI

struct BrandHeader: View {
    var body: some View {
        HStack(spacing: 9) {
            Image("BrandMark").resizable().scaledToFit().frame(width: 34, height: 34).clipShape(RoundedRectangle(cornerRadius: 8)).accessibilityHidden(true)
            Text("KontYT").font(.headline.bold())
        }.accessibilityElement(children: .combine)
    }
}
extension View {
    func kontytBrand() -> some View {
        navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .principal) { BrandHeader() } }
    }
}
