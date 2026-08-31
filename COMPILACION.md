# Compilar SYSdiag desde código fuente

Esta guía está pensada tanto para usuarios que quieran auditar/compilar SYSdiag como para mantenedores que preparen una release.

## 1. Toolchain

SYSdiag v0.14.2 exige **Go 1.27.0 exactamente**. `.go-version` y `go.mod` son la fuente de verdad. Las releases oficiales no se construyen con una versión distinta.

Comprueba:

```bash
cat .go-version
go version
```

Resultado esperado:

```text
1.27.0
go version go1.27.0 ...
```

Cuando Go publique una versión estable posterior, el workflow `Go stable version watch` abrirá un PR que actualiza y valida la nueva versión antes de adoptarla. La publicación de una release se bloquea si el repositorio no usa el último Go estable disponible.

## 2. Requisitos

Mínimo para compilar:

- Linux.
- Bash.
- Go 1.27.0.
- GNU Make.
- `sha256sum`.

Para ejecutar la validación completa de release se usan además:

- ShellCheck.
- Python 3 + `jsonschema`.
- `jq`.
- `govulncheck`.
- utilidades habituales Linux usadas por los tests.

## 3. Descargar el código

```bash
git clone https://github.com/chus87/sysdiag.git
cd sysdiag
```

Comprueba la versión:

```bash
cat .go-version
go version
```

## 4. Compilación rápida

```bash
make build
```

Genera binarios estáticos en:

```text
bin/sysdiag-linux-amd64
bin/sysdiag-linux-arm64
```

También regenera el standalone/collector Bash embebido.

## 5. Compilar sólo binarios Linux

```bash
make build-linux
```

## 6. Tests Go

```bash
make test-go
make test-race
```

## 7. Suite funcional completa

```bash
make test
```

## 8. Lint

```bash
make lint
```

Si ShellCheck no está instalado y la ejecución es interactiva, SYSdiag puede preguntar si quieres instalarlo. En CI no se instala implícitamente.

## 9. Vulnerabilidades Go

Instala la herramienta oficial si no la tienes:

```bash
go install golang.org/x/vuln/cmd/govulncheck@latest
```

Después:

```bash
make vuln-check
```

## 10. Validar schema y supply-chain

```bash
make schema-check
make sbom
make build-info
make release-tree
```

## 11. Validación equivalente a una release

```bash
make release-check
```

Incluye tests, race detector, schema, SBOM, build metadata, limpieza del árbol y checksums.

## 12. Crear todos los artefactos

```bash
make release
```

Se generan en `dist/`:

```text
sysdiag-vX.Y.Z.zip
sysdiag-vX.Y.Z.tar.gz
sysdiag-vX.Y.Z-linux-amd64
sysdiag-vX.Y.Z-linux-arm64
sysdiag-vX.Y.Z-standalone.sh
sysdiag-vX.Y.Z-SHA256SUMS.txt
sysdiag-vX.Y.Z-SBOM.spdx.json
sysdiag-vX.Y.Z-BUILDINFO.txt
sysdiag-vX.Y.Z-LICENSE.txt
sysdiag-vX.Y.Z-NOTICE.txt
sysdiag-vX.Y.Z-AUTHORS.txt
```

`release.sh` reconstruye ZIP/TAR de forma reproducible, los extrae, compara sus ficheros por SHA-256 y vuelve a validar los artefactos resultantes.

## 13. Release oficial en GitHub

Las releases oficiales se publican desde un **tag anotado y firmado**, por ejemplo:

```bash
git checkout main
git pull --ff-only
git tag -s v0.14.2 -m "SYSdiag v0.14.2"
git push origin v0.14.2
```

El workflow de release exige:

1. Tag `vX.Y.Z` coincidente con la versión del código.
2. Tag anotado y firma marcada como verificada por GitHub.
3. Toolchain exactamente igual a `.go-version`.
4. `.go-version` igual a la **última versión estable publicada por Go**.
5. `make lint`, `govulncheck` y `make release-check` correctos.
6. Paquetes reproducibles.
7. Attestation de GitHub y firma keyless Sigstore de cada artefacto.

Consulta `docs/RELEASING.md` para el procedimiento completo de publicación y verificación.

## 14. Compilar sin Git

Si has descargado el ZIP de código fuente:

```bash
unzip sysdiag-v0.14.2.zip
cd sysdiag-v0.14.2
make build
```

El build seguirá siendo funcional, aunque `--version` mostrará `Commit: unknown` y `Tag: untagged` si no existe metadata Git/inyección de release.

## 15. Principio read-only

Compilar desde fuentes no cambia el modelo de seguridad. Los comandos externos pasan por las barreras de ejecución read-only y las regresiones deben impedir acciones correctivas automáticas.

## Configuración de GitHub

Después de subir el código, aplica los ajustes de seguridad y automatización descritos en `docs/GITHUB-SETUP.md`. Algunos controles (protección de ramas/tags, secret scanning o permiso para que Actions abra PRs) son ajustes del repositorio y no pueden imponerse únicamente desde Git.

## Paquete fuente reproducible

Para generar un ZIP/TAR.GZ del código fuente sin incorporar binarios ni metadatos de una build local:

```bash
make source-release
```

Se crean en `dist-source/`. Esta es la opción adecuada para transportar o archivar el árbol que posteriormente compilará GitHub Actions con el toolchain fijado.
