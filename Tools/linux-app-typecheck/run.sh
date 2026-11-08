#!/usr/bin/env bash
# Type-checks the iOS app sources (App/Forma) on Linux against minimal stand-ins for SwiftUI, Charts,
# Core Bluetooth, AccessorySetupKit, LocalAuthentication, UIKit and a few Apple-only Foundation APIs,
# plus the REAL FormaKit modules. It catches Swift-level mistakes (wrong names, labels, optionality,
# closure types, actor isolation against FormaKit); it does NOT prove the code compiles against Apple's
# SDKs — the stand-ins encode only the subset of API shapes the app uses. Build in Xcode to be sure.
set -euo pipefail
cd "$(dirname "$0")"
APP=../../App/Forma
find Sources/AppCheck -name '*.swift' ! -name 'FoundationShims.swift' -delete
( cd "$APP" && find . -name '*.swift' ) | while read -r f; do
  mkdir -p "Sources/AppCheck/$(dirname "$f")"
  cp "$APP/$f" "Sources/AppCheck/$f"
done
# #Preview is a macro unavailable on Linux: drop the preview blocks, keep the helper types.
python3 - <<'PY'
p='Sources/AppCheck/Preview/Previews.swift'
lines=open(p).read().split('\n'); out=[]; skip=False; depth=0
for line in lines:
    if line.startswith('#Preview'): skip=True; depth=0
    if skip:
        depth += line.count('{') - line.count('}')
        if depth <= 0 and '}' in line: skip=False
        continue
    out.append(line)
open(p,'w').write('\n'.join(out))
PY
swift build 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -E "error:|warning:|Build complete" || true
