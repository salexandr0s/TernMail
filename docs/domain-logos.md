# Company logos

Tern uses a sender's website icon when no contact photo is available. The fallback appears in the message list, conversation headers and assistant email cards. Existing photos take precedence. If no usable icon is found, the avatar keeps its initials.

**Settings → Reading → Privacy → Show company logos** controls these lookups and is enabled by default. Turning it off hides website icons and cancels requests once their last visible avatar stops using them. This setting is separate from images inside email bodies; those keep their existing privacy controls.

The loader uses only the domain from the parsed sender address. It never sends the email address, message content, OAuth tokens, cookies or a referrer. The website still receives the connection's IP address. Common personal mail domains, local addresses, IP literals, unknown suffixes and public suffixes are skipped. A logo is decoration, not proof of the sender's identity.

## Retrieval and storage

- Registrable domains use the bundled Public Suffix List, including private hosting rules, wildcards and exceptions. A mail subdomain can use its company's website without crossing a hosting tenant boundary.
- HTTPS requests discover website-declared touch icons and favicons, then try conventional icon paths on the domain and its `www` host. Icon URLs and redirects must remain within the same registrable domain. There is no third-party logo service or API key.
- Requests have a 15-second total lookup deadline, four concurrent domain slots and shared work for avatars using the same domain. Every production request checks DNS answers for local/private addresses; URLSession resolves independently, so this check does not pin DNS or fully prevent rebinding.
- Images are limited to 1 MiB and 4,194,304 pixels, decoded from bounded raster formats including ICO, then re-encoded as a static PNG of at most 160 pixels per side. SVG and tracking-pixel dimensions are rejected. Website scripts and other page resources never run.
- Domain-only cache entries expire after seven days for found icons, six hours for missing icons and one minute for temporary failures. Failed refreshes can retain an existing icon for up to 30 days. Cancellation is not cached. Disk storage is capped at 128 entries and 16 MiB; resetting the mail cache also clears logos.

Some sites provide only SVG icons, host icons on a different company's CDN or block automated requests. These senders retain initials.

## Maintenance

`App/Design/PublicSuffixList.dat` is a bundled snapshot from [publicsuffix.org](https://publicsuffix.org/list/public_suffix_list.dat). Preserve its Mozilla license and version header when refreshing it. Run `xcodegen generate` after adding or moving sources or resources.

`Tests/AppTests/DomainLogoImagesTests.swift` covers domain boundaries, request privacy, redirects, image limits, cache persistence and expiry, cancellation, shared requests and the total deadline. Existing contact-photo and cache-reset suites cover the surrounding integration.
