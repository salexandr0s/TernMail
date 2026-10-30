# Contacts

Turn on Contacts for a Google account in Settings → Accounts → Connections. Tern uses the existing read-only Contacts permissions for suggestions, saved and other-contact photos, and contact groups. Enable People API in the Google Cloud project that owns the app's OAuth client if it is not already enabled.

## Photos

Contact sync requests `photos` together with names, addresses and metadata. This field is supported for both saved contacts and Other contacts. A default Google image is ignored so Tern can show its own initials fallback. [People photos](https://developers.google.com/people/api/rest/v1/people#Photo), [Other contacts fields](https://developers.google.com/people/api/rest/v1/otherContacts/list).

Photos appear in reader and message-list avatars when a matching address exists in the account's cached contacts. Saved contacts take precedence over Other contacts. The fallback uses initials and a color derived from the address. Photo lookup never blocks mail loading or recipient entry.

Photo downloads use a separate ephemeral session without OAuth headers, cookies or credentials. Only HTTPS Google image hosts under `googleusercontent.com` or `ggpht.com` are accepted; redirects are refused. Downloads stop at 1 MiB. Tern accepts PNG, JPEG, GIF and WebP only, checks dimensions up to 4,096 per side and 4,194,304 pixels, then stores a 160-pixel PNG thumbnail. Animation and source metadata do not enter the cache. A failed or unsupported photo leaves initials visible.

Thumbnails expire after seven days and share a 64 MiB cache allowance. The cache identity includes account, contact source and person resource name. Replacing a contact reference changes its version so an older download cannot overwrite a later sync. Turning Contacts off or removing the account clears references and bytes through the existing contact cleanup; active avatar work is cancelled.

## Contact groups

Type a group name in a recipient field and select its group suggestion. Groups remain account-specific even when their names match. Tern lists user-created contact groups; the list API omits members, so selecting a suggestion fetches the current membership before adding recipients. Existing `contacts.readonly` permission covers these reads. [Group listing](https://developers.google.com/people/api/rest/v1/contactGroups/list), [Group membership lookup](https://developers.google.com/people/api/rest/v1/contactGroups/get).

The catalogue holds up to 1,000 user groups and reports incomplete coverage when its bound is reached. Expansion handles up to 1,000 members and 1,000 distinct valid addresses. Member details are requested in batches of at most 200. Every address returned for each member is considered, duplicates are removed without regard to address case, and the composer applies its own-address and suggestion-blocklist choices. [People batch lookup](https://developers.google.com/people/api/rest/v1/people/getBatchGet).

Missing members, invalid addresses, unavailable membership and limits produce an incomplete expansion. Tern leaves the recipient field unchanged and explains the problem. It never inserts a partial member list silently. Sending waits while a selected group is expanding. Account or Contacts changes invalidate pending expansion; choosing a group never sends mail.

## Verification

Automated checks cover source/account separation, permission cleanup, stale photo writes, group pagination and 200-member batches, unresolved membership, off/on changes during expansion, and photo host/credential/format/size/pixel boundaries. The integration handoff records the current run results.

Live People API photo and group round trips remain an acceptance check. The Google API must be enabled and the account must grant Contacts permissions. Unsupported photo hosts or asset redirects keep the initials fallback; oversized or incomplete groups require resolving the membership before expansion.
