import type { Metadata } from 'next';
import Script from 'next/script';
import { Provider } from './provider';
import { SiteHeader } from './site-header';
import { text, homeUrl, alternates, type Locale } from '@/lib/i18n';
import '@/app/global.css';
export function siteMetadata(locale: Locale): Metadata {
  return { metadataBase: new URL('https://docs-appports.shimoko.com'), title: { default: text(locale, 'AppPorts 使用文档'), template: `%s · ${text(locale, 'AppPorts 文档')}` }, description: text(locale, '了解如何迁移应用与数据、使用外置存储，以及处理日常问题。'), icons: { icon: '/logo.png' }, alternates: { canonical: homeUrl(locale), ...alternates() } };
}
export function SiteDocument({ locale, children }: { locale: Locale; children: React.ReactNode }) {
  return (
    <html lang={locale} suppressHydrationWarning>
      <body>
        <Provider locale={locale}><SiteHeader />{children}</Provider>
        <Script
          src="https://cloud.umami.is/script.js"
          strategy="afterInteractive"
          data-website-id="2f0679ac-f605-4a76-9a55-11681b47cef5"
          data-domains="docs-appports.shimoko.com"
          data-exclude-search="true"
          data-exclude-hash="true"
        />
      </body>
    </html>
  );
}
