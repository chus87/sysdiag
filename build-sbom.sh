#!/usr/bin/env bash
set -euo pipefail
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$BASE_DIR"
version="$(sed -n 's/^SYS_DIAG_VERSION="\([^"]*\)"/\1/p' lib/version.sh | head -n1)"
out="${1:-SBOM.spdx.json}"
for f in sysdiag-standalone.sh bin/sysdiag-linux-amd64 bin/sysdiag-linux-arm64; do [[ -f "$f" ]] || { printf 'Falta %s\n' "$f" >&2; exit 1; }; done
sha_standalone="$(sha256sum sysdiag-standalone.sh | awk '{print $1}')"
sha_amd64="$(sha256sum bin/sysdiag-linux-amd64 | awk '{print $1}')"
sha_arm64="$(sha256sum bin/sysdiag-linux-arm64 | awk '{print $1}')"
created="$(python3 - <<'PY'
import datetime,os
v=int(os.environ.get('SOURCE_DATE_EPOCH','0') or 0)
print(datetime.datetime.fromtimestamp(v,datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))
PY
)"
cat >"$out" <<JSON
{
  "spdxVersion": "SPDX-2.3",
  "dataLicense": "CC0-1.0",
  "SPDXID": "SPDXRef-DOCUMENT",
  "name": "SYSdiag-${version}",
  "documentNamespace": "https://github.com/chus87/sysdiag/spdx/sysdiag-${version}",
  "creationInfo": {"created": "${created}", "creators": ["Person: Chus (GitHub: chus87)", "Tool: SYSdiag build-sbom.sh"]},
  "packages": [{
    "name": "SYSdiag", "SPDXID": "SPDXRef-Package-SYSdiag", "versionInfo": "${version}",
    "downloadLocation": "NOASSERTION", "filesAnalyzed": true,
    "licenseConcluded": "Apache-2.0", "licenseDeclared": "Apache-2.0",
    "copyrightText": "Copyright 2026 Chus (GitHub: chus87)"
  }],
  "files": [
    {"fileName":"sysdiag-standalone.sh","SPDXID":"SPDXRef-File-Standalone","checksums":[{"algorithm":"SHA256","checksumValue":"${sha_standalone}"}],"licenseConcluded":"Apache-2.0","copyrightText":"Copyright 2026 Chus (GitHub: chus87)"},
    {"fileName":"bin/sysdiag-linux-amd64","SPDXID":"SPDXRef-File-AMD64","checksums":[{"algorithm":"SHA256","checksumValue":"${sha_amd64}"}],"licenseConcluded":"Apache-2.0","copyrightText":"Copyright 2026 Chus (GitHub: chus87)"},
    {"fileName":"bin/sysdiag-linux-arm64","SPDXID":"SPDXRef-File-ARM64","checksums":[{"algorithm":"SHA256","checksumValue":"${sha_arm64}"}],"licenseConcluded":"Apache-2.0","copyrightText":"Copyright 2026 Chus (GitHub: chus87)"}
  ],
  "relationships": [
    {"spdxElementId":"SPDXRef-Package-SYSdiag","relationshipType":"CONTAINS","relatedSpdxElement":"SPDXRef-File-Standalone"},
    {"spdxElementId":"SPDXRef-Package-SYSdiag","relationshipType":"CONTAINS","relatedSpdxElement":"SPDXRef-File-AMD64"},
    {"spdxElementId":"SPDXRef-Package-SYSdiag","relationshipType":"CONTAINS","relatedSpdxElement":"SPDXRef-File-ARM64"}
  ]
}
JSON
printf 'Generado %s\n' "$out"
