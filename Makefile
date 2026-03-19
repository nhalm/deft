.PHONY: setup deps compile format format.check lint dialyzer test test.eval test.eval.e2e test.eval.benchmark test.eval.holdout test.eval.validate_fixtures test.eval.check-structure test.eval.calibrate test.integration test.all check ci clean

setup: deps
	lefthook install

deps:
	mix deps.get

compile:
	mix compile --warnings-as-errors

format:
	mix format

format.check:
	mix format --check-formatted

lint:
	mix credo --strict

dialyzer:
	mix dialyzer

test:
	mix test --exclude eval --exclude integration

test.eval:
	mix test --only eval --exclude holdout

test.eval.e2e:
	mix test --only e2e

test.eval.benchmark:
	mix test --only benchmark --include e2e

test.eval.holdout:
	mix test --only holdout

test.eval.validate_fixtures:
	mix eval.validate_fixtures

test.eval.check-structure:
	@echo "Validating test/eval/ directory structure..."
	@test -d test/eval || (echo "ERROR: test/eval/ directory is missing" && exit 1)
	@test $$(find test/eval -name "*.exs" -type f | wc -l) -ge 26 || \
		(echo "ERROR: test/eval/ is missing test files (found $$(find test/eval -name "*.exs" -type f | wc -l), expected at least 26)" && exit 1)
	@test -f test/eval/support/eval_helpers.ex || (echo "ERROR: test/eval/support/eval_helpers.ex is missing" && exit 1)
	@echo "✓ test/eval/ structure validation passed ($$(find test/eval -name "*.exs" -type f | wc -l) test files found)"

test.eval.calibrate:
	mix test --only calibration

test.integration:
	mix test --only integration

test.all:
	mix test --include eval --include integration

check: compile format.check lint test.eval.check-structure test

ci: test.eval.check-structure compile format.check lint dialyzer test.all

clean:
	mix clean
	rm -rf _build deps
