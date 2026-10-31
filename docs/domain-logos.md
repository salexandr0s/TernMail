# Company logos

Tern uses an address's website icon when no photo is available. The fallback appears in mail lists, conversation headers, assistant email cards, attachment senders, Calendar guests and invitation organizers, compose From choices, account settings, Assistant account rows, and To/Cc/Bcc recipient suggestions and chips. Existing photos take precedence. If no usable icon is found, the avatar keeps its initials.

**Settings → Reading → Privacy → Show company logos** controls these lookups and is enabled by default. Turning it off hides website icons and cancels requests once their last visible avatar stops using them. This setting is separate from images inside email bodies; those keep their existing privacy controls.

The loader uses only the domain from the parsed sender address. It never sends the email address, message content, OAuth tokens, cookies or a referrer. The website still receives the connection's IP address. Common personal mail domains, local addresses, IP literals, unknown suffixes and public suffixes are skipped. A logo is decoration, not proof of the sender's identity.

`AddressAvatarModel` chooses a matching authenticated account photo, then an allowed contact photo from the owning account, then a website icon. Contacts access and record changes remain account-scoped. Late photo arrivals replace logos, while changing the address, owner, settings or account context cancels obsolete work. Verified From aliases retain their account's existing photo. Recipient lookups start only for complete addresses in chips or suggestions; partial typing is never used as a website domain.

Recipient chips keep the native token field and its address objects. Logos draw in reserved display space; editing, copying and saved drafts keep the original address text. The suggestion popup uses the same resolver without taking keyboard focus away from the editor.

## Retrieval and storage

- Registrable domains use the bundled Public Suffix List, including private hosting rules, wildcards and exceptions. A mail subdomain can use its company's website without crossing a hosting tenant boundary.
- HTTPS requests discover website-declared touch icons and favicons, then try conventional icon paths on the domain and its `www` host. Icon URLs and redirects must remain within the same registrable domain. There is no third-party logo service or API key.
- A small explicit mapping handles verified domain migrations before lookup and caching. Unity's legacy `unity3d.com` sender domain uses `unity.com`, which [Unity lists as its primary website](https://docs.unity.com/en-us/engine/6000.6/manual/get-started/install-and-upgrade/ent-deployment/ent-web-proxies/ent-proxy-exception-list). Both domains share one cache entry; unrelated cross-domain redirects remain blocked.
- Requests have a 15-second total lookup deadline, four concurrent domain slots and shared work for avatars using the same domain. Every production request checks DNS answers for local/private addresses; URLSession resolves independently, so this check does not pin DNS or fully prevent rebinding.
- Images are limited to 1 MiB and 4,194,304 pixels, decoded from bounded raster formats including ICO, then re-encoded as a static PNG of at most 160 pixels per side. SVG and tracking-pixel dimensions are rejected. Website scripts and other page resources never run.
- Domain-only cache entries expire after seven days for found icons, six hours for missing icons and one minute for temporary failures. Failed refreshes can retain an existing icon for up to 30 days. Cancellation is not cached. Disk storage is capped at 128 entries and 16 MiB; resetting the mail cache also clears logos.

Some sites provide only SVG icons, host icons on a different company's CDN or block automated requests. These senders retain initials.

## Maintenance

`App/Design/PublicSuffixList.dat` is a bundled snapshot from [publicsuffix.org](https://publicsuffix.org/list/public_suffix_list.dat). Preserve its Mozilla license and version header when refreshing it. Run `xcodegen generate` after adding or moving sources or resources.

`Tests/AppTests/DomainLogoImagesTests.swift` covers domain boundaries, the Unity migration, request privacy, redirects, image limits, cache persistence and expiry, cancellation, shared requests and the total deadline. `AddressAvatarModelTests` covers photo priority, account boundaries, contact access changes and stale requests. `RecipientAvatarTests` checks native token serialization and completion guards. Existing contact-photo and cache-reset suites cover the surrounding integration.
