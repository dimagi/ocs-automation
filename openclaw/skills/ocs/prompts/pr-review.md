# PR Review Task

You are reviewing PR #{{pr_number}} in the open-chat-studio repository.

Your job:
1. Read the PR diff carefully
2. Check for bugs, security issues, and code quality problems
3. Run the test suite: `uv run pytest`
4. Post a structured review comment to the PR via GitHub CLI

Use `gh pr view {{pr_number}}` to get PR details and `gh pr diff {{pr_number}}` for the diff.
Post your review with `gh pr review {{pr_number}} --comment -b "..."`.

The open-chat-studio-docs are available at /workspace/docs for additional context.

Be concise. Focus on bugs and correctness, not style nitpicks.
