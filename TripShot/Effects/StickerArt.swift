// 효과 스티커 그림: 번들 PNG(`Resources/Stickers/stk_*.png`, Fluent Emoji MIT 벡터를 Mac에서 변환)를 한 번만 읽어 CIImage로 캐시한다.
import CoreImage
import Foundation

/// 캐시된 스티커 한 장. `anchor`는 이 그림에서 얼굴 기준점에 맞출 점(픽셀, CIImage 좌표 — 원점 좌하단).
struct StickerArt {
    let image: CIImage
    let anchor: CGPoint

    var width: CGFloat { image.extent.width }

    /// 번들 그림을 읽는다. `u`·`v`는 기준점(0~1, v는 아래 0 → 위 1). 파일이 없으면 nil(그 층은 건너뛴다).
    static func asset(_ name: String, u: CGFloat = 0.5, v: CGFloat = 0.5, bundle: Bundle = .main) -> StickerArt? {
        let file = "stk_" + name
        guard let url = bundle.url(forResource: file, withExtension: "png")
                ?? bundle.url(forResource: file, withExtension: "png", subdirectory: "Stickers"),
              let image = CIImage(contentsOf: url) else { return nil }
        // 원점을 (0,0)으로 맞춘다.
        let e = image.extent
        let normalized = image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
        return StickerArt(image: normalized, anchor: CGPoint(x: e.width * u, y: e.height * v))
    }

    /// 기준점을 `target`에 맞춰 폭 `width`(픽셀)로, `angle`(라디안)만큼 돌려 놓는다. `stretchY`로 세로만 늘릴 수 있다.
    func placed(at target: CGPoint, width targetWidth: CGFloat, angle: CGFloat, stretchY: CGFloat = 1) -> CIImage {
        let s = targetWidth / max(width, 1)
        let t = CGAffineTransform(translationX: target.x, y: target.y)
            .rotated(by: angle)
            .scaledBy(x: s, y: s * stretchY)
            .translatedBy(x: -anchor.x, y: -anchor.y)
        return image.transformed(by: t)
    }
}

/// 스티커 그림 모음. 정적 상수라 처음 쓸 때 한 번만 읽는다(Swift 정적 초기화는 스레드 안전).
/// 기준점(u, v)은 그림을 보고 정했다: 귀·모자는 아래 가운데(머리 위에 얹음), 코·수염은 코 위치, 안경은 두 렌즈 중심.
enum StickerLibrary {
    static let dogEars = StickerArt.asset("ears_dog", u: 0.5, v: 1.0)
    static let dogNose = StickerArt.asset("nose_dog", u: 0.5, v: 0.5)
    static let dogTongue = StickerArt.asset("tongue_dog", u: 0.5, v: 1.0)
    static let catEars = StickerArt.asset("ears_cat", u: 0.5, v: 0.0)
    static let catWhiskers = StickerArt.asset("whiskers_cat", u: 0.5, v: 0.62)
    static let rabbitEars = StickerArt.asset("ears_rabbit", u: 0.5, v: 0.0)
    static let rabbitWhiskers = StickerArt.asset("whiskers_rabbit", u: 0.5, v: 0.55)
    static let bearEars = StickerArt.asset("ears_bear", u: 0.5, v: 0.1)
    static let bearMuzzle = StickerArt.asset("nose_bear", u: 0.5, v: 0.65)
    static let mouseEars = StickerArt.asset("ears_mouse", u: 0.5, v: 0.1)
    static let mouseWhiskers = StickerArt.asset("whiskers_mouse", u: 0.5, v: 0.6)
    static let crown = StickerArt.asset("crown", u: 0.5, v: 0.05)
    static let cherryBlossom = StickerArt.asset("cherry_blossom")
    static let hibiscus = StickerArt.asset("hibiscus")
    static let redHeart = StickerArt.asset("red_heart")
    static let sparklingHeart = StickerArt.asset("sparkling_heart")
    static let sunglasses = StickerArt.asset("sunglasses", u: 0.5, v: 0.5)
    static let glasses = StickerArt.asset("glasses", u: 0.5, v: 0.5)
    static let ribbon = StickerArt.asset("ribbon")
    static let topHat = StickerArt.asset("top_hat", u: 0.5, v: 0.08)
    static let gradCap = StickerArt.asset("graduation_cap", u: 0.5, v: 0.3)
    static let butterfly = StickerArt.asset("butterfly")
    static let halo = StickerArt.asset("halo")
    static let horns = StickerArt.asset("horns", u: 0.5, v: 0.0)
    static let snowflake = StickerArt.asset("snowflake")
}
