# Create a directory, enter it, and open either a requested file or the folder.
mkcd-vim() {
  if [[ $# -lt 1 || $# -gt 2 ]]; then
    print -u2 "usage: mkcd-vim <directory> [file]"
    return 2
  fi
  mkdir -p -- "$1" || return
  cd -- "$1" || return
  nvim "${2:-.}"
}
