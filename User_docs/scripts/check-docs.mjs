import assert from 'node:assert/strict';
import { readFile, access, stat } from 'node:fs/promises';
import path from 'node:path';
import { convert } from './prepare-fumadocs.mjs';

const root = path.resolve(import.meta.dirname, '..');
const out = path.join(root, 'out');
const pages = JSON.parse(await readFile(path.join(root, '.content/manifest.json'), 'utf8'));
const navigation = JSON.parse(await readFile(path.join(root, 'config/docs-navigation.json'), 'utf8'));
const catalogs = JSON.parse(await readFile(path.join(root, 'config/locales.json'), 'utf8'));
const locales = ['zh-Hans', 'zh-Hant', 'en'];
const prefix = locale => locale === 'zh-Hans' ? '' : `/${locale}`;
const url = (locale, slug) => `${prefix(locale)}/docs/${slug}`;
const exists = async file => { try { return (await stat(file)).isFile(); } catch { return false; } };
const cache = new Map();
async function html(file) {
  if (!cache.has(file)) cache.set(file, await readFile(path.join(out, file), 'utf8'));
  return cache.get(file);
}
const expected = [...navigation.main.flatMap(entry => entry.children ?? [entry]).map(entry => entry.slug), ...navigation.auxiliary].sort();
assert.equal(expected.length, 28);
assert.equal(pages.length, 84);
for (const locale of locales) {
  assert.deepEqual(pages.filter(page => page.locale === locale).map(page => page.slug).sort(), expected);
  for (const group of ['text', 'provider', 'descriptions']) {
    assert.deepEqual(Object.keys(catalogs[locale][group]).sort(), Object.keys(catalogs['zh-Hans'][group]).sort(), `Incomplete ${locale} ${group}`);
    assert.ok(Object.values(catalogs[locale][group]).every(value => typeof value === 'string' && value.trim()), `Empty ${locale} ${group}`);
  }
}
const failures = [];
const routes = [
  ...locales.map(locale => ({ locale, url: prefix(locale) || '/', file: locale === 'zh-Hans' ? 'index.html' : locale + '.html' })),
  ...pages.map(page => ({ ...page, file: page.url.slice(1) + '.html' })),
];
for (const route of routes) {
  const body = await html(route.file);
  assert.ok(body.includes(`<html lang="${route.locale}"`), `Wrong HTML language: ${route.url}`);
  assert.ok(!body.includes('::: tip') && !body.includes('::: warning'), `Unconverted callout: ${route.url}`);
  assert.ok(body.includes(`rel="canonical" href="https://docs-appports.shimoko.com${route.url === "/" ? "" : route.url}"`), `Wrong canonical: ${route.url}`);
  for (const locale of locales) {
    const alternate = route.slug ? url(locale, route.slug) : prefix(locale) || '/';
    assert.ok(body.includes(`hrefLang="${locale}" href="https://docs-appports.shimoko.com${alternate === "/" ? "" : alternate}"`), `Wrong hreflang: ${route.url}/${locale}`);
  }
  const current = new URL(route.url, 'https://docs.test');
  for (const [, raw] of body.matchAll(/<(?:a|link)\b[^>]*\bhref="([^"]+)"/g)) {
    if (/^(?:mailto:|tel:|data:)/.test(raw)) continue;
    const target = new URL(raw.replaceAll('&amp;', '&'), current);
    if (target.origin !== current.origin) continue;
    const pathname = decodeURIComponent(target.pathname).replace(/^\//, '');
    const candidates = pathname ? [pathname, pathname + '.html', pathname + '/index.html'] : ['index.html'];
    let destination;
    for (const candidate of candidates) if (await exists(path.join(out, candidate))) { destination = candidate; break; }
    if (!destination) { failures.push(`${route.url}: missing ${raw}`); continue; }
    if (target.hash && destination.endsWith('.html')) {
      const id = decodeURIComponent(target.hash.slice(1));
      if (!(await html(destination)).includes(`id="${id}"`)) failures.push(`${route.url}: missing anchor ${raw}`);
    }
    if (target.pathname.includes('/docs/') && !target.pathname.startsWith(`${prefix(route.locale)}/docs/`)) {
      // Language choices are the only links allowed to leave the current locale.
      if (!locales.some(locale => target.pathname === url(locale, route.slug ?? 'AppPorts'))) failures.push(`${route.url}: cross-language link ${raw}`);
    }
  }
}
for (const page of pages) {
  const markdown = await readFile(path.join(out, 'docs-md', page.locale, page.slug + '.md'), 'utf8');
  assert.ok(!/<(?:SponsorList|Mermaid|Callout)\b/.test(markdown), `Non-portable Markdown: ${page.url}`);
  assert.ok(markdown.startsWith('# ' + page.title), `Wrong exported title: ${page.url}`);
  const rendered = await html(page.url.slice(1) + '.html');
  for (const id of page.headings) assert.ok(rendered.includes(`id="${id}"`), `Missing heading: ${page.url}#${id}`);
  const canonical = pages.find(item => item.locale === 'zh-Hans' && item.slug === page.slug);
  assert.deepEqual(page.headings, canonical.headings, `Chapter mismatch: ${page.url}`);
  if (page.slug === 'sponsor') {
    for (const value of ['a@shimoko.com', '350', '0.63']) assert.ok(markdown.includes(value), `Sponsor export missing ${value}: ${page.url}`);
  }
  if (page.slug === 'AppPorts') for (const link of ['https://deepwiki.com/wzh4869/AppPorts', 'https://www.shimoko.com/p/appports/']) assert.ok(markdown.includes(link));
  if (page.slug === 'migration-strategy/portal') assert.ok(markdown.includes('```mermaid'));
}
for (const retired of ['ja', 'ko', 'de', 'fr', 'es']) {
  await assert.rejects(access(path.join(root, 'docs', retired)));
  await assert.rejects(access(path.join(out, retired)));
}
for (const retired of ['docs/.vitepress', 'config/legacy-links.json', 'config/language-links.json', 'lib/legacy-links.mjs', 'components/legacy-redirect.tsx', 'scripts/export-legacy-paths.mjs']) await assert.rejects(access(path.join(root, retired)));
for (const slug of [...expected, 'why-apfs', 'limitations', 'logging', 'troubleshooting']) assert.ok(!await exists(path.join(out, slug + '.html')), `Old root alias still exported: ${slug}`);
for (const slug of ['research/sandbox-symlink', 'research/sandbox-mountpoint', 'research/unplug-test', 'research/prelogin-mount', 'research/container-structure', 'research/data-integrity', 'why-apfs', 'limitations', 'logging', 'troubleshooting']) {
  for (const locale of locales) assert.ok(!await exists(path.join(out, prefix(locale), 'docs', slug + '.html')), `Retired route exported: ${locale}/${slug}`);
}
assert.equal(navigation.main[0].slug, 'AppPorts');
assert.equal(navigation.main.at(-1).slug, 'glossary');
assert.equal(navigation.main.at(-1).name, '名词解释');
assert.equal(navigation.main.flatMap(entry => entry.children ?? [entry]).length, 27);
assert.deepEqual(navigation.main.filter(entry => entry.children).map(entry => entry.name), ['原理', '博客', '帮助与支持', '历史功能归档']);
assert.equal(navigation.main.find(entry => entry.name === '历史功能归档').children.length, 4);
for (const slug of ['settings', 'changelog', 'sponsor', 'licenses', 'privacy']) assert.ok(navigation.main.some(entry => entry.slug === slug));
assert.deepEqual(JSON.parse(await readFile(path.join(out, 'sponsors.json'))), JSON.parse(await readFile(path.join(root, '../sponsors.json'))));
for (const asset of ['latest.json', 'logo.png']) assert.deepEqual(await readFile(path.join(out, asset)), await readFile(path.join(root, 'docs/public', asset)));
const sample = convert('# Test\n\n::: warning Important\n\nKeep {literal} and <path>.\n\n```sh\necho ":::"\n```\n\n:::\n\n::: details More\n\n[Link](/docs/faststart#install)\n\n:::\n', 'en');
assert.match(sample.body, /<Callout type="warning" title="Important">/);
assert.match(sample.body, /<details>/);
assert.match(sample.body, /\/en\/docs\/faststart#install/);
assert.match(sample.body, /echo ":::"/);
assert.equal(convert('## A chapter {#chapter}').body.trim(), '## A chapter [#chapter]');
assert.throws(() => convert('::: warning Oops\n\ntext'), /Unclosed/);
assert.throws(() => convert('## One {#same}\n\n## Two {#same}'), /Duplicate heading/);
assert.equal(failures.length, 0, failures.join('\n'));
console.log(`Verified ${pages.length} translated articles, ${routes.length} pages, metadata, internal links/anchors, portable Markdown, navigation, retired routes, and public assets.`);
