function pipeline_run {
  COMMAND="$@"
  echo -e "$COMMAND\n"
  echo -e "$COMMAND\n" >>logs/commands.log
  if [ ! ${DRY:+1} ] || [ $DRY -eq 0 ]; then
    $COMMAND
  fi
}