package security

import (
	"fmt"
	"path/filepath"
	"strings"
)

var forbiddenKube = map[string]bool{
	"apply": true, "create": true, "delete": true, "patch": true, "edit": true, "replace": true,
	"exec": true, "debug": true, "port-forward": true, "cp": true, "drain": true, "cordon": true, "uncordon": true,
	"scale": true, "autoscale": true, "rollout": true, "set": true, "taint": true, "label": true, "annotate": true,
}

// ValidateKubeArgs is the read-only policy for future direct Kubernetes/OpenShift
// execution from the Go core. It intentionally rejects entire mutating command
// families rather than trying to whitelist individual dangerous variants.
func ValidateKubeArgs(args []string) error {
	for i, a := range args {
		v := strings.ToLower(strings.TrimSpace(a))
		if forbiddenKube[v] {
			return fmt.Errorf("operación Kubernetes no permitida por política read-only: %s", a)
		}
		if v == "adm" && i+1 < len(args) {
			next := strings.ToLower(strings.TrimSpace(args[i+1]))
			switch next {
			case "drain", "cordon", "prune", "upgrade", "must-gather":
				return fmt.Errorf("operación OpenShift no permitida por política read-only: adm %s", next)
			}
		}
	}
	return nil
}

// ValidateCollectorArgs protects the only external execution path used by the
// Go core today: the embedded Bash collector. Only documented read-only
// diagnostic switches are accepted. Internal switches are allowed because
// they are generated exclusively by the Go orchestrator.
func ValidateCollectorArgs(args []string) error {
	valueFlags := map[string]bool{
		"--section": true, "--container-mode": true, "--k8s-mode": true,
		"--k8s-node": true, "--k8s-namespace": true, "--k8s-pod": true,
		"--k8s-context": true, "--k8s-kubeconfig": true, "--sample": true,
		"--internal-sections": true, "--machine-report": true,
	}
	boolFlags := map[string]bool{
		"--verbose": true, "--explain": true, "--no-color": true, "--summary": true,
		"--containers-deep": true, "--k8s-no-auth-prompt": true, "--recent-errors": true,
		"--all": true, "--json": true, "--host-only": true, "--guide": true,
	}
	for i := 0; i < len(args); i++ {
		a := args[i]
		if boolFlags[a] {
			continue
		}
		if valueFlags[a] {
			if i+1 >= len(args) {
				return fmt.Errorf("falta valor para %s", a)
			}
			i++
			continue
		}
		return fmt.Errorf("argumento del collector no permitido por política read-only: %s", a)
	}
	return nil
}

func ValidateCollectorExecution(path string, args []string) error {
	if filepath.Clean(path) != "/bin/bash" {
		return fmt.Errorf("intérprete del collector no permitido: %s", path)
	}
	if len(args) == 0 || !strings.Contains(filepath.Base(args[0]), "sysdiag-collector-") {
		return fmt.Errorf("ruta temporal de collector no válida")
	}
	return ValidateCollectorArgs(args[1:])
}

func ContainsCredentialArg(args []string) bool {
	for i, a := range args {
		v := strings.ToLower(a)
		if strings.HasPrefix(v, "--password=") || strings.HasPrefix(v, "--token=") || v == "-p" || v == "--password" || v == "--token" {
			if i+1 < len(args) || strings.Contains(a, "=") {
				return true
			}
		}
	}
	return false
}

// ClassifyManualCommand is conservative: known read-only inspection commands
// are labelled read_only; known mutating verbs are mutating; everything else
// remains unknown and therefore requires administrator review.
func ClassifyManualCommand(command string) string {
	c := strings.ToLower(strings.TrimSpace(command))
	if c == "" {
		return "unknown"
	}
	mutating := []string{
		" systemctl restart ", " systemctl stop ", " systemctl start ", " systemctl reload ",
		" kubectl apply ", " kubectl delete ", " kubectl patch ", " kubectl edit ", " kubectl exec ",
		" oc apply ", " oc delete ", " oc patch ", " oc edit ", " oc debug ",
		" docker rm ", " docker restart ", " docker stop ", " podman rm ", " podman restart ",
		" rm ", " mv ", " chmod ", " chown ", " mount ", " umount ", " sysctl -w ", " iptables -", " nft add ",
	}
	padded := " " + c + " "
	for _, x := range mutating {
		if strings.Contains(padded, x) {
			return "mutating"
		}
	}
	readOnlyPrefixes := []string{
		"kubectl get ", "kubectl describe ", "kubectl logs ", "kubectl top ", "oc get ", "oc describe ", "oc logs ", "oc adm node-logs ",
		"systemctl status ", "systemctl is-active ", "journalctl ", "cat ", "grep ", "ss ", "ip ", "lsblk", "findmnt", "df ", "free ", "vmstat", "iostat", "docker inspect ", "docker logs ", "docker stats ", "podman inspect ", "podman logs ", "podman stats ", "crictl info", "crictl ps",
	}
	for _, p := range readOnlyPrefixes {
		if strings.HasPrefix(c, p) {
			return "read_only"
		}
	}
	return "unknown"
}
