package correlation

import (
	"fmt"
	"strings"
	"time"

	"github.com/chus87/sysdiag/internal/model"
)

// Correlate builds conclusions only from stable finding identifiers/domains and
// structured metrics. Human-facing wording must never be part of rule matching.
func Correlate(r *model.Report) {
	BuildEvidence(r)
	idx := newIndex(r)

	correlateStorageClassPVC(r, idx)
	correlateLivenessRestarts(r, idx)
	correlateNodeMemory(r, idx)
	correlateServices(r, idx)
	correlateScheduling(r, idx)
	correlateStorageOperations(r, idx)
	correlateContainerHost(r, idx)

	r.Conclusions = dedupeConclusions(r.Conclusions)
}

// BuildEvidence converts findings into a stable evidence surface. More precise
// evidence can also be added by correlation rules from structured metrics.
func BuildEvidence(r *model.Report) {
	seen := map[string]bool{}
	for _, e := range r.Evidence {
		seen[e.ID] = true
	}
	for _, f := range r.Findings {
		id := "ev-" + f.ID
		if seen[id] {
			continue
		}
		seen[id] = true
		layer := f.Layer
		if layer == "" {
			layer = layerForCategory(f.Category)
		}
		r.Evidence = append(r.Evidence, model.Evidence{
			ID: id, Layer: layer, Scope: f.Scope, Resource: f.Resource,
			Kind: f.Domain, TemporalState: model.TemporalUnknown, Message: f.Message,
			Attributes: map[string]any{"finding_id": f.ID, "points": f.Points, "impact": f.Impact},
		})
	}

	addTemporalEventEvidence(r, seen)
}

func layerForCategory(c string) string {
	switch c {
	case "kubernetes":
		return "kubernetes"
	case "containers":
		return "container/runtime"
	default:
		return "host-linux"
	}
}

type findingIndex struct {
	findings []model.Finding
	byID     map[string]model.Finding
}

func newIndex(r *model.Report) findingIndex {
	i := findingIndex{findings: r.Findings, byID: map[string]model.Finding{}}
	for _, f := range r.Findings {
		i.byID[f.ID] = f
	}
	return i
}

func (i findingIndex) prefix(prefix string) []model.Finding {
	out := []model.Finding{}
	for _, f := range i.findings {
		if strings.HasPrefix(f.ID, prefix) {
			out = append(out, f)
		}
	}
	return out
}

func (i findingIndex) has(id string) bool {
	_, ok := i.byID[id]
	return ok
}

func evidenceIDs(fs ...model.Finding) []string {
	out := make([]string, 0, len(fs))
	for _, f := range fs {
		out = append(out, "ev-"+f.ID)
	}
	return dedupe(out)
}

func correlateStorageClassPVC(r *model.Report, idx findingIndex) {
	for _, sc := range idx.prefix("K8S_PVC_SC_") {
		suffix := strings.TrimPrefix(sc.ID, "K8S_PVC_SC_")
		ids := evidenceIDs(sc)
		if p, ok := idx.byID["K8S_PVC_PENDING_"+suffix]; ok {
			ids = evidenceIDs(sc, p)
		}
		r.Conclusions = append(r.Conclusions, model.Conclusion{
			ID: "corr-k8s-storageclass-pvc-" + suffix, Title: "StorageClass inexistente bloqueando el PVC",
			Confidence: "ALTA", RootCause: true, EvidenceIDs: ids,
			Interpretation: "El PVC solicita una StorageClass que no aparece disponible. Esta evidencia explica el bloqueo de aprovisionamiento sin necesidad de atribuirlo al scheduler, CSI o backend antes de obtener más datos.",
			ManualChecks:   []string{"kubectl describe pvc <PVC> -n <NS>", "kubectl get storageclass"},
		})
	}
}

func correlateLivenessRestarts(r *model.Report, idx findingIndex) {
	for _, kill := range idx.prefix("K8S_LIVENESS_KILL_") {
		suffix := strings.TrimPrefix(kill.ID, "K8S_LIVENESS_KILL_")
		fs := []model.Finding{kill}
		if f, ok := idx.byID["K8S_LIVENESS_"+suffix]; ok {
			fs = append(fs, f)
		}
		if f, ok := idx.byID["K8S_POD_RESTARTS_"+podSuffixFromEventSuffix(suffix)]; ok {
			fs = append(fs, f)
		}
		r.Conclusions = append(r.Conclusions, model.Conclusion{
			ID: "corr-liveness-restarts-" + suffix, Title: "Kubelet está provocando reinicios tras fallos de liveness",
			Confidence: "ALTA", RootCause: false, EvidenceIDs: evidenceIDs(fs...),
			Interpretation: "Los eventos muestran que kubelet mata el contenedor después de fallar la liveness. El contador RESTARTS no demuestra por sí mismo un crash espontáneo de la aplicación.",
			ManualChecks:   []string{"kubectl describe pod <POD> -n <NS>", "kubectl logs <POD> -n <NS> --previous"},
		})
	}
}

// Event IDs include namespace-kind-name while Pod IDs include namespace-name.
func podSuffixFromEventSuffix(s string) string {
	for _, marker := range []string{"_Pod_", "-Pod-", "_pod_", "-pod-"} {
		if p := strings.Index(s, marker); p >= 0 {
			return s[:p] + s[p+len(marker)-1:]
		}
	}
	return s
}

type nodeState struct {
	Name           string
	MemoryPressure bool
}

type podIssue struct {
	Namespace  string
	Name       string
	Node       string
	LastReason string
	Reason     string
}

func correlateNodeMemory(r *model.Report, idx findingIndex) {
	nodes := k8sNodes(r)
	pods := k8sPodIssues(r)
	for _, p := range pods {
		n, ok := nodes[p.Node]
		if !ok || p.Node == "" || p.Node == "n/d" {
			continue
		}
		podID := kubeID(p.Namespace + "-" + p.Name)
		if p.LastReason == "OOMKilled" || idx.has("K8S_POD_OOM_"+podID) {
			if !n.MemoryPressure {
				ids := []string{}
				if f, ok := idx.byID["K8S_POD_OOM_"+podID]; ok {
					ids = evidenceIDs(f)
				}
				ev := addMetricEvidence(r, "kubernetes", "node_condition", p.Node,
					fmt.Sprintf("El nodo %s informa MemoryPressure=False mientras %s/%s registra OOMKilled.", p.Node, p.Namespace, p.Name),
					map[string]any{"memory_pressure": false, "pod": p.Namespace + "/" + p.Name})
				ids = append(ids, ev)
				r.Conclusions = append(r.Conclusions, model.Conclusion{
					ID: "corr-k8s-cgroup-oom-" + podID, Title: "OOM del contenedor sin evidencia de presión global del nodo",
					Confidence: "ALTA", RootCause: false, EvidenceIDs: dedupe(ids),
					Interpretation: "OOMKilled coincide con MemoryPressure=False en el nodo. Gana fuerza un límite/cgroup del contenedor frente a una falta global de RAM; debe verificarse memory limit y uso del cgroup.",
					ManualChecks:   []string{"kubectl describe pod <POD> -n <NS>", "kubectl get pod <POD> -n <NS> -o yaml", "revisar memory.current y memory.max del cgroup cuando exista acceso al nodo"},
				})
			}
		}
		if p.Reason == "Evicted" || idx.has("K8S_POD_EVICTED_"+podID) {
			if n.MemoryPressure {
				ids := []string{}
				if f, ok := idx.byID["K8S_POD_EVICTED_"+podID]; ok {
					ids = evidenceIDs(f)
				}
				if f, ok := idx.byID["K8S_NODE_MEMORY_"+kubeID(p.Node)]; ok {
					ids = append(ids, "ev-"+f.ID)
				}
				r.Conclusions = append(r.Conclusions, model.Conclusion{
					ID: "corr-node-pressure-eviction-" + podID, Title: "Node-pressure eviction por memoria es una hipótesis fuerte",
					Confidence: "ALTA", RootCause: false, EvidenceIDs: dedupe(ids),
					Interpretation: "El Pod figura Evicted y su nodo informa MemoryPressure=True. El eviction manager del kubelet es una explicación coherente; el motivo exacto del eviction debe confirmarse en Pod/Events.",
					ManualChecks:   []string{"kubectl describe pod <POD> -n <NS>", "kubectl describe node <NODE>", "kubectl get events -A --sort-by=.lastTimestamp"},
				})
			}
		}
	}
}

func correlateServices(r *model.Report, idx findingIndex) {
	for _, f := range idx.prefix("K8S_SVC_SELECTOR_") {
		suffix := strings.TrimPrefix(f.ID, "K8S_SVC_SELECTOR_")
		r.Conclusions = append(r.Conclusions, model.Conclusion{
			ID: "corr-service-selector-" + suffix, Title: "Service sin backends por selección de Pods",
			Confidence: "ALTA", RootCause: false, EvidenceIDs: evidenceIDs(f),
			Interpretation: "El Service tiene selector, pero no Pods coincidentes ni endpoints. La relación selector→labels debe corregirse o explicarse antes de investigar el CNI/dataplane.",
			ManualChecks:   []string{"kubectl get svc <SERVICE> -n <NS> -o yaml", "kubectl get pods -n <NS> --show-labels"},
		})
	}
	for _, f := range idx.prefix("K8S_SVC_READINESS_") {
		suffix := strings.TrimPrefix(f.ID, "K8S_SVC_READINESS_")
		r.Conclusions = append(r.Conclusions, model.Conclusion{
			ID: "corr-service-readiness-" + suffix, Title: "Service sin backend Ready por estado de los Pods",
			Confidence: "ALTA", RootCause: false, EvidenceIDs: evidenceIDs(f),
			Interpretation: "El Service selecciona Pods pero ninguno está Ready. La investigación debe seguir readiness/aplicación/dependencias antes de atribuir el síntoma al dataplane del Service.",
			ManualChecks:   []string{"kubectl get pods -n <NS> -o wide", "kubectl describe pod <POD> -n <NS>"},
		})
	}
}

func correlateScheduling(r *model.Report, idx findingIndex) {
	for _, f := range idx.prefix("K8S_SCHED_MEM_") {
		suffix := strings.TrimPrefix(f.ID, "K8S_SCHED_MEM_")
		r.Conclusions = append(r.Conclusions, model.Conclusion{
			ID: "corr-scheduling-memory-" + suffix, Title: "Scheduling bloqueado por requests de memoria",
			Confidence: "ALTA", RootCause: false, EvidenceIDs: evidenceIDs(f),
			Interpretation: "FailedScheduling: Insufficient memory se decide con requests, Allocatable y nodos elegibles; no demuestra que Linux tenga poca MemAvailable en ese instante.",
			ManualChecks:   []string{"kubectl describe pod <POD> -n <NS>", "kubectl describe node <NODE>"},
		})
	}
}

func correlateStorageOperations(r *model.Report, idx findingIndex) {
	for _, f := range idx.prefix("K8S_MOUNT_") {
		suffix := strings.TrimPrefix(f.ID, "K8S_MOUNT_")
		r.Conclusions = append(r.Conclusions, model.Conclusion{
			ID: "corr-storage-mount-" + suffix, Title: "Fallo durante el montaje del volumen",
			Confidence: "ALTA", RootCause: false, EvidenceIDs: evidenceIDs(f),
			Interpretation: "La evidencia es FailedMount: el PVC puede estar ya aprovisionado y el fallo está en la fase kubelet/CSI node/filesystem/dispositivo. No equivale a FailedAttach ni demuestra un fallo del CSI controller.",
			ManualChecks:   []string{"kubectl describe pod <POD> -n <NS>", "revisar kubelet y CSI node plugin en el nodo", "revisar filesystem/dispositivo y opciones de mount"},
		})
	}
	for _, f := range idx.prefix("K8S_ATTACH_") {
		suffix := strings.TrimPrefix(f.ID, "K8S_ATTACH_")
		r.Conclusions = append(r.Conclusions, model.Conclusion{
			ID: "corr-storage-attach-" + suffix, Title: "Fallo durante el attach del volumen",
			Confidence: "ALTA", RootCause: false, EvidenceIDs: evidenceIDs(f),
			Interpretation: "La evidencia es FailedAttach. Debe investigarse la cadena CSI controller/backend→nodo antes de bajar directamente a filesystem o mount del host.",
			ManualChecks:   []string{"kubectl describe pod <POD> -n <NS>", "revisar CSI controller y eventos del backend de almacenamiento"},
		})
	}
}

func correlateContainerHost(r *model.Report, idx findingIndex) {
	if !idx.has("CONTAINER_OOMKILLED") {
		return
	}
	var host []model.Finding
	for _, id := range []string{"MEM_AVAILABLE_LOW", "MEM_PRESSURE_CORRELATED", "MEM_OOM_RECENT"} {
		if f, ok := idx.byID[id]; ok {
			host = append(host, f)
		}
	}
	if len(host) == 0 {
		return
	}
	fs := []model.Finding{idx.byID["CONTAINER_OOMKILLED"]}
	fs = append(fs, host...)
	r.Conclusions = append(r.Conclusions, model.Conclusion{
		ID: "corr-container-host-memory", Title: "OOM de contenedor coincide con señales de memoria del host",
		Confidence: "MEDIA", RootCause: false, EvidenceIDs: evidenceIDs(fs...),
		Interpretation: "Hay evidencia simultánea en contenedor/cgroup y host. La coincidencia aumenta la prioridad de investigar memoria, pero no demuestra causalidad: deben compararse límites del contenedor, memory.current/max y MemAvailable/PSI.",
		ManualChecks:   []string{"cat /proc/meminfo", "cat /proc/pressure/memory", "inspeccionar memory.current y memory.max del cgroup"},
	})
}

func k8sNodes(r *model.Report) map[string]nodeState {
	out := map[string]nodeState{}
	if r.Typed == nil {
		model.HydrateTypedMetrics(r)
	}
	if r.Typed == nil {
		return out
	}
	for _, n := range r.Typed.Kubernetes.Nodes {
		if n.Name != "" {
			out[n.Name] = nodeState{Name: n.Name, MemoryPressure: n.MemoryPressure}
		}
	}
	return out
}

func k8sPodIssues(r *model.Report) []podIssue {
	out := []podIssue{}
	if r.Typed == nil {
		model.HydrateTypedMetrics(r)
	}
	if r.Typed == nil {
		return out
	}
	for _, p := range r.Typed.Kubernetes.PodIssues {
		out = append(out, podIssue{Namespace: p.Namespace, Name: p.Name, Node: p.Node, LastReason: p.LastReason, Reason: p.StatusReason})
	}
	return out
}

func addTemporalEventEvidence(r *model.Report, seen map[string]bool) {
	if r.Typed == nil {
		model.HydrateTypedMetrics(r)
	}
	if r.Typed == nil {
		return
	}
	now := time.Now().UTC()
	for _, ev := range r.Typed.Kubernetes.WarningEvents {
		resource := ev.Kind + "/" + ev.Namespace + "/" + ev.Name
		id := "ev-k8s-event-" + sanitizeID(ev.Namespace+"-"+ev.Kind+"-"+ev.Name+"-"+ev.Reason+"-"+ev.LastTimestamp)
		if seen[id] {
			continue
		}
		seen[id] = true
		e := model.Evidence{ID: id, Layer: "kubernetes", Scope: ev.Namespace, Resource: resource, Kind: "warning_event", TemporalState: model.TemporalUnknown, Message: ev.Message, Attributes: map[string]any{"reason": ev.Reason}}
		if ts, ok := parseEventTime(ev.LastTimestamp); ok {
			age := int64(now.Sub(ts).Seconds())
			if age < 0 {
				age = 0
			}
			e.ObservedAt = ts.Format(time.RFC3339)
			e.LastSeen = e.ObservedAt
			e.AgeSeconds = &age
			current := age <= 3600
			e.Current = model.Bool(current)
			if current {
				e.TemporalState = model.TemporalCurrent
			} else {
				e.TemporalState = model.TemporalHistorical
			}
		}
		r.Evidence = append(r.Evidence, e)
	}
}
func parseEventTime(v string) (time.Time, bool) {
	v = strings.TrimSpace(v)
	if v == "" || v == "n/d" || v == "<none>" {
		return time.Time{}, false
	}
	for _, layout := range []string{time.RFC3339, time.RFC3339Nano, "2006-01-02T15:04:05Z0700"} {
		if t, err := time.Parse(layout, v); err == nil {
			return t.UTC(), true
		}
	}
	return time.Time{}, false
}

func addMetricEvidence(r *model.Report, layer, kind, resource, message string, attrs map[string]any) string {
	id := "ev-metric-" + sanitizeID(layer+"-"+kind+"-"+resource)
	for _, e := range r.Evidence {
		if e.ID == id {
			return id
		}
	}
	r.Evidence = append(r.Evidence, model.Evidence{ID: id, Layer: layer, Resource: resource, Kind: kind, Current: model.Bool(true), TemporalState: model.TemporalCurrent, ObservedAt: time.Now().UTC().Format(time.RFC3339), Message: message, Attributes: attrs})
	return id
}

func kubeID(s string) string {
	var b strings.Builder
	for _, r := range s {
		if (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') || r == '_' || r == '-' {
			b.WriteRune(r)
		} else {
			b.WriteByte('_')
		}
		if b.Len() >= 100 {
			break
		}
	}
	return b.String()
}

func sanitizeID(s string) string {
	var b strings.Builder
	lastSep := false
	for _, r := range s {
		if r >= 'A' && r <= 'Z' {
			r += 'a' - 'A'
		}
		if (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') {
			b.WriteRune(r)
			lastSep = false
		} else if !lastSep && b.Len() > 0 {
			b.WriteByte('_')
			lastSep = true
		}
	}
	return strings.Trim(b.String(), "_")
}

func dedupe(in []string) []string {
	m := map[string]bool{}
	out := []string{}
	for _, x := range in {
		if x != "" && !m[x] {
			m[x] = true
			out = append(out, x)
		}
	}
	return out
}

func dedupeConclusions(in []model.Conclusion) []model.Conclusion {
	m := map[string]bool{}
	out := []model.Conclusion{}
	for _, x := range in {
		if x.ID == "" || m[x.ID] {
			continue
		}
		m[x.ID] = true
		x.EvidenceIDs = dedupe(x.EvidenceIDs)
		out = append(out, x)
	}
	return out
}
