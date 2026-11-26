/**
 * Fill-batch skill bundle.
 *
 * Registers one runtime skill (`fill-batch-number`) that teaches an agent to
 * fill batch numbers on the Liaoning drug procurement platform from an export
 * table, hospital by hospital, and ships the helper scripts the skill relies on
 * under `assets/fill-batch/scripts/`.
 */

import { readFile } from 'node:fs/promises'
import { isAbsolute, join, sep } from 'node:path'
import { fileURLToPath } from 'node:url'

/** Skill name exposed to the model catalog. */
const SKILL_NAME = 'fill-batch-number'
/** Provider label registered on the skill registry. */
const PROVIDER = 'fill-batch'
/** Packaged skill assets. */
const DEFAULT_ASSET_ROOT = fileURLToPath(new URL('./assets/', import.meta.url))

/** Cordis plugin name. */
export const name = 'fill-batch'
/** The skill registry this plugin contributes to. */
export const inject = ['skills']

/**
 * Split a `SKILL.md` into its frontmatter description and body.
 * @param {string} raw - file contents.
 * @param {string} path - file path, for diagnostics.
 * @returns {{ description: string, content: string }} parsed skill.
 */
function parseSkill(raw, path) {
  const frontmatter = /^---\r?\n([\s\S]*?)\r?\n---(?:\r?\n|$)/u.exec(raw)
  if (frontmatter?.[1] === undefined) throw new Error(`fill-batch: ${path} has no YAML frontmatter`)
  const description = /^description:\s*(.+)$/mu.exec(frontmatter[1])?.[1]?.trim().replace(/^["']|["']$/g, '')
  if (description === undefined || description.length === 0) {
    throw new Error(`fill-batch: ${path} has no description`)
  }
  return { description, content: raw.slice(frontmatter[0].length).trim() }
}

/**
 * Register the fill-batch skill provider.
 * @param {import('@deepseek-ai/cordis').Context} ctx - host context.
 * @param {{ assetRoot?: string }} [config] - optional asset root override.
 */
export function apply(ctx, config = {}) {
  const assetRoot = config.assetRoot ?? DEFAULT_ASSET_ROOT
  if (!isAbsolute(assetRoot)) throw new Error('fill-batch: assetRoot must be an absolute directory')
  const skillDir = join(assetRoot, 'fill-batch')
  const skillFile = join(skillDir, 'SKILL.md')

  ctx.skills.registerProvider(() => ({
    name: PROVIDER,
    async list(options) {
      try {
        const raw = await readFile(skillFile, { encoding: 'utf8', signal: options?.signal })
        const { description } = parseSkill(raw, skillFile)
        return {
          candidates: [{
            name: SKILL_NAME,
            description,
            invocation: { modelInvocable: true, userInvocable: true },
            provider: PROVIDER,
            source: 'bundled',
            rank: 600,
            resourceBase: { kind: 'directory', path: skillDir.split(sep).join('/') },
            locator: skillFile,
          }],
          complete: true,
        }
      } catch (error) {
        if (options?.signal?.aborted === true) throw error
        ctx.logger?.warn?.(`fill-batch: skill unavailable: ${String(error)}`)
        return { candidates: [], complete: false }
      }
    },
    async get(candidate, options) {
      const raw = await readFile(skillFile, { encoding: 'utf8', signal: options?.signal })
      const { content } = parseSkill(raw, skillFile)
      const { rank: _rank, locator: _locator, ...summary } = candidate
      return { ...summary, content }
    },
  }))
}
