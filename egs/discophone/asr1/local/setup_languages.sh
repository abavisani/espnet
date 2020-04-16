#!/bin/bash

# Copyright 2020 Johns Hopkins University (Piotr Żelasko)
# Copyright 2018 Johns Hopkins University (Matthew Wiesner)
#  Apache 2.0  (http://www.apache.org/licenses/LICENSE-2.0)

. ./path.sh
. ./cmd.sh
. ./conf/lang.conf

langs="101 102 103 104 105 106 202 203 204 205 206 207 301 302 303 304 305 306 401 402 403"
recog="107 201 307 404"
FLP=true

# GlobalPhone related options
gp_path="/export/corpora5/GlobalPhone"
gp_langs="Arabic Czech French Korean Mandarin Spanish Thai"
gp_recog="Arabic Czech French Korean Mandarin Spanish Thai"
gp_romanized=false
ipa_transcript=false

. ./utils/parse_options.sh

set -euo pipefail

echo "Stage 0: Prepare GlobalPhone"

all_gp_langs=""
for l in $(cat <(echo ${gp_langs}) <(echo ${gp_recog}) | tr " " "\n" | sort -u); do
  all_gp_langs="${l} ${all_gp_langs}"
done
all_gp_langs=${all_gp_langs%% }

echo " --------------------------------------------"
echo "Languagues: ${all_gp_langs}"

# DEPENDENCIES

# We need this to decode GP audio format
local/install_shorten.sh

if command -v phonetisaurus-g2pfst; then
  echo "Phonetisaurus found!"
else
  echo "phonetisaurus-g2pfst not found - install it via espnet/tools/kaldi/tools/extras/install_phonetisaurus.sh"
  exit 1
fi

# G2P pretrained models
if [ ! -d g2ps ]; then
  git clone https://github.com/uiuc-sst/g2ps
fi

ipa_transcript_opt=
if $ipa_transcript; then
  ipa_transcript_opt="--substitute-text"
fi

# GLOBALPHONE

if [ "$gp_langs" ] || [ "$gp_recog" ]; then
  extra_args=
  if $gp_romanized; then
    extra_args="--romanized"
  fi
  python3 local/prepare_globalphone.py \
    --gp-path $gp_path \
    --output-dir data/GlobalPhone \
    --languages $all_gp_langs \
    $extra_args

  for l in $gp_langs; do
    for split in train dev eval; do
      data_dir=data/GlobalPhone/gp_${l}_${split}
      echo "(GP) Processing: $data_dir"
      utils/fix_data_dir.sh $data_dir
      utils/utt2spk_to_spk2utt.pl $data_dir/utt2spk > $data_dir/spk2utt
      local/get_utt2dur.sh --read-entire-file true $data_dir
      python3 -c "for line in open('$data_dir/utt2dur'):
      utt, dur = line.strip().split()
      print(f'{utt} {utt} 0.00 {float(dur):.2f}')
  " > $data_dir/segments
      python3 local/prepare_lexicons.py \
        --lang $l \
        --data-dir $data_dir \
        --g2p-models-dir g2ps/models \
        $ipa_transcript_opt
      utils/validate_data_dir.sh --no-feats $data_dir
    done
  done
fi

# Now onto Babel

all_langs=""
for l in $(cat <(echo ${langs}) <(echo ${recog}) | tr " " "\n" | sort -u); do
  all_langs="${l} ${all_langs}"
done
all_langs=${all_langs%% }

# Save top-level directory
cwd=$(utils/make_absolute.sh $(pwd))
echo "Stage 1: Setup Language Specific Directories"

echo " --------------------------------------------"
echo "Languagues: ${all_langs}"

if [ "$langs" ] || [ "$recog" ]; then
  # Basic directory prep
  for l in ${all_langs}; do
    [ -d data/${l} ] || mkdir -p data/${l}
    cd data/${l}

    ln -sf ${cwd}/local .
    for f in ${cwd}/{utils,steps,conf}; do
      link=`make_absolute.sh $f`
      ln -sf $link .
    done

    cp ${cwd}/cmd.sh .
    cp ${cwd}/path.sh .
    sed -i 's/\.\.\/\.\.\/\.\./\.\.\/\.\.\/\.\.\/\.\.\/\.\./g' path.sh

    cd ${cwd}
  done

  # Prepare language specific data
  for l in ${all_langs}; do
    (
      cd data/${l}
      ./local/prepare_data.sh --FLP ${FLP} ${l}
      cd ${cwd}

      for split in train dev eval; do
        python3 local/prepare_lexicons.py \
          --lang $l \
          --data-dir data/${l}/data/${split}_${l} \
          --g2p-models-dir g2ps/models \
          $ipa_transcript_opt
      done
    ) &
  done
  wait
fi

# Combine all language specific training directories and generate a single
# lang directory by combining all language specific dictionaries
train_dirs=""
dev_dirs=""
for l in ${langs}; do
  train_dirs="data/${l}/data/train_${l} ${train_dirs}"
done

for l in ${recog}; do
  dev_dirs="data/${l}/data/dev_${l} ${dev_dirs}"
done

# Now add GlobalPhone
for l in ${gp_langs}; do
  train_dirs="data/GlobalPhone/gp_${l}_train ${train_dirs}"
done

for l in ${gp_recog}; do
  dev_dirs="data/GlobalPhone/gp_${l}_dev ${dev_dirs}"
done

./utils/combine_data.sh data/train ${train_dirs}
./utils/combine_data.sh data/dev ${dev_dirs}

for l in ${recog}; do
  target_link=${cwd}/data/eval_${l}
  if [ ! -L $target_link ]; then
    ln -s ${cwd}/data/${l}/data/eval_${l} $target_link
  fi
done

for l in ${gp_recog}; do
  target_link=${cwd}/data/eval_${l}
  if [ ! -L $target_link ]; then
    ln -s ${cwd}/data/GlobalPhone/gp_${l}_eval $target_link
  fi
done
