---
labels: []
title: 'Rules for an HTMX project'
---

# Move all CSS into a common CSS file

HTMX does not update the CSS styles associated with a new page.
Since you cannot really control which page gets reloaded, you will need to
have all styles present on all pages.

# Move all Javascript into a common Javascript file

HTMX does not update the loaded scripts associated with a new page.
Since you cannot really control which page gets reloaded, you will need to
have all functions present on all pages.

The same goes for variables. These also do not necessarily get (re)initialized
when loading a new page. Call [`htmx.onLoad`](https://htmx.org/api/) with your callback function. The
callback gets called on every (partial) page load:

```
    htmx.onLoad(function(elt){
        MyLibrary.init(elt);
    })
```
