---
sidebar_position: 1
title: Evaluation Guide
description: Evaluate trained robotics policies in simulation and on physical hardware using Azure ML and NVIDIA OSMO
author: Microsoft Robotics-AI Team
ms.date: 2026-10-12
ms.topic: overview
keywords:
  - evaluation
  - robotics
  - Isaac Lab
  - LeRobot
  - OSMO
  - Azure ML
---

Evaluate trained robotics policies on Azure ML or NVIDIA OSMO, or replay LeRobot policies locally. Run the commands below from the repository root after deploying the infrastructure; the submission scripts read Azure context from Terraform outputs unless you pass it explicitly.

## 📖 Evaluation Guides

| Guide                                                  | Description                                              |
|--------------------------------------------------------|----------------------------------------------------------|
| [LeRobot ACT Policy Evaluation](lerobot-evaluation.md) | Run LeRobot ACT policies locally with ROS2 deployment    |
| [OSMO Evaluation Workflows](osmo-evaluation.md)        | Execute Isaac Lab and LeRobot evaluation via NVIDIA OSMO |
| [HiL Evaluation](hil-evaluation.md)                    | Run CPU and independently no-command HiL gates           |

## ⚖️ Evaluation Comparison

| Feature              | Azure ML                                 | OSMO                                                                     |
|----------------------|------------------------------------------|--------------------------------------------------------------------------|
| Submission script    | `submit-azureml-*.sh`                    | `submit-osmo-*.sh`                                                       |
| Policy source        | Azure ML model registry, HuggingFace Hub | Isaac Lab: MLflow, Azure Blob, HTTP(S); LeRobot: Azure ML or HuggingFace |
| Supported frameworks | Isaac Lab, LeRobot, pi0-family VLA       | Isaac Lab, LeRobot                                                       |
| GPU scheduling       | Azure ML compute target                  | KAI Scheduler                                                            |
| Monitoring           | Azure ML studio                          | `osmo workflow logs`                                                     |

## 🚀 Quick Start

Evaluate a LeRobot policy on Azure ML against a pinned dataset revision:

```bash
evaluation/sil/scripts/submit-azureml-lerobot-eval.sh \
  --from-aml-model \
  --model-name <model-name> \
  --model-version <version> \
  --dataset-repo-id <owner/dataset> \
  --dataset-revision <commit-sha>
```

Evaluate an Isaac Lab checkpoint through OSMO. The script packages the evaluation code and supplies the entry script that the workflow template requires:

```bash
evaluation/sil/scripts/submit-osmo-eval.sh \
  --checkpoint-uri runs:/<run-id>/model \
  --task <isaac-lab-task>
```

Add `--config-preview` to either submission script to print the resolved configuration without submitting. For local LeRobot replay and ROS 2 deployment, see [LeRobot ACT Policy Evaluation](lerobot-evaluation.md).

## 📚 Related Documentation

- [Training Guide](../training/README.md)
- [MLflow Integration](../training/mlflow-integration.md)
- [Workflow Templates](https://github.com/microsoft/physical-ai-toolchain/blob/main/workflows/README.md)
- [Scripts Reference](../reference/scripts.md)

---

<!-- markdownlint-disable MD036 -->
*🤖 Crafted with precision by ✨Copilot following brilliant human instruction,
then carefully refined by our team of discerning human reviewers.*
<!-- markdownlint-enable MD036 -->
