import { source } from '@/lib/source';
import Link from 'next/link';
import { PageActions } from './page-actions';
import { pageSection } from '@/lib/navigation';
import { DocsBody, DocsDescription, DocsPage, DocsTitle } from 'fumadocs-ui/layouts/docs/page';
import { notFound } from 'next/navigation';
import { getMDXComponents } from './mdx';
import { createRelativeLink } from 'fumadocs-ui/mdx';
import { description, docUrl, alternates, type Locale } from '@/lib/i18n';
const pagesWithoutSubtitle = new Set(['consensus', 'licenses', 'privacy', 'glossary']);
export function DocumentationPage({ slug, locale }: { slug: string[]; locale: Locale }) {
  const page = source.getPage(slug, locale);
  if (!page) notFound();
  const MDX = page.data.body; const key = slug.join('/'); const section = pageSection(key, locale);
  return <DocsPage breadcrumb={{ enabled: false }} toc={page.data.toc} tableOfContent={{ style: 'clerk' }}>
    <Link className="page-section" href={section.url}>{section.name}</Link><DocsTitle>{page.data.title}</DocsTitle>
    {!pagesWithoutSubtitle.has(key) && <DocsDescription>{description(locale, key)}</DocsDescription>}
    <PageActions markdownUrl={`/docs-md/${locale}/${key}.md`} sourcePath={`${locale === 'zh-Hans' ? '' : locale + '/'}${key}.md`} />
    <DocsBody><MDX components={getMDXComponents({ a: createRelativeLink(source, page) })} /></DocsBody>
  </DocsPage>;
}
export function pageMetadata(slug: string[], locale: Locale) {
  const page = source.getPage(slug, locale); if (!page) notFound(); const key = slug.join('/');
  return { title: page.data.title, description: description(locale, key), alternates: { canonical: docUrl(locale, key), ...alternates(key) } };
}
