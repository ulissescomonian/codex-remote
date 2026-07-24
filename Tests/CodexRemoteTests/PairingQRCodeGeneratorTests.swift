import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import Testing
import Vision
@testable import CodexRemote

@Suite("Pairing QR Code Generator")
struct PairingQRCodeGeneratorTests {
    @Test("Generated QR Code decodes to the exact payload")
    func generatedQRCodeDecodesExactPayload() throws {
        let payload = "https://chatgpt.com/codex/pair?pairing_code=OFFLINE-TEST-123"
        let image = try PairingQRCodeGenerator().makeImage(for: payload)

        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try VNImageRequestHandler(cgImage: image).perform([request])

        let observation = try #require(request.results?.first)
        #expect(observation.payloadStringValue == payload)
    }

    @Test("Generated QR Code keeps an integer scale and four-module quiet zone")
    func generatedQRCodeHasCrispScaleAndQuietZone() throws {
        let payload = "https://chatgpt.com/codex/pair?pairing_code=QUIET-ZONE-TEST"
        let pixelsPerModule = 7
        let image = try PairingQRCodeGenerator().makeImage(
            for: payload,
            pixelsPerModule: pixelsPerModule
        )

        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        let rawQRCode = try #require(filter.outputImage)
        let expectedModuleCount = Int(rawQRCode.extent.integral.width) + 8

        #expect(image.width == expectedModuleCount * pixelsPerModule)
        #expect(image.height == expectedModuleCount * pixelsPerModule)
        #expect(Set(image.bytes).isSubset(of: [0, 255]))
    }

    @Test("Empty payload is rejected without including content in the error")
    func emptyPayloadIsRejected() {
        do {
            _ = try PairingQRCodeGenerator().makeImage(for: "")
            Issue.record("Um payload vazio deveria falhar")
        } catch {
            #expect(error as? PairingQRCodeGeneratorError == .emptyPayload)
        }
    }

    @Test("Invalid module scales are rejected")
    func invalidScalesAreRejected() {
        for scale in [0, -1, 65] {
            do {
                _ = try PairingQRCodeGenerator().makeImage(
                    for: "https://chatgpt.com/codex/pair?pairing_code=TEST",
                    pixelsPerModule: scale
                )
                Issue.record("A escala \(scale) deveria falhar")
            } catch {
                #expect(error as? PairingQRCodeGeneratorError == .invalidScale)
            }
        }
    }
}

private extension CGImage {
    var bytes: [UInt8] {
        guard let data = dataProvider?.data,
              let pointer = CFDataGetBytePtr(data)
        else {
            return []
        }
        return Array(UnsafeBufferPointer(start: pointer, count: CFDataGetLength(data)))
    }
}
