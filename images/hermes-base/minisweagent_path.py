"""Helpers for locating the mini-swe-agent source tree.

Vendored from hermes-agent v2026.3.17 because upstream packaging omits this
module from the published install set even though gateway startup imports it.
"""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path
from typing import Optional


def _read_gitdir(repo_root: Path) -> Optional[Path]:
    """Resolve the gitdir referenced by ``repo_root/.git`` when it is a file."""
    git_marker = repo_root / ".git"
    if not git_marker.is_file():
        return None

    try:
        raw = git_marker.read_text(encoding="utf-8").strip()
    except OSError:
        return None

    prefix = "gitdir:"
    if not raw.lower().startswith(prefix):
        return None

    target = raw[len(prefix):].strip()
    gitdir = Path(target)
    if not gitdir.is_absolute():
        gitdir = (repo_root / gitdir).resolve()
    else:
        gitdir = gitdir.resolve()
    return gitdir


def discover_minisweagent_src(repo_root: Optional[Path] = None) -> Optional[Path]:
    """Return the best available ``mini-swe-agent/src`` path, if any."""
    repo_root = (repo_root or Path(__file__).resolve().parent).resolve()

    candidates: list[Path] = [repo_root / "mini-swe-agent" / "src"]

    gitdir = _read_gitdir(repo_root)
    if gitdir is not None:
        if len(gitdir.parents) >= 3 and gitdir.parent.name == "worktrees":
            candidates.append(gitdir.parents[2] / "mini-swe-agent" / "src")
        elif gitdir.name == ".git":
            candidates.append(gitdir.parent / "mini-swe-agent" / "src")

    seen = set()
    for candidate in candidates:
        candidate = candidate.resolve()
        if candidate in seen:
            continue
        seen.add(candidate)
        if candidate.exists() and candidate.is_dir():
            return candidate

    return None


def ensure_minisweagent_on_path(repo_root: Optional[Path] = None) -> Optional[Path]:
    """Ensure ``minisweagent`` is importable by prepending its src dir to sys.path."""
    if importlib.util.find_spec("minisweagent") is not None:
        return None

    src = discover_minisweagent_src(repo_root)
    if src is None:
        return None

    src_str = str(src)
    if src_str not in sys.path:
        sys.path.insert(0, src_str)
    return src
