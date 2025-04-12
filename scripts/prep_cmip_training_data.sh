#!/usr/bin/bash -l

OLD_PREFIX=$PREFIX
export PREFIX="PRETRAIN_CMIP"
source ENVS
conda activate $ICENET_CONDA

set -o pipefail
set -eu

if [ $# -lt 2 ] || [ "$1" == "-h" ]; then
    echo "Usage $0 <hemisphere> [osisaf|amsr] [download=0|1]"
    exit 1
fi

HEMI="$1"
SIC_TYPE="$2"
SIC_TYPE=${SIC_TYPE,,}  # Make sure we're lowercase
DOWNLOAD=${3:-0}

CONFIG_SUFFIX="${DATA_FREQUENCY}.${HEMI}.json"
SIC_TRUTH_DATA="data.$SIC_TYPE"

if [ ! -f ${SIC_TRUTH_DATA}.${CONFIG_SUFFIX} ]; then
  echo "This needs to be run AFTER you've prepared your main run data!"
  exit 1
fi

for SOURCE in ${!CMIP6_SOURCES[@]}; do
  for MEMBER in ${CMIP6_SOURCES[$SOURCE]}; do
    CMIP_ID="cmip_${SIC_TYPE}.${SOURCE}.${MEMBER}"
    CMIP_DATA="data.$CMIP_ID"
    CMIP_PROC="proc.$CMIP_ID"

    # download-toolbox integration
    # This updates our source
    if [ $DOWNLOAD -eq 1 ]; then
      echo "SOURCE: $SOURCE - MEMBER: $MEMBER"
      COMMAND="download_cmip --config-path ${CMIP_DATA}.${CONFIG_SUFFIX} $DATA_ARGS --source $SOURCE --member $MEMBER $HEMI $CMIP6_DATES $CMIP6_VAR_ARGS $CMIP6_EXCLUDE_NODES"
      echo -e "\n\n$COMMAND\n\n"
      $COMMAND 2>&1 | tee logs/download.cmip_${HEMI}.${SOURCE}.${MEMBER}.log
    fi

    PROCESSED_DATASET="pretrain.${CMIP_ID}.${DATA_FREQUENCY}.${HEMI}"
    preprocess_loader_init -v $PROCESSED_DATASET

    if [ $SIC_TYPE == "osisaf" ]; then
      preprocess_add_mask -v $PROCESSED_DATASET $SIC_TRUTH_DATA.$CONFIG_SUFFIX land "icenet.data.masks.osisaf:Masks"
      preprocess_add_mask -v $PROCESSED_DATASET $SIC_TRUTH_DATA.$CONFIG_SUFFIX polarhole "icenet.data.masks.osisaf:Masks"
      preprocess_add_mask -v $PROCESSED_DATASET $SIC_TRUTH_DATA.$CONFIG_SUFFIX active_grid_cell "icenet.data.masks.osisaf:Masks"
    elif [ $SIC_TYPE == "amsr" ]; then
      preprocess_add_mask -v $PROCESSED_DATASET $SIC_TRUTH_DATA.$CONFIG_SUFFIX land "icenet.data.masks.nsidc:Masks"
    fi

    REGRID_TRAIN_START=`date --date="$TRAIN_START - $LAG $DATA_FREQUENCY" +%F`
    preprocess_regrid -v -c ./regrid.$CMIP_DATA.$CONFIG_SUFFIX \
      -ps "train" -sn "train" -ss "$REGRID_TRAIN_START" -se "$TRAIN_END" \
      $CMIP_DATA.$CONFIG_SUFFIX ref.${SIC_TYPE}.${HEMI}.nc $CMIP_PROC

    preprocess_dataset $PROC_ARGS_CMIP -v \
      -ps "train" -sn "train" -ss "$TRAIN_START" -se "$TRAIN_END" \
      -i "icenet.data.processors.cmip:CMIP6PreProcessor" \
      -sh $LAG -st $FORECAST_LENGTH \
      regrid.$CMIP_DATA.$CONFIG_SUFFIX ${PROCESSED_DATASET}_${CMIP_DATA}

    preprocess_add_processed -v $PROCESSED_DATASET processed.${PROCESSED_DATASET}_${CMIP_DATA}.json

    preprocess_add_channel -v $PROCESSED_DATASET regrid.${CMIP_DATA}.${CONFIG_SUFFIX} sin "icenet.data.meta:SinProcessor"
    preprocess_add_channel -v $PROCESSED_DATASET regrid.${CMIP_DATA}.${CONFIG_SUFFIX} cos "icenet.data.meta:CosProcessor"
    preprocess_add_channel -v $PROCESSED_DATASET regrid.${CMIP_DATA}.${CONFIG_SUFFIX} land_map "icenet.data.masks.osisaf:Masks"

    LOADER_CONFIGURATION="loader.${PROCESSED_DATASET}.json"
    DATASET_NAME=`basename $( pwd )`"_pretrain.${CMIP_ID}.${HEMI}"

    icenet_dataset_create -v -c -p -ob $BATCH_SIZE -w $WORKERS -fl $FORECAST_LENGTH $LOADER_CONFIGURATION $DATASET_NAME

    FIRST_DATE=${PLOT_DATE:-`cat ${LOADER_CONFIGURATION} | jq '.sources[.sources|keys[0]].splits.train[0]' | tr -d '"'`}
    mkdir -p plots
    icenet_plot_input -p -v dataset_config.${DATASET_NAME}.json $FIRST_DATE ./plots/input.${CMIP_ID}.${HEMI}.${FIRST_DATE}.png
    icenet_plot_input --outputs -v dataset_config.${DATASET_NAME}.json $FIRST_DATE ./plots/outputs.${CMIP_ID}.${HEMI}.${FIRST_DATE}.png
    icenet_plot_input --weights -v dataset_config.${DATASET_NAME}.json $FIRST_DATE ./plots/weights.${CMIP_ID}.${HEMI}.${FIRST_DATE}.png

    icenet_dataset_create -v -p -ob $BATCH_SIZE -w $WORKERS -fl $FORECAST_LENGTH $LOADER_CONFIGURATION $DATASET_NAME
  done
done

# TODO: here is where we nick the val and test splits from the ground truth
#  datasets prepared in the alternative script. icenet_train can then be used
#  with MultiLoaderDataSet or whatever I called it, to pretrain the model
#  prior to the full run (TODO 2: this will need adapting to the OSI -> AMSR recipe)

unset PREFIX
export PREFIX=$OLD_PREFIX
source ENVS

# 1. Copy dataset_config.monthly.cmip_osi_north.json, with referred loader configuration
GROUND_TRUTH_DATASET="dataset_config.`basename $( pwd )`_${HEMI}.json"
GROUND_TRUTH_LOADER=`jq -r '.loader_config' $GROUND_TRUTH_DATASET`
PRETRAIN_DATASET="dataset_config.pretrain_eval.`basename $( pwd )`_${HEMI}.json"
PRETRAIN_LOADER="loader.pretrain.${PREFIX,,}.${DATA_FREQUENCY}.${HEMI}.json"

jq --arg loader `realpath $PRETRAIN_LOADER` '.loader_config=$loader | .counts.train = 0' $GROUND_TRUTH_DATASET > $PRETRAIN_DATASET

# 2. Strip out the split train dates from ground truth loader configuration

jq '.sources[].splits.train = [] | .sources[].source_files.train = []' $GROUND_TRUTH_LOADER > $PRETRAIN_LOADER

# 3. TEST with icenet_train
