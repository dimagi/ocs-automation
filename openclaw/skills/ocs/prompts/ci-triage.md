# CI Failure Triage

CI failed on {{branch}} (run ID: {{run_id}}).

Your job:
1. Fetch the failure logs: `gh run view {{run_id}} --log-failed`
2. Identify the root cause
3. If it's a flaky test, say so clearly
4. If it's a real failure, diagnose and suggest a fix
5. Post your analysis to Slack channel #ocs-ci-alerts

Be specific about the failing test/step and likely cause. Keep it under 300 words.
