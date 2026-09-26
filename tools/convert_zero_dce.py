#!/usr/bin/env python3
# R1-S7: Zero-DCE++ PyTorch 가중치 → Core ML(.mlpackage) 변환 스크립트. Mac 세션에서 실행한다.
#
# 준비(Python 3.10~3.12 권장):
#   python3 -m venv .venv && source .venv/bin/activate
#   pip install torch coremltools pillow numpy
#   git clone --depth 1 https://github.com/Li-Chongyi/Zero-DCE_extension.git ~/src/Zero-DCE_extension
#
# 사용법:
#   python3 tools/convert_zero_dce.py --repo ~/src/Zero-DCE_extension \
#       --out TripShot/Resources/ML/ZeroDCEpp.mlpackage --size 512 [--check sample.jpg]
#
# 설계:
#   - 네트워크(곡선 파라미터 맵 A 추정)만 Core ML로 옮긴다. 입력 512×512 RGB(0~1) → 출력 `curve` (1,3,512,512), tanh(−1~1).
#   - 원본 forward의 다운샘플·업샘플·LE 곡선 8회 반복은 넣지 않는다. 앱(Swift, TripShot/Enhance/LowLight.swift)이
#     입력을 512로 줄여 넣고, A 맵을 풀해상도로 업샘플한 뒤 Metal 커널로 픽셀 단위 곡선을 적용한다.
#   - Zero-DCE++는 연구용 라이선스다(PLAN §7). 개인 사용 앱에만 쓴다.
#
# 주의: 이 스크립트는 클라우드 세션에서 실행해 보지 못했다. `model.py`의 레이어 이름(e_conv1~e_conv7, 각 층은
#       CSDN_Tem = depth_conv + point_conv)과 forward 구조는 원 저장소(Zero-DCE++/model.py) 기준으로 옮겨 적었다.
#       다르면 아래 CurveNet.forward를 model.py의 forward에 맞게 고친다.

import argparse
import os
import sys

import numpy as np
import torch
import torch.nn as nn

LICENSE_NOTE = "Zero-DCE++ (Li et al., TPAMI 2021) — research-only license, personal use only"
SOURCE_URL = "https://github.com/Li-Chongyi/Zero-DCE (Zero-DCE++/snapshots_Zero_DCE++/Epoch99.pth)"


class CurveNet(nn.Module):
    """enhance_net_nopool에서 곡선 파라미터 맵 A까지만 계산하는 래퍼.

    model.py의 forward를 scale_factor=1 기준으로 복사하되, 업샘플과 LE 곡선 반복(enhance)은 뺀다.
    원본:
        x1 = relu(e_conv1(x_down))
        x2 = relu(e_conv2(x1))
        x3 = relu(e_conv3(x2))
        x4 = relu(e_conv4(x3))
        x5 = relu(e_conv5(cat([x3, x4], 1)))
        x6 = relu(e_conv6(cat([x2, x5], 1)))
        x_r = tanh(e_conv7(cat([x1, x6], 1)))
    """

    def __init__(self, net):
        super().__init__()
        self.net = net

    def forward(self, x):
        n = self.net
        relu = torch.relu  # 원본의 nn.ReLU(inplace=True)와 같은 연산(trace에서 inplace 부작용 피함)
        x1 = relu(n.e_conv1(x))
        x2 = relu(n.e_conv2(x1))
        x3 = relu(n.e_conv3(x2))
        x4 = relu(n.e_conv4(x3))
        x5 = relu(n.e_conv5(torch.cat([x3, x4], 1)))
        x6 = relu(n.e_conv6(torch.cat([x2, x5], 1)))
        return torch.tanh(n.e_conv7(torch.cat([x1, x6], 1)))


def load_network(repo):
    """원 저장소의 model.py를 import해 가중치를 올린다(scale_factor=1)."""
    pp_dir = os.path.join(repo, "Zero-DCE++")
    if not os.path.isdir(pp_dir):
        sys.exit(f"Zero-DCE++ 폴더가 없습니다: {pp_dir}")
    sys.path.insert(0, pp_dir)
    import model  # noqa: E402  (Zero-DCE++/model.py)

    net = model.enhance_net_nopool(scale_factor=1)
    weights = os.path.join(pp_dir, "snapshots_Zero_DCE++", "Epoch99.pth")
    if not os.path.isfile(weights):
        sys.exit(f"가중치 파일이 없습니다: {weights}")
    state = torch.load(weights, map_location="cpu")
    # DataParallel로 저장된 경우 "module." 접두어를 뗀다(원본 lowlight_test.py는 접두어 없이 로드).
    state = {k[len("module."):] if k.startswith("module.") else k: v for k, v in state.items()}
    net.load_state_dict(state)
    net.eval()
    params = sum(p.numel() for p in net.parameters())
    print(f"가중치 로드: {weights} (파라미터 {params:,}개)")
    return net


def to_input_tensor(path, size):
    """샘플 이미지를 size×size로 줄여 0~1 NCHW 텐서와 PIL 이미지를 돌려준다.
    앱과 같게 비율을 무시하고 늘인다(곡선 맵은 저주파라 무방)."""
    from PIL import Image

    img = Image.open(path).convert("RGB").resize((size, size), Image.BILINEAR)
    arr = np.asarray(img, dtype=np.float32) / 255.0
    tensor = torch.from_numpy(arr).permute(2, 0, 1).unsqueeze(0)
    return tensor, img


def main():
    ap = argparse.ArgumentParser(description="Zero-DCE++ → Core ML 변환 (A 맵만 출력)")
    ap.add_argument("--repo", required=True, help="Zero-DCE 저장소 클론 경로")
    ap.add_argument("--out", default="TripShot/Resources/ML/ZeroDCEpp.mlpackage", help="출력 .mlpackage 경로")
    ap.add_argument("--size", type=int, default=512, help="모델 입력 한 변(앱의 LowLightEnhancer.modelInputSize와 같아야 함)")
    ap.add_argument("--check", help="PyTorch vs Core ML 비교용 샘플 이미지(jpg/png). macOS에서만 예측 가능")
    ap.add_argument("--fp32", action="store_true", help="계산 정밀도를 FLOAT32로(기본은 mlprogram 기본값 FLOAT16)")
    args = ap.parse_args()

    import coremltools as ct

    net = load_network(args.repo)
    wrapper = CurveNet(net).eval()

    size = args.size
    example = torch.rand(1, 3, size, size)
    with torch.no_grad():
        traced = torch.jit.trace(wrapper, example)

    convert_kwargs = dict(
        inputs=[ct.ImageType(name="image", shape=(1, 3, size, size), scale=1 / 255.0,
                             color_layout=ct.colorlayout.RGB)],
        outputs=[ct.TensorType(name="curve")],
        minimum_deployment_target=ct.target.iOS17,
        compute_units=ct.ComputeUnit.ALL,
        convert_to="mlprogram",
    )
    if args.fp32:
        convert_kwargs["compute_precision"] = ct.precision.FLOAT32
    mlmodel = ct.convert(traced, **convert_kwargs)

    # 메타데이터: 라이선스·출처·입력 크기
    mlmodel.author = "Li et al. (Zero-DCE++), converted for TripShot"
    mlmodel.license = LICENSE_NOTE
    mlmodel.short_description = (
        "Zero-DCE++ curve parameter map A (tanh, -1..1). "
        "Apply x = x + A*(x^2 - x) 8 times per channel at full resolution (sRGB gamma space)."
    )
    mlmodel.version = "1.0"
    mlmodel.user_defined_metadata["source"] = SOURCE_URL
    mlmodel.user_defined_metadata["input_size"] = str(size)
    mlmodel.user_defined_metadata["iterations"] = "8"
    mlmodel.input_description["image"] = f"RGB {size}x{size}, sRGB gamma, 0..255 (scaled to 0..1)"
    mlmodel.output_description["curve"] = f"(1,3,{size},{size}) float, tanh curve map"

    out_dir = os.path.dirname(os.path.abspath(args.out))
    os.makedirs(out_dir, exist_ok=True)
    mlmodel.save(args.out)
    print(f"저장: {args.out}")

    if args.check:
        tensor, pil = to_input_tensor(args.check, size)
        with torch.no_grad():
            ref = wrapper(tensor).numpy()
        try:
            pred = mlmodel.predict({"image": pil})
        except Exception as e:  # 리눅스 등 Core ML 런타임이 없는 환경
            print(f"Core ML 예측 불가(macOS 필요): {e}")
            return
        got = np.asarray(pred["curve"], dtype=np.float32).reshape(ref.shape)
        err = np.abs(got - ref)
        print(f"A 맵 비교: 최대 오차 {err.max():.5f}, 평균 오차 {err.mean():.6f}")
        print(f"A 범위: PyTorch [{ref.min():.3f}, {ref.max():.3f}] / Core ML [{got.min():.3f}, {got.max():.3f}]")
        # FLOAT16 계산이면 1e-2 안쪽이 정상. 이보다 크면 --fp32로 다시 변환해 비교한다.
        if err.max() > 2e-2:
            print("경고: 오차가 큽니다. --fp32로 다시 변환해 비교하세요.")


if __name__ == "__main__":
    main()
