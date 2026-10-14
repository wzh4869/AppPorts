#!/usr/bin/env node

import { readFileSync, writeFileSync, readdirSync, existsSync } from 'node:fs';
import { join, resolve, relative, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

const templatePath = resolve(__dirname, '../assets/agent-notes-board.html');
const args = process.argv.slice(2);

if (!existsSync(templatePath)) {
  console.error(`❌ Template not found at: ${templatePath}`);
  process.exit(1);
}

// 检查参数
const isInitMode = args.includes('--init');
const isForce = args.includes('--force') || args.includes('-f');
const isMetadataOnly = args.includes('--metadata-only');
const cleanArgs = args.filter((a: string) => !a.startsWith('--') && !a.startsWith('-'));

function checkTargetSafety(targetPath: string) {
  if (existsSync(targetPath) && !isForce) {
    try {
      const existing = readFileSync(targetPath, 'utf8');
      const isBoard = existing.includes('generator" content="agent-notes-board"') || existing.includes('id="brand-project-title"');
      if (!isBoard) {
        console.error(`❌ 错误：目标文件已存在 (${targetPath}) 且并非看板生成文件！`);
        console.error(`💡 为防止意外覆盖已有项目页面（如 Vite/React/Vue 项目的 index.html），请指定其他输出路径或传入 --force 确认覆盖。`);
        process.exit(1);
      }
    } catch {}
  }
}

if (isInitMode) {
  const targetPath = cleanArgs[0] ? resolve(cleanArgs[0]) : resolve(process.cwd(), 'board.html');
  const projectName = cleanArgs[1] || '工程决策看板';

  checkTargetSafety(targetPath);

  let template = readFileSync(templatePath, 'utf8');
  template = template.replace('id="brand-project-title">工程决策看板<', () => `id="brand-project-title">${projectName}<`);

  writeFileSync(targetPath, template, 'utf8');
  console.log(`✅ [日常开发模式] 轻量看板已生成 (仅 ~69KB): ${targetPath}`);
  console.log(`💡 用浏览器打开后，点击右上角「连接本地目录」选择 .agents/notes，后续新建/修改笔记切回浏览器即可自动热刷新！`);
  process.exit(0);
}

// 打包模式（生成内联完整数据的单文件，如 demo.html）
const notesDir = cleanArgs[0] ? resolve(cleanArgs[0]) : resolve(process.cwd(), '.agents/notes');
const outputPath = cleanArgs[1] ? resolve(cleanArgs[1]) : resolve(process.cwd(), 'demo.html');
const projectName = cleanArgs[2] || '工程决策看板';

checkTargetSafety(outputPath);

const LIFECYCLES = ['implemented', 'proposed', 'rejected', 'archived'];

if (!existsSync(notesDir)) {
  console.error(`❌ Notes directory not found at: ${notesDir}`);
  process.exit(1);
}

/** Blank out fenced code-block lines so `## ` headings and [](.md) links inside them are never parsed as note structure. */
function stripFencedBlocks(raw: string): string {
  let inFence = false;
  return raw
    .replace(/\r\n?/g, "\n")
    .split("\n")
    .map((l) => {
      if (/^\s{0,3}```/.test(l)) {
        inFence = !inFence;
        return "";
      }
      return inFence ? "" : l;
    })
    .join("\n");
}

function parseNoteContent(raw: string, relPath: string, slugToId: Map<string, string>) {
  const parseable = stripFencedBlocks(raw);
  const slug = relPath.split('/').pop()!.replace(/\.md$/, '');
  const parts = relPath.split('/');
  const lifecycle = parts[0];
  const cls = parts[1] || 'architecture';

  let title = slug;
  let status = lifecycle;
  let date = '';

  const dMatch = /^(\d{4}-\d{2}-\d{2})/.exec(slug);
  if (dMatch) date = dMatch[1];

  const h1Match = /^# Agent Note[^:：]*[:：]\s*(.*)$/m.exec(parseable);
  if (h1Match) title = h1Match[1].trim();

  function extractSection(secNamePattern: string) {
    const re = new RegExp(`^## (?:${secNamePattern})\\s*\\n+([\\s\\S]*?)(?=^## |\\s*$)`, 'm');
    const m = re.exec(parseable);
    return m ? m[1].trim() : '';
  }

  const problem = extractSection('Problem|问题');
  const decision = extractSection('Decision|Proposal|决策|提案');
  const alternatives = extractSection('Alternatives considered|曾考虑的替代方案|曾考虑的备选');
  const consequences = extractSection('Consequences|后果');

  const links: string[] = [];
  for (const m of parseable.matchAll(/\]\(([^)]+\.md)\)/g)) {
    let targetHref = m[1].split('#')[0].trim();
    if (targetHref.includes('://')) continue;
    targetHref = targetHref.replace(/\.zh\.md$/, '.md');
    const segs = `${lifecycle}/${cls}/${targetHref}`.split('/');
    const resolved: string[] = [];
    for (const s of segs) {
      if (!s || s === '.') continue;
      if (s === '..') resolved.pop();
      else resolved.push(s);
    }
    const cleanTarget = resolved.join('/');

    let finalTarget = '';
    if (slugToId.has(cleanTarget)) {
      finalTarget = slugToId.get(cleanTarget)!;
    } else {
      const targetSlug = targetHref.split('/').pop()!.replace(/\.md$/, '');
      if (slugToId.has(targetSlug)) {
        finalTarget = slugToId.get(targetSlug)!;
      }
    }
    if (finalTarget && finalTarget !== relPath) {
      links.push(finalTarget);
    }
  }

  return {
    id: relPath,
    slug,
    lifecycle,
    cls,
    date,
    title,
    status,
    problem,
    decision,
    alternatives,
    consequences,
    outLinks: [...new Set(links)],
    rawBody: raw,
  };
}

function walk(dir: string, baseDir: string = dir): any[] {
  const noteFiles = new Map<string, string>(); // relPath -> fullPath

  function scan(currentDir: string) {
    const items = readdirSync(currentDir, { withFileTypes: true });
    for (const entry of items) {
      if (entry.name.startsWith('.')) continue;
      const fullPath = join(currentDir, entry.name);

      if (entry.isDirectory()) {
        scan(fullPath);
      } else if (entry.isFile() && entry.name.endsWith('.md')) {
        const isZh = entry.name.endsWith('.zh.md');
        const relPath = relative(baseDir, fullPath).replace(/\\/g, '/');
        const cleanRel = isZh ? relPath.replace(/\.zh\.md$/, '.md') : relPath;
        const parts = cleanRel.split('/');

        if (parts.length >= 3 && LIFECYCLES.includes(parts[0])) {
          if (!noteFiles.has(cleanRel) || isZh) {
            noteFiles.set(cleanRel, fullPath);
          }
        }
      }
    }
  }

  scan(dir);

  const slugToId = new Map<string, string>();
  for (const relPath of noteFiles.keys()) {
    const slug = relPath.split('/').pop()!.replace(/\.md$/, '');
    slugToId.set(slug, relPath);
    slugToId.set(relPath, relPath);
  }

  const results: any[] = [];
  for (const [relPath, fullPath] of noteFiles.entries()) {
    try {
      const raw = readFileSync(fullPath, 'utf8');
      results.push(parseNoteContent(raw, relPath, slugToId));
    } catch (err) {
      console.warn(`⚠️ Error reading ${relPath}:`, err);
    }
  }

  return results;
}

console.log(`🔍 [打包模式] 正在扫描笔记目录: ${notesDir}`);
const notes = walk(notesDir);
console.log(`✅ 解析完成，共发现 ${notes.length} 篇有效 Agent Notes。`);

if (isMetadataOnly) {
  console.log('🔒 [安全脱敏] 启用 --metadata-only 模式，已剥离所有笔记的具体正文和详细论证，仅保留决策元数据与关联拓扑。');
  for (const n of notes) {
    n.problem = '[正文已脱敏]';
    n.decision = '[正文已脱敏]';
    n.alternatives = '';
    n.consequences = '';
    n.rawBody = `# Agent Note: ${n.title}\n\nStatus: ${n.status}\n\n<!-- content redacted for public demo -->`;
  }
} else {
  console.log('⚠️ [安全提示] 正在生成包含完整正文的数据包。如需对外公开发布且避免泄露内部决策细节，请添加 --metadata-only 参数。');
}

let template = readFileSync(templatePath, 'utf8');

// 注入项目名
template = template.replace('id="brand-project-title">工程决策看板<', () => `id="brand-project-title">${projectName}<`);

// 注入数据
const jsonSafe = JSON.stringify(notes).replace(/</g, '\\u003c');
template = template.replace(
  'window.__INLINE_DATA__ = null;',
  () => `window.__INLINE_DATA__ = ${jsonSafe};`
);

writeFileSync(outputPath, template, 'utf8');
console.log(`🎉 [打包完成] 看板已生成: ${outputPath}`);
console.log(`💡 该文件内置了 ${notes.length} 篇笔记数据，可脱机分发、离线演示或部署至 GitHub Pages。`);
