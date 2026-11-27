import { text, docUrl, type Locale } from './i18n';
import type { Root, Node } from 'fumadocs-core/page-tree';
import { source } from './source';
import { entries } from './docs-structure';
import { createElement } from 'react';
import { AppWindow, BookOpen, BookA, Rocket, Boxes, Tags, FolderOpen, HardDrive, ShieldAlert, ShieldCheck, RefreshCw, Settings, CircleHelp, ScrollText, FlaskConical, Heart, Scale, Lock, Undo2, History, Newspaper, FolderLock, Archive, FileText, type LucideIcon } from 'lucide-react';
const icons: Record<string, LucideIcon> = { AppWindow, BookOpen, BookA, Rocket, Boxes, Tags, FolderOpen, HardDrive, ShieldAlert, ShieldCheck, RefreshCw, Settings, CircleHelp, ScrollText, FlaskConical, Heart, Scale, Lock, Undo2, History, Newspaper, FolderLock, Archive };


export function docsTree(locale: Locale): Root {
  const names = new Map(entries.flatMap(entry => [entry, ...(entry.children ?? [])]).map(entry => [text(locale, entry.name), entry.icon]));
  function decorate(node: Node): Node {
    const icon = createElement(icons[names.get(String(node.name)) ?? ''] ?? FileText, { size: 17, strokeWidth: 1.6, 'aria-hidden': true });
    return node.type === 'folder' ? { ...node, icon, children: node.children.map(decorate) } : { ...node, icon };
  }
  return { ...source.getPageTree(locale), children: source.getPageTree(locale).children.map(decorate) };
}

export function pageSection(slug: string, locale: Locale): { name: string; url: string } {
  if (slug === 'contributing' || slug === 'archive/overview') return { name: text(locale, '项目'), url: docUrl(locale, 'AppPorts') };
  for (const entry of entries) {
    if (entry.children?.some(child => child.slug === slug)) return { name: text(locale, entry.name), url: docUrl(locale, entry.children[0].slug!) };
  }
  return { name: text(locale, '文档'), url: docUrl(locale, 'AppPorts') };
}
