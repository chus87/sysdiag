# Changelog

## 0.14.1 — Public Release Hardening

- Toolchain fijado en Go 1.27.0, con workflow semanal que detecta la última versión estable publicada y abre un PR de actualización.
- Licencia Apache-2.0, `NOTICE` y atribución explícita a Chus (GitHub: chus87) en versión, README y metadata de build/SBOM.
- Documentación `COMANDOS.md`, `COMPILACION.md`, `CONTRIBUTING.md`, política de plataformas y proceso de release firmado.
- GitHub Release automático desde tags `v*` firmados y verificados, con Artifact Attestations criptográficas para los artefactos.
- CodeQL, Dependabot, `govulncheck`, issue templates y workflow nativo ARM64 periódico.
- Build metadata ampliada con tag/fecha/autor/licencia y release oficial ligada a commit/tag reales.
- Métricas KiB/bytes/porcentajes presentadas en formato humano sin perder el valor exacto.
- Pipeline de release ampliada para incluir y validar licencia, notice, documentación, workflows y scripts de mantenimiento.

## 0.14.0 — Solid Foundation / Go Core

- Nuevo núcleo Go como entrypoint principal, conservando los collectors Bash maduros como backend read-only aislado.
- Binarios estáticos Linux para amd64 y arm64; `sysdiag.sh` selecciona automáticamente el binario compatible y mantiene fallback.
- Modelo tipado para findings, evidence, conclusions, limitations y next steps.
- Motor de correlación desacoplado de los collectors para construir hipótesis cross-layer sin mezclar capas.
- `--all --json` separa host, contenedores y Kubernetes en transacciones independientes y las ejecuta en paralelo; un fallo parcial se declara como limitación.
- Salida JSON 1.1 formalizada, con campos tipados `engine`, `evidence`, `conclusions`, `collectors`, acciones manuales y build metadata.
- Endurecida la autenticación OpenShift: las contraseñas ya no se pasan en `argv`; `oc` realiza el prompt directamente.
- El kubeconfig habitual continúa sin modificarse; tokens/credenciales temporales usan un fichero `0600` eliminado al finalizar.
- Política Go read-only con pruebas unitarias para bloquear verbos mutantes de Kubernetes/OpenShift.
- Se conserva `sysdiag-standalone.sh` como edición Bash de compatibilidad.
- Añadidos tests Go, `go vet`, `gofmt`, regresión Bash y comprobaciones de paridad del contrato JSON.
- Correlación reescrita sobre IDs y métricas estructuradas: la redacción humana ya no participa en las reglas y las correlaciones de presión/OOM/Eviction respetan el nodo real del Pod.
- El scoring Go incorpora automáticamente dominios que aparecen por correlaciones cross-layer sin fabricar categorías sanas ni ocultar findings reales.
- Visibilidad Kubernetes/RBAC endurecida: no poder listar StorageClass, EndpointSlices o Pods se declara como limitación y nunca se interpreta como recurso inexistente, Service sin endpoints o selector incorrecto.
- Los fallos del propio comando `docker logs`/`podman logs` no se clasifican como errores de aplicación; los timeouts conservan únicamente evidencia parcial explícitamente marcada.
- `--report` crea informes con permisos `0600` y rechaza destinos que ya sean enlaces simbólicos.
- `--section all --json` usa la misma ruta aislada que `--all --json`; combinaciones interactivas incompatibles con JSON se rechazan explícitamente.
- Builds Linux reproducibles con `-trimpath`, `-buildvcs=false` y comprobación byte a byte para amd64/arm64.
- Salida humana renovada con color semántico de severidad (`--color auto|always|never`, `NO_COLOR`) sin ANSI en JSON, pipes ni reports.
- Eliminada la autodetección de collectors externos desde el CWD; el binario usa exclusivamente el collector embebido auditado.
- El collector se materializa en directorio privado, se verifica por SHA-256 y se ejecuta mediante `/bin/bash` con entorno saneado.
- Hardening para ejecuciones privilegiadas: PATH confiable, HOME de root y rechazo de kubeconfig heredado inseguro; se eliminan hooks de shell y rutas de runtime heredadas.
- Gestión de `SIGINT`/`SIGTERM`/timeout por grupos de procesos para no dejar descendientes huérfanos.
- Evidencia temporal (`current`, `historical`, `unknown`) y metadata de ejecución de collectors.
- Siguientes pasos tipados como read-only, mutantes o de revisión; las acciones mutantes siguen siendo únicamente recomendaciones manuales.
- JSON Schema 1.1 validado formalmente con Draft 2020-12 y build metadata ampliada con target de compilación.
- Pipeline de release reproducible con limpieza de árbol, BUILDINFO, SBOM SPDX, checksums, validación independiente de ZIP/TAR.GZ y comprobación del binario portable aislado.
- Regresiones adversariales para entorno, cancelación, symlinks, integridad del collector y limpieza del paquete.

## 0.12.1 — Container Deep Diagnostics

- Añade `--container-mode deep` y `--containers-deep` para analizar todos los contenedores Docker/Podman visibles y todo el histórico de logs accesible.
- Analiza los logs en streaming y resume patrones, muestras, interpretación y posibles resoluciones manuales sin volcar el histórico completo.
- Correlaciona errores de logs con estado/health/OOM/reinicios de forma conservadora; un error histórico aislado no se convierte en causa actual.
- Añade salida JSON para el análisis profundo de contenedores.
- El menú interactivo permite elegir modo normal o profundo al seleccionar Contenedores.
- La suite de desarrollo puede preguntar si se desea instalar ShellCheck cuando falta; nunca se instala durante la ejecución normal de SYSdiag ni sin consentimiento explícito.
- Mantiene el diagnóstico operativo estrictamente read-only.

## 0.12.0 — Kubernetes Diagnostics

- Nueva sección `kubernetes` independiente de `containers`, manteniendo la separación host Linux → runtime → contenedor → Kubernetes/OpenShift → aplicación.
- Detección de `kubectl`/`oc`, contexto, API Server, identidad, versión observable y permisos RBAC básicos de lectura.
- Autenticación interactiva opcional cuando no existe sesión válida: API URL + token o usuario/contraseña; se usa un kubeconfig temporal eliminado al finalizar y no se modifica el kubeconfig habitual.
- Modos `quick`, `deep` y `exhaustive`; ámbitos cluster, nodo, namespace y Pod.
- Node Conditions: `Ready`, `MemoryPressure`, `DiskPressure`, `PIDPressure`, sin convertir NotReady/Pressure en causa raíz.
- Inventario y findings para Pods Pending/Failed/NotReady, reinicios altos, CrashLoopBackOff, ImagePullBackOff, OOMKilled y Evicted.
- Análisis de eventos Warning para FailedScheduling, probes, FailedAttach, FailedMount y fallos de provisioning, con ventana temporal conservadora: los eventos históricos se muestran como contexto pero no puntúan como causa actual.
- Services basados en EndpointSlices, con correlación selector → Pods coincidentes → readiness antes de atribuir el fallo a networking.
- PVC/StorageClass y separación explícita de provisioning, attach y mount.
- Workloads: Deployments, StatefulSets y DaemonSets con disponibilidad inferior a la deseada.
- Métricas de nodos mediante `top nodes` cuando están disponibles y `stats/summary` del kubelet a través del API Server según RBAC.
- OpenShift: ClusterOperators, Machines y muestreo read-only de `oc adm node-logs` en nodos sospechosos durante modo exhaustivo.
- Salida JSON ampliada con `metrics.kubernetes` y detalle estructurado de nodes, Pods, Services, PVC, workloads y eventos.
- Guía técnica ampliada con flujo DNS → Service → EndpointSlice → Pod → aplicación y reglas `Pending ≠ causa`, `OOMKilled ≠ MemoryPressure`, `Bound ≠ attached ≠ mounted`.
- Nueva suite `test_kubernetes.sh` y extensión de regresiones read-only para bloquear acciones mutantes de `kubectl`/`oc`.

## 0.11.0 — Container Diagnostics

- Nueva sección `containers` y opción de menú dedicada para Docker/Podman, con visibilidad ligera de CRI mediante `crictl`.
- Detección de endpoints Docker/Podman remotos; se omite el análisis profundo para no correlacionar runtimes remotos con métricas del host local.
- Inventario acotado de lifecycle, exit code, `OOMKilled`, `RestartCount`, health, restart policy, límites, mounts y network mode.
- Muestra read-only de recursos con `docker/podman stats --no-stream`, con detección de presión de memoria/CPU respecto a límites.
- Correlación con cgroup v2 mediante PID del host y `cpu.stat` para identificar throttling durante la ventana observada cuando es accesible.
- Análisis del filesystem que aloja el storage del runtime, con protección frente a storage remoto y timeouts.
- Detección limitada del tamaño de logs locales del runtime; no se recorren recursivamente los árboles de Docker/Podman.
- Señales de seguridad/operación para `privileged`, `network=host` y mounts de `docker.sock`, sin tratarlas automáticamente como fallos.
- Scoring conservador para restart loops, unhealthy, OOM de cgroup, presión de recursos y storage/logging.
- `--json` ampliado con métricas agregadas, detalle estructurado de contenedores inspeccionados y muestra de recursos.
- Guía técnica ampliada con Docker, Podman, CRI, cgroups, lifecycle, health, storage y seguridad.
- Nueva suite `test_containers.sh`, regresión de endpoint remoto y extensión de la prueba ejecutable read-only para bloquear acciones mutantes de Docker/Podman.

## 0.10.1 — Professional Polish

- Presentación revisada para mantener una voz profesional y autónoma en toda la herramienta.
- Frases de ayuda, findings, limitaciones y guía técnica normalizadas con inicio en mayúscula.
- Eliminadas referencias ajenas al uso operativo en CLI, documentación y guía integrada.
- Guía renombrada como referencia técnica de diagnóstico y comandos.
- Corregida la documentación de la opción de menú de la guía (`11`).
- Añadidas regresiones estáticas para impedir que reaparezcan referencias de desarrollo y mensajes diagnósticos con inicio en minúscula.

## 0.10.0 — Boot, Startup & Structured Diagnostics

- Nueva sección `boot` y opción de menú dedicada.
- Contexto de arranque: kernel, `root=` del cmdline, root source/fstype e initramfs detectado.
- Parsing read-only de `/etc/fstab` con entradas inválidas, mountpoints duplicados y referencias locales ausentes.
- Distinción explícita entre referencias obligatorias, `nofail`, `noauto` y `x-systemd.automount` para reducir falsos positivos.
- Mounts remotos reconocidos sin contacto automático con el destino.
- Consulta acotada de `.mount` units fallidas; reutilización del estado systemd previo para no repetir llamadas a un manager bloqueado.
- Integración de `systemd-analyze time`, `blame` y `critical-chain`; `blame` nunca se interpreta por sí solo como causalidad.
- Correlación acotada del journal del boot/kernel para emergency/rescue, device timeout, fsck, mount failures y errores de storage/filesystem.
- Detección de ejecución dentro de contenedor; el contexto Boot se marca `LIMITADO` y no mezcla cmdline del host con root del contenedor.
- Reutilización del estado de Logging cuando journald ya falló/expiró, evitando repetir consultas costosas.
- Corregido Logging: un fallo de `journalctl --list-boots` deja `n/d` y nunca se interpreta como 0 boots.
- Nueva salida `--json` con schema versionado 1.0, findings/limitaciones/next-steps y métricas clave por dominio.
- Schema formal y documentación en `docs/`.
- Guía integrada ampliada con Boot y comandos de troubleshooting del arranque.
- CI GitHub con sintaxis, ShellCheck, suite, standalone y validación JSON.
- Matriz de integración systemd en VMs Ubuntu 24.04, Debian 12, Rocky 9 y AlmaLinux 9 para runners KVM/libvirt.
- Nuevas suites `test_boot.sh`, `test_json.sh` y `test_readonly.sh`, más regresiones de contenedor, journald/systemd reuse, fstab opcional y verificación ejecutable de que no se invocan acciones mutantes.

## 0.9.0 — systemd & Services Diagnostics

- Nueva sección `systemd` y opción de menú dedicada.
- Verificación explícita de PID 1 antes de interpretar el system manager; entornos sin systemd se marcan como limitados.
- Estado global de systemd, target por defecto, unidades failed, services failed y timers conocidos.
- Detalle acotado de unidades fallidas mediante propiedades read-only: estado, resultado, MainPID, exit code/status, política de restart, NRestarts y ruta efectiva de la unit.
- Correlación acotada del journal del manager para `start-limit`, reinicios repetidos y fallos de dependencia.
- Detección adicional de `Result=start-limit-hit` y `NRestarts>=3` en propiedades, sin depender únicamente del journal.
- Scoring conservador específico para systemd; `failed` o `running` no se reinterpretan como causa/readiness.
- Recomendaciones de investigación con `systemctl status/cat/show/list-dependencies` y `journalctl -u`, sin acciones automáticas.
- Sanitización y límites en descripciones/logs de unidades problemáticas.
- Nueva guía integrada `--guide` / `--section guide` con explicación de cada sección y comandos de diagnóstico.
- Separación explícita en la guía entre comandos de diagnóstico y acciones manuales que cambian el sistema.
- Resumen general ampliado con estado `systemd / servicios` y semántica `LIMITADO` cuando PID 1 no es systemd o el manager no es accesible.
- Tests nuevos para systemd, start-limit, reinicios, dependencias, PID 1 no-systemd, ausencia de mutaciones, guía y standalone.

## 0.8.2 — Quality & UX Hardening

- Nueva opción de menú `Warnings y errores recientes (última hora)` y alias CLI `--recent-errors` / `--section recent`.
- Separación de eventos `ERROR+` y `WARNING` del journal, con límites estrictos para evitar inundar la terminal.
- `dmesg` se usa como fuente complementaria solo si soporta filtros temporales; no se vuelca el ring buffer completo como fallback.
- Deduplicación de mensajes de `dmesg` ya presentes en el journal del kernel.
- Sanitización de secuencias ANSI/caracteres de control procedentes de logs y límite de longitud por línea.
- Los warnings/errores genéricos siguen sin convertirse automáticamente en findings ni sumar scoring.
- Corregido el bug de selección múltiple por el que CPU/Red podían iniciar la ventana compartida sin `iostat` antes de seleccionar I/O.
- La selección múltiple se planifica antes del muestreo y reutiliza una sola ventana temporal con todos los colectores necesarios.
- Nueva defensa interna: una petición tardía de `iostat` no mezcla silenciosamente otra ventana de tiempo.
- I/O diferencia `iostat` instalado de una muestra realmente válida. Sin tabla válida se muestra `LIMITADO`, nunca ceros aparentando normalidad.
- `--section` muestra ahora `ANÁLISIS Y PRIORIZACIÓN` para las áreas relevantes, incluyendo findings cross-domain.
- La opción CPU + procesos evita recogidas duplicadas y permite correlación load/idle/procesos D.
- `/var/log` detecta su filesystem mediante `findmnt` o `/proc/self/mountinfo`; se omiten recorridos automáticos sobre NFS/CIFS/Ceph/GlusterFS/SSHFS/9p/AFS/Lustre.
- Fuente única de versión en `lib/version.sh`.
- CLI/menú separados en `lib/cli.sh`; el builder standalone deja de depender de un marcador textual frágil.
- Builder standalone determinista y test de reproducibilidad SHA256.
- Suite de tests dividida por dominio, manteniendo `tests/smoke.sh` como wrapper compatible.
- `shellcheck` se ejecuta opcionalmente cuando ya está instalado; nunca se instala automáticamente.
- Nueva opción `--version`.

## 0.8.1 — Interactive Diagnostic Menu

- Nuevo menú numérico al ejecutar SYSdiag sin argumentos en una terminal interactiva.
- Selección de áreas concretas y selección múltiple (`2,5,7`) sin eliminar `--section`.
- Nueva vista `Resumen general`, con estado compacto por dominio y prioridad actual sin volcar todas las métricas.
- El resumen distingue `LIMITADO` de `OK` cuando faltan herramientas o acceso necesario para completar una comprobación relevante.
- Nueva opción `--summary` para obtener el resumen compacto de forma no interactiva.
- Nueva opción `--all` para solicitar explícitamente el diagnóstico completo sin menú.
- Nueva opción `--menu` para forzar el menú cuando se desea.
- Compatibilidad con automatización: sin TTY y sin argumentos se conserva el diagnóstico completo histórico, evitando bloqueos esperando entrada.
- El menú se muestra antes de `--report`, para no contaminar el fichero con prompts interactivos.
- Sin cambios en las operaciones de diagnóstico: SYSdiag continúa siendo 100 % read-only.

## 0.8.0 — Logs & Journal Diagnostics

- Nueva sección `logging` centrada en capacidad de diagnóstico, no en contar errores.
- Detección read-only de journald: estado, `Storage=`, stores persistente/volátil, boots disponibles y uso del journal.
- Muestra acotada de mensajes `WARNING` o superiores de los últimos 30 minutos, sin tratarlos automáticamente como causa.
- Detección de rsyslog, estado del servicio, configuración e indicios de forwarding remoto.
- Detección de logrotate, timer/servicio, estado y directivas `compress`, `delaycompress`, `copytruncate`, `create` y `postrotate`.
- Revisión superficial y con timeout de ficheros grandes bajo `/var/log`; se evita `du` recursivo automático.
- Findings conservadores únicamente para fallos observables de journald/rsyslog/logrotate; `Storage=volatile/none` se trata como limitación de observabilidad, no como causa de una incidencia.
- Recomendaciones manuales para correlación temporal, boots, kernel, logs rotados, validación de logrotate y deleted-open.
- Tests ampliados para parsing, heurísticas y nueva sección.

## 0.7.0 — MTU / PMTU Diagnostics

- Añadido resumen de MTU para interfaces activas y detección de valores distintos sin asumir que sean un problema.
- Muestreo pasivo y sincronizado de contadores kernel relacionados con fragmentación y Path MTU.
- Añadidos `IpFragFails`, `Ip6FragFails`, `Ip6InTooBigErrors`, `Icmp6InPktTooBigs` y `TCPMTUPFail/TCPMTUPSuccess`.
- Lectura read-only de `net.ipv4.tcp_mtu_probing` y `net.ipv4.tcp_base_mss`.
- Nueva heurística explicable `NET_PMTU_KERNEL`: solo se activa con evidencia observada en contadores, no por una MTU local distinta.
- Retransmisiones elevadas ahora recomiendan discriminar pérdida/congestión frente a PMTU cuando el patrón encaja.
- Añadidos comandos manuales para `ip route get`, `tracepath`, ping IPv4 con DF, `ss -ti`, `nstat` y captura ICMP.
- Sin probes activos automáticos: SYSdiag continúa siendo read-only y evita generar tráfico innecesario.
- Tests ampliados para la nueva salida y heurística MTU/PMTU.

## 0.6.1 — Quality & Architecture Pass

- Corregido `CPU idle`: ya no incluye `iowait`.
- Añadida métrica `CPU activa (sin iowait)` y `steal`.
- Muestreo sincronizado de CPU, swap, red/TCP e iostat; una sola ventana temporal.
- Nueva opción `--sample <1..30>`.
- Scoring refactorizado a findings deduplicables con IDs y dominios de evidencia.
- Confianza basada en fuerza y señales independientes; añadido impacto separado.
- Recomendaciones y comandos deduplicados.
- Timeouts defensivos y listado de limitaciones de recogida.
- Salida adaptativa para terminal estrecho.
- Informes sin ANSI.
- OOM ponderado por antigüedad.
- `lsof +L1` deduplicado por device+inode; memfd/tmpfs temporal separado.
- I/O con `aqu-sz`, exclusión de loop y perfil rotacional/no rotacional.
- Red optimizada: una sola captura `ss`, throughput, softnet y deltas en ventana común.
- Suite de regresión ampliada para CPU, scoring, AppImage, deleted/open, red, report y standalone.

## 0.6

- Módulo de red/TCP: interfaces, routing, DNS local, sockets, retransmisiones, conntrack y drops.

## 0.5.1

- Alineación UTF-8 y comandos sugeridos en líneas independientes.

## 0.5

- AppImage/SquashFS read-only ignorados para alertas.
- Topología CPU física/lógica.
- Zombies con padre.
- Explicación de puntuación/confianza.
