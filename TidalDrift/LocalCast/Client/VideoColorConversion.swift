import CoreVideo
import simd

/// YCbCr conversion rows shared by the Metal fragment shader and color tests.
/// Four-float rows avoid Swift/Metal float3 alignment differences.
struct VideoColorConversion {
    var red: SIMD4<Float>
    var green: SIMD4<Float>
    var blue: SIMD4<Float>

    init(pixelFormat: OSType, matrix: CFString? = nil) {
        let kr: Float
        let kb: Float
        switch matrix {
        case kCVImageBufferYCbCrMatrix_ITU_R_601_4: (kr, kb) = (0.299, 0.114)
        case kCVImageBufferYCbCrMatrix_ITU_R_2020: (kr, kb) = (0.2627, 0.0593)
        default: (kr, kb) = (0.2126, 0.0722)
        }
        let videoRange = pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let yScale: Float = videoRange ? 255.0 / 219.0 : 1
        let chromaScale: Float = videoRange ? 255.0 / 224.0 : 1
        let yOffset: Float = videoRange ? 16.0 / 255.0 : 0
        let chromaOffset: Float = 128.0 / 255.0
        let kg = 1 - kr - kb
        func row(cb: Float, cr: Float) -> SIMD4<Float> {
            SIMD4(yScale, cb * chromaScale, cr * chromaScale,
                -yScale * yOffset - (cb + cr) * chromaScale * chromaOffset)
        }
        red = row(cb: 0, cr: 2 * (1 - kr))
        green = row(cb: -2 * kb * (1 - kb) / kg, cr: -2 * kr * (1 - kr) / kg)
        blue = row(cb: 2 * (1 - kb), cr: 0)
    }

    init(imageBuffer: CVImageBuffer) {
        let matrix = CVBufferCopyAttachment(imageBuffer, kCVImageBufferYCbCrMatrixKey, nil) as? String
        self.init(pixelFormat: CVPixelBufferGetPixelFormatType(imageBuffer), matrix: matrix as CFString?)
    }

    func rgb(y: Float, cb: Float, cr: Float) -> SIMD3<Float> {
        let sample = SIMD4(y, cb, cr, 1)
        return SIMD3(simd_dot(red, sample), simd_dot(green, sample), simd_dot(blue, sample))
    }
}
