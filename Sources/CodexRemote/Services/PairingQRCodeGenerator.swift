import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

enum PairingQRCodeGeneratorError: LocalizedError, Equatable {
    case emptyPayload
    case invalidScale
    case generationFailed
    case renderingFailed

    var errorDescription: String? {
        switch self {
        case .emptyPayload:
            "O conteúdo do QR Code está vazio."
        case .invalidScale:
            "A escala do QR Code é inválida."
        case .generationFailed, .renderingFailed:
            "Não foi possível gerar o QR Code."
        }
    }
}

struct PairingQRCodeGenerator {
    private static let quietZoneModules = 4
    private static let maximumPixelsPerModule = 64

    private let context: CIContext

    init(context: CIContext = CIContext(options: [.cacheIntermediates: false])) {
        self.context = context
    }

    func makeImage(
        for payload: String,
        pixelsPerModule: Int = 8
    ) throws -> CGImage {
        guard !payload.isEmpty else {
            throw PairingQRCodeGeneratorError.emptyPayload
        }
        guard (1...Self.maximumPixelsPerModule).contains(pixelsPerModule) else {
            throw PairingQRCodeGeneratorError.invalidScale
        }

        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"

        guard let rawQRCode = filter.outputImage else {
            throw PairingQRCodeGeneratorError.generationFailed
        }

        let rawExtent = rawQRCode.extent.integral
        guard !rawExtent.isEmpty,
              rawExtent.minX.isFinite,
              rawExtent.minY.isFinite,
              rawExtent.width.isFinite,
              rawExtent.height.isFinite
        else {
            throw PairingQRCodeGeneratorError.generationFailed
        }

        let quietZone = CGFloat(Self.quietZoneModules)
        let canvasBounds = CGRect(
            x: 0,
            y: 0,
            width: rawExtent.width + (quietZone * 2),
            height: rawExtent.height + (quietZone * 2)
        )
        let positionedQRCode = rawQRCode.transformed(
            by: CGAffineTransform(
                translationX: quietZone - rawExtent.minX,
                y: quietZone - rawExtent.minY
            )
        )
        let whiteBackground = CIImage(color: .white).cropped(to: canvasBounds)
        let paddedQRCode = positionedQRCode
            .composited(over: whiteBackground)
            .cropped(to: canvasBounds)

        let scale = CGFloat(pixelsPerModule)
        let scaledQRCode = paddedQRCode.transformed(
            by: CGAffineTransform(scaleX: scale, y: scale)
        )
        let renderBounds = scaledQRCode.extent.integral

        guard let image = context.createCGImage(scaledQRCode, from: renderBounds) else {
            throw PairingQRCodeGeneratorError.renderingFailed
        }
        return image
    }
}
