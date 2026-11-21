"""移动端资源导出与跨语言协议测试向量生成器的离线单元测试。"""
from __future__ import annotations

import json
from pathlib import Path

from scripts.dump_test_vectors import build_protocol_test_vectors
from scripts.prepare_mobile_assets import (
    MOBILE_ORT_MAX_IR_VERSION,
    MOBILE_ORT_MAX_OPSET,
    _read_onnx_versions,
    export_room_catalog,
)


def test_build_protocol_test_vectors_contract() -> None:
    vectors = build_protocol_test_vectors()
    assert vectors["constants"]["aes_key"] == "server_date_time"
    assert vectors["constants"]["aes_iv"] == "client_date_time"
    assert len(vectors["aes_vectors"]) >= 5
    for item in vectors["aes_vectors"]:
        assert item["login_credential"].endswith("_encrypt")

    assert len(vectors["hmac_vectors"]) == 2
    for h in vectors["hmac_vectors"]:
        hdrs = h["expected_headers"]
        assert hdrs["X-request-id"] == h["request_id"]
        assert hdrs["X-request-date"] == str(h["timestamp_ms"])
        assert len(hdrs["X-hmac-request-key"]) == 64

    grace_cases = [
        c for c in vectors["classifier_vectors"] if c["in_open_grace_window"]
    ]
    assert len(grace_cases) == 1
    assert grace_cases[0]["status"] == "retry_captcha"
    assert grace_cases[0]["not_open_yet"] is True


def test_export_room_catalog(tmp_path: Path) -> None:
    out_file = export_room_catalog(tmp_path)
    assert out_file.is_file()
    data = json.loads(out_file.read_text(encoding="utf-8"))
    assert "蒲河校区图书馆" in data["campuses"]
    assert "崇山校区图书馆" in data["campuses"]
    assert "三楼智慧研修空间" in data["room_seats"]
    assert "1" in data["room_seats"]["三楼智慧研修空间"]
    assert len(data["room_seats"]) >= 21


def test_package_unsigned_ipa_structure(tmp_path: Path) -> None:
    import zipfile
    from build_ios import package_unsigned_ipa

    fake_runner = tmp_path / "Runner.app"
    fake_runner.mkdir()
    (fake_runner / "Info.plist").write_text("<plist/>", encoding="utf-8")
    out_ipa = tmp_path / "LNU-LibSeat-test.ipa"

    package_unsigned_ipa(fake_runner, out_ipa)
    assert out_ipa.is_file()
    with zipfile.ZipFile(out_ipa, "r") as zf:
        names = zf.namelist()
        assert any(n.endswith("Payload/Runner.app/Info.plist") for n in names)


def test_mobile_onnx_models_compatible_with_ort_1_15() -> None:
    """所有移动端 ONNX 模型必须满足 IR<=8 且 Opset<=18，兼容 Flutter onnxruntime 1.15.1。"""
    models_dir = Path("mobile/assets/models")
    manifest_path = models_dir / "manifest.json"
    if not manifest_path.is_file():
        return
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    entries = manifest.get("models", [])
    assert len(entries) == 5
    for entry in entries:
        model_path = models_dir / entry["filename"]
        assert model_path.is_file(), f"缺少移动端模型: {model_path}"
        ir_v, opset_v = _read_onnx_versions(model_path)
        assert ir_v <= MOBILE_ORT_MAX_IR_VERSION, (
            f"{entry['filename']} IR={ir_v} 超出 ORT 1.15.1 上限 {MOBILE_ORT_MAX_IR_VERSION}"
        )
        assert opset_v <= MOBILE_ORT_MAX_OPSET, (
            f"{entry['filename']} Opset={opset_v} 超出 ORT 1.15.1 上限 {MOBILE_ORT_MAX_OPSET}"
        )
        assert entry["ir_version"] == ir_v
        assert entry["opset_version"] == opset_v
        assert entry["max_abs_diff"] == 0.0


