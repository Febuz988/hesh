import CoreImage.CIFilterBuiltins
import SwiftUI

struct QRCodeView: View {
    let text: String
    var body: some View {
        if let img = Self.render(text) {
            Image(uiImage: img).interpolation(.none).resizable().scaledToFit()
                .padding(12).background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.white))
        }
    }

    static func render(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let out = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cg = CIContext().createCGImage(out, from: out.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
