package model

import "time"

const (
	TemporalCurrent    = "current"
	TemporalHistorical = "historical"
	TemporalUnknown    = "unknown"
)

type Finding struct {
	ID       string `json:"id"`
	Category string `json:"category"`
	Domain   string `json:"domain"`
	Points   int    `json:"points"`
	Impact   string `json:"impact"`
	Message  string `json:"message"`
	Layer    string `json:"layer,omitempty"`
	Scope    string `json:"scope,omitempty"`
	Resource string `json:"resource,omitempty"`
}

type Evidence struct {
	ID            string         `json:"id"`
	Layer         string         `json:"layer"`
	Scope         string         `json:"scope,omitempty"`
	Resource      string         `json:"resource,omitempty"`
	Kind          string         `json:"kind"`
	Current       *bool          `json:"current,omitempty"`
	TemporalState string         `json:"temporal_state,omitempty"`
	ObservedAt    string         `json:"observed_at,omitempty"`
	FirstSeen     string         `json:"first_seen,omitempty"`
	LastSeen      string         `json:"last_seen,omitempty"`
	AgeSeconds    *int64         `json:"age_seconds,omitempty"`
	Message       string         `json:"message"`
	Attributes    map[string]any `json:"attributes,omitempty"`
}

type Conclusion struct {
	ID             string   `json:"id"`
	Title          string   `json:"title"`
	Confidence     string   `json:"confidence"`
	RootCause      bool     `json:"root_cause_candidate"`
	EvidenceIDs    []string `json:"evidence_ids"`
	Interpretation string   `json:"interpretation"`
	ManualChecks   []string `json:"manual_checks,omitempty"`
}

type ManualAction struct {
	Command           string `json:"command"`
	Safety            string `json:"safety"` // read_only, mutating, unknown
	RequiresPrivilege bool   `json:"requires_privilege,omitempty"`
}

type NextStep struct {
	Description string         `json:"description"`
	Commands    []string       `json:"commands,omitempty"` // compatibilidad schema 1.0
	Actions     []ManualAction `json:"actions,omitempty"`
}

type Summary struct {
	Category   string `json:"category"`
	Title      string `json:"title"`
	Status     string `json:"status"`
	Score      int    `json:"score"`
	Signals    int    `json:"signals"`
	Confidence string `json:"confidence"`
	Impact     string `json:"impact"`
}

type Coverage struct {
	Category string `json:"category"`
	Observed bool   `json:"observed"`
	Limited  bool   `json:"limited,omitempty"`
}

type CollectorRun struct {
	Name        string `json:"name"`
	Status      string `json:"status"` // ok, limited, failed
	StartedAt   string `json:"started_at"`
	CompletedAt string `json:"completed_at"`
	DurationMS  int64  `json:"duration_ms"`
	Error       string `json:"error,omitempty"`
}

type BuildInfo struct {
	Author          string `json:"author,omitempty"`
	License         string `json:"license,omitempty"`
	GoVersion       string `json:"go_version,omitempty"`
	Commit          string `json:"commit,omitempty"`
	Tag             string `json:"tag,omitempty"`
	BuildDate       string `json:"build_date,omitempty"`
	Target          string `json:"target,omitempty"`
	CollectorSHA256 string `json:"collector_sha256,omitempty"`
	SchemaVersion   string `json:"schema_version,omitempty"`
}

type Report struct {
	SchemaVersion  string         `json:"schema_version"`
	SysdiagVersion string         `json:"sysdiag_version"`
	Engine         string         `json:"engine,omitempty"`
	GeneratedAt    string         `json:"generated_at"`
	StartedAt      string         `json:"started_at,omitempty"`
	CompletedAt    string         `json:"completed_at,omitempty"`
	DurationMS     int64          `json:"duration_ms,omitempty"`
	ReadOnly       bool           `json:"read_only"`
	Scope          []string       `json:"scope"`
	Host           string         `json:"host"`
	Summary        []Summary      `json:"summary"`
	Coverage       []Coverage     `json:"coverage,omitempty"`
	Findings       []Finding      `json:"findings"`
	Evidence       []Evidence     `json:"evidence,omitempty"`
	Conclusions    []Conclusion   `json:"conclusions,omitempty"`
	Limitations    []string       `json:"limitations"`
	NextSteps      []NextStep     `json:"next_steps"`
	Collectors     []CollectorRun `json:"collectors,omitempty"`
	Build          BuildInfo      `json:"build,omitempty"`
	Metrics        map[string]any `json:"metrics"`
	Typed          *TypedMetrics  `json:"-"`
}

func NewReport() Report {
	return Report{ReadOnly: true, GeneratedAt: time.Now().UTC().Format(time.RFC3339), Metrics: map[string]any{}}
}

func Bool(v bool) *bool { return &v }
