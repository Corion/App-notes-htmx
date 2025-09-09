---
created: 2025-02-10T22:06:29Z
labels:
  - notekeeper
pinned: 1
shared:
  demo: Next_steps.markdown
title: 'Next steps'
updated: 2025-05-06T08:46:52Z
---
*   [ ]  Have views for `deleted` and `archived`
*   [ ]  Pop up a note instead of having it as a new screen
*   [ ]  Use a CSS transform so reordering notes gets animated instead of flashing
    *   CSS grid animations cannot/do not support moving elements around in the grid
    *   a JS "manual" animation, recording the absolute positions and then (CSS-)animating between them could work, but would involve CSS
*   [ ]  Infinite scroll for notes instead of loading all notes all the time
*   [ ]  Notes with the attribute "Archived" don't show up on the main (non-filter) screen
    *   maybe the archive should be a filesystem folder?
*   [ ]  Returning from note view should go to the filtered main view
*   [ ]  Background image / header image for notes (?!)
*   [ ]  Continous audio recording
*   [ ]  Continous video recording
*   [ ]  Drawing/whiteboard
*   [ ]  Add "pinned" status maybe per-label
    *   what data structure for the per-label thing?
*   [ ] make date/time search more dynamic
*   [ ] Show number of documents in each bucket (?)