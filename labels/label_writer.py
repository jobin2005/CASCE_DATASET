"""
labels/label_writer.py

Writes the ground-truth label sidecar for a completed session run.
"""

import json
from pathlib import Path
from typing import Dict, Any


def write_label(out_dir: str, run_id: str, template_metadata: Dict[str, Any]) -> str:
    """
    Saves a label.json sidecar file for run_id containing template metadata,
    declared label classification (benign / attack), identity, and timestamps.
    Returns the absolute path of the written file.
    """
    out_path = Path(out_dir)
    out_path.mkdir(parents=True, exist_ok=True)

    label_file = out_path / f"{run_id}_label.json"

    data = {
        "run_id": run_id,
        "schema_name": template_metadata.get("schema", "unknown"),
        "template_name": template_metadata.get("name", "unknown"),
        "type": template_metadata.get("type", "unknown"),
        "username": template_metadata.get("username", ""),
        "client_ip": template_metadata.get("client_ip", ""),
        "start_time": template_metadata.get("start_time"),
        "end_time": template_metadata.get("end_time"),
        "metadata": template_metadata,
    }

    with label_file.open("w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)

    return str(label_file.resolve())
