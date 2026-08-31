# Salida JSON de SYSdiag

`--json` produce una salida estructurada pensada para automatización, comparación entre hosts, almacenamiento histórico o ingestión posterior en una plataforma de observabilidad/SIEM.

```bash
./sysdiag.sh --all --json > host.json
./sysdiag.sh --section boot --json > boot.json
./sysdiag.sh --section containers --json > containers.json
./sysdiag.sh --section kubernetes --k8s-mode deep --json > kubernetes.json
./sysdiag.sh --section network --json --report network.json
```

No convierte texto coloreado a JSON: usa un **schema propio versionado** (`schema_version: 1.1`) con:

- versión de SYSdiag y timestamp UTC;
- ámbito (`scope`);
- resumen por categoría con estado, score, señales independientes, confianza e impacto;
- findings identificables;
- limitaciones explícitas;
- siguientes pasos y comandos sugeridos;
- métricas clave por dominio;
- en `metrics.containers`, resumen Docker/Podman/CRI, detalle de contenedores inspeccionados y muestra de recursos;
- en `metrics.kubernetes`, contexto/plataforma, cobertura RBAC, Node Conditions, Pods problemáticos, Services/EndpointSlices, PVC, workloads, Events (totales, recientes, históricos y sin fecha validable) y cobertura de métricas/kubelet.

La compatibilidad se gobierna por `schema_version`, no por la versión del programa. Una futura SYSdiag puede evolucionar sin romper consumidores mientras conserve el schema 1.x compatible. Un cambio incompatible requiere un nuevo schema.

El fichero `docs/sysdiag-json-schema-v1.1.json` documenta la estructura formal. La salida no necesita `jq` ni Python para generarse; esas herramientas se usan únicamente en tests/consumo opcional.

`--guide --json` no está soportado porque la guía es una referencia humana, no un resultado de diagnóstico.

## Campos del núcleo Go

Cuando el informe se genera mediante el núcleo Go (`engine: "go-core"`) el schema 1.1 puede incluir campos aditivos:

- `evidence`: representación tipada de evidencias observadas y su capa (`host-linux`, `container/runtime`, `kubernetes`, etc.);
- `conclusions`: correlaciones construidas a partir de varias evidencias, con confianza, IDs de evidencia y comprobaciones manuales sugeridas;
- `engine`: identifica el motor que produjo el informe.

Estos campos son aditivos y no eliminan `findings`, `summary`, `limitations`, `next_steps` ni `metrics`. Los consumidores que sólo utilizan el contrato original 1.1 continúan funcionando.

En un diagnóstico completo estructurado, el núcleo Go aísla las ramas host, contenedores y Kubernetes/OpenShift. Si una rama no puede completarse, el resto del informe se conserva y la cobertura ausente se declara explícitamente en `limitations`/`summary`; nunca se interpreta como estado saludable.

## Evidencia temporal y cobertura

Cada evidencia puede indicar `temporal_state` como `current`, `historical` o `unknown`. Cuando la fuente proporciona timestamps fiables, SYSdiag añade `observed_at`, `first_seen`, `last_seen` y/o `age_seconds`. Un evento antiguo puede conservarse como contexto sin puntuar como causa actual.

`collectors` describe qué ramas se pudieron ejecutar, su duración y si terminaron como `ok`, `limited` o `failed`. Esto permite distinguir un resultado sin findings de un diagnóstico incompleto.

## Build y acciones manuales

`build` identifica toolchain, target, commit cuando está disponible, versión del schema y SHA-256 del collector embebido. `next_steps[].actions` clasifica cada comando sugerido como `read_only`, `mutating` o `unknown`; esta clasificación no autoriza ejecución automática: SYSdiag continúa sin ejecutar acciones correctivas.
