#!/usr/bin/env python3
"""scripts/ci/nightly_next_supersede.py and scripts/ci/nightly_now.py (no network).

2026-11-10/11: push runs 42925854615 and 42929616529, then sign run 42930383771, held nightly-next's push and
sign groups for hours with every remaining job queued on a runner label that had gone; tip runs 42945365476,
42947517129 and 42948266530 were each replaced while pending and never started. Leo: "aren't there things we
can just be like 'ok just get this one in asap'".
"""

from __future__ import annotations

import datetime as dt
import json
import sys
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
import nightly_next_supersede as sup  # noqa: E402
import nightly_now  # noqa: E402

TIP, OLD = "b" * 40, "a" * 40
NOW = dt.datetime.now(dt.timezone.utc)


def stamp(minutes_ago: float) -> str:
    return (NOW - dt.timedelta(minutes=minutes_ago)).strftime("%Y-%m-%dT%H:%M:%SZ")


def run(ident, head, status, *, event="push", title="x", created=60.0):
    return {"id": ident, "path": ".github/workflows/nightly.yml", "name": "Nightly macOS build",
            "display_title": title, "status": status, "conclusion": None, "head_sha": head,
            "head_branch": "nightly-next", "event": event, "run_attempt": 1, "workflow_id": 7,
            "created_at": stamp(created), "head_repository": {"full_name": "manaflow-ai/cmux"}}


JOB_IDS = iter(range(1000, 10**6))


def job(name, status="queued", conclusion=None, *, runner=None, start=58.0, end=None):
    return {"id": next(JOB_IDS), "name": name, "status": status, "conclusion": conclusion, "labels": ["dead-light-label"],
            "runner_name": runner, "started_at": stamp(start), "completed_at": None if end is None else stamp(end),
            "run_attempt": 1}


QUEUED = [job("decide", "completed", "success", runner="r", start=59, end=58),
          job("build-nightly-app"), job("signer-build")]


class FakeGh:
    """Answers the reads from a table; records writes."""

    def __init__(self, runs, jobs, prs=()):
        self.runs, self.jobs, self.prs, self.writes = runs, jobs, list(prs), []

    def __call__(self, args, write):
        if write:
            self.writes.append(list(args))
            return ""
        path = args[1].split("repos/o/r/", 1)[1]
        if path.startswith("actions/workflows/nightly.yml/runs?"):
            status = path.split("status=", 1)[1].split("&", 1)[0]
            listed = [r for r in self.runs if r["status"] == status]
            return json.dumps({"total_count": len(listed), "workflow_runs": listed})
        if path.startswith("actions/runs/") and "/jobs" in path:
            ident = int(path.split("/")[2])
            listed = self.jobs.get(ident, [])
            return json.dumps({"total_count": len(listed), "jobs": listed})
        if path.startswith("actions/runs/"):
            ident = int(path.split("/")[2].split("?")[0])
            return json.dumps(next(r for r in self.runs if r["id"] == ident))
        if path.startswith("commits/"):
            return json.dumps(self.prs)
        raise AssertionError(path)


def api(gh, tip=TIP):
    return sup.Api("o/r", gh=gh, tip=lambda repo, branch: tip)


class SupersedeTests(unittest.TestCase):
    def test_tonights_push_holder_is_cancelled_for_the_waiting_tip(self):
        holder, waiter = run(42925854615, OLD, "in_progress"), run(42948266530, TIP, "pending", created=2)
        gh = FakeGh([holder, waiter], {42925854615: QUEUED, 42948266530: []})
        log = []
        self.assertEqual(sup.tick(api(gh), log=log.append), [42925854615])
        self.assertEqual(gh.writes, [["api", "-X", "POST", "repos/o/r/actions/runs/42925854615/cancel"]])
        self.assertTrue(any("cancelled run 42925854615" in line and "(3b)" in line for line in log), log)

    def test_dry_run_cancels_nothing(self):
        holder, waiter = run(1, OLD, "in_progress"), run(2, TIP, "pending", created=2)
        gh = FakeGh([holder, waiter], {1: QUEUED, 2: []})
        self.assertEqual(sup.tick(api(gh), dry_run=True, log=lambda _: None), [1])
        self.assertEqual(gh.writes, [])

    def test_a_started_build_is_never_cancelled(self):
        started = [*QUEUED[:1], job("build-nightly-app", "in_progress", runner="mini", start=30)]
        holder, waiter = run(1, OLD, "in_progress"), run(2, TIP, "pending", created=2)
        gh = FakeGh([holder, waiter], {1: started, 2: []})
        self.assertEqual(sup.tick(api(gh), log=lambda _: None), [])
        self.assertEqual(gh.writes, [])

    def test_the_tip_run_itself_is_never_cancelled(self):
        holder = run(1, TIP, "in_progress")
        gh = FakeGh([holder], {1: QUEUED})
        self.assertEqual(sup.tick(api(gh), log=lambda _: None), [])

    def test_an_open_pull_request_at_its_head_keeps_it(self):
        holder, waiter = run(1, OLD, "in_progress"), run(2, TIP, "pending", created=2)
        gh = FakeGh([holder, waiter], {1: QUEUED, 2: []}, prs=[{"number": 9, "state": "open", "head": {"sha": OLD}}])
        self.assertEqual(sup.tick(api(gh), log=lambda _: None), [])
        self.assertEqual(gh.writes, [])

    def test_an_unread_listing_cancels_nothing(self):
        def broken(args, write):
            raise sup.Unreadable("rate limited")
        log = []
        self.assertEqual(sup.tick(sup.Api("o/r", gh=broken, tip=lambda r, b: TIP), log=log.append), [])
        self.assertIn("nothing cancelled", log[0])

    def test_a_refused_cancel_is_a_warning(self):
        holder, waiter = run(1, OLD, "in_progress"), run(2, TIP, "pending", created=2)
        gh = FakeGh([holder, waiter], {1: QUEUED, 2: []})
        real = gh.__call__

        def refuse(args, write):
            if write:
                raise sup.Unreadable("409")
            return real(args, write)
        log = []
        self.assertEqual(sup.tick(sup.Api("o/r", gh=refuse, tip=lambda r, b: TIP), log=log.append), [])
        self.assertTrue(any("refused" in line for line in log), log)

    def test_the_tick_runs_it_in_its_own_group_for_every_event(self):
        tick = yaml.safe_load((ROOT / ".github/workflows/nightly-next-tick.yml").read_text(encoding="utf-8"))
        job = tick["jobs"]["supersede"]
        self.assertEqual(job["concurrency"], {"group": "nightly-next-tick-supersede", "cancel-in-progress": False})
        self.assertNotIn("inputs.sha", job["if"], "a dispatch for one commit (nightly-now) supersedes too")
        self.assertEqual(job["permissions"], {"actions": "write", "contents": "read"})
        self.assertNotIn("secrets.", json.dumps(job))
        step = job["steps"][-1]
        self.assertTrue(step.get("continue-on-error"), "a failed supersede never fails the tick")
        self.assertIn("nightly_next_supersede.py", step["run"])
        sparse = job["steps"][0]["with"]["sparse-checkout"]
        for path in ("scripts/ci/delivery_workflows.py", "scripts/ci/nightly_next_supersede.py"):
            self.assertIn(path, sparse)


class NightlyNowTests(unittest.TestCase):
    def call(self, argv, tip=TIP):
        sent, log = [], []

        def gh(args):
            sent.append(list(args))
            if args[0] == "api":
                return "c" * 40 + "\n"
            return ""
        code = nightly_now.main(argv, gh=gh, tip=lambda repo, branch: tip, check=lambda repo: [], log=log.append)
        return code, sent, log

    def test_defaults_to_the_feat_cmux_next_tip(self):
        code, sent, _ = self.call(["--repo", "o/r"])
        self.assertEqual(code, 0)
        self.assertEqual(sent, [["workflow", "run", "nightly-next-tick.yml", "--repo", "o/r", "--ref", "main",
                                 "-f", f"sha={TIP}"]])

    def test_a_given_sha_and_a_short_one(self):
        self.assertEqual(self.call([OLD, "--repo", "o/r"])[1][-1][-1], f"sha={OLD}")
        code, sent, _ = self.call(["abc1234", "--repo", "o/r"])
        self.assertEqual(code, 0)
        self.assertEqual(sent[0][:2], ["api", "repos/o/r/commits/abc1234"])
        self.assertEqual(sent[-1][-1], "sha=" + "c" * 40)

    def test_dry_run_sends_nothing_and_a_bad_sha_is_refused(self):
        code, sent, log = self.call(["--repo", "o/r", "--dry-run"])
        self.assertEqual((code, sent), (0, []))
        self.assertIn("would run gh workflow run nightly-next-tick.yml", log[0])
        self.assertEqual(self.call(["not-a-sha", "--repo", "o/r"])[0], 2)

    def test_it_never_cancels(self):
        _, sent, _ = self.call(["--repo", "o/r", "--check"])
        self.assertFalse(any("cancel" in " ".join(args) for args in sent))


if __name__ == "__main__":
    unittest.main()
