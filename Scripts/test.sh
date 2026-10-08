#!/bin/zsh
set -euo pipefail
script_dir=${0:A:h}
cd "${script_dir:h}"
swift_compiler=$(xcrun --find swiftc)
testing_plugin="${swift_compiler:h}/../lib/swift/host/plugins/testing/libTestingMacros.dylib"
flags=(--enable-swift-testing)
# Swift 6.4 swiftbuild can omit this plugin from incremental test compilation.
if [[ -f "$testing_plugin" ]]; then
  flags+=(-Xswiftc -load-plugin-library -Xswiftc "$testing_plugin")
fi
swift test "${flags[@]}"
(cd Bridge/Claude && node --test bridge.test.mjs)
