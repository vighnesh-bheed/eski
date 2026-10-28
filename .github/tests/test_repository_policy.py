from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from repository_policy import body_errors, branch_errors, event_errors


def pull_request(head, base, head_repo="owner/project"):
    return {
        "body": "We need this change so the intended workflow works. The focused checks pass.",
        "head": {"ref": head, "repo": {"full_name": head_repo}},
        "base": {"ref": base, "repo": {"full_name": "owner/project"}},
    }


class BodyPolicyTests(unittest.TestCase):
    def test_accepts_plain_paragraphs_and_paths(self):
        body = "We need src/file_name.py to handle x < y.\n\nChecks passed; see https://example.com/result."
        self.assertEqual(body_errors(body), [])

    def test_accepts_exactly_500_words(self):
        self.assertEqual(body_errors(" ".join(["word"] * 500)), [])

    def test_rejects_501_words(self):
        self.assertTrue(body_errors("\n".join(["word"] * 501)))

    def test_rejects_missing_explanation(self):
        for body in (None, "", " \n\t"):
            with self.subTest(body=body):
                self.assertTrue(body_errors(body))

    def test_rejects_headings_sections_and_decoration(self):
        for body in (
            "# Summary\nA change.", "Summary\n=======\nA change.",
            "Testing:\nChecks passed.", "- A change.", "1. A change.",
            "**A change.**", "*A change.*", "_A change._", "`file.py` changed.",
            "```\ncode\n```", "[A link](https://example.com)",
            "| Column | Value |", "> Quoted text", "<h1>A change</h1>",
        ):
            with self.subTest(body=body):
                self.assertTrue(body_errors(body))

    def test_rejects_attribution_footers(self):
        self.assertTrue(body_errors("A change.\nGenerated with Codex"))
        self.assertTrue(body_errors("A change.\nCo-Authored-By: Name"))


class BranchPolicyTests(unittest.TestCase):
    def test_accepts_work_branches_into_dev(self):
        for prefix in ("feature", "task", "chore", "bugfix"):
            with self.subTest(prefix=prefix):
                self.assertEqual(branch_errors(pull_request(f"{prefix}/a-change", "dev")), [])

    def test_accepts_contributor_work_into_dev(self):
        self.assertEqual(branch_errors(pull_request("feature/a-change", "dev", "contributor/fork")), [])

    def test_accepts_promotions(self):
        for head, base in (("dev", "stage"), ("stage", "main")):
            with self.subTest(head=head, base=base):
                self.assertEqual(branch_errors(pull_request(head, base)), [])

    def test_accepts_hotfix_and_synchronization(self):
        self.assertEqual(branch_errors(pull_request("hotfix/a-change", "stage")), [])
        self.assertEqual(branch_errors(pull_request("stage", "dev")), [])

    def test_rejects_skipped_levels(self):
        for head, base in (("feature/a-change", "main"), ("feature/a-change", "stage"), ("dev", "main")):
            with self.subTest(head=head, base=base):
                self.assertTrue(branch_errors(pull_request(head, base)))

    def test_rejects_fork_promotions_and_hotfixes(self):
        for head, base in (("stage", "main"), ("dev", "stage"), ("hotfix/a-change", "stage"), ("stage", "dev")):
            with self.subTest(head=head, base=base):
                self.assertTrue(branch_errors(pull_request(head, base, "contributor/fork")))

    def test_rejects_invalid_slugs_and_other_targets(self):
        for head, base in (("feature/Upper", "dev"), ("feature/two/levels", "dev"), ("misc/change", "dev"), ("feature/change", "other")):
            with self.subTest(head=head, base=base):
                self.assertTrue(branch_errors(pull_request(head, base)))

    def test_rejects_deleted_fork_during_promotion(self):
        request = pull_request("stage", "main")
        request["head"]["repo"] = None
        self.assertTrue(branch_errors(request))


class EventPolicyTests(unittest.TestCase):
    def test_validates_pull_request_body_and_route(self):
        request = pull_request("feature/change", "dev")
        self.assertEqual(event_errors({"pull_request": request}), [])
        request["body"] = "# Heading"
        self.assertTrue(event_errors({"pull_request": request}))

    def test_validates_issue_body(self):
        self.assertTrue(event_errors({"issue": {"body": "# Heading"}}))
        self.assertEqual(event_errors({"issue": {"body": "We need this so the workflow works."}}), [])

    def test_ignores_pull_requests_delivered_as_issue_events(self):
        self.assertEqual(event_errors({"issue": {"body": "# Heading", "pull_request": {}}}), [])

    def test_push_and_manual_events_need_no_body(self):
        self.assertEqual(event_errors({"ref": "refs/heads/dev"}), [])


if __name__ == "__main__":
    unittest.main()
