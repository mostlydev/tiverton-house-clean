# Private Surface Mirror

This directory is mounted directly into pod containers at the same absolute path.

Host path and runtime path are both `<repo-root>/storage/private`, with one subtree per agent.

Tracked files here should stay limited to structure and documentation. Live agent memory and notes remain on disk for the pod but are gitignored.
