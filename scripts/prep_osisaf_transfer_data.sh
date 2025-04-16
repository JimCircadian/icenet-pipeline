#!/usr/bin/bash -l

OLD_PREFIX=$PREFIX
export PREFIX="RUN_OSI"
source ENVS
source scripts/pipeline_cmds.sh
conda activate $ICENET_CONDA

set -o pipefail
set -eu

if [ $# -lt 2 ] || [ "$1" == "-h" ]; then
    echo "Usage $0 <hemisphere> [download=0|1] [dry=0|1]"
    exit 1
fi

HEMI="$1"
SIC_TYPE="amsr2"
DOWNLOAD=${2:-0}
DRY=${3:-0}

CONFIG_SUFFIX="${DATA_FREQUENCY}.${HEMI}.json"
SIC_TRUTH_DATA="data.$SIC_TYPE"
HEMI_SHORT="nh"
[ $HEMI == "south" ] && HEMI_SHORT="sh"

if [ ! -f ${SIC_TRUTH_DATA}.${CONFIG_SUFFIX} ]; then
  echo "This needs to be run AFTER you've prepared your main run data!"
  exit 1
fi

echo -e "\n=============================================\n"
OSISAF_ID="osisaf"
OSISAF_DATA="data.$OSISAF_ID"
OSISAF_PROC="proc.$OSISAF_ID"

# download-toolbox integration
# This updates our source
if [ $DOWNLOAD -eq 1 ]; then
  pipeline_run download_osisaf --config-path ${OSISAF_DATA}.${CONFIG_SUFFIX} $DATA_ARGS $HEMI $OSISAF_DATES $OSISAF_VAR_ARGS
fi

PROCESSED_DATASET="pretrain.${OSISAF_ID}.${DATA_FREQUENCY}.${HEMI}"
pipeline_run preprocess_loader_init -v $PROCESSED_DATASET

pipeline_run preprocess_add_mask -v $PROCESSED_DATASET $SIC_TRUTH_DATA.$CONFIG_SUFFIX land "icenet.data.masks.nsidc:Masks"

REGRID_TRAIN_START=`date --date="$TRAIN_START - $LAG $DATA_FREQUENCY" +%F`
pipeline_run preprocess_regrid -v -c ./regrid.$OSISAF_DATA.$CONFIG_SUFFIX \
  -ps "train" -sn "train" -ss "$REGRID_TRAIN_START" -se "$TRAIN_END" \
  -cp "icenet.data.processors.osisaf:amsr_coordinate_regrid" \
  -ca `ls data/osisaf/siconca/*/*${HEMI_SHORT}*.nc | head -n 1` \
  $OSISAF_DATA.$CONFIG_SUFFIX ref.${SIC_TYPE}.${HEMI}.nc $OSISAF_PROC

pipeline_run preprocess_dataset $PROC_ARGS_SIC -v \
  -ps "train" -sn "train" -ss "$TRAIN_START" -se "$TRAIN_END" \
  -sh $LAG -st $FORECAST_LENGTH \
  regrid.$OSISAF_DATA.$CONFIG_SUFFIX ${PROCESSED_DATASET}_${OSISAF_DATA}

pipeline_run preprocess_add_processed -v $PROCESSED_DATASET processed.${PROCESSED_DATASET}_${OSISAF_DATA}.json

pipeline_run preprocess_add_channel -v $PROCESSED_DATASET regrid.${OSISAF_DATA}.${CONFIG_SUFFIX} sin "icenet.data.meta:SinProcessor"
pipeline_run preprocess_add_channel -v $PROCESSED_DATASET regrid.${OSISAF_DATA}.${CONFIG_SUFFIX} cos "icenet.data.meta:CosProcessor"
pipeline_run preprocess_add_channel -v $PROCESSED_DATASET regrid.${OSISAF_DATA}.${CONFIG_SUFFIX} land_map "icenet.data.masks.nsidc:Masks"

LOADER_CONFIGURATION="loader.${PROCESSED_DATASET}.json"
DATASET_NAME=`basename $( pwd )`"_pretrain.${OSISAF_ID}.${HEMI}"

pipeline_run icenet_dataset_create -v -c -p -ob $BATCH_SIZE -w $WORKERS -fl $FORECAST_LENGTH $LOADER_CONFIGURATION $DATASET_NAME

if [ ! $DRY ]; then
  LAG_DATE=${PLOT_DATE:-`cat ${LOADER_CONFIGURATION} | jq '.sources[.sources|keys[0]].splits.train['$LAG']' | tr -d '"'`}
else
  OFFSET=""
  if [ $DATA_FREQUENCY == "month" ]; then
    OFFSET=" - 1 day"
  fi
  LAG_DATE=`date --date="$TRAIN_START + $( expr $LAG + 1 ) ${DATA_FREQUENCY}s $OFFSET" +%F`
fi
mkdir -p plots
pipeline_run icenet_plot_input -p -v dataset_config.${DATASET_NAME}.json $LAG_DATE ./plots/input.${OSISAF_ID}.${HEMI}.${LAG_DATE}.png
pipeline_run icenet_plot_input --outputs -v dataset_config.${DATASET_NAME}.json $LAG_DATE ./plots/outputs.${OSISAF_ID}.${HEMI}.${LAG_DATE}.png
pipeline_run icenet_plot_input --weights -v dataset_config.${DATASET_NAME}.json $LAG_DATE ./plots/weights.${OSISAF_ID}.${HEMI}.${LAG_DATE}.png

echo "To cache the dataset, please run:"
echo icenet_dataset_create -v -p -ob $BATCH_SIZE -w $WORKERS -fl $FORECAST_LENGTH $LOADER_CONFIGURATION $DATASET_NAME

# TODO: here is where we nick the val and test splits from the ground truth
#  datasets prepared in the alternative script. icenet_train can then be used
#  with MultiLoaderDataSet or whatever I called it, to pretrain the model
#  prior to the full run (TODO 2: this will need adapting to the OSI -> AMSR recipe)

unset PREFIX
export PREFIX=$OLD_PREFIX

if [ ! ${DRY:+1} ] || [ $DRY -eq 0 ]; then
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
fi