import { readFileSync, writeFileSync, mkdirSync, existsSync, readdirSync } from "node:fs";
import { dirname, join, relative, resolve, posix } from "node:path";
import { fileURLToPath } from "node:url";
import { createHash } from "node:crypto";
import matter from "gray-matter";
import yaml from "js-yaml";
import { createMarkdownRenderer, resolveConfig } from "vitepress";
import { createComponentRenderer } from "./gitbook-components.mjs";
import { applyGitBookDesign } from "./gitbook-design.mjs";

const project = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const docs = join(project, "docs");
const outputArgument = process.argv.indexOf("--output");
if (outputArgument !== -1 && !process.argv[outputArgument + 1]) throw new Error("--output requires a directory");
const output = outputArgument === -1 ? join(project, "gitbook") : resolve(project, process.argv[outputArgument + 1]);
const mode = process.argv[2] ?? "export";
if (!["export", "check", "resolve-links"].includes(mode)) {
  throw new Error("Usage: node scripts/migrate-gitbook.mjs [export|check|resolve-links] [--output directory]");
}
const config = await resolveConfig(docs);
const markdown = await createMarkdownRenderer(docs);
const components = createComponentRenderer({ docsRoot: docs, repositoryRoot: dirname(project) });
const languageCodes = { root: "zh", en: "en", "zh-Hant": "zh-tw", ja: "ja", ko: "ko", de: "de", fr: "fr", es: "es" };
const locales = Object.entries(config.site.locales).map(([key, value]) => ({
  key, directory: key === "root" ? "zh-Hans" : key,
  sourcePrefix: key === "root" ? "" : `${key}/`,
  label: value.label, componentLocale: value.lang, language: languageCodes[key],
  sidebar: value.themeConfig.sidebar,
}));
const pages = [];
const routeMap = new Map();
const crossLinks = [];

function walk(directory) {
  return readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
    if (entry.name.startsWith(".") || entry.name === "public") return [];
    const filename = join(directory, entry.name);
    return entry.isDirectory() ? walk(filename) : filename.endsWith(".md") ? [filename] : [];
  });
}
function html(value) {
  return String(value ?? "").replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}
function hash(value) { return createHash("sha256").update(value).digest("hex"); }
function writeNew(filename, content) {
  mkdirSync(dirname(filename), { recursive: true });
  if (existsSync(filename)) {
    // GitBook can edit these files after import; never regenerate over those edits.
    if (hash(readFileSync(filename)) !== hash(content)) skipped.add(relative(project, filename));
    return;
  }
  writeFileSync(filename, content);
}
function fencedTokens(body) { return markdown.parse(body, {}).filter((token) => token.type === "fence"); }
function firstHeading(body) {
  const heading = body.match(/^#\s+(.+)$/m)?.[1];
  return heading?.replace(/\s*<a\b[^>]*><\/a>\s*$/, "").replace(/\s*\{#[^}]+\}\s*$/, "").trim();
}
function parseSource(filename) {
  const raw = readFileSync(filename, "utf8").replace(/\r\n/g, "\n");
  const parsed = matter(raw);
  return { raw, data: parsed.data, body: parsed.content.trim() + "\n" };
}

for (const filename of walk(docs).sort()) {
  const source = relative(docs, filename).split("\\").join("/");
  const locale = locales.find((item) => item.sourcePrefix && source.startsWith(item.sourcePrefix)) ?? locales[0];
  const local = source.slice(locale.sourcePrefix.length);
  const target = local === "index.md" ? "README.md" : local;
  const page = { source, local, target, locale, filename, ...parseSource(filename) };
  pages.push(page);
  const route = `/${source.replace(/\.md$/, "")}`;
  for (const alias of [route, `${route}.md`, `${route}.html`]) routeMap.set(alias, page);
  if (local === "index.md") {
    routeMap.set(`/${locale.sourcePrefix}`, page);
    if (locale.sourcePrefix) routeMap.set(`/${locale.sourcePrefix.slice(0, -1)}`, page);
  }
}

function rewriteURL(url, page, record = true) {
  if (/^(?:[a-z][a-z\d+.-]*:|\/\/|#)/i.test(url)) {
    if (!url.startsWith("https://docs-appports.shimoko.com/")) return url;
    url = url.slice("https://docs-appports.shimoko.com".length);
  }
  const [, pathname, suffix = ""] = url.match(/^([^?#]*)([\s\S]*)$/);
  const sourceRoute = pathname.startsWith("/") ? pathname : posix.resolve("/", posix.dirname(page.source), pathname);
  const target = routeMap.get(decodeURI(sourceRoute));
  if (!target) {
    if (pathname === "/logo.png") return posix.relative(posix.dirname(page.target), ".gitbook/assets/logo.png");
    if (!pathname || !pathname.startsWith("/") && !/\.md$|\.html$/.test(pathname)) return url;
    throw new Error(`Unresolved source link in ${page.source}: ${url}`);
  }
  if (target.locale.key === page.locale.key) {
    return posix.relative(posix.dirname(page.target), target.target) + suffix;
  }
  const sentinel = `XSPACE_${target.locale.directory.replace(/-/g, "_").toUpperCase()}`;
  const provisional = `https://app.gitbook.com/s/${sentinel}/${target.target.replace(/\.md$/, "")}${suffix}`;
  if (record) crossLinks.push({ file: `${page.locale.directory}/${page.target}`, provisional,
    locale: target.locale.directory, target: target.target, suffix });
  return provisional;
}

function transformLinks(line, page) {
  // Fenced code is protected by the caller; inline code is protected here.
  return line.split(/(`+[^`]*`+)/g).map((part, index) => index % 2 ? part : part
    .replace(/(\]\(\s*)(<?)([^\s)>]+)(>?)/g, (_, prefix, open, url, close) => `${prefix}${open}${rewriteURL(url, page)}${close}`)
    .replace(/\b(href|src)="([^"]*)"/g, (_, attribute, url) => `${attribute}="${html(rewriteURL(url.replace(/&amp;/g, "&"), page))}"`)
  ).join("");
}

function homepage(page) {
  const { hero, features } = page.data;
  if (!hero?.name || !Array.isArray(features)) throw new Error(`Missing homepage data: ${page.source}`);
  return [
    `# ${hero.name}`,
    `<figure><img src="/logo.png" alt="${html(hero.image.alt)}" width="160"><figcaption></figcaption></figure>`,
    `## ${hero.text}`,
    hero.tagline,
    hero.actions.map((action) => `<a href="${html(action.link)}" class="button ${action.theme === "brand" ? "primary" : "secondary"}">${html(action.text)}</a>`).join("\n\n"),
    '<table data-view="cards"><thead><tr><th></th><th></th></tr></thead><tbody>',
    ...features.map((feature) => `<tr><td><strong>${html(feature.icon)} ${html(feature.title)}</strong></td><td>${html(feature.details)}</td></tr>`),
    "</tbody></table>",
  ].join("\n\n") + "\n";
}

function convert(page) {
  let body = page.local === "index.md" ? homepage(page) : page.body
    .replace(/<script\b[^>]*>[\s\S]*?<\/script>\s*/g, "")
    .replace(/<style\b[^>]*>[\s\S]*?<\/style>\s*/g, "")
    .replace(/<PrivacyView\b[^>]*\/>/g, () => components.privacy(page.locale.componentLocale))
    .replace(/<LicensesView\b[^>]*\/>/g, () => components.licenses(page.locale.componentLocale))
    .replace(/<SponsorList\b[^>]*\/>/g, () => components.sponsors(page.locale.componentLocale))
    .replace(/<div align="center">\s*(<img\b[^>]*>)\s*<\/div>/g, "<figure>$1<figcaption></figcaption></figure>");
  const lines = body.split("\n");
  const headingIds = markdown.parse(body, {}).filter((token) => token.type === "heading_open" && token.tag !== "h1");
  for (const token of headingIds) {
    const index = token.map[0];
    const id = token.attrGet("id");
    if (id && /^#{2,6}\s/.test(lines[index])) {
      lines[index] = lines[index].replace(/\s*\{#[^}]+\}\s*$/, "") + ` <a href="#${html(id)}" id="${html(id)}"></a>`;
    }
  }
  const converted = [];
  let fence = null;
  const containers = [];
  for (const line of lines) {
    const marker = line.match(/^\s*(`{3,}|~{3,})/);
    if (marker) {
      if (!fence) fence = marker[1];
      else if (marker[1][0] === fence[0] && marker[1].length >= fence.length && /^\s*[`~]+\s*$/.test(line)) fence = null;
      converted.push(line);
      continue;
    }
    if (fence) { converted.push(line); continue; }
    const open = line.match(/^\s*:::\s*(tip|warning|info|details)\s*(.*)$/);
    if (open) {
      const [, type, title] = open;
      containers.push(type);
      if (type === "details") converted.push(`<details>\n<summary>${html(title || "Details")}</summary>\n`);
      else converted.push(`{% hint style="${type === "tip" ? "success" : type}" %}\n${title ? `**${title}**\n` : ""}`);
    } else if (/^\s*:::\s*$/.test(line)) {
      const type = containers.pop();
      if (!type) throw new Error(`Unmatched container in ${page.source}`);
      converted.push(type === "details" ? "\n</details>" : "{% endhint %}");
    } else converted.push(transformLinks(line, page));
  }
  if (fence || containers.length) throw new Error(`Unclosed block in ${page.source}`);
  const metadata = {};
  if (page.data.description) metadata.description = page.data.description;
  if (page.local === "index.md") {
    metadata.description = page.data.hero.tagline;
    metadata.layout = { width: "wide", outline: { visible: false } };
  } else if (page.data.aside === false || page.data.prev === false && page.data.next === false) {
    metadata.layout = {};
    if (page.data.aside === false) metadata.layout.outline = { visible: false };
    if (page.data.prev === false && page.data.next === false) metadata.layout.pagination = { visible: false };
  }
  body = converted.join("\n").trim() + "\n";
  page.title = firstHeading(body) ?? page.data.title;
  if (!page.title) throw new Error(`Missing page title: ${page.source}`);
  return (Object.keys(metadata).length ? `---\n${yaml.dump(metadata, { lineWidth: -1 })}---\n\n` : "") + body;
}

// These are the existing named sidebar groups, not inferred filesystem groups.
function groupDirectory(item) {
  const first = item.items.find((child) => child.link)?.link;
  const source = routeMap.get(first)?.local;
  if (source?.startsWith("datamigrae/baseinfo")) return "datamigrae";
  if (source?.startsWith("migration-strategy/portal")) return "migration-strategy";
  if (source === "storage-guide.md") return "external-storage";
  if (source === "macos-27.md") return "upgrades-and-repairs";
  if (source?.startsWith("research/")) return "research";
  throw new Error(`Unrecognized sidebar group: ${item.text}`);
}
function summaryLink(page, navigationTitle) {
  const title = page.title.replace(/\[/g, "\\[").replace(/\]/g, "\\]");
  const override = navigationTitle === page.title ? "" : ` "${navigationTitle.replace(/"/g, "&quot;")}"`;
  return `[${title}](${page.target}${override})`;
}
function navigationLink(page, navigationTitle, locale) {
  if (page.locale === locale) return summaryLink(page, navigationTitle);
  const source = { locale, source: `${locale.sourcePrefix}SUMMARY.md`, target: "SUMMARY.md" };
  return `[${navigationTitle}](${rewriteURL(`/${page.source}`, source)})`;
}

function transformBodyLinks(content, rewrite) {
  const transform = (part) => part.split("\n").map((line) => line
      .replace(/(\]\(\s*<?)([^\s)>]+)(>?)/g, (_, prefix, url, suffix) => `${prefix}${rewrite(url)}${suffix}`)
      // Empty <a id="..."> elements define headings; only visit actual links.
      .replace(/(<a\b(?![^>]*\bid=)[^>]*\bhref=")([^"]*)(")/g, (_, prefix, url, suffix) => `${prefix}${html(rewrite(url.replace(/&amp;/g, "&")))}${suffix}`)
    ).join("\n");
  let result = "", cursor = 0;
  for (const [start, end] of bodyCodeRanges(content)) {
    result += transform(content.slice(cursor, start)) + content.slice(start, end);
    cursor = end;
  }
  return result + transform(content.slice(cursor));
}

function bodyCodeRanges(content) {
  const positions = new WeakMap();
  const ruler = markdown.inline.ruler;
  const rules = ["backticks", "image"].map((name) => [name, ruler.__rules__.find((rule) => rule.name === name).fn]);
  let tokens;
  try {
    for (const [name, rule] of rules) ruler.at(name, (state, silent) => {
      const start = state.pos, count = state.tokens.length;
      const matched = rule(state, silent);
      const token = state.tokens.at(-1);
      if (!silent && state.tokens.length > count && ["code_inline", "image"].includes(token.type)) {
        positions.set(token, [start, state.pos]);
      }
      return matched;
    });
    tokens = markdown.parse(content, {});
  } finally {
    for (const [name, rule] of rules) ruler.at(name, rule);
  }
  const lineStarts = [0];
  for (const match of content.matchAll(/\n/g)) lineStarts.push(match.index + 1);
  const sourceTicks = ([first, last]) => {
    const start = lineStarts[first], end = lineStarts[last] ?? content.length;
    return [...content.slice(start, end).matchAll(/`/g)].map((match) => start + match.index);
  };
  const ranges = [];
  let rowTicks = [], rowCursor = 0;
  for (const token of tokens) {
    if (["fence", "code_block"].includes(token.type)) {
      ranges.push([lineStarts[token.map[0]], lineStarts[token.map[1]] ?? content.length]);
    } else if (token.type === "tr_open") {
      rowTicks = sourceTicks(token.map);
      rowCursor = 0;
    } else if (token.type === "inline") {
      // Block prefixes and escaped table pipes change offsets, but preserve backtick order.
      const ticks = [...token.content.matchAll(/`/g)].map((match) => match.index);
      const originals = token.map ? sourceTicks(token.map) : rowTicks.slice(rowCursor, rowCursor += ticks.length);
      const offsets = new Map(ticks.map((tick, index) => [tick, originals[index]]));
      const collect = (children, base = 0) => {
        for (const child of children ?? []) {
          const position = positions.get(child);
          if (child.type === "code_inline" && position) {
            const start = offsets.get(base + position[0]), last = offsets.get(base + position[1] - 1);
            if (start === undefined || last === undefined) throw new Error("Cannot locate inline code in original Markdown");
            ranges.push([start, last + 1]);
          } else if (child.type === "image" && position) {
            // Image children are parsed from the label after its opening ![.
            collect(child.children, base + position[0] + 2);
          }
        }
      };
      collect(token.children);
    }
  }
  return ranges.sort(([left], [right]) => left - right);
}

function importedFragment(url, file, spaces, anchorIds) {
  file = file.split("\\").join("/");
  const hashIndex = url.indexOf("#");
  if (hashIndex < 0) return null;
  const path = url.slice(0, hashIndex).split("?")[0];
  const anchor = decodeURIComponent(url.slice(hashIndex + 1));
  if (!anchor) return null;
  let target = file;
  if (path.startsWith("https://app.gitbook.com/s/")) {
    const match = path.match(/^https:\/\/app\.gitbook\.com\/s\/([^/]+)\/(.+)$/);
    const space = match && Object.entries(spaces).find(([, value]) => value.id === match[1]);
    const page = space && Object.entries(space[1].pages).find(([, value]) => value === match[2]);
    if (!page) return null;
    target = `${space[0]}/${page[0]}`;
  } else if (/^(?:[a-z][a-z\d+.-]*:|\/)/i.test(path)) return null;
  else if (path) target = posix.normalize(posix.join(posix.dirname(file), decodeURI(path)));
  const ids = anchorIds[target];
  const actual = ids && Object.hasOwn(ids, anchor) ? ids[anchor] : anchor;
  return { target, anchor, actual, ids, url: actual === anchor ? url : `${url.slice(0, hashIndex)}#${actual}` };
}

function validateNativeBlocks(content, file, failures) {
  const paired = new Set(["hint", "tabs", "tab", "stepper", "step", "columns", "column", "updates", "update", "file", "openapi", "code", "content-ref"]);
  let markup = "", cursor = 0;
  for (const [start, end] of bodyCodeRanges(content)) {
    markup += content.slice(cursor, start);
    cursor = end;
  }
  markup += content.slice(cursor);
  const stack = [];
  for (const match of markup.matchAll(/\{%\s*(end)?([a-z-]+)\b[^%]*%\}/g)) {
    const [, closing, name] = match;
    if (!paired.has(name)) continue;
    if (closing) {
      if (stack.pop() !== name) failures.push(`Mismatched GitBook block in ${file}: ${match[0]}`);
    } else stack.push(name);
  }
  if (stack.length) failures.push(`Unclosed GitBook blocks in ${file}: ${stack.join(", ")}`);
}

function validateBodyTarget(url, file, localeRoot, redirects, spaces, failures) {
  let pathname;
  try { pathname = decodeURI(url.split(/[?#]/)[0]); }
  catch { failures.push(`Malformed link in ${file}: ${url}`); return; }
  if (pathname.startsWith("/broken/")) {
    failures.push(`Broken GitBook reference in ${file}: ${url}`);
    return;
  }
  // Both short and org-qualified URLs are valid GitBook serialization forms.
  const crossSpace = pathname.match(/^https:\/\/app\.gitbook\.com\/(?:o\/[^/]+\/)?s\/([^/]+)(?:\/(.*))?$/);
  if (crossSpace) {
    const space = Object.values(spaces ?? {}).find((value) => value.id === crossSpace[1]);
    const page = crossSpace[2]?.replace(/\/$/, "");
    if (space && page && !Object.values(space.pages).includes(page)) failures.push(`Broken cross-space target in ${file}: ${url}`);
    return;
  }
  if (!pathname || /^(?:[a-z][a-z\d+.-]*:|\/)/i.test(pathname)) return;
  const target = resolve(dirname(file), pathname);
  const local = relative(localeRoot, target).split("\\").join("/");
  const redirected = Object.hasOwn(redirects, local) ? resolve(localeRoot, redirects[local]) : null;
  if (local === ".." || local.startsWith("../") || !existsSync(target) && !(redirected && existsSync(redirected))) {
    failures.push(`Broken local target in ${file}: ${url}`);
  }
}

const skipped = new Set();
const generated = new Map();
const navigationPages = [];
for (const page of pages) generated.set(`${page.locale.directory}/${page.target}`, convert(page));
for (const locale of locales) {
  const home = pages.find((page) => page.locale === locale && page.local === "index.md");
  const summary = ["# Table of contents", "", `* ${summaryLink(home, home.title)}`, ""];
  for (const section of locale.sidebar) {
    summary.push(`## ${section.text}`, "");
    for (const item of section.items) {
      if (item.link) {
        const page = routeMap.get(item.link);
        if (!page) throw new Error(`Invalid sidebar link: ${item.link}`);
        summary.push(`* ${navigationLink(page, item.text, locale)}`);
      } else {
        const directory = groupDirectory(item);
        const target = `${directory}/README.md`;
        const groupBody = [`# ${item.text}`, ""];
        summary.push(`* [${item.text}](${target})`);
        for (const child of item.items) {
          const page = routeMap.get(child.link);
          if (!page) throw new Error(`Invalid sidebar child: ${child.link}`);
          summary.push(`  * ${navigationLink(page, child.text, locale)}`);
          const group = { locale, source: `${locale.sourcePrefix}${target}`, target };
          groupBody.push(`* [${child.text}](${rewriteURL(child.link, group)})`);
        }
        generated.set(`${locale.directory}/${target}`, groupBody.join("\n") + "\n");
        navigationPages.push({ locale: locale.directory, target, title: item.text });
      }
    }
    summary.push("");
  }
  generated.set(`${locale.directory}/SUMMARY.md`, summary.join("\n"));
  const redirects = {};
  for (const page of pages.filter((entry) => entry.locale === locale)) {
    redirects[page.local.replace(/\.md$/, ".html")] = page.target;
  }
  generated.set(`${locale.directory}/.gitbook.yaml`, yaml.dump({ root: "./", structure: { readme: "README.md", summary: "SUMMARY.md" }, redirects }, { lineWidth: -1 }));
  generated.set(`${locale.directory}/.gitbook/assets/logo.png`, readFileSync(join(docs, "public/logo.png")));
}

for (const [filename, content] of generated) {
  const match = filename.match(/^([^/]+)\/(.+\.md)$/);
  if (match && match[2] !== "SUMMARY.md") {
    generated.set(filename, applyGitBookDesign(content, { locale: match[1], target: match[2] }));
  }
}

const manifest = {
  source: "docs", site: "site_02JAH", organization: "EVCRCIIkGN9ucEMGTbom",
  locales: locales.map(({ directory, label, language }) => ({ directory, label, language })),
  pages: pages.map((page) => ({ source: page.source, locale: page.locale.directory, target: page.target, sourceHash: hash(page.raw) })),
  navigationPages,
  crossLinks,
};
const spaceMapPath = join(output, "space-ids.json");
const anchorMapPath = join(output, "anchor-ids.json");
const importedSpaces = existsSync(spaceMapPath) ? JSON.parse(readFileSync(spaceMapPath, "utf8")) : null;
const importedAnchors = existsSync(anchorMapPath) ? JSON.parse(readFileSync(anchorMapPath, "utf8")) : null;

if (mode === "export") {
  for (const [filename, content] of generated) writeNew(join(output, filename), content);
  writeNew(join(output, "migration-manifest.json"), JSON.stringify(manifest, null, 2) + "\n");
  console.log(`Exported ${pages.length} source pages and ${navigationPages.length} navigation pages across ${locales.length} languages.`);
  if (skipped.size) console.log(`Preserved ${skipped.size} existing edited files. Regenerate into a separate checkout to compare changes.`);
} else if (mode === "resolve-links") {
  if (!importedSpaces || !importedAnchors) throw new Error("Read the imported page paths and heading IDs into space-ids.json and anchor-ids.json before resolving links.");
  const importedManifest = JSON.parse(readFileSync(join(output, "migration-manifest.json"), "utf8"));
  const changes = new Map();
  let crossSpaceReferences = 0;
  for (const link of importedManifest.crossLinks) {
    const target = importedSpaces[link.locale];
    if (!target?.id || !Object.hasOwn(target.pages, link.target)) throw new Error(`Missing imported page: ${link.locale}/${link.target}`);
    const url = `https://app.gitbook.com/s/${target.id}/${target.pages[link.target]}${link.suffix}`;
    const filename = join(output, link.file);
    const content = changes.get(filename) ?? readFileSync(filename, "utf8");
    const count = content.split(link.provisional).length - 1;
    if (!count) continue;
    crossSpaceReferences += count;
    changes.set(filename, content.replaceAll(link.provisional, url));
  }
  let fragments = 0;
  for (const locale of locales) for (const filename of walk(join(output, locale.directory))) {
    const content = changes.get(filename) ?? readFileSync(filename, "utf8");
    const updated = transformBodyLinks(content, (url) => {
      const reference = importedFragment(url, relative(output, filename), importedSpaces, importedAnchors);
      if (!reference || reference.url === url) return url;
      fragments++;
      return reference.url;
    });
    if (updated !== content) changes.set(filename, updated);
  }
  for (const [filename, content] of changes) writeFileSync(filename, content);
  console.log(`Resolved ${crossSpaceReferences} cross-space references and ${fragments} heading fragments using imported page paths and IDs.`);
}

// Check rendered source content rather than demanding GitBook's exact serialization.
const failures = [];
let fences = 0;
let mermaids = 0;
let anchors = 0;
let unresolved = 0;
let fragments = 0;
for (const page of pages) {
  const filename = join(output, page.locale.directory, page.target);
  if (!existsSync(filename)) { failures.push(`Missing page: ${filename}`); continue; }
  const converted = readFileSync(filename, "utf8");
  try { matter(converted); } catch (error) { failures.push(`${filename}: ${error.message}`); }
  const sourceFences = fencedTokens(page.body);
  const importedFences = fencedTokens(matter(converted).content);
  let previous = -1;
  for (const sourceFence of sourceFences) {
    const match = importedFences.findIndex((item, index) => index > previous && item.info === sourceFence.info && item.content === sourceFence.content);
    if (match < 0) failures.push(`Changed or missing code block in ${page.source}`);
    else previous = match;
  }
  fences += sourceFences.length;
  mermaids += sourceFences.filter((item) => item.info === "mermaid").length;
  for (const match of page.body.matchAll(/\{#([^}]+)\}/g)) {
    anchors += 1;
    if (!converted.includes(`id="${match[1]}"`)) failures.push(`Missing explicit anchor ${match[1]} in ${page.source}`);
  }
  const prose = matter(converted).content.split("\n");
  for (const token of importedFences) for (let line = token.map[0]; line < token.map[1]; line++) prose[line] = "";
  if (/^\s*:::|<(?:script|style|PrivacyView|LicensesView|SponsorList)\b|\{\{\s*frontmatter/m.test(prose.join("\n"))) failures.push(`Unconverted VitePress syntax in ${page.source}`);
}
for (const locale of locales) {
  const localeRoot = join(output, locale.directory);
  if (!existsSync(join(localeRoot, "SUMMARY.md"))) { failures.push(`Missing SUMMARY: ${locale.directory}`); continue; }
  const summary = readFileSync(join(localeRoot, "SUMMARY.md"), "utf8");
  const listed = [...summary.matchAll(/^\s*\* \[.*\]\(([^\s)]+)(?: "[^"]*")?\)$/gm)].map((match) => match[1]);
  if (new Set(listed).size !== listed.length) failures.push(`Duplicate SUMMARY page: ${locale.directory}`);
  for (const page of pages.filter((entry) => entry.locale === locale)) if (!listed.includes(page.target)) failures.push(`Page omitted from SUMMARY: ${locale.directory}/${page.target}`);
  for (const target of listed) if (!/^https?:\/\//.test(target) && !existsSync(join(localeRoot, target))) failures.push(`Broken SUMMARY target: ${locale.directory}/${target}`);
  const settings = yaml.load(readFileSync(join(localeRoot, ".gitbook.yaml"), "utf8"));
  for (const target of Object.values(settings.redirects ?? {})) if (!existsSync(join(localeRoot, target))) failures.push(`Broken redirect target: ${locale.directory}/${target}`);
  for (const filename of walk(localeRoot)) {
    const content = readFileSync(filename, "utf8");
    unresolved += (content.match(/XSPACE_[A-Z_]+/g) ?? []).length;
    try {
      const { data, content: body } = matter(content);
      if (data.description !== undefined && typeof data.description !== "string") failures.push(`Invalid page description in ${filename}`);
      if (data.icon !== undefined && typeof data.icon !== "string") failures.push(`Invalid page icon in ${filename}`);
      validateNativeBlocks(body, filename, failures);
    } catch (error) { failures.push(`${filename}: ${error.message}`); }
    transformBodyLinks(content, (url) => {
      validateBodyTarget(url, filename, localeRoot, settings.redirects ?? {}, importedSpaces, failures);
      if (!importedSpaces || !importedAnchors) return url;
      const reference = importedFragment(url, relative(output, filename), importedSpaces, importedAnchors);
      if (!reference) return url;
      fragments++;
      if (!reference.ids) failures.push(`Missing imported heading IDs for ${reference.target}`);
      else if (reference.url !== url || !Object.values(reference.ids).includes(reference.anchor)) {
        failures.push(`Broken imported heading link in ${relative(output, filename)}: ${url}${reference.url !== url ? ` (use ${reference.url})` : ""}`);
      }
      return url;
    });
  }
}
if (mode !== "export" && (!importedSpaces || !importedAnchors)) failures.push("Imported page/heading maps are missing; collect space-ids.json and anchor-ids.json after the initial Git Sync import.");
if (unresolved) {
  const message = `${unresolved} cross-space references await the initial Git Sync import and resolve-links.`;
  if (mode === "check") failures.push(message);
  else console.log(message);
}
if (!failures.length) console.log(`Verified ${pages.length} pages, ${fences} original code blocks (${mermaids} Mermaid), ${anchors} explicit anchors, ${fragments} imported heading links, and all navigation/redirect targets.`);
if (failures.length) { console.error(failures.join("\n")); process.exitCode = 1; }
