.PHONY: check test

# The house rules, in about a second. Each breach prints as file:line and the fix.
check:
	@node --test --test-reporter=./checks/reporter.mjs checks/*.test.mjs

# The Swift tests: the app scheme's test action, which runs KitTests with no host application, so
# nothing opens on screen. Unsigned, into .build/, which git ignores. It prints each test's line;
# the whole log is .build/test.log.
test:
	@xcodegen generate --no-env --quiet --spec project.yml --project . --project-root .
	@mkdir -p .build; xcodebuild test -project QotaFolio.xcodeproj -scheme QotaFolio \
	  -destination "platform=macOS,arch=$$(uname -m)" -derivedDataPath .build/DerivedData CODE_SIGNING_ALLOWED=NO \
	  > .build/test.log 2>&1; status=$$?; \
	  grep -E '(✔|✘) Test |recorded an issue|Test run with|error:' .build/test.log; \
	  [ $$status -eq 0 ] && echo "test: pass" || echo "test: fail. The whole log is .build/test.log."; exit $$status
