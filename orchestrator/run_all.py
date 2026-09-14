"""
orchestrator/run_all.py

Outer dataset generation orchestrator:
  - Iterates through database schemas configured in config.yaml
  - Re-initializes each database with setup_db.sh
  - Discovers benign and attack templates under templates/<schema>/
  - Executes runs_per_template sessions sequentially
  - Partitions dataset into output/dataset_dev and output/dataset_test
"""

import os
import subprocess
import sys
import time
from pathlib import Path
from typing import List
import yaml

# Add project root to sys.path
PROJECT_ROOT = Path(__file__).resolve().parent.parent
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

from orchestrator.run_session import run_session


def find_templates(schema_name: str) -> List[Path]:
    """Finds all YAML templates (benign and attack) for the given schema."""
    template_dirs = [
        PROJECT_ROOT / "templates" / schema_name / "benign_templates",
        PROJECT_ROOT / "templates" / schema_name / "attack_templates",
        PROJECT_ROOT / "templates" / schema_name / "benign",
        PROJECT_ROOT / "templates" / schema_name / "attack",
    ]
    found = []
    for t_dir in template_dirs:
        if t_dir.exists():
            for f in sorted(t_dir.glob("*.yaml")):
                found.append(f)
            for f in sorted(t_dir.glob("*.yml")):
                found.append(f)
    return found


def setup_database(schema_name: str, config: dict):
    """Invokes setup_db.sh if present and executable, or logs notice."""
    setup_script = PROJECT_ROOT / "setup_db.sh"
    pg_cfg = config.get("postgres", {})
    host = pg_cfg.get("host", "localhost")
    port = str(pg_cfg.get("port", "5432"))
    user = pg_cfg.get("user", "postgres")
    password = pg_cfg.get("password", "password")

    if setup_script.exists() and os.name != "nt":
        print(f"--- Running setup_db.sh for {schema_name} ---")
        try:
            subprocess.run(
                ["bash", str(setup_script), schema_name, host, port, user, password],
                check=True,
                cwd=str(PROJECT_ROOT)
            )
        except Exception as exc:
            print(f"Notice: setup_db.sh execution exited with: {exc}", file=sys.stderr)
    else:
        print(f"--- Setting up database schema '{schema_name}' ---")


def main():
    config_file = PROJECT_ROOT / "config.yaml"
    if not config_file.exists():
        print(f"Config file not found: {config_file}", file=sys.stderr)
        sys.exit(1)

    with config_file.open("r", encoding="utf-8") as f:
        config = yaml.safe_load(f)

    runs_per_tmpl = int(config.get("runs_per_template", 5))
    dev_split = float(config.get("dev_test_split", 0.7))
    out_cfg = config.get("output", {})
    dev_dir = PROJECT_ROOT / out_cfg.get("dev_dir", "output/dataset_dev")
    test_dir = PROJECT_ROOT / out_cfg.get("test_dir", "output/dataset_test")
    databases = config.get("databases", ["ecommerce", "banking", "healthcare", "logistics"])

    dev_dir.mkdir(parents=True, exist_ok=True)
    test_dir.mkdir(parents=True, exist_ok=True)

    print(f"CASCE v2 Dataset Generation Orchestrator")
    print(f"Databases: {databases}")
    print(f"Runs per template: {runs_per_tmpl}, Split: {dev_split * 100:.0f}% Dev / {(1 - dev_split) * 100:.0f}% Test")

    total_runs = 0
    successful_runs = 0

    for schema in databases:
        templates = find_templates(schema)
        if not templates:
            print(f"Warning: No templates found for schema '{schema}'. Skipping.")
            continue

        print(f"\n=======================================================")
        print(f"Processing Database Schema: {schema} ({len(templates)} templates)")
        print(f"=======================================================")
        setup_database(schema, config)

        for tmpl_idx, tmpl_path in enumerate(templates, 1):
            tmpl_name = tmpl_path.stem
            print(f"\nTemplate [{tmpl_idx}/{len(templates)}]: {tmpl_name} ({tmpl_path.parent.name})")

            for run_num in range(1, runs_per_tmpl + 1):
                # Partition between dev and test
                is_dev = (run_num - 1) < (runs_per_tmpl * dev_split)
                target_dir = dev_dir if is_dev else test_dir
                partition_label = "dev" if is_dev else "test"

                run_id = f"{schema}_{tmpl_name}_run{run_num:02d}_{partition_label}"
                total_runs += 1

                try:
                    res = run_session(
                        schema_name=schema,
                        template_path=str(tmpl_path),
                        out_dir=str(target_dir),
                        run_id=run_id,
                        pg_config=config.get("postgres", {}),
                        registry_path=str(PROJECT_ROOT / "identity" / "identity_registry.tsv")
                    )
                    successful_runs += 1
                except Exception as exc:
                    print(f"Run {run_id} failed: {exc}", file=sys.stderr)

    print("\n=======================================================")
    print(f"Dataset Generation Complete. Total Runs: {total_runs}, Successful: {successful_runs}")
    print(f"Outputs written to:\n  Dev:  {dev_dir}\n  Test: {test_dir}")
    print("=======================================================")


if __name__ == "__main__":
    main()
