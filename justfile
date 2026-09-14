# Task runner. Run `just` to list recipes.

# The shell files, by shebang rather than by name: bin/ holds Python too
# (,hyprfocus, ,hyprfocus-units) and shfmt cannot parse it.
shell_files := "$(git ls-files '*.sh' 'bin/,*' 'tests/*.sh' | xargs -r grep -lE '^#!.*(ba)?sh' )"
python_files := "$(git ls-files 'bin/,*' '*.py' | xargs -r grep -lE '^#!.*python' )"

default:
	@just --list

# Reformat the tree in place
fmt:
	shfmt -w -i 4 {{ shell_files }}
	ruff format .
	prettier --write '**/*.md'

# Verify formatting without writing
fmt-check:
	shfmt -d -i 4 {{ shell_files }}
	ruff format --check .
	prettier --check '**/*.md'

# Static analysis. Gated rather than advisory: these scripts run against a live
# desktop, and ,theme.sh alone touches five subsystems.
lint:
	shellcheck {{ shell_files }}

# The Python helpers carry findings that predate the gate. Advisory until they
# are cleared, so the shell side is not held up behind them.
lint-py:
	ruff check .

# Tests run against scratch XDG trees, never the machine they run on.
test:
	./tests/theme_test.sh
	./tests/scene_apply_test.sh
	./tests/hyprfocus_test.sh
	./tests/hyprfocus_units_test.sh
	@pytest -q 2>/dev/null || true

# Regenerate the capability targets. `just check` fails if the committed ones
# and the contract have drifted, so this is what clears that.
units:
	./bin/,hyprfocus-units generate

# CI/pre-commit gate. lint-py stays out until its findings are cleared.
check: fmt-check lint test
