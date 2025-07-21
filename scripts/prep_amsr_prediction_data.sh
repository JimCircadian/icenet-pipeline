#!/usr/bin/bash -l

source ENVS
source scripts/pipeline_cmds.sh
conda activate $ICENET_CONDA

set -o pipefail
set -eu

HEMI="$1"
FORECAST_NAME="$2"
FORECAST_START=${3:-"2025-01-01"}
FORECAST_END=${4:-${FORECAST_START}}
DRY=${5:-0}

INPUT_START_DATE=$( date --date="${FORECAST_START} - `expr $LAG + 2` ${DATA_FREQUENCY}s" +%F )
INPUT_END_DATE=$( date --date="${FORECAST_END} - 1 ${DATA_FREQUENCY}s" +%F)

if [ $DATA_FREQUENCY == "month" ]; then
  # FIXME: This is horrible, use a non-bash method
  INPUT_END_DATE=$( date --date="${FORECAST_END} + 1 day" +%F )
  INPUT_END_DATE=$( date --date="${INPUT_END_DATE} - 1 month" +%F )
  INPUT_END_DATE=$( date --date="${INPUT_END_DATE} - 1 day" +%F )
fi

CONFIG_SUFFIX="${FORECAST_NAME}.${HEMI}.json"

DATASET_NAME=`basename $( pwd )`"_${HEMI}"
SOURCE_CONFIG_NAME="dataset_config.${DATASET_NAME}.json"

##
# TODO: Usable as is for training, but for prediction we need to restrict this to relevant activities and dates
#   ./run_prediction.sh fc.09_12.2024 amsr_6k_6m_120125.south south

# Forecast dates are the FIRST date of SIC you expect, so we download and prepare from t-1 onwards


# download-toolbox integration
# This updates our source
pipeline_run download_amsr2 --config-path data.prediction.amsr2.${CONFIG_SUFFIX} $DATA_ARGS $HEMI $INPUT_START_DATE $INPUT_END_DATE $AMSR2_VAR_ARGS
pipeline_run download_cds -i era5 --config-path data.prediction.era5.${CONFIG_SUFFIX} $DATA_ARGS $HEMI $INPUT_START_DATE $INPUT_END_DATE $ERA5_VAR_ARGS

FORECAST_DATASET="prediction.${FORECAST_NAME}.${HEMI}"
LOADER_CONFIGURATION="loader.${FORECAST_DATASET}.json"

# Creates our LOADER_CONFIGURATION file
pipeline_run preprocess_loader_init -v $FORECAST_DATASET
pipeline_run preprocess_add_mask -v $FORECAST_DATASET data.prediction.amsr2.${CONFIG_SUFFIX} land "icenet.data.masks.nsidc:Masks"

pipeline_run preprocess_regrid -v \
  -c proc.prediction.era5.${CONFIG_SUFFIX} \
  -sn "prediction" -ss $INPUT_START_DATE -se $INPUT_END_DATE -sh $LAG \
  data.prediction.era5.${CONFIG_SUFFIX} ref.amsr2.${HEMI}.nc ${FORECAST_NAME}_era5

pipeline_run preprocess_dataset $PROC_ARGS_ERA5 -v \
  -r processed/${TRAIN_DATA_NAME}.${DATA_FREQUENCY}.${HEMI}_era5 \
  -sn "prediction" -ss "$FORECAST_START" -se "$FORECAST_END" -sh $LAG \
  -i "icenet.data.processors.cds:ERA5PreProcessor" \
  proc.prediction.era5.${CONFIG_SUFFIX} ${FORECAST_NAME}_era5

pipeline_run preprocess_dataset $PROC_ARGS_SIC -v \
  -r processed/${TRAIN_DATA_NAME}.${DATA_FREQUENCY}.${HEMI}_amsr \
  -sn "prediction" -ss "$FORECAST_START" -se "$FORECAST_END" -sh $LAG \
  -i "icenet.data.processors.amsr:AMSR2PreProcessor" \
  data.prediction.amsr2.${CONFIG_SUFFIX} ${FORECAST_NAME}_amsr2

pipeline_run preprocess_add_processed -v $FORECAST_DATASET processed.${FORECAST_NAME}_amsr2.json processed.${FORECAST_NAME}_era5.json

pipeline_run preprocess_add_channel -v $FORECAST_DATASET data.prediction.amsr2.${CONFIG_SUFFIX} sin "icenet.data.meta:SinProcessor"
pipeline_run preprocess_add_channel -v $FORECAST_DATASET data.prediction.amsr2.${CONFIG_SUFFIX} cos "icenet.data.meta:CosProcessor"
pipeline_run preprocess_add_channel -v $FORECAST_DATASET data.prediction.amsr2.${CONFIG_SUFFIX} land_map "icenet.data.masks.nsidc:Masks"

pipeline_run icenet_dataset_create -v -c -p -ob $BATCH_SIZE -fl $FORECAST_LENGTH $LOADER_CONFIGURATION $FORECAST_DATASET

FIRST_DATE=${PLOT_DATE:-`cat ${LOADER_CONFIGURATION} | jq -r '.sources[.sources|keys[0]].splits.prediction[0]'`}
pipeline_run icenet_plot_input -p -v dataset_config.${FORECAST_DATASET}.json $FIRST_DATE ./plots/prediction_input.${HEMI}.${FIRST_DATE}.png

