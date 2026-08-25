#!/usr/bin/env bash

platform_prepare() {
  if ! has brew; then
    local script_dir script_path
    script_dir="$(mktemp -d "${TMPDIR:-/tmp}/vedup-homebrew.XXXXXX")"
    script_path="$script_dir/install.sh"
    download_verified \
      "https://raw.githubusercontent.com/Homebrew/install/${HOMEBREW_INSTALL_COMMIT}/install.sh" \
      "$HOMEBREW_INSTALL_SHA256" "$script_path"
    if [ "${DRY_RUN:-0}" = 1 ]; then
      printf '[dry-run] NONINTERACTIVE=1 /bin/bash %q\n' "$script_path"
    else
      NONINTERACTIVE=1 /bin/bash "$script_path"
      rm -rf "$script_dir"
    fi
  fi

  # Hermetic tests inject a fixture-backed brew on PATH. Do not replace it
  # with a package manager from the CI host or the test stops representing
  # the declared machine inventory.
  if [ -n "${VEDUP_TEST_INVENTORY_FILE:-}" ]; then
    :
  elif [ -x /opt/homebrew/bin/brew ]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  elif [ -x /usr/local/bin/brew ]; then
    eval "$(/usr/local/bin/brew shellenv)"
  elif [ "${DRY_RUN:-0}" != "1" ]; then
    die "Homebrew was installed but is not available on PATH."
  fi

  # macOS Git is owned by Apple Command Line Tools. Vedup deliberately neither
  # installs nor changes Homebrew Git, credential helpers, .gitconfig or Keychain.
  if [ "${DRY_RUN:-0}" != 1 ] && ! xcrun -f git >/dev/null 2>&1; then
    xcode-select --install >/dev/null 2>&1 || true
    die "Apple Command Line Tools are still installing. Complete the macOS prompt, then run Vedup again."
  fi
}

brew_install_missing_formulae() {
  local formula token
  local -a missing=()
  for formula in "$@"; do
    token="${formula##*/}"
    if inventory_package_installed formula "$token"; then :; else
      type brew_trust_scoped_package >/dev/null 2>&1 && brew_trust_scoped_package formula "$formula"
      missing+=("$formula")
    fi
  done
  [ "${#missing[@]}" -gt 0 ] || return 0
  if [ "${DRY_RUN:-0}" = 1 ]; then
    printf '[dry-run] HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_UPGRADE=1 brew install'
    quote_command "${missing[@]}"
  else
    retry_command 3 2 env HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_UPGRADE=1 \
      brew install "${missing[@]}"
  fi
}

brew_trust_scoped_package() {
  local provider="$1" identifier="$2"
  case "$provider:$identifier" in
    cask:nikitabobko/tap/aerospace)
      run brew trust --cask nikitabobko/tap/aerospace
      ;;
    formula:FelixKratz/formulae/borders)
      run brew trust --formula FelixKratz/formulae/borders
      ;;
    formula:jorgerojas26/lazysql/lazysql)
      run brew trust --formula jorgerojas26/lazysql/lazysql
      ;;
  esac
}

brew_install_missing_casks() {
  local cask token
  local -a missing=()
  for cask in "$@"; do
    token="${cask##*/}"
    if inventory_package_installed cask "$token"; then :; else
      brew_trust_scoped_package cask "$cask"
      missing+=("$cask")
    fi
  done
  [ "${#missing[@]}" -gt 0 ] || return 0
  if [ "${DRY_RUN:-0}" = 1 ]; then
    printf '[dry-run] HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_UPGRADE=1 brew install --cask'
    quote_command "${missing[@]}"
  else
    retry_command 3 2 env HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_UPGRADE=1 \
      brew install --cask "${missing[@]}"
  fi
}

platform_install_app_scope() {
  local wanted="$1" _scope provider identifier label _label _description installed_ids="" has_mas_formula=0 has_mas_apps=0
  local -a formulae=() casks=()
  while IFS=$'\t' read -r _scope provider identifier _label _description; do
    case "$provider" in
      formula)
        formulae+=("$identifier")
        [ "${identifier##*/}" != mas ] || has_mas_formula=1
        ;;
      cask) casks+=("$identifier") ;;
      mas) has_mas_apps=1 ;;
    esac
  done < <(apps_each_selected | awk -F '\t' -v wanted="$wanted" '$1 == wanted')
  if [ "$has_mas_apps" = 1 ] && [ "$has_mas_formula" = 0 ]; then formulae+=(mas); fi
  [ "${#formulae[@]}" -eq 0 ] || brew_install_missing_formulae "${formulae[@]}"
  [ "${#casks[@]}" -eq 0 ] || brew_install_missing_casks "${casks[@]}"

  if [ "${DRY_RUN:-0}" = 1 ]; then
    while IFS=$'\t' read -r _scope provider identifier label _description; do
      [ "$provider" = mas ] || continue
      plan_has_action_for_resource "mas:$identifier" || continue
      run mas install "$identifier"
    done < <(apps_each_selected | awk -F '\t' -v wanted="$wanted" '$1 == wanted')
    return 0
  fi

  inventory_command_exists mas || return 0
  if ! installed_ids="$(mas list 2>/dev/null | awk '{print $1}')"; then
    warn "Mac App Store applications are pending. Sign in to the App Store, then rerun Safe sync."
    return 0
  fi
  while IFS=$'\t' read -r _scope provider identifier label _description; do
    [ "$provider" = mas ] || continue
    printf '%s\n' "$installed_ids" | grep -Fxq "$identifier" && continue
    if ! run mas install "$identifier"; then
      warn "$label could not be installed from the App Store; sign in or accept updated store terms, then rerun."
    fi
  done < <(apps_each_selected | awk -F '\t' -v wanted="$wanted" '$1 == wanted')
}

brew_upgrade_selected_apps() {
  [ "${UPGRADE_APPS:-0}" = 1 ] || [ -n "${VEDUP_SELECTED_APP_UPGRADES:-}" ] || return 0
  local cask token _scope provider label _description
  while IFS=$'\t' read -r _scope provider cask label _description; do
    [ "$provider" = cask ] || continue
    token="${cask##*/}"
    if [ "${UPGRADE_APPS:-0}" != 1 ]; then
      case " ${VEDUP_SELECTED_APP_UPGRADES:-} " in *" $token "*) ;; *) continue ;; esac
    fi
    brew list --cask "$token" >/dev/null 2>&1 || continue
    plan_cask_outdated "$token" || continue
    retry_command 3 2 run env HOMEBREW_NO_AUTO_UPDATE=1 brew upgrade --cask "$token"
  done < <(apps_each_selected)
}

platform_install_foundations() {
  brew_install_missing_formulae stow tmux btop eza
  # These upstream releases do not publish Intel macOS artifacts for Mise.
  if [ "$ARCH" = x64 ]; then brew_install_missing_formulae fd git-delta; fi
}

platform_install_workstation() {
  platform_install_app_scope workstation
  brew_upgrade_selected_apps
}

platform_install_personal_apps() {
  platform_install_app_scope optional
  brew_upgrade_selected_apps
}

platform_install_docker() {
  # Docker Desktop is already part of the workstation profile.
  :
}

platform_install_aws_dependencies() { :; }
