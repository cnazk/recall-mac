.DEFAULT_GOAL := build

build: ## Build all targets (debug)
	swift build

test: ## Run the test suite
	swift test

app: ## Assemble and sign Recall.app
	./Scripts/bundle.sh

run: app ## Build the app bundle and launch it
	open .build/Recall.app

clean: ## Remove build products
	rm -rf .build

help: ## List targets
	@grep -E '^[a-z-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-8s %s\n", $$1, $$2}'

.PHONY: build test app run clean help
