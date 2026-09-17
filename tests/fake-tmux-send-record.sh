# shellcheck shell=bash
# tests/fake-tmux-send-record.sh - ONE OWNER of how a fake tmux records a
# `send-keys` invocation into FM_FAKE_LAUNCH_LOG.
#
# Sourced from inside a fake tmux stub, not from a test file:
#   . "$FM_FAKE_SEND_RECORD_LIB"
#   fm_fake_record_send "$@"
# with "$@" the stub's full argument list, including the leading `send-keys`.
#
# WHY THIS EXISTS. A real pane CONCATENATES literal writes and ends the line
# only when Enter is submitted. Every fake here used to append each
# `send-keys -l <payload>` on its own line, which was indistinguishable from the
# real thing while the launcher wrote a launch command in one call. It stopped
# being true the moment bin/fm-launch-send-lib.sh started writing that command
# in queue-safe chunks: one launch became several recorded lines, split at
# arbitrary byte offsets, and suites asserting on the launch command saw a path
# or a flag cut in half. The fake was wrong, not the launcher, so the recording
# rule is stated once here and shared.
#
# Recording rules:
#  - a `-l` payload is appended RAW, with no newline, exactly as a pane receives
#    it, so any number of chunked writes rejoin into one line;
#  - an invocation carrying Enter (or C-m) ends that line, and only when a
#    literal write is actually pending, so repeated launches into one log stay
#    one line each and no blank line is introduced;
#  - a text-line payload (`send-keys -t <target> <text> Enter`) is recorded as
#    its own complete line only when FM_FAKE_LAUNCH_LOG_TEXT_LINES=1, because
#    most suites assert on the launch command alone and the launcher sends its
#    readiness probe and env exports through that same form.
#
# CLASSIFYING A LAUNCH BY ITS CONTENT. Several fakes do not merely record the
# literal, they branch on it - this one is the launch, that one is a pointer,
# this one starts the harness named in a file. Those fakes must classify the
# COMPLETE line, never a chunk: a launch written in pieces puts the substring
# they match in one chunk and not the others, so a per-chunk classifier fires
# on the wrong piece or not at all. A fake opts into reassembly by setting
# FM_FAKE_SEND_BUFFER to a writable path and FM_FAKE_SEND_ON_LINE to the name
# of a function taking the complete line. The literals accumulate in the buffer
# and the function is called once, when Enter submits the line.
#
# A fake that sets FM_FAKE_SEND_ON_LINE owns its own launch log through that
# classifier, so the raw literals are NOT also appended here: the classifier
# decides which log a complete line belongs in, and appending the chunks too
# would interleave partial writes with the line the fake wrote itself.
#
# FM_FAKE_LAUNCH_LOG unset means record nothing, which keeps a fake usable by
# suites that never inspect the launch; the probe answer and the content
# classification below still run, because a fake that does not record a launch
# can still have to accept one.
#
# ANSWERING THE READINESS PROBE. bin/fm-launch-send-lib.sh refuses to type a
# launch command into a pane that renders text but never EXECUTES the probe it
# was sent, because that is exactly the wedged shell the refusal exists for. A
# fake whose capture-pane prints a frame, a prompt, or a composer box therefore
# earns that refusal unless it also runs the probe, and a fake that prints
# nothing at all instead makes the launcher spend its blank bound learning that
# there is no shell to judge. Either way the fake is the thing that is wrong: a
# pane willing to accept a launch is a pane whose shell is reading.
#
# fm_fake_record_send answers the probe on the fake's behalf: when a text line
# is the probe, it appends the marker the probe would have printed to the
# fake's echo file. The marker is reconstructed from the two pieces the probe
# carries rather than matched as one string, so the echo can never satisfy the
# launcher's check without the fake having actually seen the probe line.
#
# A stub completes the round trip by printing that file from its own
# capture-pane, which is the whole of the wiring:
#
#   capture-pane) ... ; fm_fake_print_pane_echo; exit 0 ;;
#
# The file defaults to one beside the stub itself, so a fake needs no env var
# and every invocation of that one stub shares one file. FM_FAKE_PANE_ECHO
# overrides the path for a fake that wants it somewhere its own test can read.

# fm_fake_answer_ready_probe <text line>: if the line is the launch-readiness
# probe, append the marker its printf would have produced to this stub's echo
# file. A stub that never prints that file from capture-pane is unaffected.
fm_fake_answer_ready_probe() {
  local line=$1 tail
  case "$line" in
  "printf '%s%s\\n' 'FM_LAUNCH_' '"*"'") ;;
  *) return 0 ;;
  esac
  tail=${line##*\'FM_LAUNCH_\' \'}
  tail=${tail%\'}
  printf 'FM_LAUNCH_%s\n' "$tail" >>"$(fm_fake_pane_echo_path)"
}

# fm_fake_pane_echo_path: the file this stub answers probes into.
fm_fake_pane_echo_path() {
  printf '%s' "${FM_FAKE_PANE_ECHO:-$0.pane-echo}"
}

# fm_fake_print_pane_echo: print the probe answers this stub has accepted, for
# its capture-pane to render. Nothing yet answered prints nothing, which is the
# same blank frame the fake showed before it was wired.
fm_fake_print_pane_echo() {
  local echo_file
  echo_file=$(fm_fake_pane_echo_path)
  [ ! -s "$echo_file" ] || cat "$echo_file"
}

# fm_fake_record_send <send-keys argument list...>
fm_fake_record_send() {
  local log=${FM_FAKE_LAUNCH_LOG:-}
  local pending="$log.literal-pending"
  local a literal=0 enter=0 skip=0
  shift # the `send-keys` word itself
  for a in "$@"; do
    if [ "$skip" = 1 ]; then
      skip=0
      continue
    fi
    case "$a" in
    -t)
      skip=1
      continue
      ;;
    -l)
      literal=1
      continue
      ;;
    Enter | C-m)
      enter=1
      continue
      ;;
    esac
    if [ "$literal" = 1 ]; then
      literal=0
      fm_fake_buffer_literal "$a"
      if [ -n "$log" ] && [ -z "${FM_FAKE_SEND_ON_LINE:-}" ]; then
        printf '%s' "$a" >>"$log"
        : >"$pending"
      fi
      continue
    fi
    fm_fake_answer_ready_probe "$a"
    if [ -n "$log" ] && [ "${FM_FAKE_LAUNCH_LOG_TEXT_LINES:-0}" = 1 ]; then
      printf '%s\n' "$a" >>"$log"
    fi
  done
  if [ "$enter" = 1 ] && [ -n "$log" ] && [ -e "$pending" ]; then
    printf '\n' >>"$log"
    rm -f "$pending"
  fi
  [ "$enter" = 1 ] && fm_fake_flush_line
  return 0
}

# fm_fake_buffer_literal <payload>: accumulate one literal write for a fake
# that classifies the complete line. No FM_FAKE_SEND_BUFFER means the fake does
# not classify and nothing is buffered.
fm_fake_buffer_literal() {
  [ -n "${FM_FAKE_SEND_BUFFER:-}" ] || return 0
  printf '%s' "$1" >>"$FM_FAKE_SEND_BUFFER"
}

# fm_fake_flush_line: hand the reassembled line to the fake's classifier and
# clear the buffer. Called on Enter, and a no-op when nothing accumulated, so a
# bare Enter never invents an empty line.
fm_fake_flush_line() {
  [ -n "${FM_FAKE_SEND_BUFFER:-}" ] || return 0
  [ -s "$FM_FAKE_SEND_BUFFER" ] || return 0
  local line
  line=$(cat "$FM_FAKE_SEND_BUFFER")
  : >"$FM_FAKE_SEND_BUFFER"
  [ -n "${FM_FAKE_SEND_ON_LINE:-}" ] || return 0
  "$FM_FAKE_SEND_ON_LINE" "$line"
}
