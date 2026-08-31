package assets

import (
	"crypto/sha256"
	"embed"
	"encoding/hex"
)

var _ embed.FS

// LegacyStandalone is the audited read-only collector backend embedded into
// the Go binary. Production execution never auto-discovers an external copy.
//
//go:embed sysdiag-standalone.sh
var LegacyStandalone []byte

func CollectorSHA256() string {
	s := sha256.Sum256(LegacyStandalone)
	return hex.EncodeToString(s[:])
}
