# ReRNDIS build entry points.

CONFIG ?= release

.PHONY: build debug test lint app install uninstall dist clean

build:
	swift build -c $(CONFIG)

debug:
	swift build

test:
	swift test

lint:
	swiftlint lint --strict --quiet

app: build
	Support/bundle-app.sh $(CONFIG)

install: build
	sudo Support/install.sh $(CONFIG)

uninstall:
	sudo Support/uninstall.sh

dist:
	# Macro-based dependencies cannot resolve in a single multi-arch build
	# (SwiftPM cannot place the macro plugin per slice), so each architecture is
	# built on its own and the slices are merged with lipo.
	swift build -c release --arch arm64
	swift build -c release --arch x86_64
	rm -rf dist/ReRNDIS-dist && mkdir -p dist/ReRNDIS-dist
	for tool in ReRNDISDaemon rerndisctl; do \
		lipo -create \
			.build/arm64-apple-macosx/release/$$tool \
			.build/x86_64-apple-macosx/release/$$tool \
			-output dist/ReRNDIS-dist/$$tool; \
	done
	swift build -c release
	lipo -create \
		.build/arm64-apple-macosx/release/ReRNDISApp \
		.build/x86_64-apple-macosx/release/ReRNDISApp \
		-output dist/ReRNDIS-dist/app-universal
	mv dist/ReRNDIS-dist/app-universal .build/release/ReRNDISApp
	Support/bundle-app.sh release
	cp -R dist/ReRNDIS.app dist/ReRNDIS-dist/
	cp Support/be.zvz.rerndis.daemon.plist Support/install.sh Support/uninstall.sh dist/ReRNDIS-dist/
	cd dist && zip -qry ReRNDIS-dist.zip ReRNDIS-dist
	Support/make-dmg.sh
	@echo "dist/ReRNDIS-dist.zip and dist/ReRNDIS-dist.dmg ready"

clean:
	swift package clean
	rm -rf dist
