# Google Tasks in Tern

Open **Google Tasks** from the toolbar beside Assistant. The two panels share the same resizable sidebar. Choose a Google account and task list at the top. Tern remembers the list for each account.

Select text in an email, right-click, and choose **Add to Google Tasks**. In an expanded AI summary, click the **+** beside a detected task. A spinner appears while it saves, then a checkmark confirms it was added. Both actions use the email's Google account and save a link to the source email. AI suggestions keep their due date and put any named owner in the notes; they do not assign the task to another person.

Calendar suggestions also have a **+** beside **Review**. It adds the detected event to Google Tasks, using the date shown on the card as the due date and keeping the time, location, and email excerpt in the notes. Review and the plus remain available in a narrow reader. Cancelled or superseded suggestions cannot be added as tasks.

Use the field above the list to add a task, or its details button to include notes and a due date. Click a task's title to edit it. The circle completes a task, and the Completed section lets you reopen it. A task's email link opens its source message; the options menu also includes deletion. Deletion removes subtasks in Google Tasks too.

## Connect an account

Tasks access is optional. Choose **Connect Google Tasks** in the sidebar, or turn on **Google Tasks** under the account's Connections settings. Google asks for permission to read and change tasks. Tern keeps the existing mail connection and checks that consent belongs to the same account. Turning Tasks off stops its use in Tern without deleting tasks from Google.

The existing Google Cloud project must have the [Google Tasks API enabled](https://developers.google.com/workspace/tasks/quickstart/python#enable_the_api). Its OAuth configuration must include the [`https://www.googleapis.com/auth/tasks` scope](https://developers.google.com/workspace/tasks/auth). The read-only Tasks scope and Calendar permissions do not permit this integration's writes. Public distribution may require updating the app's Google verification submission.

## Sync behavior

Tern reads Google Tasks when the sidebar opens, when Tern becomes active, and every 30 seconds while the sidebar is active and Tern is in front. Refresh checks immediately. Changes made in Tern are sent to Google and shown as saved only after Google confirms them. An open editor keeps its original account and list even if the sidebar selection changes.

If Google might have received an Add request but its response was lost, Tern checks the account's lists for that task before sending another request. A reference in the task's Google notes identifies repeated additions from the same email or suggestion. Tern hides that reference in its editor and keeps it when notes change. If the result remains uncertain, the sidebar asks you to check Google Tasks before choosing Add Again.

The sidebar needs a network connection. It does not queue offline edits. Google Tasks exposes due dates as calendar days, without a scheduled time; Tern preserves that day across time zones. List creation and reordering remain available in Google Tasks.

## Live acceptance check

After enabling the API and granting an account access:

1. Add selected email text and confirm the task and email link appear in the chosen list on Google Tasks.
2. Add an AI task suggestion and a calendar suggestion using their plus buttons. Confirm each appears once with its due date and source link; Review still opens the calendar suggestion after its task is saved.
3. Edit, complete, reopen, and delete a temporary task in Tern; confirm each change in Google Tasks.
4. Change a task in Google Tasks and return to Tern; confirm the refreshed result.
5. Switch between accounts and lists, then disable Tasks for one account. Confirm that its tasks are no longer read or changed in Tern.

Automated API, model, and native reader tests use fixtures. They do not grant OAuth consent or change personal Google Tasks data.
