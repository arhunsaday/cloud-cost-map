.PHONY: build test app run brand open clean

build:
	swift build

test:
	swift test

# Bundled, signed app in build/
app:
	scripts/bundle.sh release

run: app
	open "build/Cloud Cost Map.app"

# Regenerate the icon and logo from scripts/brand.swift
brand:
	swift scripts/brand.swift

# Open the package in Xcode (run the CloudCostMap scheme)
open:
	open Package.swift

clean:
	rm -rf .build build
