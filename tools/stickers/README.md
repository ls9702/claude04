# 효과 스티커 그림 만들기

`TripShot/Resources/Stickers/stk_*.png`는 [Fluent Emoji](https://github.com/microsoft/fluentui-emoji)(MIT, Microsoft — `LICENSE-fluentui-emoji.txt`)의 Color SVG를 Mac에서 PNG로 바꾼 것이다.

1. 원본 받기: `assets/<이름>/Color/<이름_소문자>_color.svg` → 작업 폴더에 `svg_<이름>.svg`로 저장
2. `python3 compose.py 9.3 10.2` — 동물 귀·코·수염은 얼굴 SVG에서 도형 번호로 골라 합성(인자는 고양이·토끼 귀를 자르는 높이, viewBox 32 기준)
3. `swiftc -O render.swift -o render && RENDER_SIZE=4096 ./render out_svg out_png` — 투명 여백을 잘라 PNG로
4. 긴 변 720px로 줄여(`sips -Z 720`, 작은 그림은 그대로) `stk_` 접두어를 붙여 복사

기준점(스티커를 얼굴 어디에 맞출지)은 `TripShot/Effects/StickerArt.swift`의 `StickerLibrary`, 크기·위치 배수는 `EffectRenderer.stickerLayers`에 있다.
