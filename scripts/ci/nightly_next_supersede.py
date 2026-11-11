#!/usr/bin/env python3
"""Latest wins for nightly-next: drop an older nightly run that holds a concurrency group the tip waits on.

nightly.yml keeps nightly-next pushes (and the loop's retries) in one concurrency group and the sign stages
in another, never cancelling a started run. GitHub keeps one newer run pending per group and replaces it with
each newer push. So an older run whose remaining jobs wait on a runner label that stopped serving holds the
group for hours, and every tip run behind it is replaced while pending and never starts (2026-11-10/11: push
runs 42925854615 and 42929616529 and sign run 42930383771 held them; tip runs 42945365476, 42947517129 and
42948266530 were each replaced with no jobs). Leo, 2026-11-11: "aren't there things we can just be like 'ok
just get this one in asap'", and 2026-11-06: nothing queues.

This cancels such a holder only when delivery_workflows.superseded_unstarted() says it is stale, the one
definition the queue janitor and the agents' cancel guard read too: every job but the light control and decide
ones (LIGHT_JOBS) is queued for a runner or skipped, it is not at the branch tip, and either the newer tip run
waiting on its group (condition 3b, after READY_WAIT) or a newer tip run already building (after STALE_WAIT)
replaces it. A run with any build, sign or publish job started is never cancelled, nor is the newest tip.
Before each cancel the run, its jobs, the tip, the waiting runs and the open pull requests at its head are read
again; anything unread keeps the run. At most MAX_CANCELS a tick, never a force-cancel.

    nightly_next_supersede.py OWNER/REPO [--dry-run]
Needs gh with GH_TOKEN (actions: write). Exit 0 once the arguments read: its findings are annotations, and a
refused read or cancel never holds the tick's promotion.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from collections.abc import Callable, Mapping, Sequence
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))
from delivery_workflows import group_of, superseded_unstarted  # noqa: E402

WORKFLOW, BRANCH = "nightly.yml", "nightly-next"
STATUSES = ("pending", "queued", "in_progress")
HOLDER_STATUSES = frozenset({"queued", "in_progress"})
PAGE, MAX_PAGES = 100, 3
MAX_CANCELS = 2  # one push holder and one sign holder
SHA = re.compile(r"[0-9a-f]{40}")


class Unreadable(Exception):
    """A read or write that failed, or an answer not of the shape read here. Nothing is cancelled on it."""


Gh = Callable[[Sequence[str], bool], str]


def gh_cli(args: Sequence[str], write: bool) -> str:
    """Run gh. A write goes out once (no gh_budget_wait.sh retries)."""
    env = dict(os.environ)
    if write:
        env["GH_BUDGET_WAIT_ATTEMPTS"] = "1"
    result = subprocess.run(["gh", *args], capture_output=True, text=True, env=env, stdin=subprocess.DEVNULL)
    if result.returncode:
        raise Unreadable(f"gh {' '.join(args[:4])} failed: {result.stderr.strip()[:200]}")
    return result.stdout


def ls_remote_sha(repo: str, branch: str) -> str:
    """A branch's tip from git's ref advertisement: no token and none of the API budget."""
    server = os.environ.get("GITHUB_SERVER_URL", "https://github.com").rstrip("/")
    try:
        out = subprocess.run(["git", "ls-remote", "--exit-code", f"{server}/{repo}", f"refs/heads/{branch}"],
                             capture_output=True, text=True, timeout=60, check=True, stdin=subprocess.DEVNULL,
                             env={**os.environ, "GIT_TERMINAL_PROMPT": "0"}).stdout
    except (OSError, subprocess.SubprocessError) as error:
        raise Unreadable(f"git ls-remote {branch} failed: {error}") from error
    sha = out.split()[0].lower() if out.split() else ""
    if not SHA.fullmatch(sha):
        raise Unreadable(f"{branch} is {sha!r}")
    return sha


class Api:
    def __init__(self, repo: str, gh: Gh = gh_cli, tip: Callable[[str, str], str] = ls_remote_sha):
        self.repo, self.gh, self._tip = repo, gh, tip

    def get(self, path: str) -> Any:
        text = self.gh(["api", f"repos/{self.repo}/{path}"], False)
        try:
            return json.loads(text)
        except json.JSONDecodeError as error:
            raise Unreadable(f"{path}: not JSON") from error

    def listing(self, path: str, key: str) -> list[dict[str, Any]]:
        """Every item of a paginated listing; the items must add up to total_count, none twice."""
        items: list[dict[str, Any]] = []
        total = None
        for page in range(1, MAX_PAGES + 1):
            body = self.get(f"{path}{'&' if '?' in path else '?'}per_page={PAGE}&page={page}")
            if not isinstance(body, dict) or not isinstance(body.get(key), list) or not isinstance(
                    body.get("total_count"), int):
                raise Unreadable(f"{path}: not a listing of {key}")
            if total is not None and body["total_count"] != total:
                raise Unreadable(f"{path}: total_count moved between pages")
            total = body["total_count"]
            items.extend(item for item in body[key] if isinstance(item, dict))
            if len(items) >= total or not body[key]:
                break
        ids = [item.get("id") for item in items]
        if total is None or len(items) != total or len(ids) != len(set(map(repr, ids))):
            raise Unreadable(f"{path}: {len(items)} items for a total_count of {total}")
        return items

    def tip(self) -> str:
        return self._tip(self.repo, BRANCH)

    def runs(self) -> list[dict[str, Any]]:
        """nightly.yml's unfinished runs on nightly-next: holders and the runs pending on their groups."""
        found: dict[Any, dict[str, Any]] = {}
        for status in STATUSES:
            for run in self.listing(f"actions/workflows/{WORKFLOW}/runs?branch={BRANCH}&status={status}",
                                    "workflow_runs"):
                found[run.get("id")] = run
        return list(found.values())

    def run(self, run_id: int) -> dict[str, Any]:
        body = self.get(f"actions/runs/{run_id}")
        if not isinstance(body, dict) or body.get("id") != run_id:
            raise Unreadable(f"run {run_id}: not a run")
        return body

    def jobs(self, run_id: int) -> list[dict[str, Any]]:
        return self.listing(f"actions/runs/{run_id}/jobs?filter=latest", "jobs")

    def open_prs_at(self, sha: str) -> list[int]:
        body = self.get(f"commits/{sha}/pulls")
        if not isinstance(body, list):
            raise Unreadable(f"pull requests at {sha[:12]}: not a list")
        return [pr.get("number") for pr in body if isinstance(pr, dict) and pr.get("state") == "open"
                and str((pr.get("head") or {}).get("sha") or "").lower() == sha.lower()]

    def cancel(self, run_id: int) -> None:
        self.gh(["api", "-X", "POST", f"repos/{self.repo}/actions/runs/{run_id}/cancel"], True)


def judge(api: Api, run: Mapping[str, Any], runs: Sequence[Mapping[str, Any]], tip: str,
          cache: dict[Any, list[dict[str, Any]] | None]) -> tuple[bool, str]:
    """superseded_unstarted() on what GitHub shows; a jobs read that fails is unread (None)."""
    def jobs_of(other: Mapping[str, Any]) -> list[dict[str, Any]] | None:
        key = other.get("id")
        if key not in cache:
            try:
                cache[key] = api.jobs(int(key))
            except (Unreadable, TypeError, ValueError):
                cache[key] = None
        return cache[key]
    return superseded_unstarted(run, jobs_of(run), runs, jobs_of, tip_sha=tip)


def tick(api: Api, *, dry_run: bool = False, log: Callable[[str], None] = print) -> list[int]:
    """Cancel each stale holder (at most MAX_CANCELS); the ids cancelled, or that would be with dry_run."""
    def warn(message: str) -> None:
        log(f"::warning title=nightly-next supersede::{message}")

    try:
        tip, runs = api.tip(), api.runs()
    except Unreadable as why:
        warn(f"the nightly-next runs could not be read ({why}); nothing cancelled this tick")
        return []
    holders = sorted((run for run in runs if run.get("status") in HOLDER_STATUSES and group_of(run)),
                     key=lambda run: (str(run.get("created_at") or ""), run.get("id") or 0))
    if not holders:
        log("nightly-next supersede: no run holds the push or sign group")
    done: list[int] = []
    for listed in holders:
        run_id = int(listed["id"])
        ok, why = judge(api, listed, runs, tip, {})
        if not ok:
            log(f"nightly-next run {run_id} ({group_of(listed)} group, {str(listed.get('head_sha'))[:12]}): kept, {why}")
            continue
        if len(done) >= MAX_CANCELS:
            log(f"nightly-next run {run_id}: would be dropped ({why}), but {MAX_CANCELS} were this tick")
            continue
        # Everything once more right before the cancel: a build that started, a tip that moved, a waiter that
        # went, or a pull request opened at its head keeps the run.
        try:
            fresh_tip, fresh_runs = api.tip(), api.runs()
            current = api.run(run_id)
            ok, why = judge(api, current, fresh_runs, fresh_tip, {})
            after = api.run(run_id)
            prs = api.open_prs_at(str(current.get("head_sha") or "")) if ok else []
        except Unreadable as error:
            warn(f"run {run_id}: the re-read failed ({error}); kept")
            continue
        if not ok:
            log(f"nightly-next run {run_id}: kept on re-read, {why}")
            continue
        if (after.get("run_attempt"), after.get("status")) != (current.get("run_attempt"), current.get("status")):
            log(f"nightly-next run {run_id}: kept, it changed while its jobs were read")
            continue
        if prs:
            log(f"nightly-next run {run_id}: kept, PR #{prs[0]} is open at its head")
            continue
        if dry_run:
            log(f"nightly-next run {run_id}: would cancel, {why}")
            done.append(run_id)
            continue
        try:
            api.cancel(run_id)
        except Unreadable as error:
            warn(f"run {run_id}: the cancel was refused ({error}); the next tick reads it again")
            continue
        log(f"::notice title=nightly-next supersede::cancelled run {run_id} ({group_of(current)} group, "
            f"{str(current.get('head_sha'))[:12]}) so the tip builds: {why}")
        done.append(run_id)
    return done


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("repo")
    parser.add_argument("--dry-run", action="store_true", help="read and decide only; cancel nothing")
    args = parser.parse_args(argv)
    tick(Api(args.repo), dry_run=args.dry_run)
    return 0


if __name__ == "__main__":
    sys.exit(main())
