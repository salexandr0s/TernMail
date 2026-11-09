# Meeting preparation

Open a saved calendar event and choose **Prepare for Meeting**, or use the same action in an event's context menu. Preparation opens in a separate window. It uses the saved event; unsaved edits stay in the event editor.

The window gathers related conversations, their summaries and decisions, suggested work, commitments you already track, and recent files. Each generated point links to its supporting email. **Open Email** shows the original conversation; selecting a file requests a preview.

## Choose the sources

Conversations linked to the event and conversations you include take priority. Other suggestions require matching subject or message content. Shared attendees alone do not establish a connection. For a general title, such as “Meeting,” include the relevant conversations yourself.

Use **Include Conversation…** to search cached mail in your current account profile. **Exclude** removes a source from the preparation; expand **Excluded conversations** to restore one. These choices are saved for this occurrence, including when a recurring occurrence moves to another time. Other occurrences keep their own choices.

Source choices survive mail-cache cleanup. Removing either the event's account or a source conversation's account removes the corresponding saved choice. Preparation does not change the event's original email links.

## Review the preparation

Tern considers up to 20 related conversations and prepares at most five full summaries in one run. The view reports omitted or unavailable sources and shortened content. Narrow the source selection and refresh to review other conversations. Recent files are attachments from the included conversations, ordered by message date; the view does not establish which copy of a document is the latest everywhere.

Tracked work uses your saved description, owner, deadline, and status from [Waiting for](follow-ups.md) and [Today](today.md). Completed or dismissed work stays closed. When a refreshed suggestion cites the same evidence as accepted work, Tern may hide it to avoid presenting the same request as new. You can still track separate work manually.

New suggestions use the existing follow-up review flow. Preparation itself does not send email, save event edits, or change an invitation.

## Access and refresh

Generated summaries require a connected assistant, an available model, assistant access to the included mail accounts, and **event details** access for the meeting's calendar. Availability-only calendar access is insufficient. Source selection and opening original mail remain available under normal account access when AI preparation is unavailable.

Changes to the event or supporting mail mark the preparation as stale. Choose **Refresh** to rebuild it. Access changes cancel pending work and remove restricted generated content. **Cancel** stops preparation without removing your saved source choices.

See the [implementation and verification plan](plans/meeting-preparation.md) for the account boundaries and acceptance checks.
