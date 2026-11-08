#!/usr/bin/env bash
# Static audit: Forma's app and FormaKit sources must contain no networking, web, telemetry, cloud
# storage (iCloud/CloudKit), Apple Health, diagnostics-delivery or remote-AI code, no entitlements for
# those, and FormaKit must have no remote package dependencies.
# Exit 0 = clean, 1 = findings. Run from the repository root: Tools/audit-no-network.sh
set -euo pipefail
cd "$(dirname "$0")/.."

SOURCES=(App FormaKit/Sources)
fail=0

check() {
  local label="$1" pattern="$2"
  local hits
  hits=$(grep -RInE --include='*.swift' --include='*.plist' --include='*.xcprivacy' "$pattern" "${SOURCES[@]}" 2>/dev/null \
         | grep -vE '^\S+:[0-9]+:\s*(//|///|\*)' \
         | grep -vE '^\S+:[0-9]+:<!DOCTYPE plist' || true)   # plist DTD identifiers are never fetched
  if [[ -n "$hits" ]]; then
    echo "✘ $label"
    echo "$hits" | sed 's/^/    /'
    fail=1
  else
    echo "✔ no $label"
  fi
}

check "URLSession / URLRequest usage"            '\bURLSession\b|\bURLRequest\b|\bURLSessionConfiguration\b'
check "Network.framework usage"                  '^\s*import\s+Network\b|\bNWConnection\b|\bNWPathMonitor\b|\bNWListener\b'
check "CFNetwork / sockets"                      '\bCFNetwork\b|\bCFStream|\bCFSocket|\bgetaddrinfo\b|\bsocket\s*\('
check "web views / Safari"                       '\bWKWebView\b|\bSFSafariViewController\b|\bASWebAuthenticationSession\b|^\s*import\s+WebKit\b'
check "http(s) URLs in code"                     '"https?://'
check "openURL to external sites"                '\.openURL\b|UIApplication\.shared\.open\('
check "analytics / telemetry SDK imports"        '^\s*import\s+(Firebase|FirebaseAnalytics|Mixpanel|Amplitude|Segment|Sentry|Crashlytics|AppCenter|Datadog|Bugsnag|OneSignal)\b'
check "remote AI client code"                    '\b(OpenAI|Anthropic|Gemini|Claude)\b.*(Client|API|Request)'
check "background URL transfers"                 '\bbackgroundSession\b|\bURLSessionDownloadTask\b'
check "iCloud / CloudKit storage"                '^\s*import\s+CloudKit\b|\bCKContainer\b|\bCKDatabase\b|\bNSUbiquitousKeyValueStore\b|\bubiquityIdentityToken\b|forUbiquityContainerIdentifier'
check "HealthKit (Apple Health is deferred)"     '^\s*import\s+HealthKit\b|\bHKHealthStore\b'
check "MetricKit diagnostics delivery"           '^\s*import\s+MetricKit\b|\bMXMetricManager\b'
check "links to external sites (SwiftUI Link)"   '\bLink\s*\('
check "URLs built from strings"                  '\bURL\s*\(\s*string\s*:'

# Package manifests: no remote dependencies.
if grep -nE '\.package\(\s*url:' FormaKit/Package.swift >/dev/null 2>&1; then
  echo "✘ FormaKit/Package.swift declares remote package dependencies:"
  grep -nE '\.package\(\s*url:' FormaKit/Package.swift | sed 's/^/    /'
  fail=1
else
  echo "✔ FormaKit has no remote package dependencies"
fi
if grep -nE 'XCRemoteSwiftPackageReference' Forma.xcodeproj/project.pbxproj >/dev/null 2>&1; then
  echo "✘ Xcode project references remote Swift packages"
  fail=1
else
  echo "✔ Xcode project has no remote Swift package references"
fi

# Entitlements must not grant iCloud, HealthKit or network capabilities.
entitlements=$(find . -name '*.entitlements' -not -path '*/.build/*' 2>/dev/null || true)
if [[ -n "$entitlements" ]] && grep -nE 'com\.apple\.developer\.(icloud|ubiquity|healthkit|networking)|com\.apple\.security\.network' $entitlements >/dev/null 2>&1; then
  echo "✘ entitlements grant iCloud, HealthKit or network capabilities:"
  grep -nE 'com\.apple\.developer\.(icloud|ubiquity|healthkit|networking)|com\.apple\.security\.network' $entitlements | sed 's/^/    /'
  fail=1
else
  echo "✔ no entitlements grant iCloud, HealthKit or network capabilities"
fi

# Info.plist must not relax App Transport Security or declare network-related usage.
if grep -nE 'NSAppTransportSecurity|NSLocalNetworkUsageDescription|NSBonjourServices' App/Forma/Resources/Info.plist >/dev/null 2>&1; then
  echo "✘ Info.plist declares network-related keys"
  fail=1
else
  echo "✔ Info.plist declares no network-related keys"
fi

exit $fail
