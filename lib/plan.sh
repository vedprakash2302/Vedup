#!/usr/bin/env bash
# shellcheck disable=SC2034

# Read-only inventory and planning. The generated TSV is the single source of
# truth used by previews, the interactive review, execution and saved state.

PLAN_FILE=""
PLAN_INSTALL_COUNT=0
PLAN_UPDATE_COUNT=0
PLAN_KEEP_COUNT=0
PLAN_CONFIGURE_COUNT=0
PLAN_REVIEW_COUNT=0
PLAN_CONFLICT_COUNT=0
PLAN_NEEDS_SUDO=0
PLAN_WORKFLOW="fresh"
PLAN_OUTDATED_CASKS_LOADED=0
PLAN_OUTDATED_CASKS=""

plan_reset() {
  plan_cleanup
  PLAN_FILE="$(mktemp "${TMPDIR:-/tmp}/vedup-plan.XXXXXX")"
  PLAN_INSTALL_COUNT=0 PLAN_UPDATE_COUNT=0 PLAN_KEEP_COUNT=0
  PLAN_CONFIGURE_COUNT=0 PLAN_REVIEW_COUNT=0 PLAN_CONFLICT_COUNT=0
  PLAN_NEEDS_SUDO=0
}

plan_cleanup() {
  [ -n "${PLAN_FILE:-}" ] || return 0
  case "$PLAN_FILE" in "${TMPDIR:-/tmp}"/vedup-plan.*) rm -f "$PLAN_FILE" ;; esac
  PLAN_FILE=""
}

plan_add() {
  local action="$1" resource="$2" provider="$3" ownership="$4"
  local current="${5:-unknown}" desired="${6:-unknown}" description="${7:-No description}"
  case "$action" in
    install) PLAN_INSTALL_COUNT=$((PLAN_INSTALL_COUNT + 1)) ;;
    update) PLAN_UPDATE_COUNT=$((PLAN_UPDATE_COUNT + 1)) ;;
    keep) PLAN_KEEP_COUNT=$((PLAN_KEEP_COUNT + 1)) ;;
    configure) PLAN_CONFIGURE_COUNT=$((PLAN_CONFIGURE_COUNT + 1)) ;;
    review) PLAN_REVIEW_COUNT=$((PLAN_REVIEW_COUNT + 1)) ;;
    conflict) PLAN_CONFLICT_COUNT=$((PLAN_CONFLICT_COUNT + 1)) ;;
    *) return 1 ;;
  esac
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$action" "$resource" "$provider" "$ownership" "$current" "$desired" "$description" >> "$PLAN_FILE"
}

plan_previous_owner() {
  state_resource_owner "$1" 2>/dev/null || true
}

plan_existing_owner() {
  local resource="$1" owner
  owner="$(plan_previous_owner "$resource")"
  if [[ "$owner" == "vedup-managed" ]]; then printf 'vedup-managed'; else printf 'external'; fi
}

plan_command_resource() {
  local resource="$1" command_name="$2" provider="$3" managed_update="${4:-0}" owner
  if ! inventory_command_exists "$command_name"; then
    plan_add install "$resource" "$provider" vedup-managed missing pinned "Install missing $resource"
    return
  fi
  owner="$(plan_existing_owner "$resource")"
  if [[ "$owner" == "vedup-managed" && "$managed_update" == 1 ]]; then
    plan_add update "$resource" "$provider" vedup-managed installed pinned "Converge $resource to this release"
  else
    plan_add keep "$resource" "$provider" "$owner" installed compatible "Retain compatible $resource"
  fi
}

plan_mise_manager() {
  local owner previous_desired installed_mise="$HOME/.local/bin/mise" observed_version
  owner="$(plan_previous_owner mise)"
  previous_desired="$(state_resource_desired mise 2>/dev/null || true)"
  if ! inventory_command_exists mise; then
    plan_add install mise direct vedup-managed missing "$MISE_VERSION" "Install missing Mise $MISE_VERSION"
  elif [ "$owner" = vedup-managed ] && { [ "$previous_desired" != "$MISE_VERSION" ] || \
    [ ! -x "$installed_mise" ] || ! "$installed_mise" --version 2>/dev/null | grep -Eq "(^| )${MISE_VERSION}([ +]|$)"; }; then
    plan_add update mise direct vedup-managed installed "$MISE_VERSION" "Atomically update managed Mise"
  elif [ "$owner" != vedup-managed ]; then
    if [ -n "${VEDUP_TEST_INVENTORY_FILE:-}" ]; then
      plan_add keep mise direct external installed compatible "Retain fixture-provided compatible Mise"
    else
      observed_version="$(mise --version 2>/dev/null | sed -E 's/^[^0-9]*([0-9]+\.[0-9]+\.[0-9]+).*/\1/' || true)"
      if [ -n "$observed_version" ] && version_at_least "$observed_version" "$MISE_VERSION" && \
        mise help install >/dev/null 2>&1 && mise help trust >/dev/null 2>&1; then
        plan_add keep mise direct external "$observed_version" compatible "Retain compatible external Mise"
      else
        plan_add review mise direct unmanaged-conflict "${observed_version:-unknown}" "$MISE_VERSION" \
          "Preserve incompatible external Mise; update or move it aside before Vedup installs its pinned provider"
      fi
    fi
  else
    [ "$owner" = vedup-managed ] || owner=external
    plan_add keep mise direct "$owner" installed "$MISE_VERSION" "Retain compatible Mise"
  fi
}

plan_macos_formula() {
  local formula="$1" resource="homebrew-formula:$1" owner
  if inventory_package_installed formula "$formula"; then
    owner="$(plan_existing_owner "$resource")"
    plan_add keep "$resource" homebrew "$owner" installed required "Retain installed formula $formula"
  else
    plan_add install "$resource" homebrew vedup-managed missing required "Install missing formula $formula without upgrades"
  fi
}

plan_macos_cask() {
  local cask="$1" token="${1##*/}" resource="homebrew-cask:$1" owner
  if inventory_package_installed cask "$token"; then
    owner="$(plan_existing_owner "$resource")"
    if plan_app_upgrade_selected "$token" && plan_cask_outdated "$token"; then
      plan_add update "$resource" homebrew "$owner" installed latest "Explicitly upgrade $token"
      PLAN_NEEDS_SUDO=1
    else
      plan_add keep "$resource" homebrew "$owner" installed retained "Retain installed application $token"
    fi
  else
    plan_add install "$resource" homebrew vedup-managed missing required "Install missing application $token without upgrading others"
    PLAN_NEEDS_SUDO=1
  fi
}

plan_cask_outdated() {
  local token="$1"
  if [ -n "${VEDUP_TEST_INVENTORY_FILE:-}" ]; then
    inventory_fixture_has outdated-cask "$token"
  else
    if [ "$PLAN_OUTDATED_CASKS_LOADED" = 0 ]; then
      PLAN_OUTDATED_CASKS="$(HOMEBREW_NO_AUTO_UPDATE=1 brew outdated --cask --quiet 2>/dev/null || true)"
      PLAN_OUTDATED_CASKS_LOADED=1
    fi
    printf '%s\n' "$PLAN_OUTDATED_CASKS" | grep -Fxq "$token"
  fi
}

plan_app_upgrade_selected() {
  local token="$1" selected
  [ "${UPGRADE_APPS:-0}" = 1 ] && return 0
  for selected in ${VEDUP_SELECTED_APP_UPGRADES:-}; do [ "$selected" = "$token" ] && return 0; done
  return 1
}

plan_mas_app() {
  local id="$1" label="$2" resource="mas:$1"
  if inventory_package_installed mas "$id"; then
    plan_add keep "$resource" mas "$(plan_existing_owner "$resource")" installed retained "Retain $label"
  else
    plan_add install "$resource" mas vedup-managed missing required "Install missing App Store application $label"
  fi
}

plan_linux_package() {
  local package="$1" installed=0 resource owner
  resource="system-package:$package"
  inventory_package_installed "$PLATFORM_ADAPTER" "$package" && installed=1
  if [[ "$installed" == 1 ]]; then
    owner="$(plan_existing_owner "$resource")"
    plan_add keep "$resource" "$PLATFORM_ADAPTER" "$owner" installed retained "Retain installed system package $package"
  else
    plan_add install "$resource" "$PLATFORM_ADAPTER" vedup-managed missing required "Install missing system package $package without general upgrades"
    PLAN_NEEDS_SUDO=1
  fi
}

plan_previous_vedup_link() {
  local target="$1" link
  [ -L "$target" ] || return 1
  link="$(readlink "$target")"
  case "$link" in
    */vedup/releases/*/dotfiles/*|*/vedup/current/dotfiles/*|*/vedup/config/worktree/*) return 0 ;;
    *) return 1 ;;
  esac
}

plan_previous_vedup_command() { vedup_launcher_is_managed "$1"; }

plan_dotfile_parent_status() {
  local relative="$1" current="$HOME" part prefix="" status=clean
  local -a parts=()
  IFS='/' read -r -a parts <<< "$(dirname "$relative")"
  for part in "${parts[@]}"; do
    [ "$part" = . ] && continue
    prefix="${prefix:+$prefix/}$part"
    current="$HOME/$prefix"
    if [ -L "$current" ]; then
      if plan_previous_vedup_link "$current"; then status=managed
      else printf conflict; return 0; fi
    elif [ -e "$current" ] && [ ! -d "$current" ]; then
      printf conflict
      return 0
    fi
  done
  printf '%s' "$status"
}

plan_dotfiles() {
  local package package_dir source managed_source relative target parent_status changed=0 conflicts=0
  if ! has find; then
    plan_add configure dotfiles stow vedup-managed pending-foundations managed-links \
      "Inspect and link Vedup configuration after the planned findutils installation"
    return 0
  fi
  config_scan
  if [ "$CONFIG_CONFLICT_COUNT" -gt 0 ]; then
    plan_add review config-workspace stow unmanaged-conflict "$CONFIG_CONFLICT_COUNT conflicting paths" merge-required \
      "Preserve local configuration; review files changed both locally and by this release"
    return 0
  fi
  [ "$CONFIG_NEEDS_UPDATE" = 0 ] || changed=1
  for package in "${STOW_PACKAGES[@]}"; do
    if [ -d "$VEDUP_CONFIG_WORKTREE/$package" ]; then package_dir="$VEDUP_CONFIG_WORKTREE/$package"
    else package_dir="$REPO_ROOT/dotfiles/$package"; fi
    [[ -d "$package_dir" ]] || { plan_add conflict "dotfiles:$package" stow unmanaged-conflict missing required "Selected dotfile package is absent"; continue; }
    while IFS= read -r -d '' source; do
      relative="${source#"$package_dir"/}"
      target="$HOME/$relative"
      managed_source="$VEDUP_CONFIG_WORKTREE/$package/$relative"
      parent_status="$(plan_dotfile_parent_status "$relative")"
      if [ "$parent_status" = conflict ]; then
        conflicts=$((conflicts + 1))
        continue
      elif [ "$parent_status" = managed ]; then
        changed=1
      fi
      if [[ -L "$target" ]] && [[ -e "$managed_source" ]] && [[ "$target" -ef "$managed_source" ]]; then
        continue
      elif plan_previous_vedup_link "$target"; then
        changed=1
      elif [[ -e "$target" || -L "$target" ]]; then
        conflicts=$((conflicts + 1))
      else
        changed=1
      fi
    done < <(find "$package_dir" \( -type f -o -type l \) \
      ! -name .gitignore ! -name .gitmodules ! -name .cvsignore ! -name .DS_Store -print0)
  done
  if [[ "$conflicts" -gt 0 ]]; then
    plan_add conflict dotfiles stow unmanaged-conflict "$conflicts existing paths" managed-links "Back up and replace $conflicts conflicting dotfile paths transactionally"
  elif [[ "$changed" == 1 ]]; then
    plan_add configure dotfiles stow vedup-managed incomplete managed-links "Link missing Vedup configuration"
  else
    plan_add keep dotfiles stow vedup-managed linked managed-links "Managed configuration links are current"
  fi
}

plan_plugins() {
  local zsh_root tmux_root spec plugin_name destination desired current owner resource
  zsh_root="${XDG_DATA_HOME:-$HOME/.local/share}/vedup/zsh/plugins"
  tmux_root="$HOME/.tmux/plugins"
  for spec in \
    "zsh-autosuggestions|$zsh_root/zsh-autosuggestions|$ZSH_AUTOSUGGESTIONS_COMMIT" \
    "zsh-syntax-highlighting|$zsh_root/zsh-syntax-highlighting|$ZSH_SYNTAX_HIGHLIGHTING_COMMIT" \
    "zsh-history-substring-search|$zsh_root/zsh-history-substring-search|$ZSH_HISTORY_SUBSTRING_SEARCH_COMMIT" \
    "zsh-completions|$zsh_root/zsh-completions|$ZSH_COMPLETIONS_COMMIT" \
    "zsh-you-should-use|$zsh_root/zsh-you-should-use|$ZSH_YOU_SHOULD_USE_COMMIT" \
    "git-alias|$zsh_root/git-alias|$ZSH_GIT_ALIAS_COMMIT" \
    "tpm|$tmux_root/tpm|$TPM_COMMIT" \
    "vim-tmux-navigator|$tmux_root/vim-tmux-navigator|$TMUX_NAVIGATOR_COMMIT" \
    "tmux-resurrect|$tmux_root/tmux-resurrect|$TMUX_RESURRECT_COMMIT" \
    "tmux-continuum|$tmux_root/tmux-continuum|$TMUX_CONTINUUM_COMMIT" \
    "tmux-sensible|$tmux_root/tmux-sensible|$TMUX_SENSIBLE_COMMIT" \
    "tmux-online-status|$tmux_root/tmux-online-status|$TMUX_ONLINE_STATUS_COMMIT" \
    "tmux-battery|$tmux_root/tmux-battery|$TMUX_BATTERY_COMMIT" \
    "tmux-catppuccin|$tmux_root/tmux|$TMUX_CATPPUCCIN_COMMIT"; do
    IFS='|' read -r plugin_name destination desired <<< "$spec"
    resource="plugin:$plugin_name" owner="$(plan_previous_owner "$resource")"
    if [[ ! -e "$destination" && ! -L "$destination" ]]; then
      plan_add install "$resource" git vedup-managed missing "$desired" "Install missing pinned plugin $plugin_name"
    elif [[ ! -d "$destination/.git" ]]; then
      plan_add review "$resource" git unmanaged-conflict present "$desired" \
        "Preserve the non-Git path at $destination; move it aside or adopt it manually before Vedup can manage this plugin"
    else
      current="$(git -C "$destination" rev-parse HEAD 2>/dev/null || true)"
      if [ "$owner" = vedup-managed ] && [ -n "$(git -C "$destination" status --porcelain 2>/dev/null)" ]; then
        plan_add review "$resource" git unmanaged-conflict modified "$desired" \
          "Preserve local changes in managed plugin $plugin_name; commit or move them aside before synchronization"
      elif [ "$owner" = vedup-managed ] && [ "$current" != "$desired" ]; then
        plan_add update "$resource" git vedup-managed "$current" "$desired" "Update managed plugin $plugin_name"
      else
        [ "$owner" = vedup-managed ] || owner=external
        plan_add keep "$resource" git "$owner" "$current" compatible "Retain compatible plugin $plugin_name"
      fi
    fi
  done
}

plan_mise_version() {
  local tool="$1"
  awk -F '=' -v wanted="$tool" '
    /^\[tools\]/ { in_tools=1; next }
    /^\[/ { in_tools=0 }
    in_tools {
      key=$1; value=$2
      gsub(/^[[:space:]"]+|[[:space:]"]+$/, "", key)
      gsub(/^[[:space:]"]+|[[:space:]"]+$/, "", value)
      if (key == wanted) { print value; exit }
    }
  ' "$REPO_ROOT/mise.toml"
}

plan_mise_tool_present() {
  local tool="$1" version="$2" fixture_status
  if inventory_fixture_has mise-tool "$tool@$version"; then return 0; else fixture_status="$?"; fi
  [ "$fixture_status" != 1 ] || return 1
  inventory_command_exists mise || return 1
  local mise_bin
  mise_bin="$(mise_binary)" || return 1
  MISE_CONFIG_FILE="$REPO_ROOT/mise.toml" "$mise_bin" where "$tool@$version" >/dev/null 2>&1
}

plan_mise_tools() {
  local spec tool_name command_name resource owner desired_version previous_desired mise_present external_owner
  local -a tools=(node\|node python\|python aqua:neovim/neovim\|nvim starship\|starship zoxide\|zoxide ripgrep\|rg bat\|bat fzf\|fzf carapace\|carapace jq\|jq yq\|yq lazygit\|lazygit gh\|gh tree-sitter\|tree-sitter)
  [ "$OS/$ARCH" = linux/arm64 ] || tools+=(tlrc\|tldr)
  if [ "$OS" = linux ]; then tools+=(fd\|fd delta\|delta btop\|btop)
  elif [ "$ARCH" = arm64 ]; then tools+=(fd\|fd delta\|delta); fi
  [ "$WITH_AWS" = 1 ] && tools+=(awscli\|aws)
  [ "$WITH_DOCKER" = 1 ] && tools+=(lazydocker\|lazydocker)

  for spec in "${tools[@]}"; do
    tool_name="${spec%%|*}" command_name="${spec##*|}" resource="mise-tool:$command_name"
    desired_version="$(plan_mise_version "$tool_name")"
    [ -n "$desired_version" ] || desired_version=pinned
    owner="$(plan_previous_owner "$resource")"
    previous_desired="$(state_resource_desired "$resource" 2>/dev/null || true)"
    mise_present=0
    plan_mise_tool_present "$tool_name" "$desired_version" && mise_present=1
    external_owner="$(plan_previous_owner "external-command:$command_name")"
    if [ "$external_owner" = external ] || \
      { [ "$owner" != vedup-managed ] && [ "$mise_present" = 0 ] && inventory_command_exists "$command_name"; }; then
      plan_add keep "external-command:$command_name" path external installed retained \
        "Retain the existing external $command_name while Vedup uses an isolated pinned version"
    fi
    if [ "$owner" = vedup-managed ] && { [ "$previous_desired" != "$desired_version" ] || [ "$mise_present" = 0 ]; }; then
      plan_add update "$resource" "mise:$tool_name" vedup-managed installed "$desired_version" "Converge managed tool $tool_name"
    elif [ "$mise_present" = 0 ]; then
      plan_add install "$resource" "mise:$tool_name" vedup-managed missing "$desired_version" \
        "Install pinned $tool_name with Mise without replacing external providers"
    else
      [ "$owner" = vedup-managed ] || owner=external
      plan_add keep "$resource" "mise:$tool_name" "$owner" installed compatible "Retain compatible $tool_name"
    fi
  done

  if [ "$OS" = linux ]; then
    owner="$(plan_previous_owner cli:eza)"
    if ! inventory_command_exists eza; then
      plan_add install cli:eza direct vedup-managed missing "$EZA_VERSION" "Install missing pinned eza"
    elif [ "$owner" = vedup-managed ] && ! eza --version 2>/dev/null | grep -q "v${EZA_VERSION}"; then
      plan_add update cli:eza direct vedup-managed installed "$EZA_VERSION" "Update managed eza"
    else
      [ "$owner" = vedup-managed ] || owner=external
      plan_add keep cli:eza direct "$owner" installed compatible "Retain compatible eza"
    fi
  fi
  if [ "$OS/$ARCH" = linux/arm64 ]; then
    owner="$(plan_previous_owner cli:tldr)"
    previous_desired="$(state_resource_desired cli:tldr 2>/dev/null || true)"
    if ! inventory_command_exists tldr; then
      plan_add install cli:tldr direct vedup-managed missing "$TLRC_VERSION" "Install missing pinned tldr"
    elif [ "$owner" = vedup-managed ] && { [ "$previous_desired" != "$TLRC_VERSION" ] || ! tldr --version 2>/dev/null | grep -q "$TLRC_VERSION"; }; then
      plan_add update cli:tldr direct vedup-managed installed "$TLRC_VERSION" "Update managed tldr"
    else
      [ "$owner" = vedup-managed ] || owner=external
      plan_add keep cli:tldr direct "$owner" installed compatible "Retain compatible tldr"
    fi
  fi
}

plan_generate() {
  local package formula cask current_login_shell app_scope app_provider app_identifier app_label app_description
  local selected_mas_apps=0 selected_mas_formula=0
  local -a macos_check_args=()
  plan_reset
  state_detect_workflow
  PLAN_WORKFLOW="$STATE_WORKFLOW"

  if [[ "$DOTFILES_ONLY" != 1 ]]; then
    if [[ "$OS" == macos ]]; then
      if { [ -n "${VEDUP_TEST_INVENTORY_FILE:-}" ] && inventory_command_exists git; } || \
        { [ -z "${VEDUP_TEST_INVENTORY_FILE:-}" ] && command -v xcrun >/dev/null 2>&1 && xcrun -f git >/dev/null 2>&1; }; then
        plan_add keep git system external installed system "Use Apple Command Line Tools Git; credential settings remain untouched"
      else
        plan_add install git system vedup-managed missing system "Install Apple Command Line Tools for system Git"
        PLAN_NEEDS_SUDO=1
      fi
      if inventory_command_exists brew; then
        plan_add keep homebrew homebrew external installed retained "Retain the existing Homebrew installation"
      else
        plan_add install homebrew homebrew vedup-managed missing required "Install Homebrew non-interactively"
        PLAN_NEEDS_SUDO=1
      fi
      for formula in stow tmux btop eza; do plan_macos_formula "$formula"; done
      [[ "$ARCH" == x64 ]] && for formula in fd git-delta; do plan_macos_formula "$formula"; done
    else
      case "$PLATFORM_ADAPTER" in
        ubuntu) for package in build-essential ca-certificates curl git perl stow tmux unzip xz-utils zsh; do plan_linux_package "$package"; done ;;
        amazon)
          for package in gcc gcc-c++ make ca-certificates curl findutils git perl tar gzip unzip xz zsh tmux; do plan_linux_package "$package"; done
          if inventory_command_exists stow; then
            plan_add keep cli:stow amazon "$(plan_existing_owner cli:stow)" installed compatible "Retain compatible user-local GNU Stow"
          else
            plan_add install cli:stow amazon vedup-managed missing "$STOW_VERSION" "Install missing GNU Stow under ~/.local"
          fi
          ;;
      esac
    fi

    plan_mise_manager
    plan_mise_tools
    [[ "$SKIP_PLUGINS" == 1 ]] || plan_plugins

    if [[ "$OS" == macos ]]; then
      while IFS=$'\t' read -r app_scope app_provider app_identifier app_label app_description; do
        case "$app_provider" in
          formula)
            plan_macos_formula "$app_identifier"
            [ "${app_identifier##*/}" != mas ] || selected_mas_formula=1
            ;;
          cask) plan_macos_cask "$app_identifier" ;;
          mas)
            selected_mas_apps=1
            plan_mas_app "$app_identifier" "$app_label"
            ;;
        esac
      done < <(apps_each_selected)
      if [ "$selected_mas_apps" = 1 ] && [ "$selected_mas_formula" = 0 ]; then plan_macos_formula mas; fi
    fi

    if [[ "$WITH_DOCKER" == 1 && "$OS" == linux ]]; then
      if inventory_command_exists docker; then
        if { command -v systemctl >/dev/null 2>&1 && ! systemctl is-active docker >/dev/null 2>&1; } || \
          { [ "$(id -u)" -ne 0 ] && ! id -nG "$USER" | tr ' ' '\n' | grep -Fxq docker; }; then
          plan_add configure docker system "$(plan_existing_owner docker)" installed configured "Enable Docker and ensure the selected user has access"
          PLAN_NEEDS_SUDO=1
        else
          plan_add keep docker system "$(plan_existing_owner docker)" installed retained "Retain installed Docker Engine"
        fi
      else
        plan_add install docker system vedup-managed missing required "Install Docker Engine without a general system upgrade"
        PLAN_NEEDS_SUDO=1
      fi
    fi
  fi

  plan_dotfiles

  if [[ "$OS" == macos && "$APPLY_MACOS_DEFAULTS" == 1 && "$DOTFILES_ONLY" != 1 ]]; then
    macos_check_args=(--check)
    [ "$MINIMAL_DOCK" = 1 ] && macos_check_args+=(--minimal-dock)
    [ "$KEYBOARD_SHORTCUTS" = 1 ] && macos_check_args+=(--keyboard-shortcuts)
    [ "$EXPERIMENTAL_MACOS_DEFAULTS" = 1 ] && macos_check_args+=(--experimental)
    if [[ "$(uname -s)" == Darwin ]] && "$REPO_ROOT/dotfiles/macos/setup-commands.sh" "${macos_check_args[@]}" >/dev/null 2>&1; then
      plan_add keep macos-preferences defaults vedup-managed synchronized desired "Tracked macOS preferences were already synchronized"
    else
      plan_add configure macos-preferences defaults vedup-managed current desired "Apply only differing preferences with rollback metadata"
    fi
  fi

  if [[ "$CHANGE_SHELL" == 1 ]]; then
    current_login_shell="${SHELL:-}"
    if [ "$OS" = linux ] && command -v getent >/dev/null 2>&1; then current_login_shell="$(getent passwd "$USER" | awk -F: '{print $7}')"
    elif [ "$OS" = macos ] && command -v dscl >/dev/null 2>&1; then current_login_shell="$(dscl . -read "/Users/$USER" UserShell 2>/dev/null | awk '{print $2}')"; fi
    if inventory_command_exists zsh && command -v zsh >/dev/null 2>&1 && [[ "$current_login_shell" == "$(command -v zsh)" ]]; then
      plan_add keep login-shell chsh external zsh zsh "Zsh is already the login shell"
    else
      plan_add configure login-shell chsh vedup-managed current zsh "Change the login shell to Zsh"
      PLAN_NEEDS_SUDO=1
    fi
  else
    plan_add keep login-shell chsh external current current "Leave the login shell unchanged"
  fi

  if [ -f "$HOME/.local/bin/vedup" ] && grep -Fqx '# vedup-managed-launcher-v2' "$HOME/.local/bin/vedup" 2>/dev/null; then
    plan_add keep vedup-command launcher vedup-managed installed current "Vedup command launcher is available on PATH"
  elif [ ! -e "$HOME/.local/bin/vedup" ] && [ ! -L "$HOME/.local/bin/vedup" ]; then
    plan_add configure vedup-command launcher vedup-managed missing current "Install the stable Vedup command launcher"
  elif plan_previous_vedup_command "$HOME/.local/bin/vedup"; then
    plan_add configure vedup-command launcher vedup-managed previous current "Replace an older Vedup dispatcher with the stable launcher"
  else
    plan_add review vedup-command launcher unmanaged-conflict present current \
      "Preserve the existing ~/.local/bin/vedup path; move it aside before Vedup manages this command"
  fi

  if type choices_match_file >/dev/null 2>&1 && choices_match_file "$VEDUP_CHOICES_FILE"; then
    plan_add keep application-choices state vedup-managed saved selected "Saved setup and application choices are current"
  else
    plan_add configure application-choices state vedup-managed current selected "Save the selected setup and application choices"
  fi

  plan_retain_unselected_resources
}

plan_retain_unselected_resources() {
  local previous_action resource provider owner current desired description base_resource retained_resource
  [ -f "$VEDUP_RESOURCES_FILE" ] || return 0
  while IFS=$'\t' read -r previous_action resource provider owner current desired description; do
    [ -n "$resource" ] || continue
    base_resource="${resource#retained:}"
    awk -F '\t' -v resource="$base_resource" '$2 == resource { found=1 } END { exit !found }' "$PLAN_FILE" && continue
    retained_resource="retained:$base_resource"
    plan_add keep "$retained_resource" "$provider" "$owner" installed unselected \
      "Retained unselected $base_resource; remove it manually if it is no longer wanted"
  done < "$VEDUP_RESOURCES_FILE"
}

plan_has_action_for_provider() {
  local provider="$1" action id row_provider rest
  [[ -f "$PLAN_FILE" ]] || return 1
  while IFS=$'\t' read -r action id row_provider rest; do
    [[ "$row_provider" == "$provider" ]] || continue
    case "$action" in install|update|configure|conflict) return 0 ;; esac
  done < "$PLAN_FILE"
  return 1
}

plan_has_action_for_resource() {
  local wanted="$1" action resource rest
  while IFS=$'\t' read -r action resource rest; do
    [[ "$resource" == "$wanted" ]] || continue
    case "$action" in install|update|configure|conflict) return 0 ;; esac
  done < "$PLAN_FILE"
  return 1
}

plan_has_action_for_prefix() {
  local wanted="$1" action resource rest
  while IFS=$'\t' read -r action resource rest; do
    case "$resource" in "$wanted"*) ;; *) continue ;; esac
    case "$action" in install|update|configure|conflict) return 0 ;; esac
  done < "$PLAN_FILE"
  return 1
}

plan_has_action_for_any_resource() {
  local resource
  for resource in "$@"; do plan_has_action_for_resource "$resource" && return 0; done
  return 1
}

plan_print() {
  printf 'Workflow: %s\n' "$PLAN_WORKFLOW"
  printf 'Install: %s  Update: %s  Configure: %s  Unchanged: %s  Review: %s  Conflicts: %s\n' \
    "$PLAN_INSTALL_COUNT" "$PLAN_UPDATE_COUNT" "$PLAN_CONFIGURE_COUNT" "$PLAN_KEEP_COUNT" "$PLAN_REVIEW_COUNT" "$PLAN_CONFLICT_COUNT"
  if [[ "${1:-summary}" == details ]]; then
    awk -F '\t' '{ printf "%-10s %-30s %-16s %s\n", $1, $2, $4, $7 }' "$PLAN_FILE"
  fi
}
