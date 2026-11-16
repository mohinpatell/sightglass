#!/bin/sh
# Command Line Tools ship Swift Testing outside the default search path, and their
# Testing+Foundation overlay has no module, so that overlay is turned off.
F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
exec swift test -Xswiftc -F -Xswiftc "$F" -Xlinker -F -Xlinker "$F" -Xlinker -rpath -Xlinker "$F" \
    -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays "$@"
