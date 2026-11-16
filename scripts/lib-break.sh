#!/usr/bin/env bash
# Broken labs: a script that puts one fault into a finished lab, for the learner to find.
# Source this file after lib.sh. Do not run it on its own.
# shellcheck disable=SC2034  # Variables defined here are used by the scripts that source this file.
#
# A break script defines:
#   CHAPTER, BREAK_DIR       the chapter number and its folder name, for example "01" and "01-containers"
#   WORK_DIR                 the folder of the learner's work. The state of the exercise is kept there.
#   SCENARIOS                the names of the faults it can inject
#   CAUSES                   the possible causes shown in the diagnosis question: one per scenario,
#                            in the same order, followed by causes that are never the answer
#   symptom_NAME             prints what a user would report
#   inject_NAME              injects the fault
#   explain_NAME             prints how to see the fault and what repairs it
#   lab_is_finished          returns 0 when the lab is in the state the faults start from,
#                            which is also the state that closes an exercise
#   BREAK_CHECK              the validate.sh command that confirms the repair
#   restore_lab              puts the lab back as it was
#   BREAK_NOTICE             one sentence that says what the script changes
# and ends with: run_break "$@"

break_usage() {
  local script="chapters/${BREAK_DIR}/lab/break.sh"
  cat <<EOF
Usage: ${script} [--diagnose | --restore | --yes]

  (no option)  Puts one fault into your finished lab, after asking. ${BREAK_NOTICE}
  --diagnose   Asks what you think the cause is, and tells you whether you are right.
  --restore    Gives up on the exercise and puts the lab back as it was.
  --yes        Does not ask before injecting.
  -h, --help   Shows this text.

Find the cause with the tools of the chapter, not with validate.sh: its report names the fault.
Once you have repaired it, ${BREAK_CHECK} confirms.
EOF
}

state_file() {
  printf '%s/.broken-lab' "$WORK_DIR"
}

done_file() {
  printf '%s/.broken-lab-done' "$WORK_DIR"
}

current_scenario() {
  if [[ -f "$(state_file)" ]]; then
    head -n 1 "$(state_file)"
  fi
}

# Prints the first scenario that has not been played yet. Starts over when all were.
next_scenario() {
  local name
  for name in "${SCENARIOS[@]}"; do
    if ! grep -qx "$name" "$(done_file)" 2>/dev/null; then
      printf '%s' "$name"
      return 0
    fi
  done
  rm -f "$(done_file)"
  printf '%s' "${SCENARIOS[0]}"
}

close_scenario() {
  current_scenario >>"$(done_file)"
  rm -f "$(state_file)"
}

break_inject() {
  local scenario
  scenario="$(current_scenario)"
  if [[ -n "$scenario" ]]; then
    if lab_is_finished; then
      info "The fault of the last exercise is repaired: the validation passes again."
      close_scenario
    else
      info "A fault is already in place and the lab does not pass yet."
      "symptom_${scenario}"
      info "Find the cause, then check your diagnosis with: break.sh --diagnose"
      info "To give up and put the lab back: break.sh --restore"
      return 0
    fi
  fi

  if ! lab_is_finished; then
    die "The lab of chapter ${CHAPTER#0} is not in its finished state: make ${BREAK_CHECK} pass first. A broken lab starts from a lab that works."
  fi
  step "Broken lab, chapter ${CHAPTER#0}"
  info "This puts one fault into your lab. ${BREAK_NOTICE}"
  info "Your job: find the cause with the tools of the chapter, say what it is, and repair it."
  if ! confirm "Inject a fault now?"; then
    info "Nothing changed."
    return 0
  fi
  scenario="$(next_scenario)"
  mkdir -p "$WORK_DIR"
  printf '%s\n' "$scenario" >"$(state_file)"
  "inject_${scenario}"
  step "Something is wrong"
  "symptom_${scenario}"
  info ""
  info "Look for the cause yourself. Do not run validate.sh yet: its report names the fault."
  info "When you think you know: ~/${VM_COURSE_DIR}/chapters/${BREAK_DIR}/lab/break.sh --diagnose"
}

break_diagnose() {
  local scenario index answer="" right=0
  scenario="$(current_scenario)"
  if [[ -z "$scenario" ]]; then
    die "No fault is in place. Inject one first: break.sh"
  fi
  for index in "${!SCENARIOS[@]}"; do
    if [[ "${SCENARIOS[index]}" == "$scenario" ]]; then
      right=$((index + 1))
    fi
  done
  step "What is the cause?"
  for index in "${!CAUSES[@]}"; do
    printf '  %d. %s\n' "$((index + 1))" "${CAUSES[index]}"
  done
  read -r -p "Your answer (1 to ${#CAUSES[@]}): " answer || true
  if [[ "$answer" == "$right" ]]; then
    printf '\n%sRight.%s\n' "$C_GREEN" "$C_RESET"
    "explain_${scenario}"
    info ""
    if lab_is_finished; then
      info "The lab passes again. Exercise closed."
      close_scenario
    else
      info "Repair it, then confirm with: ~/${VM_COURSE_DIR}/chapters/${BREAK_DIR}/lab/${BREAK_CHECK}"
    fi
    return 0
  fi
  printf '\n%sNot that.%s Look again, then run break.sh --diagnose once more.\n' "$C_YELLOW" "$C_RESET"
  return 1
}

break_restore() {
  if [[ -z "$(current_scenario)" ]]; then
    info "No fault is in place. Nothing to restore."
    return 0
  fi
  step "Putting the lab back"
  restore_lab
  close_scenario
  info "Done. The next run of break.sh injects another fault."
}

run_break() {
  local action="inject"
  while (($# > 0)); do
    case "$1" in
      --diagnose) action="diagnose" ;;
      --restore) action="restore" ;;
      --yes | -y) ASSUME_YES=1 ;;
      -h | --help)
        break_usage
        exit 0
        ;;
      *) die "Unknown option: $1. Run with --help." ;;
    esac
    shift
  done
  require_lab_vm
  load_env
  "break_${action}"
}
