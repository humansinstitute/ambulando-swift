#!/bin/zsh
# Xcode build phase (app targets): builds the board editor if needed and copies it into the app as
# BoardEditor.bundle. The page is loaded only from inside the app (BoardEditorView), never from the network.
set -euo pipefail
${0:A:h}/build-board-editor.sh
dest="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/BoardEditor.bundle"
mkdir -p "$dest"
rsync -a --delete --exclude .build-stamp "${0:A:h:h}/BoardEditor/dist/" "$dest/"
