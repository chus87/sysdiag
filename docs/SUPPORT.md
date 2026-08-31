# Plataformas soportadas

## Binarios oficiales

- Linux amd64 / x86-64.
- Linux arm64 / aarch64.

El workflow ARM64 ejecuta periódicamente compilación y tests **nativos** en runner arm64, además de la compilación cruzada reproducible.

## Distribuciones Linux

La suite incluye cobertura funcional sobre familias Debian/Ubuntu y RHEL-like mediante tests/VM cuando hay virtualización disponible. SYSdiag evita instalar dependencias durante el diagnóstico.

## Contenedores

- Docker.
- Podman.
- `crictl` como fuente complementaria cuando está disponible.

## Kubernetes / OpenShift

SYSdiag usa `kubectl` y/o `oc` disponibles en el host. La profundidad depende de RBAC y de los recursos expuestos por el cluster. Falta de permisos o información se declara como **limitación**, nunca como estado sano.

## Standalone

El standalone Bash mantiene compatibilidad para sistemas donde no se quiera usar el binario Go. La vía recomendada para nuevas instalaciones es el binario Go oficial.

## Nuevas arquitecturas

Una arquitectura adicional sólo se considerará oficialmente soportada cuando tenga:

1. Build reproducible.
2. Tests de core y read-only.
3. Ejecución nativa periódica o equivalente demostrable.
4. Inclusión en la política de releases y checksums.
