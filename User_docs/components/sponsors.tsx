'use client';
import { useLocale, useText } from './provider';
import sponsors from '@/public/sponsors.json';

interface NamedSponsor {
  name: string;
  link?: string;
  message?: string;
  amount: number;
  date: string;
}

interface AnonymousSponsor {
  message: string;
  amount: number;
  date: string;
}

type SponsorEntry =
  | { kind: 'named'; key: string; name: string; link?: string; message?: string; amount: number; date: string }
  | { kind: 'anonymous'; key: string; message: string; amount: number; date: string };

function parseSponsorDate(raw: string): number {
  const parts = raw.trim().split('-').map(Number);
  if (parts.length === 3 && parts.every(Number.isFinite)) {
    return Date.UTC(parts[0], parts[1] - 1, parts[2]);
  }
  const timestamp = Date.parse(raw);
  return Number.isNaN(timestamp) ? Number.MAX_SAFE_INTEGER : timestamp;
}

export function SponsorList() {
  const locale = useLocale();
  const t = useText();
  const data = sponsors as { sponsors: NamedSponsor[]; anonymousSponsors?: AnonymousSponsor[] };
  const entries: SponsorEntry[] = [
    ...data.sponsors.map((sponsor, index) => ({
      kind: 'named' as const,
      key: `named-${sponsor.name}-${sponsor.date}-${index}`,
      name: sponsor.name,
      link: sponsor.link,
      message: sponsor.message,
      amount: sponsor.amount,
      date: sponsor.date,
    })),
    ...(data.anonymousSponsors ?? []).map((sponsor, index) => ({
      kind: 'anonymous' as const,
      key: `anonymous-${sponsor.date}-${index}`,
      message: sponsor.message,
      amount: sponsor.amount,
      date: sponsor.date,
    })),
  ].sort((a, b) => b.amount - a.amount || parseSponsorDate(a.date) - parseSponsorDate(b.date));

  return (
    <div className="sponsor-list not-prose">
      {entries.map(entry => (
        <div key={entry.key} className="sponsor-card">
          <div className="sponsor-card-main">
            {entry.kind === 'named' ? (
              <div className="sponsor-card-title">
                {entry.link ? (
                  <a href={entry.link} target="_blank" rel="noreferrer">{entry.name}</a>
                ) : (
                  <span>{entry.name}</span>
                )}
              </div>
            ) : (
              <div className="sponsor-card-title sponsor-card-anonymous">{t('匿名赞助者')}</div>
            )}
            {entry.message ? <p className="sponsor-card-message">{entry.message}</p> : null}
          </div>
          <span className="sponsor-card-amount">
            ¥{entry.amount.toLocaleString(locale, { maximumFractionDigits: 2 })}
          </span>
        </div>
      ))}
    </div>
  );
}
