.PHONY: setup project open test clean

# Симулятор для тестов: make test SIM="iPhone 16 Pro"
SIM ?= iPhone 17

# Первый запуск: ставит XcodeGen, создаёт локальный конфиг и проект, открывает Xcode.
setup:
	@command -v xcodegen >/dev/null || brew install xcodegen
	@test -f Config/Local.xcconfig || (cp Config/Local.xcconfig.example Config/Local.xcconfig && \
		echo "→ Создан Config/Local.xcconfig — впишите свой DEVELOPMENT_TEAM и BUNDLE_ID_PREFIX")
	@$(MAKE) project open

project:
	xcodegen generate

open:
	open TripAtlas.xcodeproj

test: project
	xcodebuild test -project TripAtlas.xcodeproj -scheme TripAtlas \
		-destination 'platform=iOS Simulator,name=$(SIM)'

clean:
	rm -rf TripAtlas.xcodeproj DerivedData build
