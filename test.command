#!/bin/zsh
set -eu
cd "${0:A:h}"
mkdir -p .build/module-cache dist
swiftc -swift-version 5 -parse-as-library -module-cache-path "$PWD/.build/module-cache" Sources/Feed.swift Sources/Stories.swift Sources/WorldMapData.swift Sources/WorldMap.swift Sources/MapLayers.swift Sources/CameraSources.swift Sources/CameraSnapshots.swift Tests/StoryCheck.swift Tests/FeedCheck.swift -o dist/FeedCheck
dist/FeedCheck "$@"
