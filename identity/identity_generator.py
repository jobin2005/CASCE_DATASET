"""
identity_generator.py

Generates random synthetic username + private IP per session run,
guaranteed unique across all runs via persistent TSV registry file.
Ported from v1's attack_workload/_identity_lib.sh.
"""

import os
import random
import time
from pathlib import Path
from typing import Tuple

USER_POOL = [
    "db_admin", "analyst_bob", "service_alice", "dev_charlie", "ops_dana",
    "qa_edgar", "backup_frank", "audit_grace", "intern_hank", "vendor_ivy",
    "support_jack", "replica_kim", "etl_liam", "metrics_mona", "sre_noah",
    "billing_opal", "reports_paul", "svc_quinn", "contractor_rosa", "temp_sam"
]


def _rand_username() -> str:
    base = random.choice(USER_POOL)
    num = random.randint(0, 999)
    return f"{base}_{num:03d}"


def _rand_ip() -> str:
    """Generates non-routable private IP (RFC 1918)."""
    pool_choice = random.randint(0, 2)
    if pool_choice == 0:
        return f"10.{random.randint(0, 255)}.{random.randint(0, 255)}.{random.randint(1, 254)}"
    elif pool_choice == 1:
        return f"192.168.{random.randint(0, 255)}.{random.randint(1, 254)}"
    else:
        return f"172.{random.randint(16, 31)}.{random.randint(0, 255)}.{random.randint(1, 254)}"


def new_identity(registry_path: str = "identity/identity_registry.tsv") -> Tuple[str, str]:
    """
    Returns a (username, ip) tuple never seen before in registry_path.
    Appends the chosen identity to the registry file before returning.
    """
    reg_file = Path(registry_path)
    reg_file.parent.mkdir(parents=True, exist_ok=True)

    used_users = set()
    used_ips = set()

    if reg_file.exists():
        with reg_file.open("r", encoding="utf-8", errors="ignore") as f:
            for line in f:
                parts = line.strip().split("\t")
                if len(parts) >= 2:
                    used_users.add(parts[0])
                    used_ips.add(parts[1])

    for attempt in range(1000):
        user = _rand_username()
        ip = _rand_ip()
        if user not in used_users and ip not in used_ips:
            # Record identity
            with reg_file.open("a", encoding="utf-8") as f:
                f.write(f"{user}\t{ip}\t{time.time():.3f}\n")
            return user, ip

    # Fallback with timestamp suffix to guarantee uniqueness if pool exhausted
    user = f"{_rand_username()}_{int(time.time())}"
    ip = _rand_ip()
    with reg_file.open("a", encoding="utf-8") as f:
        f.write(f"{user}\t{ip}\t{time.time():.3f}\n")
    return user, ip


if __name__ == "__main__":
    u, ip = new_identity()
    print(f"Generated identity: user={u}, ip={ip}")
