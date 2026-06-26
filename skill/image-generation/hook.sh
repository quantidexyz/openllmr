#!/usr/bin/env bash
# UserPromptSubmit hook — suggests /image-generation when the user asks for a visual.
set -euo pipefail

PROMPT=$(cat)
[ -z "$PROMPT" ] && exit 0

case "$PROMPT" in
    *[Dd]raw*|*[Ii]mage*|*[Pp]icture*|*[Ii]llustration*|*[Ii]llustrate*|*[Ii]con*|*[Bb]anner*|*[Ll]ogo*|*[Pp]hoto*|*[Rr]ender*|*[Ss]ketch*|*[Pp]ortrait*|*[Dd]iagram*|*[Pp]oster*|*[Tt]humbnail*|*[Ww]allpaper*|*[Aa]rtwork*|*[Pp]ainting*|*[Vv]isual*|*[Ii]nfographic*|*[Ss]creenshot*|*[Aa]vatar*|*[Cc]over*\ [Aa]rt*|*"generate an image"*|*"generate a picture"*|*"make an image"*|*"make a picture"*|*"create an image"*|*"create a picture"*|*"show me a"*\ *[Pp]icture*)
        echo "Tip: Use /image-generation for visuals. Example: /image-generation red cube on white background"
        ;;
esac
exit 0
