_kcrun_complete() {
  local cur prev i separator_index=-1
  cur=${COMP_WORDS[COMP_CWORD]}
  prev=${COMP_WORDS[COMP_CWORD-1]}

  for ((i = 1; i < COMP_CWORD; i++)); do
    if [[ ${COMP_WORDS[i]} == -- ]]; then
      separator_index=$i
      break
    fi
  done

  if (( separator_index >= 0 )); then
    if (( COMP_CWORD == separator_index + 1 )); then
      COMPREPLY=( $(compgen -c -- "$cur") )
    fi
    return 0
  fi

  if [[ $prev == --env ]]; then
    compopt +o bashdefault +o default
    return 0
  fi

  COMPREPLY=( $(compgen -W "--env --help -h -- completions" -- "$cur") )
}

complete -o bashdefault -o default -F _kcrun_complete kcrun
