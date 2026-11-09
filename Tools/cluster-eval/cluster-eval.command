#!/bin/zsh
# Same-event clustering evaluation (research tool; not part of the app). See docs/evaluation/热点聚类评测.md.
#   zsh Tools/cluster-eval/cluster-eval.command centroid [t]      # recommended method on the labeled fixture
#   zsh Tools/cluster-eval/cluster-eval.command hotness            # what an "N outlets" badge would show
#   zsh Tools/cluster-eval/cluster-eval.command diagnose|baseline|compare|grid|adjudicate
#   zsh Tools/cluster-eval/cluster-eval.command collect <out.json> # fetch a fresh corpus with the app's feed code
#   zsh Tools/cluster-eval/cluster-eval.command candidates|crosspool|labels|seeds|search …   # labeling helpers
set -eu
cd "${0:A:h}/../.."
mkdir -p .build/module-cache .build/cluster-eval
fixture=Tests/Fixtures/cluster-eval
mode=${1:-}
[[ $# -gt 0 ]] && shift
if [[ $mode == collect ]]; then
  swiftc -swift-version 5 -parse-as-library -module-cache-path "$PWD/.build/module-cache" \
    Sources/Feed.swift Sources/Stories.swift Sources/WorldMapData.swift Sources/WorldMap.swift Sources/MapLayers.swift \
    Sources/CameraSources.swift Sources/CameraSnapshots.swift Sources/TitleTranslation.swift \
    Tools/cluster-eval/collect/main.swift -o .build/cluster-eval/collect
  exec .build/cluster-eval/collect "$@"
fi
swiftc -O -module-cache-path "$PWD/.build/module-cache" Tools/cluster-eval/*.swift -o .build/cluster-eval/cluster-eval
case $mode in
  diagnose|baseline|compare|grid|centroid|hotness|adjudicate)
    exec .build/cluster-eval/cluster-eval $mode $fixture/corpus.json $fixture/gold.txt $fixture/pair-labels.tsv "$@" ;;
  *) exec .build/cluster-eval/cluster-eval $mode "$@" ;;
esac
