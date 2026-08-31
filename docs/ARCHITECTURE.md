# Arquitectura de SYSdiag

SYSdiag usa una arquitectura híbrida orientada a evidencias. El ejecutable principal es un núcleo Go y los collectors Linux maduros permanecen aislados como backend Bash read-only.

```text
                         SYSdiag Go Core
                              │
             ┌────────────────┼────────────────┐
             │                │                │
          Modelo          Correlación       Render
        de evidencia       / reglas        JSON/texto
             │                │                │
             └────────────────┼────────────────┘
                              │
         ┌────────────────────┼────────────────────┐
         │                    │                    │
      Host Linux          Containers        Kubernetes/OpenShift
         │                    │                    │
   collectors Bash       adapter actual       adapter actual
         │                    │                    │
 /proc /sys systemd     Docker/Podman/CRI    kubectl/oc/API
```

## Principios

- **Read-only por diseño.** La recogida no ejecuta acciones correctivas.
- **Capas separadas.** Host Linux, runtime, contenedor, Kubernetes/OpenShift y aplicación no se confunden.
- **Evidencia antes que conclusión.** Un estado o un único evento no se presenta automáticamente como causa.
- **Fallos parciales explícitos.** La ausencia de datos se representa como limitación, no como estado saludable.
- **Schema estable.** El informe JSON 1.1 se valida formalmente con JSON Schema Draft 2020-12 antes de publicar una release.
- **Compatibilidad.** El backend Bash puede ejecutarse de forma independiente mediante `sysdiag-legacy.sh` o el standalone Bash.

## Núcleo Go

El núcleo Go aporta:

- modelo tipado para findings, evidencias, conclusiones, limitaciones y siguientes pasos;
- correlación cross-layer separada de la recogida;
- serialización JSON con `encoding/json`;
- aislamiento de errores entre dominios;
- ejecución paralela de host, contenedores y Kubernetes en diagnósticos estructurados completos;
- gateway de procesos externos con política read-only obligatoria para el collector, grupos de procesos y cancelación de descendientes;
- entorno saneado al ejecutar con privilegios: no se heredan hooks de shell ni identidades/runtime paths inseguros;
- política tipada para clasificar comandos manuales como read-only, mutantes o de revisión;
- binarios Linux estáticos para amd64 y arm64, con el backend Bash standalone embebido.

## Backend Bash

Los collectors Bash siguen siendo responsables de la observación Linux y de los adapters de runtime/plataforma que ya tienen una suite amplia de regresión. Su resumen no es autoridad: Go reconstruye el scoring y las conclusiones a partir de cobertura, findings y métricas estructuradas. El objetivo es que Bash observe y Go decida; los adapters se irán portando sólo cuando exista una mejora técnica demostrable.

Esta separación permite reemplazar collectors individualmente sin reescribir el motor de evidencias ni cambiar el formato de salida.

## Autenticación Kubernetes/OpenShift

SYSdiag no modifica el kubeconfig habitual. Un token introducido de forma interactiva se guarda únicamente en un kubeconfig temporal con permisos `0600`, eliminado al terminar. En OpenShift con usuario/contraseña, `oc` solicita la contraseña directamente: SYSdiag no la lee ni la pasa como argumento de proceso.

## Standalone Bash

`sysdiag-standalone.sh` conserva una edición Bash de compatibilidad. El mismo collector standalone está embebido dentro de los binarios Go, de modo que los binarios pueden ejecutarse fuera del árbol de fuentes sin instalar SYSdiag ni copiar módulos auxiliares. Mantiene las comprobaciones read-only y el schema JSON existente, pero el motor de correlación adicional del core Go sólo está disponible mediante `sysdiag.sh`/los binarios Go.


## Frontera de confianza del collector

Los binarios Go no descubren ni ejecutan automáticamente un `sysdiag-legacy.sh` desde el directorio actual. El backend de producción es el standalone embebido en el propio binario, materializado en un directorio temporal privado (`0700`), escrito como fichero no ejecutable (`0400`) y verificado por SHA-256 antes de pasarlo explícitamente a `/bin/bash`.

Cuando SYSdiag se ejecuta como root, el subprocess usa un PATH fijo salvo override explícito formado únicamente por directorios del propio euid y no escribibles por grupo/otros. Tampoco hereda `BASH_ENV`, `ENV`, `CDPATH`, funciones exportadas, `HOME`/`XDG_RUNTIME_DIR` del llamador ni kubeconfigs heredados inseguros.

## Ciclo de vida y release

Cada collector registra inicio, fin, duración y estado (`ok`, `limited`, `failed`). `SIGINT`, `SIGTERM` y los timeouts cancelan el grupo de procesos completo para no dejar `kubectl`, `docker logs`, `journalctl` u otros descendientes huérfanos.

La release se construye de forma reproducible con toolchain Go fijado, timestamps normalizados, SHA-256 internos/externos, BUILDINFO y SBOM SPDX. ZIP y TAR.GZ se extraen y comparan byte a byte por fichero antes de considerarse válidos.
