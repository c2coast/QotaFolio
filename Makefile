.PHONY: check

# The house rules, in about a second. Each breach prints as file:line and the fix.
check:
	@node --test --test-reporter=./checks/reporter.mjs checks/*.test.mjs
