# Security-scoped folder access audit

**Audit date:** 2026-07-30

## Scope

This audit covers browser folder roots used by Open Folder, Open Recent, Favorites, sidebar
descendants, drag and drop, asynchronous thumbnail/metadata work, and folder monitoring. Import,
archive, templates, and one-shot file pickers own shorter, operation-scoped claims and balance
their own `startAccessingSecurityScopedResource()` calls.

## Decision

Browser roots use one process-lifetime security-scope claim per normalized folder URL.
`BrowserFolderSecurityScopeStore` owns those claims. It intentionally does not stop access while
the app is running because descendant thumbnails, metadata reads, exports, and folder monitors can
outlive the UI action that opened the root.

The store:

- normalizes directory URLs before deduplicating access claims and reuses an active ancestor claim
  for every descendant;
- resolves and starts access for persisted Recent and Favorite bookmarks before descendants are
  enumerated;
- refreshes stale bookmark data and persists the refreshed value;
- retries a failed access claim rather than recording it as active;
- bounds launch-time Recent claims to the existing ten-entry Recent menu limit.

## Entry-point findings

| Entry point | Access behavior |
|---|---|
| Open Folder | Captures a security-scoped bookmark and retains the selected root before async work |
| Open Recent | Resolves bookmarks during app initialization, retains access, and repairs stale data |
| Favorites | Resolves bookmarks when the browser appears, before loading top-level subfolders |
| Sidebar descendants | Reuse the retained ancestor scope; opening a descendant also records it in Recent |
| Drag and drop | Records and retains the dropped directory when it becomes the browser root |
| Folder reload/refresh | Reuses the normalized retained claim; it does not start another claim |

## Regression coverage

`RecentFoldersStoreTests` verifies normalized-root deduplication, retry after a failed access
claim, stale bookmark resolution/refresh at launch, legacy bookmark-less decoding, and Recent
list sanitization. The lifecycle boundary uses injected bookmark/access operations in tests so the
suite does not depend on a Powerbox prompt or host sandbox state.
