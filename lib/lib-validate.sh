#!/usr/bin/env bash
# Staged validation for the labs that run on the lab VM (chapter 1 onwards).
# Source this file after lib.sh. Do not run it on its own.
# shellcheck disable=SC2034  # Variables defined here are used by the validators that source this file.
#
# A validator defines:
#   CHAPTER         the chapter number, for example "01", as in: course check 01
#   STAGE_TITLES    one title per stage, in the order of the lab tasks
#   stage_N         the checks of stage N (N starts at 1). It prints only through
#                   check_pass, check_fail, check_warn, check_skip and check_note.
#   stage_N_task    prints what the learner does in stage N (guided mode)
#   stage_N_enter   optional: runs once in guided mode, just before stage N is first checked.
#                   A stage can use it to note the state it starts from.
#   DEEP_NOTICE     one sentence that says what the live tests of this chapter do
#   preflight       optional: runs first and stops the script when the lab cannot be checked at all
# and ends with: run_validation "$@"
#
# Every stage must hold for the finished lab, so that the full report passes at the end,
# and must not fail because of a later task.

VALIDATE_MODE="report"
VALIDATE_DEEP=0
VALIDATE_STAGE=""
STAGE_FAIL_BASE=0
STAGE_PASS=0
STAGE_FAIL=0
STAGE_WARN=0
STAGE_SKIP=0

validation_usage() {
  cat <<EOF
Usage: course check ${CHAPTER} [--guided] [--stage N] [--deep]

  (no option)  Full report: PASS, FAIL or WARN for every check of the lab. Read-only.
  --guided     One stage at a time, in the order of the lab tasks: shows the task,
               checks it, gives hints and lets you try again. Read-only.
  --stage N    Report for stage N only (1 to ${#STAGE_TITLES[@]}).
  --deep       Adds the live tests: ${DEEP_NOTICE}
  -h, --help   Shows this text.

Exit code 0 when no check fails, 1 otherwise.
EOF
}

parse_validation_args() {
  while (($# > 0)); do
    case "$1" in
      --guided) VALIDATE_MODE="guided" ;;
      --deep) VALIDATE_DEEP=1 ;;
      --stage)
        shift
        VALIDATE_STAGE="${1:-}"
        ;;
      --stage=*) VALIDATE_STAGE="${1#--stage=}" ;;
      -h | --help)
        validation_usage
        exit 0
        ;;
      *) die "Unknown option: $1. Run with --help." ;;
    esac
    shift
  done
  if [[ -n "$VALIDATE_STAGE" ]]; then
    if [[ ! "$VALIDATE_STAGE" =~ ^[0-9]+$ ]] || ((VALIDATE_STAGE < 1 || VALIDATE_STAGE > ${#STAGE_TITLES[@]})); then
      die "--stage takes a number from 1 to ${#STAGE_TITLES[@]}."
    fi
    if [[ "$VALIDATE_MODE" == "guided" ]]; then
      die "Use --guided or --stage, not both."
    fi
  fi
}

# Prints a count with its noun, for example "1 check" or "3 checks".
count_of() {
  if [[ "$1" == "1" ]]; then
    printf '1 %s' "$2"
  else
    printf '%s %ss' "$1" "$2"
  fi
}

# Returns 0 while the stage that is running has no failed check.
stage_clean() {
  ((FAIL_COUNT == STAGE_FAIL_BASE))
}

# Call before a live test. Returns 0 when the test should run. Otherwise it
# records a skipped check that says why, and returns 1.
live_test_ready() {
  if [[ "$VALIDATE_DEEP" != "1" ]]; then
    check_skip "Live test not run (add --deep): $1"
    return 1
  fi
  if ! stage_clean; then
    check_skip "Live test not run until the checks above pass: $1"
    return 1
  fi
  return 0
}

# Prints the totals, then the result. $1 is the number of stages that were not checked.
validation_summary() {
  local unchecked="${1:-0}"
  if ((SKIP_COUNT > 0 && VALIDATE_DEEP == 0)); then
    printf '\nChecks left out: %d. Add --deep for the live tests: %s\n' "$SKIP_COUNT" "$DEEP_NOTICE"
  fi
  if ((unchecked == 0)); then
    check_summary
    return $?
  fi
  printf '\nSummary so far: %d PASS, %d FAIL, %d WARN, %d SKIP\n' "$PASS_COUNT" "$FAIL_COUNT" "$WARN_COUNT" "$SKIP_COUNT"
  printf 'Result: not finished, %s not checked. Run the guided check again: it resumes at the first stage that does not pass.\n' "$(count_of "$unchecked" stage)"
  return 1
}

run_report() {
  local total="$1" n
  for ((n = 1; n <= total; n++)); do
    if [[ -n "$VALIDATE_STAGE" && "$VALIDATE_STAGE" != "$n" ]]; then
      continue
    fi
    step "Stage ${n} of ${total}: ${STAGE_TITLES[n - 1]}"
    STAGE_FAIL_BASE="$FAIL_COUNT"
    "stage_${n}"
  done
  validation_summary 0
}

# Runs the checks of one stage without printing them. The lines end up in CHECK_BUFFER
# and the counts in STAGE_PASS, STAGE_FAIL, STAGE_WARN and STAGE_SKIP. The run totals do not move.
run_stage_buffered() {
  local n="$1" p="$PASS_COUNT" f="$FAIL_COUNT" w="$WARN_COUNT" s="$SKIP_COUNT"
  CHECK_BUFFER=""
  CHECK_BUFFERING=1
  STAGE_FAIL_BASE="$FAIL_COUNT"
  "stage_${n}"
  CHECK_BUFFERING=0
  STAGE_PASS=$((PASS_COUNT - p))
  STAGE_FAIL=$((FAIL_COUNT - f))
  STAGE_WARN=$((WARN_COUNT - w))
  STAGE_SKIP=$((SKIP_COUNT - s))
  PASS_COUNT="$p"
  FAIL_COUNT="$f"
  WARN_COUNT="$w"
  SKIP_COUNT="$s"
}

# Adds the result of the stage that was just run to the run totals.
keep_stage_result() {
  PASS_COUNT=$((PASS_COUNT + STAGE_PASS))
  FAIL_COUNT=$((FAIL_COUNT + STAGE_FAIL))
  WARN_COUNT=$((WARN_COUNT + STAGE_WARN))
  SKIP_COUNT=$((SKIP_COUNT + STAGE_SKIP))
}

# Starts a new screen for a stage. In a terminal it clears the window, so that only
# the current stage is visible. In a pipe or a log it prints a separator.
guided_screen() {
  if [[ -t 1 ]]; then
    printf '\033[2J\033[3J\033[H'
  else
    printf '\n%s\n' "------------------------------------------------------------"
  fi
}

GUIDED_REPLY=""

# Asks for a key. The end of the input (no terminal, or Ctrl-D) counts as q.
guided_ask() {
  GUIDED_REPLY=""
  printf '%s' "$1"
  if ! read -r GUIDED_REPLY; then
    GUIDED_REPLY="q"
    printf '\n'
  fi
}

# Prints the WARN and SKIP lines of CHECK_BUFFER, each with its hint.
buffered_remarks() {
  awk '
    /\[WARN\]|\[SKIP\]/ { show = 1; print; next }
    /^       / && show { print; next }
    { show = 0 }
  ' <<<"$CHECK_BUFFER"
}

run_guided() {
  local total="$1" n title attempts quit=0 unchecked=0 progress="" remarks="" found
  local session_started="$SECONDS" stage_started timings=""
  info ""
  info "${C_BOLD}Chapter ${CHAPTER#0} guided check: ${total} stages, in the order of the lab tasks.${C_RESET}"
  info "For each stage: read the task, do it in a second terminal, then press Enter here to check."
  info "You can also quit with q, do the task, and run the guided check again."
  info "It reads the state of your work each time, so it resumes at the first stage that does not pass."
  guided_ask "Press Enter to start, q to quit: "
  if [[ "$GUIDED_REPLY" == [qQ] ]]; then
    validation_summary "$total"
    return $?
  fi

  for ((n = 1; n <= total; n++)); do
    title="Stage ${n} of ${total}: ${STAGE_TITLES[n - 1]}"
    if declare -F "stage_${n}_enter" >/dev/null; then
      "stage_${n}_enter"
    fi
    run_stage_buffered "$n"
    attempts=0
    stage_started="$SECONDS"
    while ((STAGE_FAIL > 0)); do
      guided_screen
      printf '%s' "$progress"
      printf '\n%s%s%s\n\n' "$C_BOLD" "$title" "$C_RESET"
      "stage_${n}_task"
      if ((attempts == 0)); then
        printf '\nWhere you are now:\n%s\n' "${CHECK_BUFFER//\[FAIL\]/[TODO]}"
      else
        printf '\nCheck %d:\n%s\n' "$attempts" "$CHECK_BUFFER"
      fi
      if ((attempts == 0)); then
        guided_ask "Do the task, then press Enter to check. s skips this stage, q quits: "
      else
        guided_ask "Press Enter to check again. s skips this stage, q quits: "
      fi
      case "$GUIDED_REPLY" in
        [qQ])
          quit=1
          break
          ;;
        [sS]) break ;;
      esac
      attempts=$((attempts + 1))
      run_stage_buffered "$n"
    done
    keep_stage_result
    if ((attempts > 0)); then
      timings="${timings}  Stage ${n}: $(duration_text "$((SECONDS - stage_started))")"$'\n'
    fi
    found="$(buffered_remarks)"
    if [[ -n "$found" ]]; then
      remarks="${remarks}${found}"$'\n'
    fi
    if ((STAGE_FAIL == 0)); then
      if ((attempts > 0)); then
        guided_screen
        printf '%s' "$progress"
        printf '\n%s%s%s\n\nCheck %d:\n%s\n' "$C_BOLD" "$title" "$C_RESET" "$attempts" "$CHECK_BUFFER"
        printf '%sStage %d passed.%s\n' "$C_GREEN" "$n" "$C_RESET"
        if ((n < total)); then
          guided_ask "Press Enter for the next stage, q to quit: "
          if [[ "$GUIDED_REPLY" == [qQ] ]]; then
            quit=1
          fi
        else
          guided_ask "Press Enter for the summary: "
        fi
      fi
      progress="${progress}${C_GREEN}[done]${C_RESET} ${title} ($(count_of "$STAGE_PASS" check) passed)"$'\n'
    else
      progress="${progress}${C_RED}[open]${C_RESET} ${title} ($(count_of "$STAGE_FAIL" check) failed)"$'\n'
    fi
    if ((quit == 1)); then
      unchecked=$((total - n))
      break
    fi
  done

  guided_screen
  step "Chapter ${CHAPTER#0} guided check: summary"
  printf '%s' "$progress"
  if ((unchecked > 0)); then
    info "Stopped at stage ${n} of ${total}."
  fi
  if [[ -n "$remarks" ]]; then
    printf '\nRemarks:\n%s' "$remarks"
  fi
  if [[ -n "$timings" ]]; then
    printf '\nTime with this check open, from the first look at a stage to the check that passed:\n%s' "$timings"
    printf '  This run in total: %s\n' "$(duration_text "$((SECONDS - session_started))")"
  fi
  validation_summary "$unchecked"
}

# Entry point of a validator: reads the options, runs preflight, then the report or the guided check.
run_validation() {
  parse_validation_args "$@"
  printf 'Chapter %s validation, %s UTC\n' "${CHAPTER#0}" "$(date -u '+%Y-%m-%d %H:%M')"
  if [[ "$VALIDATE_DEEP" == "1" ]]; then
    info "Live tests are on (--deep): ${DEEP_NOTICE}"
  else
    info "Read-only run: nothing is created, changed or deleted."
  fi
  if declare -F preflight >/dev/null; then
    preflight
  fi
  if [[ "$VALIDATE_MODE" == "guided" ]]; then
    run_guided "${#STAGE_TITLES[@]}"
  else
    run_report "${#STAGE_TITLES[@]}"
  fi
}
