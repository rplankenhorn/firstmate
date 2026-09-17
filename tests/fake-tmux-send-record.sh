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
# FM_FAKE_LAUNCH_LOG unset means record nothing, which keeps a fake usable by
# suites that never inspect the launch.

# fm_fake_record_send <send-keys argument list...>
fm_fake_record_send() {
  [ -n "${FM_FAKE_LAUNCH_LOG:-}" ] || return 0
  local pending="$FM_FAKE_LAUNCH_LOG.literal-pending"
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
      printf '%s' "$a" >>"$FM_FAKE_LAUNCH_LOG"
      : >"$pending"
      literal=0
    elif [ "${FM_FAKE_LAUNCH_LOG_TEXT_LINES:-0}" = 1 ]; then
      printf '%s\n' "$a" >>"$FM_FAKE_LAUNCH_LOG"
    fi
  done
  if [ "$enter" = 1 ] && [ -e "$pending" ]; then
    printf '\n' >>"$FM_FAKE_LAUNCH_LOG"
    rm -f "$pending"
  fi
}
