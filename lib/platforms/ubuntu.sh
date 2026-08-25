#!/usr/bin/env bash

platform_prepare() {
  :
}

ubuntu_missing_packages() {
  local package
  for package in "$@"; do
    inventory_package_installed ubuntu "$package" || printf '%s\n' "$package"
  done
}

ubuntu_install_missing() {
  local package
  local -a missing=()
  while IFS= read -r package; do [ -n "$package" ] && missing+=("$package"); done < <(ubuntu_missing_packages "$@")
  [ "${#missing[@]}" -gt 0 ] || return 0
  retry_command 3 2 sudo_run apt-get update
  retry_command 3 2 sudo_run apt-get install -y --no-upgrade "${missing[@]}"
}

platform_install_foundations() {
  ubuntu_install_missing \
    build-essential ca-certificates curl git perl stow tmux unzip xz-utils zsh
}

platform_install_workstation() { :; }

platform_install_docker() {
  ubuntu_install_missing docker.io
  if apt-cache show docker-compose-v2 >/dev/null 2>&1; then
    ubuntu_install_missing docker-compose-v2
  else
    ubuntu_install_missing docker-compose
  fi
  if ! systemctl is-enabled docker >/dev/null 2>&1 || ! systemctl is-active docker >/dev/null 2>&1; then
    sudo_run systemctl enable --now docker
  fi
  if [ "$(id -u)" -ne 0 ] && ! id -nG "$USER" | tr ' ' '\n' | grep -Fxq docker; then sudo_run usermod -aG docker "$USER"; fi
}

platform_install_aws_dependencies() { :; }
