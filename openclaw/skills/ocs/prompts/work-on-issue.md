# Work On Issue #{{issue_number}}

Your job: implement the changes described in GitHub issue #{{issue_number}}.

The open-chat-studio-docs are available at /workspace/docs for architectural context.

Steps:
1. Read the issue: `gh issue view {{issue_number}}`
2. Understand the codebase context (read relevant files)
3. Write tests first (TDD)
4. Implement the changes
5. Run tests: `uv run pytest`
6. Open a draft PR when done: `gh pr create --draft --title "..." --body "..."`

Stay focused on what the issue asks for. Don't refactor unrelated code.
