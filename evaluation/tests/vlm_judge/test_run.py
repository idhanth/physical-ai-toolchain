"""Judge CLI preview, dry-run, and episode-processing contracts."""

from __future__ import annotations

import json
from dataclasses import replace
from pathlib import Path

import pytest
from vlm_judge import run
from vlm_judge.dataset import iter_episodes
from vlm_judge.service import BackendConfig, FrameConfig, JudgeService, ServiceConfig


def _arguments(root: Path) -> list[str]:
    return [
        "--dataset",
        str(root),
        "--output",
        str(root / "results.jsonl"),
        "--backend",
        "echo",
        "--cache-dir",
        "",
        "--n-frames",
        "3",
    ]


def test_given_config_preview_when_running_then_omits_endpoint_and_credentials(
    jsonl_dataset: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    result = run.main(
        [
            *_arguments(jsonl_dataset),
            "--config-preview",
            "--api-key",
            "synthetic-token",
            "--base-url",
            "https://example.invalid/v1",
        ]
    )

    configuration = json.loads(capsys.readouterr().out)
    assert result == 0
    assert configuration["backend"] == "echo"
    assert {"api_key", "base_url", "config_preview"}.isdisjoint(configuration)
    assert not (jsonl_dataset / "results.jsonl").exists()


def test_given_empty_episode_selection_when_dry_running_then_returns_failure(jsonl_dataset: Path) -> None:
    assert run.main([*_arguments(jsonl_dataset), "--dry-run", "--indices", "99"]) == 1


def test_given_real_episodes_when_dry_running_then_writes_inputs_and_config_without_inference(
    jsonl_dataset: Path,
) -> None:
    result = run.main(
        [*_arguments(jsonl_dataset), "--dry-run", "--indices", "0-1, 1, ", "--instruction", "Inspect the block"]
    )

    rows = [json.loads(line) for line in (jsonl_dataset / "results.jsonl").read_text().splitlines()]
    configuration = json.loads((jsonl_dataset / "results.jsonl.config.json").read_text())
    assert result == 0
    assert len(rows) == 2
    assert all(row["dry_run"] and row["instruction"] == "Inspect the block" for row in rows)
    assert configuration["instruction_origin"] == "cli-override"
    assert len(configuration["saved_inputs"]) == 2


def test_given_unknown_dataset_when_running_status_then_reports_safe_command_failure(
    jsonl_dataset: Path, caplog: pytest.LogCaptureFixture
) -> None:
    result = run.main([*_arguments(jsonl_dataset), "--operation", "status"])

    assert result == 2
    assert "category=ValueError" in caplog.text


@pytest.mark.parametrize("instruction", [None, "Inspect", ""])
def test_given_resolved_episode_when_processing_then_validates_instruction_and_records_echo_result(
    jsonl_dataset: Path, instruction: str | None
) -> None:
    episode = next(iter_episodes(jsonl_dataset))
    if instruction == "":
        episode = replace(episode, instruction="")
    service = JudgeService(ServiceConfig(backend=BackendConfig(kind="echo"), frames=FrameConfig(n_frames=3)))

    if instruction == "":
        with pytest.raises(ValueError, match="Invalid judge result field: instruction"):
            run._process_episode(
                episode=episode,
                service=service,
                instruction_override=instruction,
                dry_run=False,
                force=True,
            )
        return

    result = run._process_episode(
        episode=episode,
        service=service,
        instruction_override=instruction,
        dry_run=False,
        force=True,
    )

    assert result["instruction"] == (instruction or episode.instruction)
    assert result["duration_s"] == 1
    assert result["outcome_success"] is True
    assert result["video_paths"] == {"front": str(episode.video_paths["front"])}
