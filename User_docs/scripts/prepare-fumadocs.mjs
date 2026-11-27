import { readFile, writeFile, mkdir, rm, readdir, cp } from 'node:fs/promises';
import path from 'node:path';
import matter from 'gray-matter';
import GithubSlugger from 'github-slugger';
import { unified } from 'unified';
import remarkParse from 'remark-parse';
import remarkStringify from 'remark-stringify';
import remarkGfm from 'remark-gfm';
import remarkMdx from 'remark-mdx';
import { visit } from 'unist-util-visit';

const root = path.resolve(import.meta.dirname, '..');
const input = path.join(root, 'docs');
const output = path.join(root, '.content/docs');
const parser = unified().use(remarkParse).use(remarkGfm);
const writer = unified().use(remarkStringify).use(remarkGfm).use(remarkMdx);
const languages = ['zh-Hans', 'zh-Hant', 'en'];
const locales = new Set(['zh-Hant', 'en']);
const navigation = JSON.parse(await readFile(path.join(root, 'config/docs-navigation.json'), 'utf8'));
const catalogs = JSON.parse(await readFile(path.join(root, 'config/locales.json'), 'utf8'));
const label = (locale, key) => catalogs[locale].text[key] ?? key;
const pageUrl = (locale, slug) => `${locale === 'zh-Hans' ? '' : '/' + locale}/docs/${slug}`;

function jsx(name, props = {}, children = []) {
  return { type: 'mdxJsxFlowElement', name, attributes: Object.entries(props).map(([name, value]) => ({ type: 'mdxJsxAttribute', name, value })), children };
}
function textOf(node) { return node.value ?? node.children?.map(textOf).join('') ?? ''; }
function spaceContainers(content) {
  let fence;
  return content.split('\n').map(line => {
    const marker = line.match(/^\s*(`{3,}|~{3,})/);
    if (marker) {
      if (!fence) fence = marker[1];
      else if (marker[1][0] === fence[0] && marker[1].length >= fence.length) fence = undefined;
    }
    return !fence && /^:::(?:\s|$)/.test(line) ? `\n${line}\n` : line;
  }).join('\n');
}
export function portableMarkdown(tree, sponsorData, locale = 'zh-Hans') {
  function convertNode(node) {
    const children = node.children?.flatMap(convertNode);
    if (node.type !== 'mdxJsxFlowElement') return [{ ...node, ...(children ? { children } : {}) }];
    const attrs = Object.fromEntries(node.attributes.map(attr => [attr.name, attr.value]));
    const paragraph = text => ({ type: 'paragraph', children: [{ type: 'strong', children: [{ type: 'text', value: text }] }] });
    if (node.name === 'Callout') return [{ type: 'blockquote', children: [paragraph(attrs.title), ...children] }];
    if (node.name === 'details') return [{ type: 'blockquote', children }];
    if (node.name === 'summary') return [{ type: 'paragraph', children: [{ type: 'strong', children }] }];
    if (node.name === 'Mermaid') return [{ type: 'code', lang: 'mermaid', value: attrs.chart }];
    if (node.name === 'span') return [];
    if (node.name === 'SponsorList') {
      const cell = children => ({ type: 'tableCell', children });
      const text = value => ({ type: 'text', value });
      const row = cells => ({ type: 'tableRow', children: cells });
      const parseSponsorDate = raw => {
        const parts = String(raw ?? '').trim().split('-').map(Number);
        if (parts.length === 3 && parts.every(Number.isFinite)) {
          return Date.UTC(parts[0], parts[1] - 1, parts[2]);
        }
        const timestamp = Date.parse(raw);
        return Number.isNaN(timestamp) ? Number.MAX_SAFE_INTEGER : timestamp;
      };
      const entries = [
        ...sponsorData.sponsors.map(sponsor => ({ ...sponsor, anonymous: false })),
        ...(sponsorData.anonymousSponsors ?? []).map(sponsor => ({ ...sponsor, anonymous: true })),
      ].sort((a, b) => b.amount - a.amount || parseSponsorDate(a.date) - parseSponsorDate(b.date));
      return [{ type: 'table', align: [null, null, 'right'], children: [
        row([cell([text(label(locale, '赞助者'))]), cell([text(label(locale, '留言'))]), cell([text(label(locale, '金额（CNY）'))])]),
        ...entries.map(entry => row([
          cell([entry.anonymous
            ? text(label(locale, '匿名赞助者'))
            : (entry.link ? { type: 'link', url: entry.link, children: [text(entry.name)] } : text(entry.name))]),
          cell([text(entry.message || '—')]),
          cell([text(entry.amount.toLocaleString(locale, { maximumFractionDigits: 2 }))]),
        ])),
      ] }];
    }
    throw new Error(`Unsupported Markdown export component: ${node.name}`);
  }
  return unified().use(remarkStringify).use(remarkGfm).stringify(convertNode(tree)[0]);
}
export function convert(content, locale = 'zh-Hans') {
  content = content.replace(/<script\b[^>]*>[\s\S]*?<\/script>/g, '')
    .replace(/<div align="center">\s*<img src="([^"]+)" alt="([^"]*)"[^>]*\/>\s*<\/div>/g, '![$2]($1)');
  const tree = parser.parse(spaceContainers(content));
  const result = { type: 'root', children: [] };
  const stack = [result];
  for (const node of tree.children) {
    const marker = node.type === 'paragraph' ? textOf(node).match(/^:::(?:\s+(tip|info|warning|danger|details)(?:\s+(.*))?)?$/) : null;
    if (marker) {
      if (!marker[1]) {
        if (stack.length === 1) throw new Error('Unexpected closing Markdown container');
        stack.pop();
      } else {
        const [, kind, title] = marker;
        const block = kind === 'details'
          ? jsx('details', {}, [jsx('summary', {}, [{ type: 'text', value: title || label(locale, '详细说明') }])])
          : jsx('Callout', { type: ({ tip: 'info', danger: 'error' })[kind] || kind, title: title || label(locale, ({ tip: '提示', info: '说明', warning: '注意', danger: '警告' })[kind]) });
        stack.at(-1).children.push(block); stack.push(block);
      }
    } else if (node.type === 'html' && /^<SponsorList\b/.test(node.value)) {
      stack.at(-1).children.push(jsx('SponsorList'));
    } else if (node.type === 'html') {
      throw new Error(`Unsupported HTML: ${node.value.slice(0, 100)}`);
    } else {
      stack.at(-1).children.push(node);
    }
  }
  if (stack.length !== 1) throw new Error('Unclosed Markdown container');
  const slugger = new GithubSlugger();
  const headingIds = new Set();
  visit(result, 'heading', node => {
    const last = node.children.at(-1);
    const anchor = last?.type === 'text' && last.value.match(/\s*\{#([^}]+)\}\s*$/);
    if (anchor) last.value = last.value.slice(0, anchor.index);
    if (node.depth === 1) return;
    const id = anchor ? anchor[1] : slugger.slug(textOf(node));
    if (headingIds.has(id)) throw new Error(`Duplicate heading ID: ${id}`);
    headingIds.add(id);
    node.data = { ...node.data, canonicalId: id };
  });
  visit(result, 'link', node => {
    if (node.url.startsWith('/docs/')) node.url = pageUrl(locale, node.url.slice(6));
  });
  visit(result, 'code', (node, index, parent) => {
    if (node.lang === 'mermaid') parent.children[index] = jsx('Mermaid', { chart: node.value });
  });
  const firstHeading = result.children.findIndex(node => node.type === 'heading' && node.depth === 1);
  let title;
  if (firstHeading !== -1) title = textOf(result.children.splice(firstHeading, 1)[0]);
  const mdxTree = structuredClone(result);
  visit(mdxTree, 'heading', node => {
    if (node.data?.canonicalId) node.children.push({ type: 'text', value: ` [#${node.data.canonicalId}]` });
  });
  // Fumadocs reads fixed IDs from heading text. Leaving remark's escape here
  // produces a stray backslash in the structured search heading.
  const body = writer.stringify(mdxTree).replace(/^(#{2,6} .*?) \\\[#([^\]]+)\]$/gm, '$1 [#$2]');
  return { title, body, tree: result };
}
async function walk(dir, prefix = '') {
  const files = [];
  for (const entry of await readdir(dir, { withFileTypes: true })) {
    if (entry.name.startsWith('.') || locales.has(entry.name) || entry.name === 'public') continue;
    const relative = path.join(prefix, entry.name);
    if (entry.isDirectory()) files.push(...await walk(path.join(dir, entry.name), relative));
    else if (entry.name.endsWith('.md') && relative !== 'index.md') files.push(relative);
  }
  return files.sort();
}
if (process.argv[1] === import.meta.filename) {
  await rm(path.join(root, '.content'), { recursive: true, force: true });
  await rm(path.join(root, 'public'), { recursive: true, force: true });
  await mkdir(output, { recursive: true });
  const manifest = [];
  const sponsors = JSON.parse(await readFile(path.join(root, '../sponsors.json'), 'utf8'));
  const expected = [...navigation.main.flatMap(entry => entry.children ?? [entry]).map(entry => entry.slug), ...navigation.auxiliary];
  if (new Set(expected).size !== expected.length) throw new Error('Duplicate navigation entries');
  const anchors = new Map();
  for (const locale of languages) {
    const directory = locale === 'zh-Hans' ? input : path.join(input, locale);
    const files = await walk(directory);
    if (files.length !== expected.length || files.some(file => !expected.includes(file.replace(/\.md$/, '')))) throw new Error(`Incomplete source inventory: ${locale}`);
    for (const file of files) {
      const { content, data } = matter(await readFile(path.join(directory, file), 'utf8'));
      const slug = file.replace(/\.md$/, '');
      const { title, body, tree } = convert(content, locale);
      const ids = []; visit(tree, 'heading', node => { if (node.data?.canonicalId) ids.push(node.data.canonicalId); });
      if (locale === 'zh-Hans') anchors.set(slug, ids);
      else if (JSON.stringify(ids) !== JSON.stringify(anchors.get(slug))) throw new Error(`Translation chapter mismatch: ${locale}/${slug}`);
      const sourcePath = (locale === 'zh-Hans' ? '' : locale + '/') + file;
      const target = path.join(output, locale, slug + '.mdx');
      await mkdir(path.dirname(target), { recursive: true });
      await writeFile(target, matter.stringify(body, { title: data.title || title || slug, sourcePath }));
      const markdownPath = path.join(root, 'public/docs-md', locale, slug + '.md');
      await mkdir(path.dirname(markdownPath), { recursive: true });
      await writeFile(markdownPath, '# ' + (data.title || title || slug) + '\n\n' + portableMarkdown(tree, sponsors, locale));
      manifest.push({ locale, slug, sourcePath, title: data.title || title || slug, url: pageUrl(locale, slug), headings: ids });
    }
  }
  await writeFile(path.join(root, '.content/manifest.json'), JSON.stringify(manifest, null, 2));
  await cp(path.join(input, 'public'), path.join(root, 'public'), { recursive: true });
  await cp(path.join(root, '../sponsors.json'), path.join(root, 'public/sponsors.json'));
  console.log(`Prepared ${manifest.length} pages in ${languages.length} languages and public assets.`);
}
