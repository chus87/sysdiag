# SYSdiag — comandos de uso

SYSdiag es read-only: recopila y correlaciona evidencias, pero no aplica correcciones automáticamente.

## Inicio rápido

### Binario Linux amd64 / x86-64

```bash
chmod +x sysdiag-v0.14.2-linux-amd64
./sysdiag-v0.14.2-linux-amd64
```

Instalación opcional en el PATH:

```bash
sudo install -m 0755 sysdiag-v0.14.2-linux-amd64 /usr/local/bin/sysdiag
sysdiag
```

### Binario Linux arm64 / aarch64

```bash
chmod +x sysdiag-v0.14.2-linux-arm64
./sysdiag-v0.14.2-linux-arm64
```

### Desde el código fuente / paquete completo

```bash
./sysdiag.sh
```

`sysdiag.sh` selecciona el binario apropiado para la arquitectura y conserva el standalone Bash como fallback controlado.

## Comandos principales

```bash
sysdiag --help
sysdiag --version
sysdiag --menu
sysdiag --summary
sysdiag --all
sysdiag --all --verbose --explain
sysdiag --all --json
```

## Por sección

```bash
sysdiag --section system
sysdiag --section cpu
sysdiag --section processes
sysdiag --section memory
sysdiag --section io
sysdiag --section filesystem
sysdiag --section network
sysdiag --section logging
sysdiag --section recent
sysdiag --section systemd
sysdiag --section boot
sysdiag --section containers
sysdiag --section kubernetes
sysdiag --section guide
```

## Contenedores

Análisis normal:

```bash
sysdiag --section containers
```

Análisis profundo de todos los contenedores visibles y del histórico de logs accesible:

```bash
sysdiag --containers-deep
sysdiag --section containers --container-mode deep
```

## Kubernetes / OpenShift

Rápido:

```bash
sysdiag --section kubernetes --k8s-mode quick
```

Profundo:

```bash
sysdiag --section kubernetes --k8s-mode deep
```

Exhaustivo:

```bash
sysdiag --section kubernetes --k8s-mode exhaustive
```

Nodo concreto:

```bash
sysdiag --section kubernetes --k8s-node worker-03 --k8s-mode exhaustive
```

Namespace:

```bash
sysdiag --section kubernetes --k8s-namespace produccion --verbose --explain
```

Pod:

```bash
sysdiag --section kubernetes --k8s-pod produccion/api-7c884 --verbose --explain
```

Contexto o kubeconfig específicos:

```bash
sysdiag --section kubernetes --k8s-context prod
sysdiag --section kubernetes --k8s-kubeconfig /ruta/kubeconfig
```

No solicitar autenticación interactiva:

```bash
sysdiag --section kubernetes --k8s-no-auth-prompt
```

## JSON e informes

Salida JSON:

```bash
sysdiag --all --json
sysdiag --all --json > sysdiag.json
```

Guardar informe con permisos restrictivos:

```bash
sysdiag --all --report
sysdiag --all --report informe.txt
sysdiag --all --json --report informe.json
```

## Color

```bash
sysdiag --color auto
sysdiag --color always
sysdiag --color never
sysdiag --no-color
NO_COLOR=1 sysdiag --all
```

JSON, reports y salida a pipes no incluyen ANSI por defecto.

## Muestreo y timeout

```bash
sysdiag --all --sample 3
sysdiag --all --timeout 10m
```

`--sample` admite 1–30. `--timeout` admite de 1 segundo a 24 horas.

## Diagnóstico explicativo

```bash
sysdiag --all --verbose
sysdiag --all --explain
sysdiag --all --verbose --explain
```

`--verbose` añade IDs, dominios y metadata. `--explain` añade evidencia estructurada y comprobaciones discriminantes.

## Guía integrada

```bash
sysdiag --guide
sysdiag --section guide
```

## Comprobar integridad y procedencia de una release

GitHub muestra el SHA-256 de cada asset publicado en la propia Release. Para verificar además que un binario procede del workflow oficial de SYSdiag:

```bash
gh attestation verify sysdiag-v0.14.2-linux-amd64 --repo chus87/sysdiag
```

Los enlaces `Source code (zip)` y `Source code (tar.gz)` de GitHub contienen el código exacto del tag, incluyendo `COMANDOS.md`, `COMPILACION.md`, licencia, NOTICE y el resto de documentación versionada. Los metadatos de build del binario se consultan con `--version`, y la procedencia criptográfica del artefacto se verifica mediante GitHub Artifact Attestations.

## Para mantenedores: paquete fuente

```bash
make source-release
```

Genera un paquete fuente limpio, sin reutilizar binarios de una compilación anterior. Consulta `COMPILACION.md`.
