package version

import (
	"runtime"

	"github.com/chus87/sysdiag/internal/assets"
	"github.com/chus87/sysdiag/internal/model"
)

const Version = "0.14.2"
const SchemaVersion = "1.1"
const Engine = "go-core"
const Author = "Chus (GitHub: chus87)"
const License = "Apache-2.0"

// Release metadata is injected with -ldflags. Defaults make local/source builds
// explicit instead of pretending provenance that cannot be proven.
var Commit = "unknown"
var Tag = "untagged"
var BuildDate = "unknown"

func BuildInfo() model.BuildInfo {
	return model.BuildInfo{
		Author:          Author,
		License:         License,
		GoVersion:       runtime.Version(),
		Commit:          Commit,
		Tag:             Tag,
		BuildDate:       BuildDate,
		Target:          runtime.GOOS + "/" + runtime.GOARCH,
		CollectorSHA256: assets.CollectorSHA256(),
		SchemaVersion:   SchemaVersion,
	}
}
