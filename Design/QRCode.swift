import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

/// QR codes via CoreImage, so nothing has to be bundled for it.
enum QRCode {
    private static let context = CIContext()

    /// Renders `text` at roughly `size` points. Returns nil when the payload is
    /// too long for a QR symbol.
    static func image(for text: String, size: CGFloat = 180) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        // Medium recovery: what the web build uses, and enough for a code that
        // will be read off a screen.
        filter.correctionLevel = "M"

        guard let output = filter.outputImage else { return nil }
        // Scale by an integer factor so the modules stay crisp.
        let scale = max(1, (size / output.extent.width).rounded(.down))
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

struct QRCodeView: View {
    let text: String
    var size: CGFloat = 180

    var body: some View {
        Group {
            if let image = QRCode.image(for: text, size: size) {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size, height: size)
                    .padding(10)
                    .background(.white)
                    .squareEdge(Palette.border)
            }
        }
        .frame(maxWidth: .infinity)
    }
}
