#!/usr/bin/env bash

# Human selections are data, never shell code. Bundle defaults allow newly
# added applications to inherit the user's intent; app records store only
# overrides from that default.
VEDUP_CHOICES_FILE="${VEDUP_CHOICES_FILE:-${VEDUP_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/vedup}/choices.tsv}"
CHOICES_WORKSTATION_BUNDLE="${VEDUP_WORKSTATION_BUNDLE:-}"
CHOICES_OPTIONAL_BUNDLE="${VEDUP_OPTIONAL_BUNDLE:-}"
CHOICES_APP_OVERRIDES="${VEDUP_APP_OVERRIDES:-}"

choices_valid_bool() { [ "$1" = 0 ] || [ "$1" = 1 ]; }

choices_validate_file() {
  local file="$1" kind name value extra schema_count=0 workstation_count=0 optional_count=0 seen=""
  [ -r "$file" ] || return 1
  while IFS=$'\t' read -r kind name value extra || [ -n "$kind$name$value$extra" ]; do
    [ -z "$extra" ] || return 1
    case "$kind" in
      schema)
        [ "$name" = 1 ] && [ -z "$value" ] || return 1
        schema_count=$((schema_count + 1))
        ;;
      bundle)
        case "$name" in
          workstation) workstation_count=$((workstation_count + 1)) ;;
          optional) optional_count=$((optional_count + 1)) ;;
          *) return 1 ;;
        esac
        choices_valid_bool "$value" || return 1
        ;;
      app)
        [[ "$name" =~ ^(formula|cask|mas):[A-Za-z0-9@._+/-]+$ ]] || return 1
        choices_valid_bool "$value" || return 1
        case " $seen " in *" $name "*) return 1 ;; esac
        seen="$seen $name"
        ;;
      *) return 1 ;;
    esac
  done < "$file"
  [ "$schema_count" = 1 ] && [ "$workstation_count" = 1 ] && [ "$optional_count" = 1 ]
}

choices_defaults() {
  if [ "${OS:-linux}" = macos ] && [ "${PROFILE:-workstation}" = workstation ]; then
    CHOICES_WORKSTATION_BUNDLE=1
  else
    CHOICES_WORKSTATION_BUNDLE=0
  fi
  CHOICES_OPTIONAL_BUNDLE="${WITH_PERSONAL_APPS:-0}"
  CHOICES_APP_OVERRIDES=""
}

choices_load() {
  local file="${1:-$VEDUP_CHOICES_FILE}" kind name value
  choices_validate_file "$file" || return 1
  CHOICES_APP_OVERRIDES=""
  while IFS=$'\t' read -r kind name value; do
    case "$kind:$name" in
      bundle:workstation) CHOICES_WORKSTATION_BUNDLE="$value" ;;
      bundle:optional) CHOICES_OPTIONAL_BUNDLE="$value" ;;
      app:*) CHOICES_APP_OVERRIDES="${CHOICES_APP_OVERRIDES}${CHOICES_APP_OVERRIDES:+$'\n'}${name}"$'\t'"$value" ;;
    esac
  done < "$file"
  export VEDUP_APP_OVERRIDES="$CHOICES_APP_OVERRIDES"
}

choices_load_or_default() {
  if [ -e "$VEDUP_CHOICES_FILE" ]; then
    choices_load "$VEDUP_CHOICES_FILE"
    return
  fi
  choices_defaults
}

choices_apply_environment() {
  [ -z "${VEDUP_WORKSTATION_BUNDLE:-}" ] || CHOICES_WORKSTATION_BUNDLE="$VEDUP_WORKSTATION_BUNDLE"
  [ -z "${VEDUP_OPTIONAL_BUNDLE:-}" ] || CHOICES_OPTIONAL_BUNDLE="$VEDUP_OPTIONAL_BUNDLE"
  [ -z "${VEDUP_APP_OVERRIDES:-}" ] || CHOICES_APP_OVERRIDES="$VEDUP_APP_OVERRIDES"
  choices_valid_bool "$CHOICES_WORKSTATION_BUNDLE" && choices_valid_bool "$CHOICES_OPTIONAL_BUNDLE"
}

choices_export() {
  VEDUP_WORKSTATION_BUNDLE="$CHOICES_WORKSTATION_BUNDLE"
  VEDUP_OPTIONAL_BUNDLE="$CHOICES_OPTIONAL_BUNDLE"
  VEDUP_APP_OVERRIDES="$CHOICES_APP_OVERRIDES"
  export VEDUP_WORKSTATION_BUNDLE VEDUP_OPTIONAL_BUNDLE VEDUP_APP_OVERRIDES
}

choices_override_value() {
  local wanted="$1" resource value
  while IFS=$'\t' read -r resource value; do
    [ "$resource" = "$wanted" ] || continue
    printf '%s' "$value"
    return 0
  done <<< "$CHOICES_APP_OVERRIDES"
  return 1
}

choices_set_override() {
  local resource="$1" value="$2" existing existing_value output=""
  choices_valid_bool "$value" || return 1
  while IFS=$'\t' read -r existing existing_value; do
    [ -n "$existing" ] || continue
    [ "$existing" = "$resource" ] && continue
    output="${output}${output:+$'\n'}$existing"$'\t'"$existing_value"
  done <<< "$CHOICES_APP_OVERRIDES"
  output="${output}${output:+$'\n'}$resource"$'\t'"$value"
  CHOICES_APP_OVERRIDES="$output"
  choices_export
}

choices_clear_matching_override() {
  local resource="$1" existing existing_value output=""
  while IFS=$'\t' read -r existing existing_value; do
    [ -n "$existing" ] || continue
    [ "$existing" = "$resource" ] && continue
    output="${output}${output:+$'\n'}$existing"$'\t'"$existing_value"
  done <<< "$CHOICES_APP_OVERRIDES"
  CHOICES_APP_OVERRIDES="$output"
  choices_export
}

choices_app_selected() {
  local scope="$1" provider="$2" identifier="$3" resource short_resource override default
  resource="$provider:$identifier"
  short_resource="$provider:${identifier##*/}"
  case "$scope" in
    workstation) default="$CHOICES_WORKSTATION_BUNDLE" ;;
    optional) default="$CHOICES_OPTIONAL_BUNDLE" ;;
    *) return 1 ;;
  esac
  override="$(choices_override_value "$resource" 2>/dev/null || true)"
  if [ -z "$override" ] && [ "$short_resource" != "$resource" ]; then
    override="$(choices_override_value "$short_resource" 2>/dev/null || true)"
  fi
  [ "${override:-$default}" = 1 ]
}

choices_write_file() {
  local file="$1" resource value
  {
    printf 'schema\t1\n'
    printf 'bundle\tworkstation\t%s\n' "$CHOICES_WORKSTATION_BUNDLE"
    printf 'bundle\toptional\t%s\n' "$CHOICES_OPTIONAL_BUNDLE"
    while IFS=$'\t' read -r resource value; do
      [ -n "$resource" ] && printf 'app\t%s\t%s\n' "$resource" "$value"
    done <<< "$CHOICES_APP_OVERRIDES"
  } > "$file"
  choices_validate_file "$file"
}

choices_match_file() {
  local file="$1" kind name value current_workstation="" current_optional="" resource override
  local expected_count=0 actual_count=0
  choices_validate_file "$file" || return 1
  while IFS=$'\t' read -r kind name value; do
    case "$kind:$name" in
      bundle:workstation) current_workstation="$value" ;;
      bundle:optional) current_optional="$value" ;;
      app:*) actual_count=$((actual_count + 1)) ;;
    esac
  done < "$file"
  [ "$current_workstation" = "$CHOICES_WORKSTATION_BUNDLE" ] && \
    [ "$current_optional" = "$CHOICES_OPTIONAL_BUNDLE" ] || return 1
  while IFS=$'\t' read -r resource override; do
    [ -n "$resource" ] || continue
    expected_count=$((expected_count + 1))
    grep -Fxq $'app\t'"$resource"$'\t'"$override" "$file" || return 1
  done <<< "$CHOICES_APP_OVERRIDES"
  [ "$actual_count" = "$expected_count" ]
}
