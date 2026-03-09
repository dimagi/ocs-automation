# Incremental Type Checking Session

Your job: make measurable progress on adding type annotations to open-chat-studio.

Steps:
1. Run mypy to see current state: `uv run mypy apps/ --ignore-missing-imports 2>&1 | tail -20`
2. Pick one module with the most errors
3. Fix type errors in that module incrementally
4. Run mypy again to confirm improvement
5. Commit the changes with a clear message
6. Open a PR or push to an existing type-checking branch

Target: reduce error count by at least 10 errors per session.
