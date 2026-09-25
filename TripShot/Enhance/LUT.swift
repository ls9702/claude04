// .cube 3D LUT 파서와 번들 LUT 로더 (보정 파이프라인 6단계 "색감 룩"에서 사용).
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// .cube 파싱 오류.
enum LUTError: Error, Equatable {
    /// `LUT_3D_SIZE` 줄이 없음
    case missingSize
    /// 크기 값이 지원 범위를 벗어나거나 숫자가 아님
    case invalidSize(String)
    /// 데이터 줄 개수가 size³과 다름
    case valueCountMismatch(expected: Int, actual: Int)
    /// 해석할 수 없는 줄 (1부터 시작하는 줄 번호)
    case parseFailure(line: Int, content: String)
    /// 1D LUT(`LUT_1D_SIZE`)는 지원하지 않음
    case unsupported1D
}

/// 3D LUT. `data`는 Core Image `CIColorCube` 계열이 요구하는 RGBA float32 배열이다.
/// 순서는 red가 가장 빠르게, 그다음 green, blue가 가장 느리게 변한다(.cube 표준과 동일).
struct LUT: Equatable {
    let size: Int
    /// size³ × 4 개의 Float32 (RGBA, alpha = 1.0)
    let data: Data
    let title: String?

    /// Core Image가 받는 큐브 한 변 크기 범위.
    /// TODO(검증): iOS 26의 CIColorCubeWithColorSpace 최대 cubeDimension(64 또는 128)을 실기기에서 확인.
    static let supportedSizes = 2...128

    // MARK: 파싱

    /// .cube 텍스트를 파싱한다. 순수 함수.
    /// 지원: `TITLE`, `LUT_3D_SIZE`, `DOMAIN_MIN`, `DOMAIN_MAX`, `#` 주석(줄 전체·줄 끝), 빈 줄, 공백/탭 구분.
    /// DOMAIN이 0…1이 아니면 값을 0…1로 정규화한다.
    static func parse(_ text: String) throws -> LUT {
        var size: Int?
        var title: String?
        var domainMin: [Float] = [0, 0, 0]
        var domainMax: [Float] = [1, 1, 1]
        var rgb: [Float] = []

        // \r\n, \r 모두 줄바꿈으로 취급
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" })

        for (index, rawLine) in lines.enumerated() {
            let lineNumber = index + 1
            // 줄 끝 주석 제거 (TITLE 안의 #은 드물어 고려하지 않음)
            var line = Substring(rawLine)
            if let hash = line.firstIndex(of: "#") { line = line[..<hash] }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            let tokens = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard let keyword = tokens.first else { continue }

            switch keyword {
            case "TITLE":
                // TITLE "이름" — 따옴표 제거
                let rest = trimmed.dropFirst("TITLE".count).trimmingCharacters(in: .whitespaces)
                title = rest.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            case "LUT_3D_SIZE":
                guard tokens.count == 2, let n = Int(tokens[1]) else {
                    throw LUTError.invalidSize(trimmed)
                }
                guard supportedSizes.contains(n) else { throw LUTError.invalidSize(String(tokens[1])) }
                size = n
            case "LUT_1D_SIZE":
                throw LUTError.unsupported1D
            case "DOMAIN_MIN", "DOMAIN_MAX":
                let values = tokens.dropFirst().compactMap { Float($0) }
                guard values.count == 3 else {
                    throw LUTError.parseFailure(line: lineNumber, content: trimmed)
                }
                if keyword == "DOMAIN_MIN" { domainMin = values } else { domainMax = values }
            case "LUT_3D_INPUT_RANGE", "LUT_1D_INPUT_RANGE":
                // 일부 도구가 쓰는 비표준 키워드. 무시.
                continue
            default:
                // 데이터 줄: 실수 3개
                guard tokens.count == 3,
                      let r = Float(tokens[0]), let g = Float(tokens[1]), let b = Float(tokens[2]) else {
                    throw LUTError.parseFailure(line: lineNumber, content: trimmed)
                }
                rgb.append(contentsOf: [r, g, b])
            }
        }

        guard let n = size else { throw LUTError.missingSize }
        let expected = n * n * n
        let actual = rgb.count / 3
        guard actual == expected else {
            throw LUTError.valueCountMismatch(expected: expected, actual: actual)
        }

        // RGB → RGBA(alpha 1.0), DOMAIN 정규화
        var rgba = [Float]()
        rgba.reserveCapacity(expected * 4)
        for i in 0..<expected {
            for c in 0..<3 {
                let span = domainMax[c] - domainMin[c]
                let v = rgb[i * 3 + c]
                rgba.append(span > 0 ? (v - domainMin[c]) / span : v)
            }
            rgba.append(1.0)
        }
        let data = rgba.withUnsafeBufferPointer { Data(buffer: $0) }
        return LUT(size: n, data: data, title: title)
    }

    /// 테스트·디버그용: `data`를 Float 배열로 되돌린다.
    var floats: [Float] {
        data.withUnsafeBytes { raw in Array(raw.bindMemory(to: Float.self)) }
    }

    // MARK: Core Image

    /// LUT를 입력 이미지에 적용한 결과(강도 100%). `colorSpace`는 LUT 값이 정의된 색공간(보통 sRGB).
    /// Core Image가 작업 색공간 → `colorSpace` 변환 후 큐브를 적용하고 다시 작업 색공간으로 돌린다.
    func ciFilter(input: CIImage, colorSpace: CGColorSpace) -> CIImage {
        let filter = CIFilter.colorCubeWithColorSpace()
        filter.inputImage = input
        filter.cubeDimension = Float(size)
        filter.cubeData = data
        // TODO(검증): CIFilterBuiltins의 colorSpace 프로퍼티 타입(CGColorSpace? 여부). 비옵셔널 값 대입은 양쪽 모두 컴파일됨.
        filter.colorSpace = colorSpace
        return filter.outputImage?.cropped(to: input.extent) ?? input
    }
}

/// 번들의 `Resources/LUT/*.cube`를 파일명(확장자 제외) 키로 로드한다.
enum LUTLibrary {
    /// 앱 번들 LUT. 처음 접근할 때 한 번만 읽는다.
    static let bundled: [String: LUT] = load(from: .main)

    /// 번들에서 .cube 파일을 모두 읽는다. 파싱 실패 파일은 건너뛴다.
    /// XcodeGen 폴더 소스는 리소스를 번들 루트로 평탄화할 수 있어 subdirectory "LUT"와 nil을 모두 찾는다.
    static func load(from bundle: Bundle) -> [String: LUT] {
        var urls: [URL] = []
        urls += bundle.urls(forResourcesWithExtension: "cube", subdirectory: "LUT") ?? []
        urls += bundle.urls(forResourcesWithExtension: "cube", subdirectory: nil) ?? []

        var result: [String: LUT] = [:]
        for url in urls {
            let name = url.deletingPathExtension().lastPathComponent
            if result[name] != nil { continue }
            guard let text = try? String(contentsOf: url, encoding: .utf8),
                  let lut = try? LUT.parse(text) else { continue }
            result[name] = lut
        }
        return result
    }
}
