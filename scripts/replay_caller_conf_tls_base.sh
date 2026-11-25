#!/usr/bin/env bash
set -euo pipefail

# Invoked by the Runtime gate's Linux test. The archive leaves its checkout alone.
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
base=00f68a8bb385dce6b810c56c6a70d092110b00b3
scratch=$(mktemp -d "${TMPDIR:-/tmp}/runtime-caller-a1-base.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT

git -C "$repo" show -s --format='Base %H, tree %T' "$base"
git -C "$repo" archive "$base" | tar -x -C "$scratch"
python3 - "$repo" "$scratch" <<'PY'
from pathlib import Path
import sys

candidate, base = (Path(path) / 'caller_cli/connect' for path in sys.argv[1:])

def replace_once(text, old, new):
    assert text.count(old) == 1, old
    return text.replace(old, new, 1)

def instrument(name, replacements):
    path = base / name
    text = path.read_text()
    for old, new in replacements:
        text = replace_once(text, old, new)
    path.write_text(text)

instrument('connect.odin', [
    ('RunControl :: struct {',
     'RunControl :: struct {\n\tenrollment_log_sink: log.LogSink,'),
])
instrument('enrollment_runtime.odin', [
    ('log.logger_init(&e.logger, .Info)',
     'log.logger_init(&e.logger, .Info)\n\tif ctl != nil && ctl.enrollment_log_sink != nil {e.logger.sink = ctl.enrollment_log_sink}'),
    ('\tr := EnrollmentReaper',
     '\tif ctl != nil {ctl.bound, _ = trans.listener_endpoint(e.links[0].ln); sync.atomic_store(&ctl.ready, true)}\n\tr := EnrollmentReaper'),
])

path = 'enrollment_network_test.odin'
text = (candidate / path).read_text()
imports = text[:text.index('// Allow a synchronous HTTPS timeout')]
for unused in ('import cl "../../caller"\n', 'import log "../../logging"\n'):
    imports = replace_once(imports, unused, '')
api = text[text.index('EnrollmentTestApi :: struct'):text.index('enrollment_test_api_hostname_mismatch ::')]
replay = text[text.index('EnrollmentFailureCase :: enum'):]
extra_cases = replay.index('@(test)\ntest_enrollment_caller_conf_unauthorized_api')
replay = replay[:extra_cases] + replay[replay.index('enrollment_failure_network_case ::'):]
replay = replace_once(replay, 'api_tls_ca = %s\n', '')
replay = replace_once(replay, 'ep.port, fx.broker, ca, ca)', 'ep.port, fx.broker, ca)')
test = api + replay
for name in ('EnrollmentTestApi', 'enrollment_test_api_connection', 'enrollment_test_api_serve'):
    test = test.replace(name, name + '_Replay')
(base / 'enrollment_tls_replay_test.odin').write_text(
    imports + 'ENROLLMENT_TEST_FAILURE_BOUND :: 2*time.Second\n\n' + test)
PY

cd "$scratch"
test_name=test_enrollment_caller_conf_untrusted_api_closes_local
log=$scratch/replay.log
rc=0
timeout --kill-after=5s 90s odin test caller_cli/connect -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true \
  -out:"$scratch/replay.test" -- "-tests:$test_name" > "$log" 2>&1 || rc=$?
sed 's/^/A1 base | /' "$log"

# A compile failure, fixture failure, timeout or allocator warning is not proof.
[[ $rc == 1 ]]
grep -Fxq 'A1: API rejected the untrusted TLS handshake' "$log"
grep -Eq '^Finished 1 test in .*\. The test failed\.$' "$log"
grep -Eq "^ - connect\.$test_name[[:space:]]" "$log"
if grep -Fq '+++ leak' "$log"; then exit 1; fi
awk '
    /^\[ERROR[[:space:]]*\]/ {
        if (/A1: missing TLS verification diagnostic$/) missing = 1
        else if (/local socket was held open until receive timeout$/) held = 1
        else unexpected = 1
    }
    END {
        if (unexpected || !(missing || held)) exit 1
        if (missing) print "A1 base assertion failed: missing TLS verification diagnostic"
        if (held) print "A1 base assertion failed: local socket was held open until receive timeout"
    }
' "$log"
