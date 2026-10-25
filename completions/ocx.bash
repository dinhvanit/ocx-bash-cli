# Bash completion cho ocx.
# Cài tự động bởi install.sh vào ~/.local/share/bash-completion/completions/ocx.

_ocx() {
  local cur prev words cword
  _init_completion 2>/dev/null || {
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"
  }

  local commands="start tui run models model fallback vpn doctor version help"
  local model_subs="list current switch use next auto fallback help"
  local vpn_subs="list regions import use next rotate random region use-region auto test status disconnect stop log logs help"

  if (( COMP_CWORD == 1 )); then
    COMPREPLY=( $(compgen -W "$commands" -- "$cur") )
    return 0
  fi

  case "${COMP_WORDS[1]}" in
    model)
      if (( COMP_CWORD == 2 )); then
        COMPREPLY=( $(compgen -W "$model_subs" -- "$cur") )
      fi
      ;;
    vpn)
      if (( COMP_CWORD == 2 )); then
        COMPREPLY=( $(compgen -W "$vpn_subs" -- "$cur") )
        return 0
      fi
      case "${COMP_WORDS[2]}" in
        use|test)
          if (( COMP_CWORD == 3 )); then
            local names
            # Cột PROFILE chứa region/name; lấy field có dấu / để không phụ
            # thuộc vào cột đánh dấu * (field có thể bị awk bỏ qua).
            names="$(ocx vpn list 2>/dev/null | awk 'NR>1 {for (i=1; i<=NF; i++) if ($i ~ /\//) {print $i; break}}')"
            COMPREPLY=( $(compgen -W "$names" -- "$cur") )
          fi
          ;;
        region|use-region)
          if (( COMP_CWORD == 3 )); then
            COMPREPLY=( $(compgen -W "vn jp us sg kr tw hk th my id ph gb de fr nl ca au in misc" -- "$cur") )
          fi
          ;;
      esac
      ;;
    run)
      COMPREPLY=( $(compgen -W "-m --model --fallback --help" -- "$cur") )
      ;;
    start)
      COMPREPLY=( $(compgen -W "--mini --auto --dir --dry-run --force --help" -- "$cur") )
      ;;
  esac
  return 0
}

complete -F _ocx ocx
