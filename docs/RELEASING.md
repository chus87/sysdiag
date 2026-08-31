# Publicar una release de SYSdiag

## Precondiciones

- Árbol limpio.
- Rama principal actualizada.
- `.go-version` en la versión estable aprobada.
- `make release-check` en verde.
- Número de versión sincronizado en el proyecto.

## Tag firmado

Las releases oficiales deben partir de un tag Git firmado por el mantenedor. SYSdiag no genera ni almacena la clave privada.

Ejemplo GPG:

```bash
git config user.signingkey <KEY_ID>
git tag -s vX.Y.Z -m "SYSdiag vX.Y.Z"
git push origin vX.Y.Z
```

El workflow `release.yml` rechaza tags no verificados por GitHub y exige que el tag coincida con la versión del código.

## Build y publicación

Al recibir `v*`, GitHub Actions:

1. Comprueba que el tag es anotado y que GitHub lo marca como verificado.
2. Configura la versión exacta de Go indicada por `.go-version`.
3. Ejecuta lint, tests, race detector, schema, `govulncheck` y release-check.
4. Construye los paquetes reproducibles.
5. Genera Artifact Attestations de los artefactos publicados.
6. Crea GitHub Release y adjunta únicamente amd64, arm64, standalone, ZIP y TAR.GZ. La metadata técnica completa permanece dentro de ZIP/TAR.GZ.

## Verificación por usuarios

GitHub muestra el SHA-256 de cada asset publicado. Para verificar procedencia criptográfica:

```bash
gh attestation verify sysdiag-vX.Y.Z-linux-amd64 --repo chus87/sysdiag
```

## Protección recomendada en GitHub

- Proteger `main` y exigir CI.
- Restringir creación/modificación de tags `v*` al mantenedor.
- Activar secret scanning y Dependabot security updates.
- No permitir merge si CodeQL o CI fallan.

## Firma Sigstore adicional

Además de GitHub Artifact Attestations, `release.yml` firma y verifica los tres artefactos ejecutables publicados mediante Cosign keyless/OIDC. Los bundles `*.sigstore.json` son temporales del workflow y no se publican como assets; la verificación pública recomendada es `gh attestation verify`.

La firma de los tags continúa siendo responsabilidad exclusiva del mantenedor; las claves privadas no se almacenan en el repositorio ni en SYSdiag.

## Ajustes del repositorio

Antes de la primera release pública completa `docs/GITHUB-SETUP.md`. Los controles de GitHub que viven fuera del repositorio forman parte del procedimiento de publicación.
