#!/usr/bin/env python3
"""nightly-now: ship a feat-cmux-next commit to cmux NIGHTLY now.

    scripts/ci/nightly_now.py [SHA] [--repo OWNER/REPO] [--check] [--dry-run]

Dispatches main's nightly-next-tick.yml for SHA (default: the tip of feat-cmux-next), which skips the rolling
rule's wait: the tick asks main's promote job to move nightly-next to the newest buildable commit at or before
SHA, and that push starts the build. The same tick's supersede job drops any older nightly-next run that holds
the push or sign group with none of its build, sign or publish jobs started
(scripts/ci/nightly_next_supersede.py, under delivery_workflows.superseded_unstarted()); later ticks do the same
for the new push run. Nothing here cancels anything: the dispatch goes first and never waits on a check.

--check also prints, read-only, which holders the supersede rule would drop right now. --dry-run prints the
dispatch without sending it.
"""
from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
from collections.abc import Callable, Sequence
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import nightly_next_supersede as supersede  # noqa: E402

TICK, SOURCE_BRANCH = "nightly-next-tick.yml", "feat-cmux-next"
FULL_SHA = re.compile(r"[0-9a-f]{40}")
SHORT_SHA = re.compile(r"[0-9a-f]{7,39}")

Run = Callable[[Sequence[str]], str]


def run_gh(args: Sequence[str]) -> str:
    try:
        result = subprocess.run(["gh", *args], capture_output=True, text=True, stdin=subprocess.DEVNULL)
    except OSError as error:
        raise RuntimeError(f"gh could not run: {error}") from error
    if result.returncode:
        raise RuntimeError(f"gh {' '.join(args[:3])} failed: {result.stderr.strip()[:300]}")
    return result.stdout


def resolve(sha: str | None, repo: str, gh: Run, tip: Callable[[str, str], str]) -> str:
    """The full commit to ask for: SHA as given (a short one through the API), else the source branch's tip."""
    if not sha:
        return tip(repo, SOURCE_BRANCH)
    sha = sha.strip().lower()
    if FULL_SHA.fullmatch(sha):
        return sha
    if not SHORT_SHA.fullmatch(sha):
        raise ValueError(f"{sha!r} is not a commit sha")
    full = gh(["api", f"repos/{repo}/commits/{sha}", "--jq", ".sha"]).strip().lower()
    if not FULL_SHA.fullmatch(full):
        raise ValueError(f"{sha} did not resolve to one commit ({full!r})")
    return full


def dispatch_args(repo: str, sha: str) -> list[str]:
    return ["workflow", "run", TICK, "--repo", repo, "--ref", "main", "-f", f"sha={sha}"]


def main(argv: Sequence[str] | None = None, *, gh: Run = run_gh,
         tip: Callable[[str, str], str] = supersede.ls_remote_sha,
         check: Callable[[str], list[int]] | None = None, log: Callable[[str], None] = print) -> int:
    parser = argparse.ArgumentParser(prog="nightly-now", description=__doc__.split("\n\n")[0])
    parser.add_argument("sha", nargs="?", help=f"commit on {SOURCE_BRANCH} (default: its tip)")
    parser.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY") or "manaflow-ai/cmux")
    parser.add_argument("--check", action="store_true", help="also print which holders would be dropped (read-only)")
    parser.add_argument("--dry-run", action="store_true", help="print the dispatch without sending it")
    args = parser.parse_args(argv)
    try:
        sha = resolve(args.sha, args.repo, gh, tip)
    except (ValueError, RuntimeError, supersede.Unreadable) as error:
        log(f"nightly-now: {error}")
        return 2
    command = dispatch_args(args.repo, sha)
    if args.dry_run:
        log("nightly-now: would run gh " + " ".join(command))
    else:
        try:
            gh(command)
        except RuntimeError as error:
            log(f"nightly-now: the dispatch failed: {error}")
            return 1
        log(f"nightly-now: asked for {sha} ({TICK} on main, rolling wait skipped). The tick promotes the newest "
            f"buildable commit at or before it; its supersede job drops older runs that never started.")
    if args.check:
        decide = check or (lambda repo: supersede.tick(supersede.Api(repo), dry_run=True, log=log))
        decide(args.repo)
    return 0


if __name__ == "__main__":
    sys.exit(main())
