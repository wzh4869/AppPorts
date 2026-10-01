# Container ownership and personal-folder presentation

The application-data list previously exposed standard container links to personal Desktop, Downloads, Movies, Music and Pictures when structural rows were enabled. These links are not application-owned data. Ordinary links are now hidden regardless of either visibility toggle; conflict, unreadable and managed recovery entries remain visible.

Data rows now retain their parent container path as an inline subtitle, including when their container ancestor is present in the outline. This avoids relying on selection or indentation to identify a generic Data name.

Ordinary Containers discovery now probes the direct child named by the resolved application bundle identifier. Product-name, substring and nested-directory matches cannot establish ownership. Existing persistent recovery records remain discoverable. This deliberately stops discovering unverified helper/extension and legacy alias containers by name alone.

Limit: Group Containers still uses the existing candidate matcher. Shared-group membership requires a separate entitlement-based design; this change does not establish verified ownership for shared groups or other heuristic Library searches. A container's personal-folder links likewise do not prove ownership of their targets.

Validation uses synthetic scanner, tree and presentation fixtures only. No user application containers are modified.

Verification completed: scoped Xcode test on macOS, 74 XCTest tests and 8 Swift Testing tests passed. Synthetic UI render matrix inspected with structural rows enabled: Data shows container path and ordinary personal-folder shortcuts are absent. Initial failures were obsolete visibility expectations and a test assertion comparing /var with /private/var without URL normalization; both corrected and rerun successfully. Only a scanner documentation comment was repositioned after the successful build.
