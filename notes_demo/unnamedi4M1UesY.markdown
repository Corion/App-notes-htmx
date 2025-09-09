---
color: '#ff8080'
created: 2025-01-23T09:22:19Z
labels:
  - Bug
  - done
title: 'FORM Redirect does not use url_for()'
updated: 2025-01-23T21:08:36Z
---
```
<form id="form-filter-instant" method="GET" action="/">
```
should be

```
<form id="form-filter-instant" method="GET" action="<%= url_for( "/" ) %>">
```

Also grep all templates for

```
    \b(href|src|hx-get|hx-post|action)="(?!<%=)
```

to find other URLs that are not relative to the script