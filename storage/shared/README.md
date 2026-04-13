# Shared Surface Mirror

This directory is mounted directly into pod containers at the same absolute path.

Host path and runtime path are both `<repo-root>/storage/shared`.

Tracked files here should stay limited to structure, templates, and documentation. Generated caches, research output, reports, and other runtime artifacts remain on disk for the pod but are gitignored.
