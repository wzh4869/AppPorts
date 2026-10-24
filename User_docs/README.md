# AppPorts documentation

This directory contains the standalone Fumadocs documentation site. It maintains Simplified Chinese, Traditional Chinese, and English. It does not depend on the former documentation framework or online translations.

## Develop and preview

Use a supported Node.js LTS release compatible with Next.js (Node 22.13+ or Node 24 recommended).

```sh
npm ci
npm run docs:dev
```

The development site listens on `http://127.0.0.1:4173`. Markdown is generated at startup; after editing source Markdown, run `npm run docs:prepare` to refresh the generated content.

To inspect the production export:

```sh
npm run docs:build
npm run docs:typecheck
npm run docs:check
npm run docs:preview
```

Stop the development server before starting the production preview on the same port. `docs:check` requires a fresh build. It verifies all 84 articles and three homepages, chapter IDs, links, metadata, portable Markdown, the navigation contract, removed routes, and public assets.

## Content and routes

| Language | Source | Homepage | Articles |
| --- | --- | --- | --- |
| Simplified Chinese | `docs/*.md` and topic subdirectories | `/` | `/docs/<slug>` |
| Traditional Chinese | `docs/zh-Hant/` | `/zh-Hant` | `/zh-Hant/docs/<slug>` |
| English | `docs/en/` | `/en` | `/en/docs/<slug>` |

Each language contains the same 28 articles, all listed in the sidebar, with the contributor guide immediately after Sponsor. `config/docs-navigation.json` defines their shared order. `config/locales.json` contains navigation, interface text, and descriptions. Simplified Chinese is the content baseline; update both translations alongside it.

Keep explicit `{#chapter-id}` markers identical and in the same order across translations. Author language-neutral `/docs/<slug>#chapter-id` links in Markdown; preparation localizes them for each language. Keep experimental dates, app/build versions, measurements, failed cases, and evidence limitations. Do not publish private conversations, account identifiers, or personal paths. Translate visible diagram labels while preserving syntax, paths, and identifiers.

The generator rejects missing pages and mismatched chapters. Generated `.content/`, `public/`, `.next/`, and `out/` must not be edited or committed. Portable article Markdown is exported to `/docs-md/<locale>/<slug>.md`. Language switching stays on the corresponding local article and chapter; search uses the current language.

## Deploy the static export

Publish the complete, freshly built `out/` directory as the documentation site's root. No Node server or old site is needed at runtime. Serve extensionless canonical paths from their generated `.html` files, and return `404.html` with HTTP status 404 for missing paths. For example, an nginx static location can use:

```nginx
location / {
    try_files $uri $uri.html $uri/ =404;
}
error_page 404 /404.html;
```

Do not configure a single-page-app fallback to `index.html`, old `.html` aliases, language fallback redirects, or redirects for merged articles. Japanese, Korean, German, French, and Spanish are retired. Their routes and former site entry points intentionally return 404. Existing app versions containing those old help links need a future app update to use canonical paths.

Replace the previous deployment's file set rather than overlaying new files while retaining old pages. Invalidate the hosting cache as appropriate. Keep these public root endpoints available: `/sponsors.json`, `/latest.json`, and `/logo.png`. Sponsor data comes from the repository-root `sponsors.json`; other static resources come from `docs/public/`.

Before publishing, check all three languages on desktop and mobile, search, language switching with a chapter hash, theme switching, and Markdown actions. Confirm an old path such as `/core.html`, a retired language path, and `/docs/research/unplug-test` return a real 404. GitHub source links target `main`, so new source files must be present there when the site is published.

The static build is deployable; running these commands does not publish it automatically.
