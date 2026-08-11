.PHONY: build test api-baseline api-baseline-update pod-lint docs-verify gate clean

# Canonical verification gate for otpless-headless-iOS-sdk (OtplessBM).
# Run `make gate` before claiming any SDK change works — see the verify skill
# (.claude/skills/verify/SKILL.md) for what each rung actually checks and why.
# CLAUDE.md's "Build & test" section documents this same command list; if you
# change a target's command here, update CLAUDE.md in the same commit —
# scripts/docs-verify.sh mechanically checks the two stay in sync.

build:
	bash scripts/build.sh

test:
	bash scripts/run-tests.sh

api-baseline:
	bash scripts/check-api-baseline.sh

api-baseline-update:
	bash scripts/check-api-baseline.sh --update

pod-lint:
	pod lib lint OtplessBM.podspec --allow-warnings

docs-verify:
	bash scripts/docs-verify.sh

gate: build test api-baseline pod-lint docs-verify

clean:
	rm -rf .build
