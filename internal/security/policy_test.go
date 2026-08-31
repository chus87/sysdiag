package security

import "testing"

func TestValidateKubeArgs(t *testing.T) {
	if ValidateKubeArgs([]string{"get", "pods", "-A"}) != nil {
		t.Fatal("get debe permitirse")
	}
	if ValidateKubeArgs([]string{"delete", "pod", "x"}) == nil {
		t.Fatal("delete debe bloquearse")
	}
}
func TestCredentialArgs(t *testing.T) {
	if !ContainsCredentialArg([]string{"login", "-u", "u", "-p", "secret"}) {
		t.Fatal("debe detectar password argv")
	}
	if ContainsCredentialArg([]string{"login", "-u", "u"}) {
		t.Fatal("falso positivo")
	}
}

func TestCollectorPolicyRejectsUnknownSwitch(t *testing.T) {
	if ValidateCollectorArgs([]string{"--delete-everything"}) == nil {
		t.Fatal("switch desconocido aceptado")
	}
}
func TestManualCommandClassification(t *testing.T) {
	if ClassifyManualCommand("kubectl get pods -A") != "read_only" {
		t.Fatal("get debía ser read_only")
	}
	if ClassifyManualCommand("systemctl restart kubelet") != "mutating" {
		t.Fatal("restart debía ser mutating")
	}
	if ClassifyManualCommand("mi-herramienta --check") != "unknown" {
		t.Fatal("comando desconocido debía requerir revisión")
	}
}
