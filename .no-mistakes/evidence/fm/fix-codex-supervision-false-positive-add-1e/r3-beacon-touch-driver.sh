#!/usr/bin/env bash
# R3 live driver: prove bin/fm-watch.sh touches .last-watcher-beat TWICE per
# supervision cycle (top of cycle + immediately before the terminal wait). A
# fake `touch` on PATH timestamps every beacon touch; two touches in one cycle,
# sub-second apart, can only happen if the pre-wait touch (the fix) runs.
set -u
ROOT="/Users/rplankenhorn/.no-mistakes/worktrees/61c331b0bdb7/01M2V0Y8VTSB8FMAXJZ6WSN152"
cd "$ROOT"
# shellcheck source=/dev/null
. "$ROOT/tests/wake-helpers.sh"
TMP_ROOT=$(fm_test_tmproot r3-beacon)
WATCH="$ROOT/bin/fm-watch.sh"

dir=$(make_case r3cycle); state="$dir/state"; fakebin="$dir/fakebin"
touchbin="$dir/touchbin"; mkdir -p "$touchbin"
LOG="$dir/beacon-touch.log"; : > "$LOG"
cat > "$touchbin/touch" <<SH
#!/usr/bin/env bash
for a in "\$@"; do
  case "\$a" in
    *.last-watcher-beat)
      printf '%s beat-touch %s\n' "\$(perl -MTime::HiRes -e 'printf "%.3f", Time::HiRes::time()')" "\$*" >> "$LOG"
      ;;
  esac
done
exec /usr/bin/touch "\$@"
SH
chmod +x "$touchbin/touch"

echo "=== running real fm-watch.sh for ~22s (FM_POLL=5) ==="
PATH="$touchbin:$fakebin:$PATH" FM_STATE_OVERRIDE="$state" \
  FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
  FM_POLL=5 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
  bash "$WATCH" >"$dir/watch.out" 2>"$dir/watch.err" &
wpid=$!
sleep 22
if kill -0 "$wpid" 2>/dev/null; then echo "watcher still alive after 2.5s (good)"; else echo "watcher EXITED early"; fi
kill "$wpid" 2>/dev/null
wait "$wpid" 2>/dev/null

echo "--- watch.err ---"; cat "$dir/watch.err"
echo "--- watch.out (head) ---"; head -5 "$dir/watch.out"
echo "--- perl check ---"; perl -MTime::HiRes -e 'printf "%.3f\n", Time::HiRes::time()'
echo "=== beacon touches (epoch  event  argv) ==="
cat "$LOG"
echo
echo "=== gap analysis (FM_POLL=5) ==="
echo "  short gap (<1.5s) = top + pre-wait touch in the SAME cycle (the R3 fix)"
echo "  long gap  (~5s)   = the terminal poll wait between cycles"
echo "  one-touch-per-cycle would show ONLY ~5s gaps, never a short gap."
perl -e '
  my @t; while(<STDIN>){ push @t, $1 if /^(\d+\.\d+)/ }
  my $short=0; my $long=0; my $total=scalar @t;
  for my $i (1..$#t){ my $d=$t[$i]-$t[$i-1];
    my $tag = $d<1.5 ? "  <-- within-cycle pair (pre-wait touch fired)" : ($d>=4 ? "  <-- poll wait" : "");
    printf "  gap %.3fs%s\n",$d,$tag;
    $short++ if $d<1.5; $long++ if $d>=4; }
  print "total beacon touches: $total\n";
  print "within-cycle pairs: $short   poll-wait gaps: $long\n";
  print $short>=1 ? "RESULT: PASS - second (pre-wait) touch observed at runtime\n"
                  : "RESULT: FAIL - only one touch per cycle\n";
' < "$LOG"
