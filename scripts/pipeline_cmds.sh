function init_pipeline_run {
  SUFFIX="pipeline"
  [ ! -z $DATA_FREQUENCY ] && [ ! -z $HEMI ] && SUFFIX="${DATA_FREQUENCY}.${HEMI}"
  _PIPELINE_LOG_NAME=logs/commands.${SUFFIX}.log

  [ ! -d logs ] && mkdir -p logs
  if [ -f $_PIPELINE_LOG_NAME ]; then
    rm $_PIPELINE_LOG_NAME
  fi
  return 0
}

function pipeline_run {
  COMMAND="$@"

  _PIPELINE_LOG_NAME=${_PIPELINE_LOG_NAME:-}
  if [ -z $_PIPELINE_LOG_NAME ]; then
    init_pipeline_run
  fi

  echo -e "$COMMAND\n"
  echo -e "$COMMAND\n" >> $_PIPELINE_LOG_NAME
  if [ ! ${DRY:+1} ] || [ $DRY -eq 0 ]; then
    $COMMAND
  fi
}