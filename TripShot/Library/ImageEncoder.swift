// 렌더된 CGImage를 원본과 같은 포맷(HEIF/JPEG)으로 인코딩하고 보존 메타데이터를 함께 기록한다 (PLAN §3.4).
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// CGImage → HEIF/JPEG Data. 메모리 안에서만 동작하며 파일·사진 보관함을 건드리지 않는다.
enum ImageEncoder {

    /// 출력 포맷. 보정 렌더 출력은 원본과 같은 포맷을 쓴다(PNG 등 그 밖의 원본은 JPEG).
    enum Format: Equatable {
        case heif
        case jpeg

        var uti: UTType {
            switch self {
            case .heif: return .heic
            case .jpeg: return .jpeg
            }
        }

        var fileExtension: String {
            switch self {
            case .heif: return "heic"
            case .jpeg: return "jpg"
            }
        }
    }

    enum EncodeError: Error, Equatable {
        /// 이 기기(또는 시뮬레이터)가 해당 포맷 인코더를 제공하지 않음.
        case unsupportedFormat(String)
        /// `CGImageDestinationFinalize`가 false를 반환함.
        case finalizeFailed
    }

    /// 원본 UTI(`CGImageSourceGetType` 또는 `PHContentEditingInput.uniformTypeIdentifier`) → 출력 포맷.
    /// HEIC/HEIF 계열이면 `.heif`, 그 밖(JPEG·PNG·알 수 없음)은 `.jpeg`.
    static func format(ofUTI uti: String) -> Format {
        if let type = UTType(uti), type.conforms(to: .heic) || type.conforms(to: .heif) {
            return .heif
        }
        let lower = uti.lowercased()
        if lower.contains("heic") || lower.contains("heif") { return .heif }
        return .jpeg
    }

    /// CGImage를 인코딩한다. `properties`는 보통 `ImageMetadata.preservedProperties` + `withPixelSize` 결과.
    /// 압축 품질과 Orientation=1(렌더 결과는 항상 `.up`)은 여기서 덮어쓴다.
    static func encode(_ image: CGImage, format: Format, properties: [CFString: Any], quality: Double = 0.92) throws -> Data {
        let data = NSMutableData()
        let type = format.uti.identifier as CFString
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, type, 1, nil) else {
            throw EncodeError.unsupportedFormat(format.uti.identifier)
        }
        var props = properties
        props[kCGImageDestinationLossyCompressionQuality] = min(max(quality, 0), 1)
        props[kCGImagePropertyOrientation] = 1
        CGImageDestinationAddImage(destination, image, props as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw EncodeError.finalizeFailed
        }
        return data as Data
    }
}
