#!/usr/bin/env bash

VEDUP_MACOS_APPS_MANIFEST="${VEDUP_MACOS_APPS_MANIFEST:-$REPO_ROOT/profiles/macos/apps.tsv}"

apps_third_party_allowed() {
  case "$1:$2" in
    cask:nikitabobko/tap/aerospace|formula:FelixKratz/formulae/borders|formula:jorgerojas26/lazysql/lazysql) return 0 ;;
    *) return 1 ;;
  esac
}

apps_manifest_validate_file() {
  local file="$1" scope provider identifier label description extra count=0 key seen=""
  [ -r "$file" ] || return 1
  while IFS=$'\t' read -r scope provider identifier label description extra || [ -n "$scope$provider$identifier$label$description$extra" ]; do
    case "$scope" in ''|'#'*) continue ;; esac
    [ -z "$extra" ] || return 1
    case "$scope" in workstation|optional) ;; *) return 1 ;; esac
    case "$provider" in formula|cask|mas) ;; *) return 1 ;; esac
    [[ "$identifier" =~ ^[A-Za-z0-9@._+/-]+$ ]] || return 1
    [ "$provider" != mas ] || [[ "$identifier" =~ ^[0-9]+$ ]]
    case "$identifier" in
      */*)
        apps_third_party_allowed "$provider" "$identifier" || return 1
        ;;
    esac
    [ -n "$label" ] && [ -n "$description" ] || return 1
    [[ "$label$description" != *$'\r'* && "$label$description" != *$'\n'* ]] || return 1
    key="$provider:$identifier"
    case " $seen " in *" $key "*) return 1 ;; esac
    seen="$seen $key"
    count=$((count + 1))
  done < "$file"
  [ "$count" -gt 0 ]
}

apps_manifest_validate() { apps_manifest_validate_file "$VEDUP_MACOS_APPS_MANIFEST"; }

apps_each_scope() {
  local wanted="$1" scope provider identifier label description extra
  apps_manifest_validate || return 1
  while IFS=$'\t' read -r scope provider identifier label description extra; do
    [ "$scope" = "$wanted" ] || continue
    printf '%s\t%s\t%s\t%s\t%s\n' "$scope" "$provider" "$identifier" "$label" "$description"
  done < "$VEDUP_MACOS_APPS_MANIFEST"
}

apps_each_selected() {
  local scope provider identifier label description
  while IFS=$'\t' read -r scope provider identifier label description; do
    if type choices_app_selected >/dev/null 2>&1; then
      choices_app_selected "$scope" "$provider" "$identifier" || continue
    else
      case "$scope" in
        workstation) [ "${PROFILE:-server}" = workstation ] || continue ;;
        optional) [ "${WITH_PERSONAL_APPS:-0}" = 1 ] || continue ;;
      esac
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$scope" "$provider" "$identifier" "$label" "$description"
  done < <(apps_each_scope workstation; apps_each_scope optional)
  return 0
}

apps_each_provider() {
  local wanted="$1" scope provider identifier label description
  while IFS=$'\t' read -r scope provider identifier label description; do
    [ "$provider" = "$wanted" ] || continue
    printf '%s\t%s\t%s\t%s\t%s\n' "$scope" "$provider" "$identifier" "$label" "$description"
  done < <(apps_each_selected)
}

apps_manifest_has() {
  local wanted_provider="$1" wanted_identifier="$2" scope provider identifier label description found=0
  while IFS=$'\t' read -r scope provider identifier label description; do
    [ "$provider" = "$wanted_provider" ] && [ "$identifier" = "$wanted_identifier" ] && found=1
  done < <(apps_each_scope workstation; apps_each_scope optional)
  [ "$found" -eq 1 ]
}

apps_manifest_installs() {
  local wanted_provider="$1" wanted_identifier="$2" scope provider identifier label description found=0
  while IFS=$'\t' read -r scope provider identifier label description; do
    [ "$provider" = "$wanted_provider" ] && \
      [ "${identifier##*/}" = "${wanted_identifier##*/}" ] && found=1
  done < <(apps_each_scope workstation; apps_each_scope optional)
  [ "$found" -eq 1 ]
}

apps_scope_has_planned_action() {
  local wanted="$1" scope provider identifier label description resource found=0
  while IFS=$'\t' read -r scope provider identifier label description; do
    [ "$scope" = "$wanted" ] || continue
    case "$provider" in
      formula) resource="homebrew-formula:$identifier" ;;
      cask) resource="homebrew-cask:$identifier" ;;
      mas) resource="mas:$identifier" ;;
      *) continue ;;
    esac
    plan_has_action_for_resource "$resource" && found=1
  done < <(apps_each_selected)
  [ "$found" -eq 1 ]
}
