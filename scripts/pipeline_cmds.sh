function pipeline_run {
  COMMAND="$@"
  COMMAND_PREFIX=""
  if [ ! ${DRY:+1} ] || [ $DRY -eq 0 ]; then
    COMMAND_PREFIX="DRY "
  fi
  echo -e "\n\n$COMMAND_PREFIX Executing: $COMMAND\n\n"
  echo -e "\n\n$COMMAND_PREFIX Executing: $COMMAND\n\n" >>logs/commands.log
  if [ ! ${DRY:+1} ] || [ $DRY -eq 0 ]; then
    $COMMAND
  fi
}