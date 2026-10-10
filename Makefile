.PHONY: web project app test run clean

web:
	cd web && npm ci && npm run build

project:
	xcodegen generate

app: web project
	xcodebuild -project Readout.xcodeproj -scheme Readout -configuration Release -derivedDataPath build build
	@echo "Built build/Build/Products/Release/Readout.app"

run: app
	open build/Build/Products/Release/Readout.app

test:
	swift test --package-path Packages/ReadoutCore

clean:
	rm -rf build web/dist Readout.xcodeproj
