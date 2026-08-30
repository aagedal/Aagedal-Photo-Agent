#!/bin/zsh

set -euo pipefail

script_directory=${0:A:h}
repository_root=${script_directory:h}
iteration_count=${APA_SLOW_VOLUME_GATE_ITERATIONS:-20}
derived_data_path=${APA_SLOW_VOLUME_GATE_DERIVED_DATA:-/private/tmp/aagedal-slow-volume-responsiveness}

if ! [[ ${iteration_count} =~ '^[0-9]+$' ]] || (( iteration_count < 1 || iteration_count > 200 )); then
    print -u2 'APA_SLOW_VOLUME_GATE_ITERATIONS must be an integer from 1 through 200.'
    exit 64
fi

iteration_arguments=()
if (( iteration_count > 1 )); then
    iteration_arguments=(-test-iterations ${iteration_count})
fi

cd ${repository_root}

xcodebuild test \
    -project 'Aagedal Photo Agent.xcodeproj' \
    -scheme 'Aagedal Photo Agent Tests' \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath ${derived_data_path} \
    -parallel-testing-enabled NO \
    ${iteration_arguments} \
    -only-testing:'Aagedal Photo Agent Tests/SlowVolumeResponsivenessGateTests'
