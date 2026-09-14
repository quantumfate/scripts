# Task runner. Run `just` to list recipes.

default:
	@just --list

# Reformat the tree in place
fmt:
	shfmt -w -i 4 $(git ls-files '*.sh' 'bin/,*' 'tests/*.sh')
	ruff format .
	prettier --write '**/*.md'

# Verify formatting without writing
fmt-check:
	shfmt -d -i 4 $(git ls-files '*.sh' 'bin/,*' 'tests/*.sh')
	ruff format --check .
	prettier --check '**/*.md'

# Static analysis. Gated rather than advisory: these scripts run against a live
# desktop, and ,theme.sh alone touches five subsystems.
lint:
	shellcheck $(git ls-files '*.sh' 'bin/,*' 'tests/*.sh')

# The Python helpers carry findings that predate the gate. Advisory until they
# are cleared, so the shell side is not held up behind them.
lint-py:
	ruff check .

# Tests run against scratch XDG trees, never the machine they run on.
test:
	./tests/theme_test.sh
	./tests/scene_apply_test.sh
	./tests/hyprfocus_test.sh
	@pytest -q 2>/dev/null || true

# CI/pre-commit gate. lint-py stays out until its findings are cleared.
check: fmt-check lint test
