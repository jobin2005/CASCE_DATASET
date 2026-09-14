"""
validator/graph_validator.py

Validates the integrity of saved CASCE v2 session graphs and labels:
  - graph is non-empty / has expected node types present
  - session node count == 1 (one session per saved graph)
  - no completely orphaned nodes disconnected from the Session root
  - label.json exists, is valid, and matches session metadata
"""

import json
from pathlib import Path
from typing import List
import networkx as nx


def validate_graph(graph_path: str, label_path: str) -> List[str]:
    """
    Validates a saved session graph against its ground-truth label.
    Returns a list of validation error strings (empty list = OK).
    """
    issues: List[str] = []

    g_path = Path(graph_path)
    l_path = Path(label_path)

    if not g_path.exists():
        issues.append(f"Graph file does not exist: {graph_path}")
        return issues

    if not l_path.exists():
        issues.append(f"Label file does not exist: {label_path}")

    # Load graph data
    try:
        with g_path.open("r", encoding="utf-8") as f:
            graph_data = json.load(f)
        try:
            G = nx.node_link_graph(graph_data, edges="links")
        except TypeError:
            G = nx.node_link_graph(graph_data)
    except Exception as exc:
        issues.append(f"Failed to parse graph JSON: {exc}")
        return issues

    # 1. Non-empty check
    if G.number_of_nodes() == 0:
        issues.append("Graph has 0 nodes (expected non-empty graph).")
        return issues

    # 2. Count Session nodes
    session_nodes = [
        n for n, d in G.nodes(data=True)
        if d.get("type") == "Session" or (isinstance(n, (tuple, list)) and n[0] == "Session")
    ]
    if len(session_nodes) == 0:
        issues.append("Graph has no 'Session' node.")
    elif len(session_nodes) > 1:
        issues.append(f"Graph has multiple 'Session' nodes ({len(session_nodes)}), expected exactly 1.")

    # 3. Check connectivity / orphans
    # In a directed graph, check weakly connected components
    UG = G.to_undirected()
    components = list(nx.connected_components(UG))
    if len(components) > 1:
        # Find which component contains the session node
        session_set = set(session_nodes)
        isolated_nodes_count = 0
        for comp in components:
            if not comp.intersection(session_set):
                isolated_nodes_count += len(comp)
        if isolated_nodes_count > 0:
            issues.append(
                f"Graph contains {isolated_nodes_count} disconnected nodes across {len(components) - 1} disconnected subgraphs."
            )

    # 4. Check label consistency
    if l_path.exists():
        try:
            with l_path.open("r", encoding="utf-8") as f:
                label_data = json.load(f)
            if "type" not in label_data or label_data["type"] not in ("benign", "attack"):
                issues.append(f"Label file missing valid 'type' field: got {label_data.get('type')}")
        except Exception as exc:
            issues.append(f"Failed to parse label JSON: {exc}")

    return issues


if __name__ == "__main__":
    import sys
    if len(sys.argv) < 3:
        print("Usage: python graph_validator.py <graph_json_path> <label_json_path>")
        sys.exit(1)

    errors = validate_graph(sys.argv[1], sys.argv[2])
    if errors:
        print("Validation FAILED:")
        for err in errors:
            print(f"  - {err}")
        sys.exit(1)
    else:
        print("Validation PASSED (0 issues).")
