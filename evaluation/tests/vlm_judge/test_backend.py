"""CPU contracts for the optional model/processor integration boundary."""

from __future__ import annotations

import sys
from types import ModuleType, SimpleNamespace
from typing import Any

import pytest
import torch
from PIL import Image
from pytest_mock import MockerFixture
from vlm_judge.backend import GenerationConfig, OpenAICompatibleBackend, Qwen3VLBackend, _load_qwen3_vl_model


@pytest.mark.parametrize("temperature", [0.0, 0.4])
@pytest.mark.parametrize("with_image", [False, True])
@pytest.mark.parametrize("decoded", [["generated answer"], []], ids=["text", "empty-decoding"])
def test_given_cpu_model_boundary_when_generating_then_preserves_options_and_decodes_only_new_tokens(
    monkeypatch: pytest.MonkeyPatch, temperature: float, with_image: bool, decoded: list[str]
) -> None:
    calls: dict[str, Any] = {}

    class Processor:
        @classmethod
        def from_pretrained(cls, model_id: str, **kwargs: Any) -> Processor:
            calls["processor_load"] = (model_id, kwargs)
            return cls()

        def apply_chat_template(self, messages: list[dict[str, Any]], **kwargs: Any) -> str:
            calls["messages"] = messages
            calls["template_options"] = kwargs
            return "formatted prompt"

        def __call__(self, **kwargs: Any) -> dict[str, torch.Tensor]:
            calls["processor_input"] = kwargs
            return {"input_ids": torch.tensor([[1, 2, 3]])}

        def batch_decode(self, tokens: torch.Tensor, **kwargs: Any) -> list[str]:
            calls["decoded_tokens"] = tokens.tolist()
            calls["decode_options"] = kwargs
            return decoded

    class Model:
        device = torch.device("cpu")

        @classmethod
        def from_pretrained(cls, model_id: str, **kwargs: Any) -> Model:
            calls["model_load"] = (model_id, kwargs)
            return cls()

        def eval(self) -> None:
            calls["eval"] = True

        def generate(self, **kwargs: Any) -> torch.Tensor:
            calls["generation"] = kwargs
            calls["inference_mode"] = torch.is_inference_mode_enabled()
            return torch.tensor([[1, 2, 3, 4, 5]])

    transformers = ModuleType("transformers")
    transformers.AutoProcessor = Processor
    transformers.Qwen3VLForConditionalGeneration = Model
    monkeypatch.setitem(sys.modules, "transformers", transformers)
    image = Image.new("RGB", (8, 8), "red")
    images = [image] if with_image else []
    backend = Qwen3VLBackend(model_id="synthetic-model", revision="synthetic-revision", device_map="cpu")

    answer = backend.generate(
        system_prompt="Judge the task",
        user_prompt="Pick",
        images=images,
        config=GenerationConfig(max_new_tokens=7, temperature=temperature, top_p=0.8),
    )

    assert answer == (decoded[0] if decoded else "")
    assert calls["processor_load"] == (
        "synthetic-model",
        {"revision": "synthetic-revision", "trust_remote_code": True},
    )
    assert calls["model_load"][1]["device_map"] == "cpu"
    assert calls["model_load"][1]["revision"] == "synthetic-revision"
    assert calls["model_load"][1]["dtype"] == torch.bfloat16
    assert calls["eval"] and calls["inference_mode"]
    assert calls["decoded_tokens"] == [[4, 5]]
    assert calls["decode_options"] == {"skip_special_tokens": True}
    assert calls["processor_input"]["text"] == ["formatted prompt"]
    assert ("images" in calls["processor_input"]) == with_image
    assert calls["generation"]["max_new_tokens"] == 7
    assert calls["generation"]["do_sample"] == (temperature > 0)
    assert ("temperature" in calls["generation"]) == (temperature > 0)
    if temperature > 0:
        assert calls["generation"]["temperature"] == temperature
        assert calls["generation"]["top_p"] == 0.8
    assert calls["messages"][0]["content"][0]["text"] == "Judge the task"
    assert calls["messages"][1]["content"][-1] == {"type": "text", "text": "Pick"}


@pytest.mark.parametrize("failure", ["no-model-classes", "all-loaders-fail", "fallback-succeeds"])
def test_given_model_loader_variants_when_loading_then_falls_back_or_reports_failure(
    monkeypatch: pytest.MonkeyPatch, failure: str
) -> None:
    transformers = ModuleType("transformers")

    class UnsupportedModel:
        @classmethod
        def from_pretrained(cls, model_id: str, **kwargs: Any) -> object:
            raise ValueError("unsupported checkpoint")

    expected = object()

    class SupportedModel:
        @classmethod
        def from_pretrained(cls, model_id: str, **kwargs: Any) -> object:
            return expected

    if failure != "no-model-classes":
        transformers.Qwen3VLForConditionalGeneration = UnsupportedModel
    if failure == "fallback-succeeds":
        transformers.AutoModelForImageTextToText = SupportedModel
    monkeypatch.setitem(sys.modules, "transformers", transformers)
    kwargs = {
        "model_id": "synthetic-model",
        "revision": None,
        "device_map": "cpu",
        "dtype": torch.float32,
        "attn_implementation": None,
        "trust_remote_code": False,
    }

    if failure == "fallback-succeeds":
        assert _load_qwen3_vl_model(**kwargs) is expected
    else:
        with pytest.raises(RuntimeError, match="Unable to load synthetic-model"):
            _load_qwen3_vl_model(**kwargs)


@pytest.mark.parametrize("api_key", [None, "explicit-test-key"])
@pytest.mark.parametrize("content", [None, "judgment"])
def test_given_openai_sdk_boundary_when_generating_then_sends_image_and_generation_contract(
    monkeypatch: pytest.MonkeyPatch, mocker: MockerFixture, api_key: str | None, content: str | None
) -> None:
    module = ModuleType("openai")
    constructor = mocker.Mock()
    client = constructor.return_value
    client.chat.completions.create.return_value = SimpleNamespace(
        choices=[SimpleNamespace(message=SimpleNamespace(content=content))]
    )
    module.OpenAI = constructor
    monkeypatch.setitem(sys.modules, "openai", module)
    monkeypatch.setenv("OPENAI_API_KEY", "environment-test-key")
    image = Image.new("RGB", (8, 8), "red")
    backend = OpenAICompatibleBackend(
        model="synthetic-model", base_url="https://example.invalid/v1", api_key=api_key, timeout_s=7
    )

    result = backend.generate(
        system_prompt="Judge",
        user_prompt="Pick",
        images=[image],
        config=GenerationConfig(max_new_tokens=12, temperature=0.2, top_p=0.8),
    )

    assert result == (content or "")
    constructor.assert_called_once_with(
        base_url="https://example.invalid/v1",
        api_key=api_key or "environment-test-key",
        timeout=7,
    )
    request = client.chat.completions.create.call_args.kwargs
    assert request["model"] == "synthetic-model"
    assert request["max_tokens"] == 12 and request["temperature"] == 0.2 and request["top_p"] == 0.8
    assert request["messages"][0] == {"role": "system", "content": "Judge"}
    assert request["messages"][1]["content"][0]["image_url"]["url"].startswith("data:image/jpeg;base64,")
    assert request["messages"][1]["content"][-1] == {"type": "text", "text": "Pick"}
