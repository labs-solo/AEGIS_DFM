#!/bin/bash
set -e
changed=0
for mmd in diagrams/*.mmd; do
  [ -e "$mmd" ] || continue
  svg="docs/img/$(basename "$mmd" .mmd).svg"
  if [ ! -f "$svg" ] || [ "$mmd" -nt "$svg" ]; then
    echo "Diagram $svg stale or missing" >&2
    changed=1
  fi
done
exit $changed
