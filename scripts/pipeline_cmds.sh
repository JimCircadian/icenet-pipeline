function pipeline_run {
  COMMAND="$@"
  SUFFIX=""

  [ ! -z $DATA_FREQUENCY ] && [ ! -z $HEMI ] && SUFFIX="${DATA_FREQUENCY}.${HEMI}."

  echo -e "$COMMAND\n"
  echo -e "$COMMAND\n" >>logs/commands.${SUFFIX}.log
  if [ ! ${DRY:+1} ] || [ $DRY -eq 0 ]; then
    $COMMAND
  fi
}