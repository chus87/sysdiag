SHELL := /usr/bin/env bash
VERSION := 0.14.2
GO_VERSION := $(shell cat .go-version)
COMMIT ?= $(shell git rev-parse --short=12 HEAD 2>/dev/null || echo unknown)
TAG ?= $(shell git describe --tags --exact-match HEAD 2>/dev/null || echo untagged)
BUILD_DATE ?= $(if $(SOURCE_DATE_EPOCH),$(shell date -u -d "@$(SOURCE_DATE_EPOCH)" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown),unknown)
GO_LDFLAGS := -s -w -buildid= \
	-X github.com/chus87/sysdiag/internal/version.Commit=$(COMMIT) \
	-X github.com/chus87/sysdiag/internal/version.Tag=$(TAG) \
	-X github.com/chus87/sysdiag/internal/version.BuildDate=$(BUILD_DATE)

.PHONY: all build build-linux test test-go test-race syntax lint standalone checksums json-check schema-check sbom build-info release-tree release-check release source-release clean vm-help vuln-check provenance-check

all: build

build: test-go build-linux

standalone:
	./build-standalone.sh
	cmp -s sysdiag-standalone.sh internal/assets/sysdiag-standalone.sh

build-linux: standalone provenance-check
	mkdir -p bin
	CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -buildvcs=false -trimpath -ldflags='$(GO_LDFLAGS)' -o bin/sysdiag-linux-amd64 ./cmd/sysdiag
	CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -buildvcs=false -trimpath -ldflags='$(GO_LDFLAGS)' -o bin/sysdiag-linux-arm64 ./cmd/sysdiag

provenance-check:
	@actual="$$(go env GOVERSION | sed 's/^go//')"; \
	[[ "$$actual" == "$(GO_VERSION)" ]] || { echo "Go toolchain esperado $(GO_VERSION), actual $$actual" >&2; exit 1; }
	@if [[ "$(TAG)" != "untagged" ]]; then \
		expected="v$(VERSION)"; [[ "$(TAG)" == "$$expected" ]] || { echo "El tag $(TAG) no coincide con $$expected" >&2; exit 1; }; \
	fi

test-go: standalone provenance-check
	@test -z "$$(gofmt -l cmd internal)" || { gofmt -l cmd internal; exit 1; }
	go vet ./...
	go test ./...

test-race: standalone provenance-check
	go test -race ./...

test: syntax test-go build-linux checksums
	./tests/run.sh

syntax:
	find . -type f -name '*.sh' -print0 | xargs -0 -n1 bash -n

lint: test-go
	@./tests/ensure-shellcheck.sh || rc=$$?; \
	if command -v shellcheck >/dev/null 2>&1; then \
		shellcheck --shell=bash --severity=error -x sysdiag.sh sysdiag-legacy.sh build-standalone.sh build-sbom.sh build-info.sh release.sh scripts/*.sh lib/*.sh modules/*.sh tests/*.sh tests/integration/*.sh tests/vm/*.sh; \
	else echo 'shellcheck no está instalado; lint Bash omitido'; exit $${rc:-2}; fi

vuln-check: provenance-check
	@command -v govulncheck >/dev/null 2>&1 || { echo 'Falta govulncheck. Instala con: go install golang.org/x/vuln/cmd/govulncheck@latest' >&2; exit 2; }
	govulncheck ./...

checksums: build-linux
	sha256sum sysdiag-standalone.sh bin/sysdiag-linux-amd64 bin/sysdiag-linux-arm64 > SHA256SUMS

schema-check: build-linux
	@python3 -c 'import jsonschema' >/dev/null 2>&1 || { echo 'Falta el módulo Python jsonschema para validar el contrato de release.' >&2; exit 2; }
	./sysdiag.sh --section memory --json > /tmp/sysdiag-schema-check.json
	python3 -c 'import json,jsonschema; s=json.load(open("docs/sysdiag-json-schema-v1.1.json")); x=json.load(open("/tmp/sysdiag-schema-check.json")); jsonschema.Draft202012Validator(s, format_checker=jsonschema.FormatChecker()).validate(x)'

json-check: schema-check
	python3 -m json.tool /tmp/sysdiag-schema-check.json >/dev/null

sbom: build-linux
	./build-sbom.sh

build-info: build-linux
	COMMIT='$(COMMIT)' TAG='$(TAG)' BUILD_DATE='$(BUILD_DATE)' ./build-info.sh

release-tree: build-linux checksums
	./tests/test_release_tree.sh

release-check: test test-race vuln-check schema-check sbom build-info release-tree
	sha256sum -c SHA256SUMS

release:
	./release.sh "$(CURDIR)/dist"

source-release:
	./scripts/source-archive.sh "$(CURDIR)/dist-source"

clean:
	rm -rf bin dist SBOM.spdx.json BUILDINFO.txt SHA256SUMS

vm-help:
	@echo 'Consulta tests/vm/README.md para la matriz Ubuntu/Debian/Rocky/Alma con KVM/libvirt.'
