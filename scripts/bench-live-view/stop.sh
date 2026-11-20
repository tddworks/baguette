#!/bin/zsh
# Stops everything start.sh launched.
RUN=${0:a:h}/.run
for name in bridge serve mediamtx proxy http; do
  [[ -f $RUN/$name.pid ]] || continue
  pid=$(cat $RUN/$name.pid)
  pkill -P $pid 2>/dev/null   # the bridge's pipeline: tail, baguette stream, python3, ffmpeg
  kill $pid 2>/dev/null
  rm -f $RUN/$name.pid
done
echo stopped
