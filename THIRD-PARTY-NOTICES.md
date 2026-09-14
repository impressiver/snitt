# Third-party notices

Snitt itself is under the [Mozilla Public License 2.0](LICENSE). It ships one
third-party component inside the application bundle, under its own terms.

## Sparkle

Copyright © 2006-2013 Andy Matuschak. Licensed under the MIT License.

- Source: https://github.com/sparkle-project/Sparkle
- Licence: https://github.com/sparkle-project/Sparkle/blob/2.x/LICENSE
- Full text as shipped: `Snitt.app/Contents/Frameworks/Sparkle.framework`

Sparkle is the in-app update framework. It is the only thing in Snitt that
makes a network request, and the only dependency the project has.

MPL-2.0 and MIT are compatible, and the MPL's file-level copyleft does not
reach Sparkle: it is a separate work distributed alongside Snitt, not a
modification of Covered Software.

---

**Why this file exists.** MIT requires its copyright notice and permission
notice to be included in all copies of the software. Shipping the framework
with its own `LICENSE` inside satisfies that literally, but it puts the notice
somewhere only a person who knows to look inside a `.app` will ever find. This
file is the version a human can read before downloading anything.
