# Google Tasks

Build Google Tasks into Tern's existing Google account connection and trailing sidebar.

1. Add the optional Tasks permission and a typed API client with pagination, date-only due dates, and explicit mutation errors. Test auth coverage and the HTTP boundary.
2. Add an account-scoped task model and sidebar. Read all task lists, remember the selected list, and support creating, editing, completing, reopening, and deleting tasks. Refresh on opening, returning to Tern, and periodically while visible. Confirm writes before showing success; reconcile uncertain creates before offering another attempt.
3. Add a selected-text context-menu action in the email reader and an Add to Tasks button for AI summary tasks. Preserve source account, source message link, and due dates. Prevent repeated clicks from creating duplicates.
4. Share the existing Assistant sidebar position and resize behavior. Review narrow and wide layouts, light and dark appearances, long titles, loading, empty, permission, and failure states. Run focused API/model/reader tests and a native app build.

Google Cloud must have the Google Tasks API enabled and the Tasks OAuth scope configured. Existing accounts grant Tasks access separately. Live Google validation requires that grant; automated tests use an injected service and never modify the user's tasks.

Existing reader and summary changes in this checkout are preserved. API/auth and task model/UI work have separate owners; the integration owner wires the workspace, email reader, and composition root.
