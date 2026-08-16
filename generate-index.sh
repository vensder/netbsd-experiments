#!/usr/bin/env bash

echo "# Document Index" > README.md
find . -type f -name "*.md" ! -name "README.md" | sort | while read -r file; do
    # Find the first line starting with # and strip the '#' symbols
    title=$(grep -m 1 '^# ' "$file" | sed 's/^# //')
    # Fallback to filename if no # heading is found
    if [ -z "$title" ]; then title="${file##*/}"; fi
    echo "* [$title]($file)" >> README.md
done

