.PHONY: setup deps compile format format.check lint dialyzer test test.eval test.eval.holdout test.eval.validate_fixtures test.integration test.all check ci clean

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

test.eval.holdout:
	mix test --only eval --only holdout

test.eval.validate_fixtures:
	mix eval.validate_fixtures

test.integration:
	mix test --only integration

test.all:
	mix test --include eval --include integration

check: compile format.check lint test

ci: compile format.check lint dialyzer test.all

clean:
	mix clean
	rm -rf _build deps
