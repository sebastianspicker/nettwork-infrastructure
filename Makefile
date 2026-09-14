.PHONY: generate build check format check-format check-scripts check-web check-demo build-demo check-package check-config check-syntax check-assets check-whitespace check-architecture check-quality test lint-docs verify-source verify-package verify-native benchmark

NATIVE_DERIVED_DATA ?= $(CURDIR)/DerivedData

generate:
	@command -v xcodegen >/dev/null || { \
		echo "xcodegen is required: brew install xcodegen"; \
		exit 1; \
	}
	xcodegen generate

build: check-package

check: build verify-source

format:
	xcrun swift format format --configuration .swift-format --in-place --recursive \
		NettworkApp Packages/NettworkCore/Sources Packages/NettworkCore/Tests Packages/NettworkCore/Benchmarks Tests/App
	npm run format
	@find scripts -type f -name '*.sh' -print0 | xargs -0 shfmt -w -i 4 -ci

check-format:
	xcrun swift format lint --strict --configuration .swift-format --recursive \
		NettworkApp Packages/NettworkCore/Sources Packages/NettworkCore/Tests Packages/NettworkCore/Benchmarks Tests/App
	xcrun swift format lint --strict --configuration .swift-format-production --recursive \
		NettworkApp Packages/NettworkCore/Sources Packages/NettworkCore/Benchmarks
	npm run check:format
	@find scripts -type f -name '*.sh' -print0 | xargs -0 shfmt -d -i 4 -ci

check-scripts:
	@find scripts -type f -name '*.rb' -print0 | xargs -0 -n1 ruby -cw
	@find scripts -type f -name '*.sh' -print0 | xargs -0 shellcheck
	@find scripts -type f -name '*.sh' -print0 | xargs -0 shfmt -d -i 4 -ci
	@find scripts -type f -name '*.sh' -print0 | xargs -0 -n1 bash -n
	npm run check:clones:scripts

check-web:
	npm run lint:js
	npm run check:format
	npm run check:clones:web
	bash scripts/validate-demo.sh

check-demo:
	bash scripts/validate-demo.sh

build-demo:
	bash scripts/build-demo.sh

check-package:
	swift package --package-path Packages/NettworkCore dump-package >/dev/null
	swift build --package-path Packages/NettworkCore --target NetworkModel -Xswiftc -warnings-as-errors
	swift build --package-path Packages/NettworkCore --target CloudSync -Xswiftc -warnings-as-errors
	swift build --package-path Packages/NettworkCore --target ImportExport -Xswiftc -warnings-as-errors

check-config:
	ruby -e 'require "yaml"; spec = YAML.load_file("project.yml"); abort "missing Nettwork targets" unless spec.dig("targets", "Nettwork") && spec.dig("targets", "NettworkMac")'
	plutil -lint NettworkApp/Resources/Info.plist Config/Nettwork-iOS.entitlements \
		Config/Nettwork-macOS.entitlements

check-syntax:
	@rg --files NettworkApp Tests/App \
		Packages/NettworkCore/Sources Packages/NettworkCore/Tests Packages/NettworkCore/Benchmarks \
		-g '*.swift' -0 | xargs -0 swiftc -parse

check-assets:
	bash scripts/validate-assets.sh

check-whitespace:
	@git ls-files --cached --others --exclude-standard | while IFS= read -r file; do \
		case "$$file" in *.md) continue ;; esac; \
		output=$$(git diff --no-index --check /dev/null "$$file" 2>&1); \
		result_code=$$?; \
		if test "$$result_code" -gt 1 || test -n "$$output"; then \
			echo "$$file"; \
			echo "$$output"; \
			exit 1; \
		fi; \
	done

check-architecture:
	bash scripts/check-architecture.sh

check-quality:
	ruby scripts/swift_quality_check.rb

test:
	swift test --package-path Packages/NettworkCore -Xswiftc -warnings-as-errors

lint-docs:
	npm run lint:markdown

verify-source: check-format check-scripts check-web check-config check-syntax check-assets check-whitespace check-architecture check-quality lint-docs

verify-package: test

verify-native: generate
	xcodebuild -quiet -project Nettwork.xcodeproj -scheme 'Nettwork macOS' \
		-destination 'platform=macOS' -derivedDataPath '$(NATIVE_DERIVED_DATA)/macOS' \
		CODE_SIGNING_ALLOWED=NO test
	xcodebuild -quiet -project Nettwork.xcodeproj -scheme Nettwork \
		-destination 'generic/platform=iOS Simulator' -derivedDataPath '$(NATIVE_DERIVED_DATA)/iOS' \
		CODE_SIGNING_ALLOWED=NO build

benchmark:
	bash scripts/benchmark.sh
