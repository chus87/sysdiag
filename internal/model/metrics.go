package model

import (
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
)

// TypedMetrics is the stable, compiler-checked view consumed by the Go engine.
// Raw Metrics remains in the JSON report for backwards compatibility and for
// collector-specific detail that has not yet earned a stable typed contract.
type TypedMetrics struct {
	Host       HostMetrics
	Containers ContainerMetrics
	Kubernetes KubernetesMetrics
}

type HostMetrics struct {
	MemoryAvailableKB *int64
	MemoryFreeKB      *int64
	SwapUsedKB        *int64
	CPUIdlePct        *float64
	CPUIOWaitPct      *float64
	IOMaxAwaitMS      *float64
	IOMaxUtilPct      *float64
	FSMaxSpacePct     *float64
	FSMaxInodePct     *float64
}

type ContainerMetrics struct {
	Runtime            string
	Running            int
	Exited             int
	Restarting         int
	Unhealthy          int
	OOMKilled          int
	DeepScanned        int
	DeepPatternMatches int
	DeepIssues         []ContainerDeepIssue
}

type ContainerDeepIssue struct {
	Runtime          string
	Name             string
	ScanState        string
	LogLines         int
	Category         string
	Matches          int
	Sample           string
	Interpretation   string
	ManualResolution string
}

type KubernetesMetrics struct {
	Access                   string
	Client                   string
	Mode                     string
	Scope                    string
	PermissionDenied         int
	Nodes                    []KubernetesNode
	PodIssues                []KubernetesPodIssue
	ServiceIssues            []KubernetesServiceIssue
	PVCIssues                []KubernetesPVCIssue
	WarningEvents            []KubernetesWarningEvent
	NodesNotReady            int
	MemoryPressureNodes      int
	DiskPressureNodes        int
	PIDPressureNodes         int
	FailedScheduling         int
	FailedAttach             int
	FailedMount              int
	StorageProvisionFailures int
}

type KubernetesNode struct {
	Name              string
	Ready             string
	MemoryPressure    bool
	DiskPressure      bool
	PIDPressure       bool
	Unschedulable     bool
	AllocatableCPU    string
	AllocatableMemory string
}

type KubernetesPodIssue struct {
	Namespace     string
	Name          string
	Phase         string
	Ready         string
	Restarts      int
	WaitingReason string
	LastReason    string
	StatusReason  string
	Node          string
}

type KubernetesServiceIssue struct {
	Namespace      string
	Name           string
	Type           string
	Endpoints      int
	ReadyEndpoints int
	Reason         string
}

type KubernetesPVCIssue struct {
	Namespace    string
	Name         string
	Status       string
	Volume       string
	StorageClass string
}

type KubernetesWarningEvent struct {
	Namespace     string
	Reason        string
	Kind          string
	Name          string
	Message       string
	LastTimestamp string
}

func HydrateTypedMetrics(r *Report) {
	t := &TypedMetrics{}
	m := r.Metrics
	if m == nil {
		r.Typed = t
		return
	}
	mem := mapValue(m["memory"])
	t.Host.MemoryAvailableKB = int64Ptr(mem["available_kb"])
	t.Host.MemoryFreeKB = int64Ptr(mem["free_kb"])
	t.Host.SwapUsedKB = int64Ptr(mem["swap_used_kb"])
	cpu := mapValue(m["cpu"])
	t.Host.CPUIdlePct = float64Ptr(cpu["idle_pct"])
	t.Host.CPUIOWaitPct = float64Ptr(cpu["iowait_pct"])
	ioM := mapValue(m["io"])
	t.Host.IOMaxAwaitMS = float64Ptr(ioM["max_await_ms"])
	t.Host.IOMaxUtilPct = float64Ptr(ioM["max_util_pct"])
	fs := mapValue(m["filesystem"])
	t.Host.FSMaxSpacePct = float64Ptr(fs["max_space_pct"])
	t.Host.FSMaxInodePct = float64Ptr(fs["max_inode_pct"])

	c := mapValue(m["containers"])
	t.Containers.Runtime = stringValue(c["runtime"])
	t.Containers.Running = intValue(c["running"])
	t.Containers.Exited = intValue(c["exited"])
	t.Containers.Restarting = intValue(c["restarting"])
	t.Containers.Unhealthy = intValue(c["unhealthy"])
	t.Containers.OOMKilled = intValue(c["oomkilled"])
	t.Containers.DeepScanned = intValue(c["deep_scanned_containers"])
	t.Containers.DeepPatternMatches = intValue(c["deep_pattern_matches"])
	for _, v := range sliceValue(c["deep_issues"]) {
		x := mapValue(v)
		t.Containers.DeepIssues = append(t.Containers.DeepIssues, ContainerDeepIssue{
			Runtime: stringValue(x["runtime"]), Name: stringValue(x["name"]), ScanState: stringValue(x["scan_state"]),
			LogLines: intValue(x["log_lines"]), Category: stringValue(x["category"]), Matches: intValue(x["matches"]),
			Sample: stringValue(x["sample"]), Interpretation: stringValue(x["interpretation"]), ManualResolution: stringValue(x["manual_resolution"]),
		})
	}

	k := mapValue(m["kubernetes"])
	t.Kubernetes.Access = stringValue(k["access"])
	t.Kubernetes.Client = stringValue(k["client"])
	t.Kubernetes.Mode = stringValue(k["mode"])
	t.Kubernetes.Scope = stringValue(k["scope"])
	t.Kubernetes.PermissionDenied = intValue(k["permission_denied"])
	t.Kubernetes.NodesNotReady = intValue(k["nodes_not_ready"])
	t.Kubernetes.MemoryPressureNodes = intValue(k["memory_pressure_nodes"])
	t.Kubernetes.DiskPressureNodes = intValue(k["disk_pressure_nodes"])
	t.Kubernetes.PIDPressureNodes = intValue(k["pid_pressure_nodes"])
	t.Kubernetes.FailedScheduling = intValue(k["failed_scheduling"])
	t.Kubernetes.FailedAttach = intValue(k["failed_attach"])
	t.Kubernetes.FailedMount = intValue(k["failed_mount"])
	t.Kubernetes.StorageProvisionFailures = intValue(k["storage_provision_failures"])
	for _, v := range sliceValue(k["nodes_detail"]) {
		x := mapValue(v)
		t.Kubernetes.Nodes = append(t.Kubernetes.Nodes, KubernetesNode{
			Name: stringValue(x["name"]), Ready: stringValue(x["ready"]), MemoryPressure: boolString(x["memory_pressure"]),
			DiskPressure: boolString(x["disk_pressure"]), PIDPressure: boolString(x["pid_pressure"]), Unschedulable: boolString(x["unschedulable"]),
			AllocatableCPU: stringValue(x["allocatable_cpu"]), AllocatableMemory: stringValue(x["allocatable_memory"]),
		})
	}
	for _, v := range sliceValue(k["pod_issues"]) {
		x := mapValue(v)
		t.Kubernetes.PodIssues = append(t.Kubernetes.PodIssues, KubernetesPodIssue{
			Namespace: stringValue(x["namespace"]), Name: stringValue(x["name"]), Phase: stringValue(x["phase"]), Ready: stringValue(x["ready"]),
			Restarts: intValue(x["restarts"]), WaitingReason: stringValue(x["waiting_reason"]), LastReason: stringValue(x["last_reason"]),
			StatusReason: stringValue(x["status_reason"]), Node: stringValue(x["node"]),
		})
	}
	for _, v := range sliceValue(k["service_issues"]) {
		x := mapValue(v)
		t.Kubernetes.ServiceIssues = append(t.Kubernetes.ServiceIssues, KubernetesServiceIssue{
			Namespace: stringValue(x["namespace"]), Name: stringValue(x["name"]), Type: stringValue(x["type"]),
			Endpoints: intValue(x["endpoints"]), ReadyEndpoints: intValue(x["ready_endpoints"]), Reason: stringValue(x["reason"]),
		})
	}
	for _, v := range sliceValue(k["pvc_issues"]) {
		x := mapValue(v)
		t.Kubernetes.PVCIssues = append(t.Kubernetes.PVCIssues, KubernetesPVCIssue{
			Namespace: stringValue(x["namespace"]), Name: stringValue(x["name"]), Status: stringValue(x["status"]),
			Volume: stringValue(x["volume"]), StorageClass: stringValue(x["storage_class"]),
		})
	}
	for _, v := range sliceValue(k["warning_event_details"]) {
		x := mapValue(v)
		t.Kubernetes.WarningEvents = append(t.Kubernetes.WarningEvents, KubernetesWarningEvent{
			Namespace: stringValue(x["namespace"]), Reason: stringValue(x["reason"]), Kind: stringValue(x["kind"]), Name: stringValue(x["name"]),
			Message: stringValue(x["message"]), LastTimestamp: stringValue(x["last_timestamp"]),
		})
	}
	r.Typed = t
}

func mapValue(v any) map[string]any {
	m, _ := v.(map[string]any)
	return m
}
func sliceValue(v any) []any {
	s, _ := v.([]any)
	return s
}
func stringValue(v any) string {
	if v == nil {
		return ""
	}
	return fmt.Sprint(v)
}
func intValue(v any) int {
	if v == nil {
		return 0
	}
	switch x := v.(type) {
	case float64:
		return int(x)
	case float32:
		return int(x)
	case int:
		return x
	case int64:
		return int(x)
	case json.Number:
		n, _ := x.Int64()
		return int(n)
	}
	n, _ := strconv.Atoi(strings.TrimSpace(fmt.Sprint(v)))
	return n
}
func int64Ptr(v any) *int64 {
	if v == nil {
		return nil
	}
	s := strings.TrimSpace(fmt.Sprint(v))
	if s == "" || s == "<nil>" {
		return nil
	}
	f, err := strconv.ParseFloat(s, 64)
	if err != nil {
		return nil
	}
	n := int64(f)
	return &n
}
func float64Ptr(v any) *float64 {
	if v == nil {
		return nil
	}
	s := strings.TrimSpace(fmt.Sprint(v))
	if s == "" || s == "<nil>" {
		return nil
	}
	f, err := strconv.ParseFloat(s, 64)
	if err != nil {
		return nil
	}
	return &f
}
func boolString(v any) bool {
	s := strings.TrimSpace(strings.ToLower(fmt.Sprint(v)))
	return s == "true" || s == "1" || s == "yes" || s == "si" || s == "sí"
}
