# Static professional diagnostic reference. No collection and no mutations.

guide_cmd() {
  local cmd="$1" desc="$2"
  printf '    %s\n' "$desc"
  printf '      $ %s\n' "$cmd"
}

print_reference_guide() {
  section "GUÍA TÉCNICA DE DIAGNÓSTICO Y COMANDOS"
  printf '  Referencia técnica de investigación para las áreas cubiertas por SYSdiag. No sustituye el análisis de evidencias.\n'
  printf '  Patrón recomendado: Datos → hipótesis → prueba que discrimina → nuevo dato → siguiente decisión.\n'
  printf '  Los comandos se muestran como referencia; SYSdiag no los ejecuta automáticamente.\n'

  subsection "QUÉ HACE CADA APARTADO"
  printf '    Resumen general       Prioriza señales sin volcar todas las métricas. LIMITADO ≠ OK.\n'
  printf '    CPU y procesos        Load, CPU real, iowait, estados R/S/D/Z y correlaciones.\n'
  printf '    Memoria               Free/available, swap, si/so, presión y OOM.\n'
  printf '    I/O y almacenamiento  Latencia, cola, IOPS/throughput, utilización y procesos D.\n'
  printf '    Filesystems           Espacio, inodos, mounts, df/du y deleted-open files.\n'
  printf '    Red                   Interfaces, rutas, DNS, sockets/TCP, drops, retransmisiones y MTU/PMTU.\n'
  printf '    Logs / journald       Persistencia, boots, rsyslog, logrotate y capacidad de investigación.\n'
  printf '    Eventos recientes     WARNING/ERROR recientes de journal y kernel como evidencia de triaje.\n'
  printf '    Systemd / servicios   Units failed, start-limit, restart loops, dependencias y estado efectivo.\n'
  printf '    Boot / arranque       Fstab, mounts, journal del boot, critical-chain y contexto initramfs/root.\n'
  printf '    Contenedores          Docker/Podman/CRI, lifecycle, health, OOM/cgroups, recursos y storage del runtime.\n'
  printf '    Kubernetes/OpenShift  Contexto/RBAC, nodes, workloads, Pods, Services/EndpointSlices, probes, storage y eventos.\n'

  subsection "PROCESOS / CPU / I/O"
  guide_cmd "ps -eo pid,ppid,user,stat,%cpu,%mem,comm --sort=-%cpu" "Procesos, estado y consumo."
  guide_cmd "pstree -p" "Relaciones padre/hijo."
  guide_cmd "uptime" "Load average y uptime."
  guide_cmd "vmstat 1" "CPU, procesos bloqueados, swap e I/O en serie temporal."
  guide_cmd "iostat -xz 1" "Latencia, colas y utilización de dispositivos."
  guide_cmd "ps -eo pid,ppid,user,stat,comm,wchan:32 | awk '\$4 ~ /^D/'" "Procesos en estado D."
  printf '    Claves: Load alto no implica CPU saturada; iowait no es CPU ocupada ejecutando trabajo; D indica espera no interrumpible.\n'

  subsection "MEMORIA"
  guide_cmd "free -h" "Interpretación de free frente a available y swap."
  guide_cmd "vmstat 1" "Actividad real de swap: si/so."
  guide_cmd "journalctl -k --since \"-1 hour\" | grep -Ei 'oom|out of memory|killed process'" "Evidencia OOM del kernel."
  printf '    Claves: Poca memoria free puede ser normal por page cache; available es más útil. Swap usada sin si/so no demuestra thrashing.\n'

  subsection "FILESYSTEMS"
  guide_cmd "df -hT" "Uso y tipo de filesystem."
  guide_cmd "df -i" "Uso de inodos."
  guide_cmd "findmnt" "Mounts y origen/tipo."
  guide_cmd "lsof -nP +L1" "Ficheros borrados que siguen abiertos."
  guide_cmd "du -xsh <ruta>" "Uso visible dentro de un filesystem; puede ser costoso."
  printf '    Claves: df mide bloques del filesystem; du suma ficheros visibles. Un deleted-open puede explicar df ≫ du.\n'

  subsection "RED / TCP / MTU"
  guide_cmd "ip addr" "Interfaces y direcciones."
  guide_cmd "ip route" "Tabla de routing."
  guide_cmd "ip route get <destino>" "Ruta efectiva hacia un destino."
  guide_cmd "getent hosts <nombre>" "Resolución usando NSS del sistema."
  guide_cmd "ss -lntp" "Listeners TCP y procesos."
  guide_cmd "ss -s" "Resumen de sockets/TCP."
  guide_cmd "ss -ti" "Detalle TCP, retransmisiones/MSS según conexión."
  guide_cmd "nc -vz <host> <puerto>" "Prueba de establecimiento TCP a un puerto concreto."
  guide_cmd "curl -v http://<host>:<puerto>/" "Prueba HTTP y detalle de conexión/respuesta."
  guide_cmd "nstat" "Contadores IP/TCP si está disponible."
  guide_cmd "tracepath <destino>" "Camino y estimación de PMTU."
  guide_cmd "ping -M do -s 1472 <destino>" "Prueba IPv4 DF para MTU 1500; genera tráfico."
  guide_cmd "tcpdump -ni <iface> <filtro>" "Captura manual acotada; requiere criterio y permisos."
  printf '    Claves: Refused implica respuesta activa; timeout implica ausencia de respuesta útil. MTU local no demuestra PMTU extremo a extremo.\n'

  subsection "LOGS"
  guide_cmd "journalctl -u <unidad> --since \"-30 min\"" "Histórico reciente de una unit."
  guide_cmd "journalctl -k --since \"-30 min\"" "Mensajes de kernel en una ventana."
  guide_cmd "journalctl --list-boots" "Boots conservados en el journal."
  guide_cmd "journalctl -k -b -1" "Kernel del boot anterior si está retenido."
  guide_cmd "journalctl -f" "Seguimiento del journal en vivo."
  guide_cmd "dmesg -T" "Ring buffer del kernel con tiempo legible aproximado."
  guide_cmd "tail -f <log>" "Seguimiento de un fichero de log."
  guide_cmd "grep -C 3 <patrón> <log>" "Coincidencia con contexto."
  guide_cmd "zgrep <patrón> <log.gz>" "Búsqueda en logs comprimidos."
  guide_cmd "less <log>" "Exploración de ficheros grandes."
  guide_cmd "awk '{print \$1, \$2, \$3}' <log>" "Selección y transformación de campos de texto."
  guide_cmd "sed -n '100,140p' <log>" "Visualización de un rango concreto de líneas."
  guide_cmd "jq 'select(.level == \"error\")' <log.json>" "Filtrado de JSON estructurado."
  printf '    Claves: ERROR ≠ causa. Prioriza ventana temporal, capa que emite el mensaje y correlation/request IDs.\n'

  subsection "SYSTEMD / SERVICIOS"
  guide_cmd "systemctl status <unidad> --no-pager -l" "Estado actual y resumen."
  guide_cmd "systemctl cat <unidad>" "Definición efectiva y overrides."
  guide_cmd "systemctl show <unidad> -p Result -p MainPID -p ExecMainStatus -p Restart -p NRestarts" "Propiedades útiles."
  guide_cmd "systemctl is-active <unidad>" "Estado activo."
  guide_cmd "systemctl is-enabled <unidad>" "Estado de enable."
  guide_cmd "systemctl is-failed <unidad>" "Estado failed."
  guide_cmd "systemctl --failed --no-pager" "Unidades actualmente failed."
  guide_cmd "systemctl list-dependencies --all <unidad>" "Grafo de dependencias."
  guide_cmd "systemctl list-timers --all" "Timers y próximas ejecuciones."
  guide_cmd "journalctl -u <unidad> --since \"-1 hour\"" "Primer error y secuencia de reinicios."
  printf '    Claves: Start ≠ enable; loaded ≠ running; After ≠ Requires; started ≠ ready; failed ≠ systemd es la causa.\n'

  subsection "BOOT / ARRANQUE"
  guide_cmd "cat /proc/cmdline" "Parámetros entregados por el bootloader/kernel, incluido root= cuando existe."
  guide_cmd "lsblk -f" "Dispositivos, filesystems, UUID/LABEL y relación con fstab."
  guide_cmd "blkid" "Identificadores de filesystems/bloques."
  guide_cmd "findmnt --verify --verbose" "Validación read-only de fstab y mounts declarados."
  guide_cmd "systemctl --failed --type=mount --no-pager" "Mount units fallidas en systemd."
  guide_cmd "systemd-analyze time" "Tiempo global informado por systemd."
  guide_cmd "systemd-analyze blame" "Duración por unit; no demuestra por sí sola retraso causal."
  guide_cmd "systemd-analyze critical-chain" "Cadena crítica que condicionó alcanzar el target."
  guide_cmd "journalctl -b --no-pager" "Userspace/systemd del boot actual."
  guide_cmd "journalctl -k -b --no-pager" "Kernel del boot actual."
  guide_cmd "journalctl -b -1 --no-pager" "Boot anterior si el journal lo conserva."
  printf '    Claves: Identifica primero la capa: firmware → GRUB → kernel → initramfs → root → systemd. Emergency es consecuencia, no causa.\n'

  subsection "CONTENEDORES / RUNTIME"
  guide_cmd "docker ps -a --no-trunc" "Inventario y estado actual/histórico de contenedores Docker."
  guide_cmd "docker inspect <contenedor>" "Estado/configuración efectiva: exit code, OOMKilled, restart policy, límites, mounts y red."
  guide_cmd "docker stats --no-stream" "Muestra puntual de CPU, memoria, I/O y PIDs."
  guide_cmd "docker logs --tail 100 <contenedor>" "Salida stdout/stderr reciente sin volcar el histórico completo."
  guide_cmd "docker system df -v" "Ocupación lógica de imágenes, contenedores, cache y volúmenes; puede ser costoso en hosts grandes."
  guide_cmd "docker network inspect <red>" "Configuración de una red Docker."
  guide_cmd "docker volume inspect <volumen>" "Configuración y mountpoint de un volumen."
  guide_cmd "podman ps -a --no-trunc" "Inventario de contenedores Podman."
  guide_cmd "podman inspect <contenedor>" "Estado y configuración efectiva en Podman."
  guide_cmd "podman stats --no-stream" "Muestra puntual de recursos Podman; rootless puede limitar algunas métricas."
  guide_cmd "crictl ps -a" "Visibilidad de contenedores a través de CRI en hosts Kubernetes/OpenShift."
  guide_cmd "cat /sys/fs/cgroup/<cgroup>/cpu.stat" "Cuotas/throttling de CPU en cgroup v2."
  guide_cmd "cat /sys/fs/cgroup/<cgroup>/memory.events" "Eventos de memoria/OOM del cgroup."
  printf '    Claves: Imagen ≠ contenedor; namespaces = qué ve; cgroups = recursos; running ≠ healthy ≠ ready; exit 137 ≠ OOM sin evidencias; volumen ≠ backup.
'
  printf '    Seguridad: docker.sock y privileged conceden capacidades muy amplias; validar necesidad y mínimo privilegio.
'


  subsection "KUBERNETES / OPENSHIFT"
  guide_cmd "kubectl config current-context" "Contexto efectivo sin modificarlo."
  guide_cmd "kubectl auth whoami" "Identidad efectiva cuando el API lo soporta."
  guide_cmd "kubectl auth can-i --list" "Permisos visibles para el usuario actual."
  guide_cmd "kubectl get nodes -o wide" "Estado general y distribución de nodos."
  guide_cmd "kubectl describe node <nodo>" "Conditions, capacity/allocatable, eventos y asignaciones del nodo."
  guide_cmd "kubectl get pods -A -o wide" "Estado, nodo e IP de Pods en todo el cluster."
  guide_cmd "kubectl describe pod -n <namespace> <pod>" "Eventos, probes, mounts, requests/limits y estado detallado."
  guide_cmd "kubectl logs -n <namespace> <pod> --all-containers --tail=100" "Logs actuales acotados."
  guide_cmd "kubectl logs -n <namespace> <pod> --all-containers --previous --tail=100" "Logs de la instancia anterior del contenedor cuando existe."
  guide_cmd "kubectl get events -A --field-selector type=Warning" "Eventos Warning como evidencia suplementaria; revisar siempre su contexto temporal."
  guide_cmd "kubectl top nodes" "Uso observado si metrics-server/monitoring y RBAC lo permiten."
  guide_cmd "kubectl get svc -n <namespace> <service> -o yaml" "Selector, puertos y configuración efectiva del Service."
  guide_cmd "kubectl get endpointslices.discovery.k8s.io -n <namespace> -l kubernetes.io/service-name=<service>" "Backends observados detrás de un Service."
  guide_cmd "kubectl get pvc,pv,storageclass -A" "Estado de claims, volúmenes y clases de almacenamiento."
  guide_cmd "kubectl get --raw /api/v1/nodes/<nodo>/proxy/stats/summary" "Stats del kubelet a través del API Server cuando RBAC lo permite."
  guide_cmd "oc get clusteroperators" "Available/Progressing/Degraded de operadores OpenShift."
  guide_cmd "oc adm node-logs <nodo> -u kubelet --since=10m" "Journal remoto del kubelet mediante OpenShift sin copiar SYSdiag al nodo."
  printf '    Claves: Pending ≠ scheduler caído; NotReady ≠ causa; OOMKilled ≠ MemoryPressure; Running ≠ Ready; Bound ≠ attached ≠ mounted.\n'
  printf '    Red: DNS → Service → EndpointSlice → Pod IP/puerto → aplicación. Localiza el primer salto roto antes de atribuirlo al CNI.\n'
  printf '    Probes: Readiness retira tráfico; liveness puede provocar reinicios; startup protege arranques lentos.\n'
  printf '    Eventos: Son evidencia best-effort y temporal; un error antiguo no debe presentarse como causa actual sin correlación.\n'

  subsection "ACCIONES QUE CAMBIAN EL SISTEMA — SOLO MANUALES"
  printf '    SYSdiag no ejecuta estas acciones. Se incluyen únicamente como referencia operativa y deben utilizarse tras evaluar su impacto.\n'
  guide_cmd "systemctl start|stop|restart|reload <unidad>" "Cambio del estado/lifecycle del servicio."
  guide_cmd "systemctl enable|disable <unidad>" "Cambio de las relaciones de arranque automático."
  guide_cmd "systemctl mask|unmask <unidad>" "Bloqueo o restauración de la activación normal."
  guide_cmd "systemctl edit <unidad>" "Creación o edición de un override local de la unit."
  guide_cmd "systemctl daemon-reload" "Recarga de definiciones de units; no reinicia servicios."
  guide_cmd "systemctl reset-failed <unidad>" "Limpieza del estado y contadores failed; no corrige la causa."
  guide_cmd "kill <PID>" "Envío de SIGTERM por defecto; permite cierre ordenado."
  guide_cmd "kill -9 <PID>" "SIGKILL; último recurso, no permite cleanup."

  subsection "REGLAS DE TROUBLESHOOTING"
  printf '    1. Empieza por el síntoma y el momento exacto, no por una lista de comandos.\n'
  printf '    2. Separa datos de interpretación.\n'
  printf '    3. Prioriza hipótesis que expliquen más evidencias independientes.\n'
  printf '    4. Busca una prueba que discrimine entre hipótesis, no otra métrica al azar.\n'
  printf '    5. La correlación temporal fuerte ayuda a priorizar, pero no demuestra causalidad.\n'
  printf '    6. Si una herramienta falta o una muestra no es válida, el estado correcto es LIMITADO, no OK.\n'
}
