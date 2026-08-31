# Configuración recomendada del repositorio GitHub

Este documento recoge ajustes de GitHub que no viven en el árbol Git y que conviene activar después de crear el repositorio público `chus87/sysdiag`.

## 1. Crear el repositorio

1. Crea el repositorio público `chus87/sysdiag`.
2. No inicialices README, licencia ni `.gitignore` desde GitHub si vas a subir este árbol: ya existen en SYSdiag.
3. Sube la rama principal como `main`.

## 2. Actions

En **Settings → Actions → General**:

- Permite GitHub Actions para el repositorio.
- En **Workflow permissions**, usa los permisos mínimos posibles. Los workflows de SYSdiag declaran explícitamente los permisos adicionales que necesitan.
- Activa **Allow GitHub Actions to create and approve pull requests**. Es necesario para que `go-version-watch.yml` pueda abrir automáticamente un PR cuando aparezca una versión estable de Go más reciente.

## 3. Protección de `main`

Configura una ruleset o branch protection para `main`:

- Requerir Pull Request antes de merge.
- Requerir al menos una revisión si habrá más mantenedores.
- Requerir que pasen los checks de CI y CodeQL.
- Bloquear force-push.
- Bloquear eliminación de la rama.
- Requerir resolución de conversaciones antes del merge.

Si GitHub muestra los nombres exactos de checks después del primer PR, selecciona los correspondientes a:

- `SYSdiag CI`
- `CodeQL`

## 4. Protección de tags de release

Crea una ruleset para `v*`:

- Impedir actualización o eliminación accidental de tags publicados.
- Restringir la creación de tags de release a los mantenedores autorizados si el plan de GitHub lo permite.

El workflow `release.yml` añade además otra barrera: sólo publica si el tag es anotado, está firmado y GitHub verifica la firma.

## 5. Seguridad

En **Settings → Security / Code security and analysis** activa, cuando estén disponibles para el repositorio:

- Dependabot alerts.
- Dependabot security updates.
- Secret scanning.
- Push protection for secrets.
- Private vulnerability reporting.

El repositorio incluye `SECURITY.md` para dirigir los reportes privados.

## 6. Actualización automática de Go

`go-version-watch.yml` se ejecuta semanalmente y también manualmente.

Su funcionamiento es:

1. Consulta `https://go.dev/VERSION?m=text`.
2. Compara la última versión estable con `.go-version`.
3. Si hay una más reciente, actualiza `.go-version` y `go.mod`.
4. Ejecuta `go mod tidy`, `go test` y `go vet`.
5. Abre un Pull Request para revisión.

La versión de Go queda fijada por release. Esto combina toolchain reciente con builds reproducibles: una release nunca cambia de compilador a posteriori.

## 7. Primera release

Antes de crearla:

```bash
git status
git pull --ff-only
git tag -s v0.14.1 -m "SYSdiag v0.14.1"
git tag -v v0.14.1
git push origin v0.14.1
```

El push del tag dispara `.github/workflows/release.yml`.

Ese workflow:

- exige Go estable más reciente;
- verifica versión y tag firmado;
- ejecuta lint, tests, race detector, `govulncheck` y validaciones de release;
- genera amd64, arm64, standalone, ZIP, TAR.GZ, checksums, SBOM y BUILDINFO;
- genera GitHub Artifact Attestations;
- firma los artefactos mediante Sigstore/Cosign keyless;
- verifica las firmas creadas;
- publica GitHub Release.

## 8. Verificar una release como usuario

SHA-256:

```bash
sha256sum -c sysdiag-v0.14.1-SHA256SUMS.txt
```

Artifact Attestation con GitHub CLI:

```bash
gh attestation verify sysdiag-v0.14.1-linux-amd64 --repo chus87/sysdiag
```

Sigstore/Cosign:

```bash
cosign verify-blob sysdiag-v0.14.1-linux-amd64 \
  --bundle sysdiag-v0.14.1-linux-amd64.sigstore.json \
  --certificate-identity "https://github.com/chus87/sysdiag/.github/workflows/release.yml@refs/tags/v0.14.1" \
  --certificate-oidc-issuer "https://token.actions.githubusercontent.com"
```

## 9. ARM64

`arm64-native.yml` ejecuta periódicamente pruebas nativas en un runner Linux ARM64 de GitHub. No sustituye a la matriz de integración con distribuciones, pero evita limitar la validación ARM64 a una mera cross-compilation.

## 10. Checklist de publicación

Antes de anunciar públicamente una release comprueba:

- [ ] `main` protegida.
- [ ] checks obligatorios configurados.
- [ ] tags `v*` protegidos.
- [ ] Dependabot activado.
- [ ] Secret scanning y push protection activados, si están disponibles.
- [ ] Private vulnerability reporting activado.
- [ ] Actions puede abrir PRs para actualizar Go.
- [ ] Tag firmado y verificado.
- [ ] Workflow de release verde.
- [ ] Checksums, attestation y firma Sigstore verificables.
