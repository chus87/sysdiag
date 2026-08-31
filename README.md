# SYSdiag 0.14.1 — Go Core

**Autor:** Chus (GitHub: `chus87`)  
**Licencia:** Apache-2.0 — consulta `LICENSE` y `NOTICE`.

Documentos de uso y desarrollo:

- `COMANDOS.md`: comandos de ejecución.
- `COMPILACION.md`: compilación desde código fuente.
- `CONTRIBUTING.md`: contribuciones.
- `docs/RELEASING.md`: publicación y procedencia de releases.
- `docs/SUPPORT.md`: plataformas soportadas.
- `docs/GITHUB-SETUP.md` — ajustes recomendados del repositorio GitHub.

SYSdiag es una herramienta **read-only** de diagnóstico Linux, contenedores, Kubernetes y OpenShift. Recopila datos, conserva la separación entre capas, relaciona evidencias y propone siguientes comprobaciones sin convertir un síntoma aislado en una causa.

## Arquitectura 0.14.1

El ejecutable principal usa un **núcleo Go**. Los collectors Linux maduros permanecen como backend Bash aislado, de forma que la evolución del motor no invalida las comprobaciones ya probadas. La arquitectura mantiene explícitamente:

```text
Host Linux → runtime → contenedor → Kubernetes/OpenShift → aplicación
```

El núcleo Go aporta un modelo tipado de evidencias y conclusiones, correlación cross-layer, serialización estructurada y aislamiento de fallos entre dominios. En `--all --json`, host, contenedores y Kubernetes se recogen como transacciones independientes y pueden ejecutarse en paralelo; una rama que no pueda completarse genera una limitación explícita y no convierte su ausencia de datos en `OK`.

Los paquetes incluyen binarios estáticos Linux para **amd64** y **arm64**. Cada binario lleva embebido el collector Bash standalone, por lo que puede copiarse y ejecutarse de forma independiente sin instalar SYSdiag ni desplegar ficheros auxiliares. `sysdiag.sh` selecciona el binario adecuado y el standalone Bash continúa disponible como edición de compatibilidad.

La sección Kubernetes/OpenShift sigue siendo centralizada y agentless: puede ejecutarse desde una máquina de administración sin copiar SYSdiag a cada nodo. Usa `kubectl`/`oc`, la API del cluster, EndpointSlices, Events, métricas existentes y, cuando RBAC lo permite, `stats/summary` del kubelet a través del API Server.

La autenticación no modifica el kubeconfig habitual. Los tokens se guardan únicamente en un kubeconfig temporal `0600`, eliminado al finalizar. En OpenShift con usuario/contraseña, `oc` solicita la contraseña directamente; SYSdiag no la pasa en la línea de comandos del proceso.

La salida JSON mantiene `schema_version: 1.1` y añade de forma compatible `engine`, `evidence` y `conclusions` cuando se ejecuta mediante el núcleo Go.

Documentación de diseño: `docs/ARCHITECTURE.md`.

## Menú interactivo

Al ejecutar desde una terminal sin argumentos:

```text
¿Qué quieres analizar?

  1) Resumen general
  2) CPU y procesos
  3) Memoria
  4) I/O y almacenamiento
  5) Filesystems
  6) Red
  7) Logs / journald
  8) Warnings y errores recientes (última hora)
  9) Systemd / servicios
 10) Boot / arranque
 11) Contenedores / runtime
 12) Kubernetes / OpenShift
 13) Guía de diagnóstico y comandos
 14) Diagnóstico completo

  0) Salir
```

Se pueden combinar áreas, por ejemplo `4,6,8,9,10,11,12`. `Resumen general` y `Guía` deben elegirse solos. `Diagnóstico completo` prevalece si se combina con otras opciones.

La CLI sigue siendo prioritaria para automatización, SSH y scripts:

```bash
./sysdiag.sh --summary
./sysdiag.sh --section network --verbose
./sysdiag.sh --section logging --explain
./sysdiag.sh --recent-errors
./sysdiag.sh --section systemd --verbose --explain
./sysdiag.sh --section boot --verbose --explain
./sysdiag.sh --section containers --verbose --explain
./sysdiag.sh --section kubernetes --k8s-mode deep --verbose --explain
./sysdiag.sh --section kubernetes --k8s-node worker-03 --k8s-mode exhaustive
./sysdiag.sh --section kubernetes --k8s-namespace produccion --verbose
./sysdiag.sh --all --json
./sysdiag.sh --guide
./sysdiag.sh --all
```

Sin TTY y sin argumentos, SYSdiag conserva el comportamiento no interactivo y ejecuta el diagnóstico completo; nunca debe quedarse esperando una respuesta de menú en cron, pipes o automatizaciones.



## Boot / arranque

`--section boot` y la opción 10 realizan un análisis read-only del arranque observable:

- kernel actual y `root=` de `/proc/cmdline`;
- source/fstype del `/` realmente montado;
- detección de `initramfs-tools` o dracut;
- parsing defensivo de `/etc/fstab` sin montar nada;
- UUID/LABEL/PARTUUID/PARTLABEL locales ausentes;
- clasificación separada de mounts obligatorios, `nofail`, `noauto` y `x-systemd.automount`;
- mountpoints duplicados y entradas que no pueden interpretarse;
- mounts remotos detectados sin contactar con el servidor remoto;
- `.mount` units en `failed` cuando systemd es accesible;
- `systemd-analyze time`, `blame` y `critical-chain` con timeout;
- journal del boot actual/kernel para emergency/rescue, device timeouts, fsck, mounts y errores I/O/storage;
- disponibilidad del boot anterior cuando journald lo conserva.

`blame` se presenta expresamente como **duración, no causalidad**. `critical-chain` es la herramienta que ayuda a comprobar qué estuvo realmente en el camino crítico.

Si SYSdiag corre dentro de un contenedor, Boot aparece como **LIMITADO** para el diagnóstico del host: no correlaciona `root=` del kernel con `/` del contenedor como si fueran la misma capa.

## Salida JSON estructurada

```bash
./sysdiag.sh --all --json > host.json
./sysdiag.sh --section boot --json > boot.json
./sysdiag.sh --section network --json --report network.json
```

La salida usa `schema_version: 1.1` y contiene resumen por categoría, score, señales independientes, confianza, impacto, findings, limitaciones, siguientes pasos y métricas clave. No necesita `jq` ni Python para generarse.

Documentación y schema formal: `docs/JSON.md` y `docs/sysdiag-json-schema-v1.1.json`.

## Systemd / servicios

`--section systemd` y la opción 9 realizan diagnóstico de systemd sin modificar el host:

- confirma si PID 1 es realmente `systemd` antes de confiar en `systemctl`;
- muestra versión, `is-system-running`, target por defecto y número de timers conocidos;
- enumera unidades `failed` y cuenta específicamente las `.service`;
- limita el detalle automático a un número acotado de unidades fallidas;
- consulta propiedades read-only (`LoadState`, `ActiveState`, `SubState`, `UnitFileState`, `Result`, `MainPID`, `ExecMainCode`, `ExecMainStatus`, `Restart`, `NRestarts`, `FragmentPath`);
- correlaciona mensajes del manager de la última hora para detectar `Start request repeated too quickly`, reinicios repetidos y fallos de dependencia;
- reconoce `Result=start-limit-hit` y `NRestarts` elevado incluso si el journal no aporta toda la historia;
- sanitiza descripciones/logs antes de imprimirlos;
- no interpreta `active (running)` como readiness funcional;
- no interpreta `failed` como prueba de que systemd sea la causa;
- recomienda `status`, `cat`, `show`, `list-dependencies` y `journalctl -u` como siguientes pasos, sin ejecutar acciones de cambio.

Para controlar coste y volumen de salida, el modo normal detalla como máximo 5 unidades fallidas; `--verbose` eleva ese límite a 10 y solo entonces consulta un extracto de hasta 8 líneas recientes por unidad. La lista visible de nombres también está acotada. Si la primera consulta al system manager expira o no responde, SYSdiag corta esa rama en lugar de encadenar más llamadas.

Si PID 1 no es systemd —por ejemplo en ciertos contenedores— SYSdiag marca el área como **LIMITADO** y evita consultas al system manager que producirían resultados engañosos.

### Scoring conservador de systemd

La categoría `systemd` suma evidencia únicamente para señales operativas concretas como unidades actualmente `failed`, `start-limit`/`start-limit-hit`, patrones de reinicio repetido y fallos de dependencia. Un estado `running`, un número alto de timers o una línea genérica del journal no se convierte por sí solo en finding.

## Contenedores / runtime

`--section containers` y la opción 11 realizan diagnóstico read-only de runtimes y contenedores:

- Docker y Podman: disponibilidad, acceso, versión, storage driver y root del runtime;
- detección de endpoint/contexto remoto para impedir correlaciones falsas con el host local;
- inventario acotado de estados `running`, `restarting`, `exited`, `paused`, `dead`;
- healthchecks `healthy`, `unhealthy` y `starting`, sin confundir health con readiness funcional;
- `ExitCode`, `OOMKilled`, `RestartCount`, restart policy y PID del host cuando el runtime lo expone;
- límites de memoria/CPU y muestra `stats --no-stream`;
- presión de memoria respecto al límite y señales de CPU cerca de cuota;
- lectura de `cpu.stat` en cgroup v2 para detectar throttling durante la ventana observada cuando es accesible;
- filesystem que contiene el storage del runtime, evitando consultas automáticas si está sobre almacenamiento remoto;
- tamaño de logs locales conocidos por el runtime con límites defensivos;
- recuento de contenedores `privileged`, `network=host` y mounts de `docker.sock`;
- visibilidad ligera de CRI con `crictl ps -a -q` cuando existe y es accesible.

SYSdiag no ejecuta automáticamente `docker/podman restart`, `rm`, `prune`, `pull`, `exec` ni otras acciones de cambio. Tampoco ejecuta por defecto `docker system df -v`, `podman system df -v` o `ps --size`, ya que pueden resultar costosos en hosts con muchos layers/objetos; se proponen como comprobaciones manuales cuando aportan valor.

### Análisis profundo Docker/Podman

`--container-mode deep` o `--containers-deep` amplía el inventario a todos los contenedores visibles y lee el histórico completo de logs accesible mediante `docker logs --timestamps` / `podman logs --timestamps` sin `--tail` ni `--since`. Los logs no se vuelcan íntegros en el informe: se analizan en streaming, se cuentan patrones relevantes y se conservan muestras sanitizadas y redactadas para patrones habituales de credenciales, junto con interpretación y posibles resoluciones manuales.

El análisis distingue, entre otros, memoria/OOM, falta de espacio, permisos, `connection refused`, timeouts, DNS, TLS/certificados, autenticación/autorización, filesystem read-only, puertos ocupados, agotamiento de FDs, rutas inexistentes, panic/segfault/traceback, dependencias de base de datos y errores de I/O. Un patrón histórico aislado no se puntúa como causa actual; sólo gana peso cuando se correlaciona con estado `restarting`/`dead`, `unhealthy`, OOM, exit no cero o reinicios elevados.

Cada lectura completa de logs tiene un timeout de seguridad (120 s por defecto, configurable con `CONTAINER_DEEP_LOG_TIMEOUT_SECONDS`, limitado internamente a 10-600 s). Si el histórico no puede recorrerse completo, SYSdiag lo declara como limitación en lugar de asumir que no hay errores. El modo `normal` sigue siendo el predeterminado, incluido `--all`.

### Scoring conservador de contenedores

Se puntúan señales concretas como estado `restarting`, `unhealthy`, `OOMKilled`, presión contra límites, throttling observado, logs locales excepcionalmente grandes o storage del runtime cerca del límite. `Privileged`, `docker.sock`, `network=host` o un `RestartCount` histórico se presentan con contexto y recomendaciones, sin convertir automáticamente cada configuración válida en una incidencia.


## Presentación y color

La salida humana usa color únicamente como semántica de severidad: verde para `OK`, cian para información, azul para cobertura limitada, amarillo para `WARNING` y rojo para `CRITICAL`. El comportamiento por defecto es `--color auto`; se puede forzar con `--color always`, desactivar con `--color never` o mediante el estándar `NO_COLOR`. JSON, pipes y ficheros `--report` nunca reciben ANSI.

Los informes se escriben con permisos `0600` mediante un temporal y reemplazo atómico. SYSdiag rechaza symlinks y destinos existentes que no sean ficheros regulares.

La especificación del modelo de amenaza y las fronteras read-only está en `docs/SECURITY.md`.

## Seguridad del núcleo Go

Los binarios Go usan exclusivamente el collector Bash embebido; no buscan un backend alternativo en el directorio de trabajo. El collector se materializa en un directorio privado, se verifica por SHA-256 y se ejecuta explícitamente con `/bin/bash` a través del gateway de procesos del núcleo.

Cuando SYSdiag corre como root, el entorno del collector se reduce deliberadamente: PATH fijo o explícitamente confiable, HOME de root, sin `BASH_ENV`/`ENV`/funciones exportadas y sin heredar kubeconfigs inseguros. Un kubeconfig pasado expresamente con `--k8s-kubeconfig` se considera una decisión consciente del administrador.

`SIGINT`, `SIGTERM` y `--timeout` cancelan el grupo de procesos del collector para no dejar herramientas auxiliares ejecutándose por detrás.

## Kubernetes / OpenShift

`--section kubernetes` y la opción 12 realizan diagnóstico read-only del cluster. Por defecto se usa `--k8s-mode deep` sobre todo el cluster.

Modos:

- `quick`: inventario y señales principales con coste reducido;
- `deep`: añade correlación de Services/EndpointSlices, workloads, probes, PVC, métricas y `stats/summary` en nodos sospechosos;
- `exhaustive`: amplía límites, consulta `stats/summary` de todos los nodos visibles y profundiza en recursos OpenShift.

Ámbitos:

```bash
./sysdiag.sh --section kubernetes --k8s-mode deep
./sysdiag.sh --section kubernetes --k8s-node worker-03 --k8s-mode exhaustive
./sysdiag.sh --section kubernetes --k8s-namespace produccion --verbose
./sysdiag.sh --section kubernetes --k8s-pod produccion/api-7c884 --verbose --explain
./sysdiag.sh --section kubernetes --k8s-context prod-eu
./sysdiag.sh --section kubernetes --k8s-kubeconfig ~/.kube/prod.yaml
```

La sección comprueba:

- cliente, contexto, API Server, identidad y permisos read-only básicos;
- plataforma Kubernetes/OpenShift y versión observable;
- `Ready`, `MemoryPressure`, `DiskPressure`, `PIDPressure` y `unschedulable`;
- Pods `Pending`, `Failed`, `Running` no Ready, reinicios altos, `CrashLoopBackOff`, `ImagePullBackOff`, `OOMKilled` y `Evicted`;
- `FailedScheduling`, diferenciando requests/Allocatable, taints y PVC sin enlazar;
- readiness/liveness/startup mediante Events, sin confundir reinicios provocados por kubelet con crashes espontáneos;
- clasificación temporal conservadora de Events: los Warning fuera de la ventana reciente se conservan como contexto, pero no puntúan ni se presentan como causa actual;
- Services y EndpointSlices, correlacionando selector, Pods coincidentes y readiness antes de culpar al networking;
- PVC `Pending`, StorageClass inexistente, fallos de provisioning, `FailedAttach` y `FailedMount`;
- Deployments, StatefulSets y DaemonSets con disponibilidad inferior a la deseada;
- `kubectl top nodes` cuando existe metrics-server/monitoring y RBAC suficiente;
- `stats/summary` del kubelet a través del API Server cuando `nodes/proxy` es accesible;
- en OpenShift, ClusterOperators y Machines; el modo exhaustivo puede consultar `oc adm node-logs` sólo en nodos ya sospechosos.

El análisis es centralizado y no despliega DaemonSets, Pods privilegiados, `oc debug`, `must-gather`, agentes ni componentes temporales en el cluster. Si una capa no es observable por RBAC o por falta de métricas, se registra como **LIMITADO**; ausencia de datos no se transforma en estado saludable.

### Autenticación temporal

Si la ejecución es interactiva y el API no acepta la sesión actual, SYSdiag puede pedir API URL y token o usuario/contraseña. El material de autenticación se guarda únicamente dentro del directorio temporal de la ejecución, con permisos restrictivos, y se elimina mediante el cleanup normal de SYSdiag. `--k8s-no-auth-prompt` desactiva este comportamiento para automatización.

Para Kubernetes genérico, usuario/contraseña sólo funcionará si el API admite ese mecanismo. En OpenShift, si se usa usuario/contraseña y `oc` está disponible, SYSdiag realiza `oc login` contra un kubeconfig temporal, nunca contra `~/.kube/config`. No se desactiva la validación TLS automáticamente. En OpenShift con usuario/contraseña, `oc` solicita la contraseña directamente en su propio prompt: SYSdiag no la lee ni la pasa en `argv`. Para token, SYSdiag usa un kubeconfig temporal con permisos `0600`. En ambos casos el kubeconfig habitual permanece sin cambios.

### Correlación de red

SYSdiag intenta seguir esta secuencia:

```text
DNS → Service → EndpointSlice → Pod IP/puerto → aplicación
```

Un Service con selector y cero endpoints conduce primero a revisar selector/labels y readiness. Si hay Pods seleccionados pero ninguno Ready, la hipótesis principal se mantiene en probes/aplicación/dependencias. Sólo cuando el Pod es alcanzable directamente y la ClusterIP falla gana peso el dataplane del Service/CNI.

### Correlación de storage

```text
PVC Pending                 → configuración/provisioning/StorageClass/PV
PVC Bound + FailedAttach    → CSI controller/backend/attach hacia nodo
PVC Bound + FailedMount     → CSI node/kubelet/filesystem/Linux del nodo
```

`Bound` significa que PVC y PV están enlazados; no demuestra que el volumen esté attached ni mounted.

## Guía de diagnóstico integrada

`--guide`, `--section guide` y la opción 13 muestran una referencia técnica integrada. Incluye:

- qué hace cada apartado de SYSdiag;
- procesos/CPU/I/O;
- memoria;
- filesystems;
- red/TCP/MTU/PMTU;
- logs y correlación temporal;
- systemd/servicios;
- comandos que cambian el sistema, claramente separados y marcados como **solo manuales**;
- reglas de troubleshooting y distinciones como `load ≠ CPU`, `free ≠ available`, `df ≠ du`, `refused ≠ timeout`, `After ≠ Requires` y `started ≠ ready`.

La guía no ejecuta ninguna comprobación ni acción; funciona como referencia operativa para investigación y consulta de comandos.

## ShellCheck en la suite de desarrollo

La ejecución normal de SYSdiag sigue siendo estrictamente read-only y nunca instala paquetes. Si `tests/test_static.sh` se ejecuta de forma interactiva y no encuentra `shellcheck`, la suite pregunta si se desea instalarlo. Sólo tras una confirmación explícita utiliza el gestor de paquetes detectado. En CI/no-TTY se conserva `SKIP` y no se instala nada. También puede controlarse con `SYSDIAG_SHELLCHECK_INSTALL=1` (opt-in explícito) o `0` (no instalar).

## Warnings y errores recientes

`--recent-errors` y la opción 8 muestran una vista de triaje de los últimos 60 minutos:

- journal `ERROR` o más grave separado de `WARNING`;
- máximo de 20 entradas recientes por categoría;
- kernel mediante `dmesg` solo cuando puede limitarse temporalmente de forma segura;
- deduplicación de mensajes de `dmesg` ya visibles en el journal del kernel;
- si `dmesg` no es legible por permisos, SYSdiag lo indica y **no eleva privilegios**;
- si la versión de `dmesg` no soporta filtros temporales, se omite en vez de volcar todo el ring buffer;
- caracteres de control y secuencias ANSI procedentes de logs se sanitizan antes de mostrarse;
- líneas patológicamente largas se limitan para proteger la legibilidad de la terminal.

La prioridad del log **no suma scoring por sí sola**. Un `ERROR` sigue siendo una evidencia del productor del mensaje, no una demostración causal.

## Muestreo sincronizado

CPU, swap, red/TCP y `iostat` comparten una sola ventana temporal. En 0.8.2 la selección múltiple se planifica **antes** de iniciar esa ventana. Esto corrige el caso en el que elegir CPU/Red antes de I/O podía iniciar el muestreo sin `iostat` y presentar después métricas de I/O inválidas.

Si por una invocación interna inesperada se solicita `iostat` después de haber cerrado la ventana común, SYSdiag no remuestrea silenciosamente otro periodo: declara la limitación.

## I/O: datos válidos frente a herramienta instalada

`iostat` instalado ya no significa automáticamente que el análisis esté disponible. SYSdiag diferencia:

- comando ausente;
- comando presente pero sin datos;
- tabla de dispositivos inválida/incompleta;
- muestra válida.

Si no existe una muestra válida, I/O aparece como **LIMITADO** y no se muestran `await=0`, `aqu-sz=0` o `%util=0` como si fueran observaciones reales.

## Interpretación por sección

Una ejecución específica como:

```bash
./sysdiag.sh --section network
```

muestra ahora también **ANÁLISIS Y PRIORIZACIÓN** para las categorías relevantes y cualquier finding cross-domain generado por esa comprobación. Esto evita calcular findings y ocultarlos en ejecuciones parciales.

La opción `CPU y procesos` recoge ambas áreas una sola vez y permite correlacionar load, CPU idle/iowait y procesos `D` sin duplicar snapshots.

## Logs / journald

La sección `logging` conserva:

- estado y disponibilidad de `journald`;
- `Storage=` efectivo/configurado;
- stores persistente/volátil observados;
- boots visibles y disponibilidad del boot anterior;
- uso del journal;
- muestra acotada de `WARNING+` reciente en modo verbose;
- estado/configuración de rsyslog e indicios de forwarding remoto;
- logrotate, timer/servicio, estado y directivas `compress`, `delaycompress`, `copytruncate`, `create`, `postrotate`;
- comandos manuales para ventanas temporales, boots, `zgrep`, validación de logrotate y `lsof +L1`.

### Protección de `/var/log`

Antes de listar ficheros, SYSdiag determina el filesystem mediante `findmnt` o, si no está disponible, leyendo `/proc/self/mountinfo`.

Se omite automáticamente el `df`/`find` de `/var/log` cuando está sobre tipos remotos/distribuidos conocidos como NFS, CIFS/SMB, Ceph, GlusterFS, SSHFS, 9p, AFS o Lustre. La razón es operativa: una herramienta de diagnóstico no debe quedarse bloqueada sobre un almacenamiento remoto que podría ser precisamente el componente degradado.

En filesystems locales el listado sigue limitado a profundidad 2, mismo filesystem (`-xdev`), máximo 10 ficheros y timeout. No se ejecuta `du` recursivo.

## Resumen general

`--summary` muestra `OK`, `INFO`, `WARNING`, `CRITICAL` o `LIMITADO`.

`OK` significa únicamente que las comprobaciones ejecutadas no produjeron un patrón relevante. **No significa sistema sano**.

`LIMITADO` significa que faltó una comprobación necesaria o que los datos no fueron válidos. Ejemplos:

- `iostat` ausente o sin muestra válida;
- `lsof`/`findmnt` necesarios no disponibles;
- acceso insuficiente a journald;
- `systemctl` ausente, PID 1 distinto de systemd o system manager inaccesible;
- otras limitaciones registradas por los módulos.

## Arquitectura y standalone

El ejecutable principal toma la versión de `internal/version/version.go`; el backend Bash mantiene `lib/version.sh` sincronizado para poder seguir funcionando de forma independiente. La suite comprueba que ambas superficies anuncien la misma release.

La CLI principal y la orquestación estructurada residen en Go. `lib/cli.sh` conserva la interfaz del backend Bash y del standalone de compatibilidad. `build-standalone.sh` genera de forma determinista ese backend y la compilación Go lo embebe para que los binarios `amd64`/`arm64` puedan ejecutarse aislados del árbol del proyecto.

## Tests

La antigua prueba monolítica se mantiene como punto de entrada compatible (`tests/smoke.sh`), pero la suite está dividida por dominios:

```text
tests/
  run.sh
  test_core.sh
  test_filesystem.sh
  test_network.sh
  test_logging.sh
  test_systemd.sh
  test_boot.sh
  test_json.sh
  test_readonly.sh
  test_cli.sh
  test_standalone.sh
  test_shellcheck_helper.sh
  test_go_core.sh
  test_go_isolation.sh
  test_static.sh
```

Incluye regresiones específicas para:

- CPU idle frente a iowait;
- scoring/recomendaciones deduplicados;
- AppImage/SquashFS;
- deleted-open por device+inode;
- MTU/PMTU;
- selección múltiple CPU + I/O;
- `iostat` instalado pero sin datos válidos;
- análisis visible en `--section`;
- `/var/log` remoto sin recorrido automático;
- separación ERROR/WARNING reciente;
- límite de eventos;
- deduplicación journal/dmesg;
- sanitización de secuencias de terminal;
- systemd PID 1, unidades failed, start-limit, reinicios y dependencias;
- verificación de que el colector systemd no ejecuta acciones de cambio;
- guía integrada y menú;
- menú/report;
- reproducibilidad del standalone.

`test_static.sh` ejecuta `shellcheck` cuando ya está instalado. Si falta y la suite corre en una terminal interactiva, puede ofrecer su instalación; nunca instala herramientas sin confirmación explícita. En CI/no-TTY se marca como `SKIP`.


## CI e integración profesional

`.github/workflows/ci.yml` ejecuta sintaxis Bash, ShellCheck cuando está disponible, `gofmt`, `go vet`, tests Go, regresiones Bash/Go, standalone determinista, compilación Linux amd64/arm64 y validación JSON en Ubuntu 24.04.

La integración pesada está separada en `.github/workflows/vm-integration.yml` y requiere un runner self-hosted `linux+kvm` con Vagrant/libvirt. La matriz definida en `tests/vm/` cubre Ubuntu 24.04, Debian 12, Rocky 9 y AlmaLinux 9 con **systemd real como PID 1**. El test live crea unidades temporales fallidas/restart-loop solo dentro de la VM desechable, verifica SYSdiag y limpia todo al terminar.

Los mocks siguen siendo necesarios para regresiones deterministas y escenarios difíciles de provocar, pero ya no son la única estrategia de validación prevista.

## Uso

```bash
chmod +x sysdiag-standalone.sh

./sysdiag-standalone.sh
./sysdiag-standalone.sh --summary
./sysdiag-standalone.sh --recent-errors
./sysdiag-standalone.sh --section recent
./sysdiag-standalone.sh --section network --sample 5 --verbose
./sysdiag-standalone.sh --section logging --verbose --explain
./sysdiag-standalone.sh --section systemd --verbose --explain
./sysdiag-standalone.sh --section boot --verbose --explain
./sysdiag-standalone.sh --section kubernetes --k8s-mode deep --verbose --explain
./sysdiag-standalone.sh --all --json
./sysdiag-standalone.sh --guide
./sysdiag-standalone.sh --all
./sysdiag-standalone.sh --report
./sysdiag-standalone.sh --version
```

La ventana de muestreo admite `--sample 1..30`.

## Confianza, puntuación e impacto

- **Puntuación**: peso heurístico de findings deduplicados. No es porcentaje ni probabilidad.
- **Señales independientes**: familias de evidencia diferentes.
- **Confianza**: fuerza y diversidad de evidencias que apoyan una hipótesis.
- **Impacto**: efecto potencial/observado sobre el host; es independiente de la confianza.

## Seguridad operacional

Por defecto SYSdiag es read-only respecto al sistema diagnosticado. No ejecuta automáticamente `kill`, `restart`, `reboot`, `rm`, instalaciones, cambios de configuración, cambios de red/firewall/sysctl ni acciones Kubernetes/OpenShift.

Crea únicamente un directorio temporal propio para su ejecución y lo elimina al terminar. `--report` escribe un fichero **solo porque el usuario lo solicita explícitamente**. Los informes nuevos se crean con permisos `0600`; SYSdiag rechaza un destino de informe que ya sea un enlace simbólico para evitar escrituras indirectas accidentales.

Las comprobaciones potencialmente problemáticas están acotadas por timeout o se omiten cuando no puede garantizarse un coste razonable. Los comandos activos o de cambio se muestran únicamente como recomendaciones manuales cuando corresponde.

## Interpretación profesional

SYSdiag está diseñado para ayudar con el patrón:

```text
datos → hipótesis → prueba que discrimina → nuevo dato → siguiente decisión
```

No debe utilizarse como sustituto de una RCA, un SIEM ni una plataforma de observabilidad. Su objetivo es reducir el espacio de búsqueda y hacer explícitas las evidencias y limitaciones disponibles en el host.
