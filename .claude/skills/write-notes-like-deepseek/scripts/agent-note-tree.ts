/**
 * Shared structural source of truth for the Agent Note tree.
 * Portable: resolves .agents/notes from cwd (or AGENT_NOTE_ROOT env).
 */
import { readdirSync, existsSync } from 'node:fs'
import { resolve } from 'node:path'

/** Recurse `dir` and return posix-relative `.md` paths prefixed with `prefix`. Node 18 compatible (no fs.globSync). */
function listMd(dir: string, prefix: string): string[] {
  if (!existsSync(dir)) return []
  const out: string[] = []
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    if (entry.name.startsWith('.')) continue
    const rel = prefix ? `${prefix}/${entry.name}` : entry.name
    if (entry.isDirectory()) out.push(...listMd(resolve(dir, entry.name), rel))
    else if (entry.isFile() && entry.name.endsWith('.md')) out.push(rel)
  }
  return out
}

function resolveAgentNoteRoot(): string {
  if (process.env.AGENT_NOTE_ROOT) return resolve(process.env.AGENT_NOTE_ROOT)
  return resolve(process.cwd(), '.agents/notes')
}

export const agentNoteRoot = resolveAgentNoteRoot()

const AGENT_NOTE_LIFECYCLES = ['proposed', 'implemented', 'rejected'] as const
export const AGENT_NOTE_CLASSES = ['feature', 'bug-fix', 'simplification', 'architecture', 'process', 'testing'] as const
const AGENT_NOTE_ARCHIVE = 'archived'
const ROOT_ALLOWLIST = new Set(['AGENTS.md', 'CLAUDE.md'])

export interface AgentNote {
  lifecycle: string
  rel: string
  date: string
}

export function walkAgentNoteTree(): { notes: AgentNote[]; errors: string[] } {
  const notes: AgentNote[] = []
  const errors: string[] = []
  if (!existsSync(agentNoteRoot)) return { notes, errors }
  for (const entry of readdirSync(agentNoteRoot, { withFileTypes: true })) {
    if (entry.name === 'INDEX.md') {
      errors.push('structure: INDEX.md — centralized Agent Note indexes are forbidden; browse the lifecycle/class tree or search the repository')
      continue
    }
    if (entry.isDirectory() && entry.name !== AGENT_NOTE_ARCHIVE && !(AGENT_NOTE_LIFECYCLES as readonly string[]).includes(entry.name)) {
      errors.push(`structure: ${entry.name}/ — unknown lifecycle folder (allowed: ${AGENT_NOTE_LIFECYCLES.join(', ')}, plus ${AGENT_NOTE_ARCHIVE}/)`)
    }
  }
  for (const lifecycle of AGENT_NOTE_LIFECYCLES) {
    for (const match of listMd(resolve(agentNoteRoot, lifecycle), lifecycle).sort()) {
      const segs = match.split('/')
      if (segs.length === 2 && ROOT_ALLOWLIST.has(segs[1] ?? '')) continue
      if (match.endsWith('.zh.md')) continue
      const cls = segs[1]
      const base = segs[2]
      if (segs.length !== 3 || cls === undefined || base === undefined) {
        errors.push(`structure: ${match} — expected {lifecycle}/{class}/file.md (got depth ${segs.length})`)
        continue
      }
      if (!(AGENT_NOTE_CLASSES as readonly string[]).includes(cls)) {
        errors.push(`structure: ${match} — unknown class folder "${cls}" (allowed: ${AGENT_NOTE_CLASSES.join(', ')})`)
        continue
      }
      if (!/^\d{4}-\d{2}-\d{2}-.+\.md$/.test(base)) {
        errors.push(`structure: ${match} — filename must be yyyy-mm-dd-topic.md`)
        continue
      }
      notes.push({ lifecycle, rel: match, date: base.slice(0, 10) })
    }
  }
  return { notes, errors }
}
