#!/usr/bin/bash -l

source ENVS
conda activate $ICENET_CONDA

set -o pipefail
set -eu

if [ $# -lt 1 ] || [ "$1" == "-h" ]; then
    echo "Usage $0 <hemisphere> [download=0|1]"
    exit 1
fi

HEMI="$1"
DOWNLOAD=${2:-0}

CONFIG_SUFFIX="${DATA_FREQUENCY}.${HEMI}.json"
OSISAF_DATA="data.osisaf"
OSISAF_PROC="proc.osisaf"
ERA5_DATA="data.era5"
ERA5_PROC="proc.era5"

# download-toolbox integration
# This updates our source
if [ $DOWNLOAD -eq 1 ]; then
  # We use --config-path to localise the generation of config to the pipeline rather than the dataset
  download_osisaf --config-path ${OSISAF_DATA}.${CONFIG_SUFFIX} $DATA_ARGS $HEMI $OSISAF_DATES $OSISAF_VAR_ARGS
  download_era5 --config-path ${ERA5_DATA}.${CONFIG_SUFFIX} $DATA_ARGS $HEMI $ERA5_DATES $ERA5_VAR_ARGS
fi 2>&1 | tee logs/download.osisaf_training.log

##
# OSISAF ground truth with ERA5
#

PROCESSED_DATASET="${TRAIN_DATA_NAME}.${DATA_FREQUENCY}.${HEMI}"

## Workflow
preprocess_loader_init -v $PROCESSED_DATASET
preprocess_add_mask -v $PROCESSED_DATASET $OSISAF_DATA.$CONFIG_SUFFIX land "icenet.data.masks.osisaf:Masks"
preprocess_add_mask -v $PROCESSED_DATASET $OSISAF_DATA.$CONFIG_SUFFIX polarhole "icenet.data.masks.osisaf:Masks"
preprocess_add_mask -v $PROCESSED_DATASET $OSISAF_DATA.$CONFIG_SUFFIX active_grid_cell "icenet.data.masks.osisaf:Masks"

# We CAN supply splits and lead / lag to prevent unnecessarily large copies of datasets
# or interpolation of time across huge spans
# TODO: temporal interpolation limiting
preprocess_missing_time \
  -c ./interp.osisaf.$CONFIG_SUFFIX \
  -n siconca -v $OSISAF_DATA.$CONFIG_SUFFIX $OSISAF_PROC

preprocess_missing_spatial \
  -m processed.masks.osisaf.${HEMI}.json -mp land,inactive_grid_cell,polarhole \
  -n siconca -v interp.osisaf.$CONFIG_SUFFIX

preprocess_dataset $PROC_ARGS_SIC -v \
  -ps "train" -sn "train,val,test" -ss "$TRAIN_START,$VAL_START,$TEST_START" -se "$TRAIN_END,$VAL_END,$TEST_END" \
  -i "icenet.data.processors.osisaf:SICPreProcessor" \
  -sh $LAG -st $FORECAST_LENGTH \
  interp.osisaf.$CONFIG_SUFFIX ${PROCESSED_DATASET}_osisaf

HEMI_SHORT="nh"
[ $HEMI == "south" ] && HEMI_SHORT="sh"

icenet_generate_ref_osisaf -v data/masks.osisaf/ice_conc_${HEMI_SHORT}_ease2-250_cdr-v2p0_200001021200.nc

# Creates a new version of the dataset - processed_data/ so include any lag
# The resulting configuration doesn't care about splits, so it won't carry forward
REGRID_TRAIN_START=`date --date="$TRAIN_START - $LAG $DATA_FREQUENCY" +%F`
REGRID_VAL_START=`date --date="$VAL_START - $LAG $DATA_FREQUENCY" +%F`
REGRID_TEST_START=`date --date="$TEST_START - $LAG $DATA_FREQUENCY" +%F`
preprocess_regrid -v -c ./regrid.era5.$CONFIG_SUFFIX \
  -ps "train" -sn "train,val,test" -ss "$REGRID_TRAIN_START,$REGRID_VAL_START,$REGRID_TEST_START" -se "$TRAIN_END,$VAL_END,$TEST_END" \
  $ERA5_DATA.$CONFIG_SUFFIX ref.osisaf.${HEMI}.nc $ERA5_PROC
preprocess_rotate -n uas,vas -v regrid.era5.$CONFIG_SUFFIX ref.osisaf.${HEMI}.nc

preprocess_dataset $PROC_ARGS_ERA5 -v \
  -ps "train" -sn "train,val,test" -ss "$TRAIN_START,$VAL_START,$TEST_START" -se "$TRAIN_END,$VAL_END,$TEST_END" \
  -i "icenet.data.processors.cds:ERA5PreProcessor" \
  -sh $LAG -st $FORECAST_LENGTH \
  regrid.era5.$CONFIG_SUFFIX ${PROCESSED_DATASET}_era5

preprocess_add_processed -v $PROCESSED_DATASET processed.${PROCESSED_DATASET}_osisaf.json processed.${PROCESSED_DATASET}_era5.json

preprocess_add_channel -v $PROCESSED_DATASET interp.osisaf.$CONFIG_SUFFIX sin "icenet.data.meta:SinProcessor"
preprocess_add_channel -v $PROCESSED_DATASET interp.osisaf.$CONFIG_SUFFIX cos "icenet.data.meta:CosProcessor"
preprocess_add_channel -v $PROCESSED_DATASET interp.osisaf.$CONFIG_SUFFIX land_map "icenet.data.masks.osisaf:Masks"

LOADER_CONFIGURATION="loader.${PROCESSED_DATASET}.json"
DATASET_NAME=`basename $( pwd )`"_${HEMI}"

icenet_dataset_create -v -c -p -ob $BATCH_SIZE -w $WORKERS -fl $FORECAST_LENGTH $LOADER_CONFIGURATION $DATASET_NAME

# For when we don't have the preceding data, make sure there's an offset. These will be dropped in generation
LAG_DATE=${PLOT_DATE:-`cat ${LOADER_CONFIGURATION} | jq '.sources[.sources|keys[0]].splits.train['$LAG']' | tr -d '"'`}
mkdir -p plots
icenet_plot_input -p -v dataset_config.${DATASET_NAME}.json ${LAG_DATE} ./plots/input.${HEMI}.${LAG_DATE}.png
icenet_plot_input --outputs -v dataset_config.${DATASET_NAME}.json ${LAG_DATE} ./plots/outputs.${HEMI}.${LAG_DATE}.png
icenet_plot_input --weights -v dataset_config.${DATASET_NAME}.json ${LAG_DATE} ./plots/weights.${HEMI}.${LAG_DATE}.png

icenet_dataset_create -v -p -ob $BATCH_SIZE -w $WORKERS -fl $FORECAST_LENGTH $LOADER_CONFIGURATION $DATASET_NAME
