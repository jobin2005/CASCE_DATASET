"""
graph_store/writer.py

Serializes the finished NetworkX MultiDiGraph for a session run into
the target dataset directory along with a metadata sidecar.
"""

import json
from pathlib import Path
from typing import Optional, Dict, Any
import networkx as nx


def write_graph(graph: nx.MultiDiGraph, out_dir: str, run_id: str, metadata: Optional[Dict[str, Any]] = None) -> str:
    """
    Serializes `graph` to out_dir as node-link JSON format and writes
    a small metadata sidecar. Returns the path of the saved graph file.
    """
    out_path = Path(out_dir)
    out_path.mkdir(parents=True, exist_ok=True)

    graph_file = out_path / f"{run_id}_graph.json"
    metadata_file = out_path / f"{run_id}_metadata.json"

    # Serialize MultiDiGraph to node-link representation
    # nx.node_link_data is standard across NetworkX versions
    try:
        data = nx.node_link_data(graph, edges="links")
    except TypeError:
        # Compatibility with older NetworkX versions
        data = nx.node_link_data(graph)

    with graph_file.open("w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, default=str)

    # Compute node type distribution for metadata
    type_counts: Dict[str, int] = {}
    for _, attrs in graph.nodes(data=True):
        ntype = attrs.get("type", "Unknown")
        type_counts[ntype] = type_counts.get(ntype, 0) + 1

    sidecar = {
        "run_id": run_id,
        "node_count": graph.number_of_nodes(),
        "edge_count": graph.number_of_edges(),
        "node_types": type_counts,
        "graph_file": graph_file.name,
    }
    if metadata:
        sidecar.update(metadata)

    with metadata_file.open("w", encoding="utf-8") as f:
        json.dump(sidecar, f, indent=2, default=str)

    return str(graph_file.resolve())
