import { readFileSync } from "node:fs";
import { join } from "node:path";
import { createContext, runInContext } from "node:vm";

// Read only the component's named data literal, without running imports or Vue setup.
function readObjectLiteral(filename, name) {
  const source = readFileSync(filename, "utf8");
  const script = source.match(/<script\b[^>]*>([\s\S]*?)<\/script>/)?.[1];
  const declaration = script?.match(new RegExp(`\\bconst\\s+${name}\\s*=\\s*\\{`));
  if (!declaration) {
    throw new Error(`Cannot find object literal ${name} in ${filename}`);
  }

  const start = declaration.index + declaration[0].length - 1;
  let depth = 0;
  let quote = null;
  let comment = null;
  for (let index = start; index < script.length; index += 1) {
    const char = script[index];
    const next = script[index + 1];
    if (comment === "line") {
      if (char === "\n") comment = null;
      continue;
    }
    if (comment === "block") {
      if (char === "*" && next === "/") {
        comment = null;
        index += 1;
      }
      continue;
    }
    if (quote) {
      if (char === "\\") index += 1;
      else if (char === quote) quote = null;
      continue;
    }
    if (char === '"' || char === "'") {
      quote = char;
    } else if (char === "`") {
      throw new Error(`Expected static strings in ${name} in ${filename}`);
    } else if (char === "/" && (next === "/" || next === "*")) {
      comment = next === "/" ? "line" : "block";
      index += 1;
    } else if (char === "{") {
      depth += 1;
    } else if (char === "}" && --depth === 0) {
      const literal = script.slice(start, index + 1);
      const context = createContext(Object.create(null), {
        codeGeneration: { strings: false, wasm: false },
      });
      const serialized = runInContext(`JSON.stringify((${literal}))`, context, {
        filename,
        timeout: 1000,
      });
      return JSON.parse(serialized);
    }
  }
  throw new Error(`Unclosed object literal ${name} in ${filename}`);
}

// Vue interpolates these values as text; preserve that meaning in Markdown too.
function text(value) {
  return String(value ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/[\\`*_[\]{}#|~]/g, "\\$&");
}

function link(label, url) {
  const destination = String(url).replace(/[\r\n<>]/g, encodeURIComponent);
  return `[${text(label)}](<${destination}>)`;
}

function cell(value) {
  return text(value).replace(/\r?\n/g, "<br>");
}

function codeBlock(value) {
  const content = String(value);
  const fenceLength = Math.max(3, ...Array.from(content.matchAll(/`+/g), (match) => match[0].length + 1));
  const fence = "`".repeat(fenceLength);
  return `${fence}text\n${content}\n${fence}`;
}

function document(blocks) {
  return `${blocks.filter((block) => block !== "").join("\n\n")}\n`;
}

/** Expand the existing Vue components into static GitBook Markdown. */
export function createComponentRenderer({ docsRoot, repositoryRoot }) {
  const components = join(docsRoot, ".vitepress", "theme", "components");
  const policies = readObjectLiteral(join(components, "PrivacyView.vue"), "policies");
  const licenseFile = join(components, "LicensesView.vue");
  const groups = readObjectLiteral(licenseFile, "groups");
  const licenseText = readObjectLiteral(licenseFile, "text");
  const sponsorLabels = readObjectLiteral(join(components, "SponsorList.vue"), "labels");
  const sponsorData = JSON.parse(readFileSync(join(repositoryRoot, "sponsors.json"), "utf8"));

  function privacy(locale = "zh-Hans") {
    const policy = policies[locale] ?? policies["zh-Hans"];
    const blocks = [
      `# ${text(policy.title)}`,
      policy.meta.map(([label, value]) => `- **${text(label)}:** ${text(value)}`).join("\n"),
      ...policy.preamble.map(text),
    ];
    for (const clause of policy.clauses) {
      blocks.push(`## ${text(clause.title)}`, ...(clause.paras ?? []).map(text));
      if (clause.items?.length) {
        blocks.push(clause.items.map((item, index) => `${index + 1}. ${text(item)}`).join("\n"));
      }
      blocks.push(...(clause.tail ?? []).map(text));
      if (clause.contact) {
        const { label, value, href } = clause.contact;
        blocks.push(`**${text(label)}:** ${link(value, href)}`);
      }
    }
    return document(blocks);
  }

  function licenses(locale = "zh-Hans") {
    const translation = licenseText[locale] ?? licenseText["zh-Hans"];
    const blocks = [text(translation.lead)];
    for (const [key, items] of Object.entries(groups)) {
      blocks.push(`## ${text(translation.sections[key])}`);
      blocks.push(items.map((item) => {
        const parts = [`**${text(item.name)}**`, text(item.license)];
        if (translation.meta[item.key]) parts.push(text(translation.meta[item.key]));
        if (item.link) parts.push(link(translation.view, item.link));
        return `- ${parts.join(" — ")}`;
      }).join("\n"));
    }
    for (const notice of translation.notices ?? []) {
      blocks.push(`### ${text(notice.title)}`, text(notice.body));
      if (notice.quote) blocks.push(codeBlock(notice.quote));
    }
    return document(blocks);
  }

  function sponsors(locale = "zh-Hans") {
    const labels = sponsorLabels[locale] ?? sponsorLabels["zh-Hans"];
    const numberFormat = new Intl.NumberFormat(locale, {
      style: "currency",
      currency: sponsorData.currency ?? "CNY",
      minimumFractionDigits: 0,
      maximumFractionDigits: 2,
    });
    const rows = [...(sponsorData.sponsors ?? [])].sort((a, b) =>
      (b.amount ?? 0) - (a.amount ?? 0) || String(a.date ?? "").localeCompare(String(b.date ?? "")),
    );
    return [
      `| ${cell(labels.name)} | ${cell(labels.amount)} | ${cell(labels.link)} |`,
      "| --- | --- | --- |",
      ...rows.map((sponsor) => `| ${cell(sponsor.name)} | ${cell(numberFormat.format(sponsor.amount ?? 0))} | ${sponsor.link ? link(sponsor.link, sponsor.link) : "—"} |`),
      "",
    ].join("\n");
  }

  return { privacy, licenses, sponsors };
}
