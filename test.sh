#!/bin/sh
# `swift test` puro falha nesta máquina (CommandLineTools sem Xcode): o
# _Testing_Foundation.framework do CLT vem sem Modules, então `import Testing`
# quebra no cross-import overlay. Estes flags apontam o framework e desligam o
# overlay. Aceita argumentos extras (ex.: ./test.sh --filter ULID).
FRAMEWORKS=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
exec swift test \
  -Xswiftc -F -Xswiftc "$FRAMEWORKS" \
  -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays \
  -Xlinker -F -Xlinker "$FRAMEWORKS" \
  -Xlinker -rpath -Xlinker "$FRAMEWORKS" \
  "$@"
