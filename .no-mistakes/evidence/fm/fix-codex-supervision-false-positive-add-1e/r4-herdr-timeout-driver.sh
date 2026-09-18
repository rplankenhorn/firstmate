#!/usr/bin/env bash
# R4 live driver: prove fm_backend_herdr_cli bounds a wedged herdr round trip.
set -u
ROOT="/Users/rplankenhorn/.no-mistakes/worktrees/61c331b0bdb7/01M2V0Y8VTSB8FMAXJZ6WSN152"
TMP=$(mktemp -d)
mkdir -p "$TMP/fakebin" "$TMP/home/state"
printf '#!/usr/bin/env bash\nsleep 60\n' > "$TMP/fakebin/herdr"
chmod +x "$TMP/fakebin/herdr"
export FM_HOME="$TMP/home"
export PATH="$TMP/fakebin:$PATH"
export FM_HERDR_CLI_TIMEOUT=2
set +u
. "$ROOT/bin/backends/herdr.sh" 2>/dev/null

echo "=== drive fm_backend_herdr_cli against a WEDGED herdr, bound=2s ==="
start=$(date +%s)
out=$(fm_backend_herdr_cli "sess-wedged" status 2>&1); rc=$?
end=$(date +%s)
echo "elapsed=$((end-start))s  rc=$rc  (expect rc=124, elapsed~2s)"
echo "--- combined output ---"
printf '%s\n' "$out"

echo
echo "=== bound computation (malformed/non-positive falls back to 30) ==="
FM_HERDR_CLI_TIMEOUT=abc; echo "abc -> $(fm_backend_herdr_cli_timeout)"
FM_HERDR_CLI_TIMEOUT=0;   echo "0   -> $(fm_backend_herdr_cli_timeout)"
FM_HERDR_CLI_TIMEOUT=-5;  echo "-5  -> $(fm_backend_herdr_cli_timeout)"
FM_HERDR_CLI_TIMEOUT=7;   echo "7   -> $(fm_backend_herdr_cli_timeout)"
unset FM_HERDR_CLI_TIMEOUT; echo "unset -> $(fm_backend_herdr_cli_timeout)"

rm -f "$TMP/fakebin/herdr"
rmdir "$TMP/fakebin" "$TMP/home/state" "$TMP/home" "$TMP" 2>/dev/null || true
