---
color: '#ffbe6f'
created: 2024-12-31T12:22:13Z
labels: []
pinned: '0'
title: 'Check if we are overwriting a newer version of a note'
updated: 2024-12-31T12:23:16Z
---
If/before we save, check the `updated` timestamp of a note against the `updated` timestamp that is (to be) sent with the update so we don't overwrite changes.

If we detect overwriting, maybe save the changes to a fresh note version?!