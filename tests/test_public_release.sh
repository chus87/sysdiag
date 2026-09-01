#!/usr/bin/env bash
set -euo pipefail
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$BASE_DIR"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

go_version="$(cat .go-version)"
[[ "$go_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail '.go-version no contiene una versión estable X.Y.Z'
grep -qx "go $go_version" go.mod || fail "go.mod no declara go $go_version"
! grep -q '^toolchain ' go.mod || fail 'go.mod contiene una directiva toolchain redundante'
[[ "$go_version" == "1.27.0" ]] || fail 'La release 0.14.2 debe partir de Go 1.27.0'
grep -q '^VERSION := 0.14.2$' Makefile || fail 'Makefile no está en 0.14.2'
grep -q '^SYS_DIAG_VERSION="0.14.2"$' lib/version.sh || fail 'backend Bash no está en 0.14.2'
grep -q 'const Version = "0.14.2"' internal/version/version.go || fail 'Go Core no está en 0.14.2'

for f in LICENSE NOTICE AUTHORS COMANDOS.md COMPILACION.md CONTRIBUTING.md SECURITY.md .gitignore .gitattributes .editorconfig; do [[ -s "$f" ]] || fail "Falta $f"; done
for f in .github/dependabot.yml .github/CODEOWNERS .github/workflows/ci.yml .github/workflows/release.yml .github/workflows/go-version-watch.yml .github/workflows/codeql.yml .github/workflows/arm64-native.yml; do [[ -s "$f" ]] || fail "Falta $f"; done
for f in .github/ISSUE_TEMPLATE/bug_report.yml .github/ISSUE_TEMPLATE/feature_request.yml .github/PULL_REQUEST_TEMPLATE.md docs/SUPPORT.md docs/RELEASING.md docs/GITHUB-SETUP.md scripts/update-go-version.sh scripts/source-archive.sh; do [[ -s "$f" ]] || fail "Falta $f"; done

grep -q 'Apache License' LICENSE || fail 'LICENSE no parece Apache-2.0'
grep -q 'Copyright 2026 Chus' NOTICE || fail 'NOTICE no conserva copyright/autoria'
grep -q 'Chus' AUTHORS || fail 'AUTHORS no identifica al autor original'
grep -q 'const Author = "Chus' internal/version/version.go || fail 'El binario Go no identifica al autor'
grep -q 'Autor: Chus' lib/cli.sh || fail 'El standalone no identifica al autor'
grep -q -- '--containers-deep' COMANDOS.md || fail 'COMANDOS.md no documenta contenedores deep'
grep -q -- '--k8s-mode' COMANDOS.md || fail 'COMANDOS.md no documenta Kubernetes'
grep -q 'make release' COMPILACION.md || fail 'COMPILACION.md no documenta releases'
grep -q "$go_version" COMPILACION.md || fail "COMPILACION.md no documenta Go $go_version"

grep -q 'govulncheck' .github/workflows/ci.yml || fail 'CI sin govulncheck'
grep -q 'github/codeql-action/analyze@v4' .github/workflows/codeql.yml || fail 'CodeQL no configurado'
grep -q 'runs-on: ubuntu-24.04-arm' .github/workflows/arm64-native.yml || fail 'No hay validación ARM64 nativa'
grep -q 'actions/attest@v4' .github/workflows/release.yml || fail 'Release sin attestation'
grep -q 'sigstore/cosign-installer@v4' .github/workflows/release.yml || fail 'Release sin firma Sigstore'
! grep -Fq 'gh release create "$GITHUB_REF_NAME" dist/*' .github/workflows/release.yml || fail 'Release publica todo dist/* en vez de limitar assets'
! grep -Fq 'artifacts=(dist/*)' .github/workflows/release.yml || fail 'Sigstore firma indiscriminadamente todo dist/*'
for asset in linux-amd64 linux-arm64 standalone.sh; do
  grep -Fq "dist/sysdiag-\${GITHUB_REF_NAME}-$asset" .github/workflows/release.yml || fail "Falta asset público $asset"
done
# ZIP/TAR.GZ públicos son los Source code archives generados automáticamente por GitHub;
# no deben subirse duplicados desde dist/.
! grep -Fq '"${prefix}.zip"' .github/workflows/release.yml || fail 'Release publica un ZIP duplicado además del Source code de GitHub'
! grep -Fq '"${prefix}.tar.gz"' .github/workflows/release.yml || fail 'Release publica un TAR.GZ duplicado además del Source code de GitHub'
grep -q 'verification.verified' .github/workflows/release.yml || fail 'Release no exige tag firmado/verificado'
grep -q 'https://go.dev/VERSION?m=text' .github/workflows/release.yml || fail 'Release no exige último Go estable'
grep -q 'https://go.dev/VERSION?m=text' .github/workflows/go-version-watch.yml || fail 'No existe vigilancia del último Go estable'
grep -q 'package-ecosystem: github-actions' .github/dependabot.yml || fail 'Dependabot no cubre Actions'
grep -q 'package-ecosystem: gomod' .github/dependabot.yml || fail 'Dependabot no cubre Go'
[[ -x scripts/update-go-version.sh ]] || fail 'update-go-version.sh no es ejecutable'
grep -q '\.go-version' scripts/update-go-version.sh || fail 'actualizador no toca .go-version'
! grep -q "f'toolchain go{v}'" scripts/update-go-version.sh || fail 'actualizador reintroduce una directiva toolchain redundante'

printf 'OK: public release hardening SYSdiag 0.14.2\n'

grep -q 'source-release' "$BASE_DIR/Makefile" || fail 'Makefile sin target source-release'
grep -q 'COMANDOS.md' "$BASE_DIR/scripts/source-archive.sh" || fail 'source-archive no verifica COMANDOS.md'
