#!/usr/bin/env node
import { spawnSync } from 'node:child_process'
import fs from 'node:fs'
import path from 'node:path'
import readline from 'node:readline'
import { fileURLToPath } from 'node:url'

/** @typedef {{ status: number | null, stdout: string, stderr: string }} CmdResult */

const __filename = fileURLToPath(import.meta.url)
const SCRIPT_DIR = path.dirname(__filename)

// homelab-dev-tools root (this file is expected to be in: <root>/git-tools/)
const TOOLS_ROOT = path.resolve(SCRIPT_DIR, '..')

// generator path (dev-tools internal)
const GEN_SCRIPT = path.join(TOOLS_ROOT, 'git-tools', 'generate-commit.sh')

// git commands should run in the user's current repo
const WORK_CWD = process.cwd()

const EMOJI = {
  ok: '✅',
  warn: '⚠️',
  err: '❌',
  run: '▶',
  stop: '⛔',
  info: 'ℹ️'
}

/**
 * @param {string} msg
 * @param {number} [code]
 * @returns {never}
 */
function die(msg, code = 1) {
  console.error(msg)
  process.exit(code)
}

/**
 * @param {string} cmd
 * @param {string[]} args
 * @param {{ cwd?: string, input?: string }} [opts]
 * @returns {CmdResult}
 */
function run(cmd, args, opts = {}) {
  const r = spawnSync(cmd, args, {
    cwd: opts.cwd ?? WORK_CWD,
    encoding: 'utf8',
    input: opts.input
  })

  return {
    status: r.status,
    stdout: typeof r.stdout === 'string' ? r.stdout : String(r.stdout ?? ''),
    stderr: typeof r.stderr === 'string' ? r.stderr : String(r.stderr ?? '')
  }
}

/**
 * @returns {boolean}
 */
function isGitRepo() {
  const r = run('git', ['rev-parse', '--is-inside-work-tree'])
  return r.status === 0 && r.stdout.trim() === 'true'
}

/**
 * @returns {boolean}
 */
function hasStagedChanges() {
  const r = run('git', ['diff', '--staged', '--quiet'])
  return r.status !== 0
}

/**
 * @returns {string[]}
 */
function getStagedFiles() {
  const r = run('git', ['diff', '--cached', '--name-only', '-z'])
  if (r.status !== 0) die(`${EMOJI.err} failed to list staged files\n${r.stderr || r.stdout}`)
  return (r.stdout || '').split('\0').filter(Boolean)
}

/**
 * @param {string} p
 * @returns {boolean}
 */
function isForbiddenPath(p) {
  const forbidden = [
    /^\.env$/,
    /^\.env\./,
    /\.pem$/i,
    /\.key$/i,
    /\.p12$/i,
    /\.pfx$/i,
    /\.jks$/i,
    /\.keystore$/i,
    /^secrets\./i,
    /^secret\./i,
    /^credentials\./i,
    /^creds\./i,
    /^node_modules\//,
    /^dist\//,
    /^out\//,
    /^build\//,
    /^releases\//,
    /^dist-electron\//,
    /\.log$/i,
    /\.log\./i,
    /\.pid$/i,
    /\.lcov$/i
  ]
  return forbidden.some((re) => re.test(p))
}

/**
 * @param {string} question
 * @returns {Promise<string>}
 */
async function prompt(question) {
  const rl = readline.createInterface({ input: process.stdin, output: process.stdout })
  const ans = await new Promise((resolve) => {
    rl.question(question, (value) => resolve(value))
  })
  rl.close()
  return String(ans ?? '').trim()
}

/**
 * @returns {Promise<string>}
 */
async function selectCommitType() {
  console.log('')
  console.log('Select commit type:')
  console.log('  1) fix      - 버그/오작동/에러 수정')
  console.log('  2) feat     - 사용자 기능 추가')
  console.log('  3) refactor - 기능 동일, 구조 개선')
  console.log('  4) chore    - 빌드/스크립트/도구/의존성/설정/인프라')
  console.log('  5) docs     - 문서')
  console.log('  6) test     - 테스트')
  console.log('  7) perf     - 성능')
  console.log('')

  const a = await prompt('Type [1-7] (default: 4=chore): ')
  const n = a ? Number(a) : 4

  /** @type {Record<number, string>} */
  const map = {
    1: 'fix',
    2: 'feat',
    3: 'refactor',
    4: 'chore',
    5: 'docs',
    6: 'test',
    7: 'perf'
  }

  const t = map[n]
  if (!t) die(`${EMOJI.err} invalid choice: ${a || '?'}`)

  console.log(`${EMOJI.ok} Selected type: ${t}\n`)
  return t
}

/**
 * @returns {Promise<void>}
 */
async function handleForbiddenFiles() {
  const staged = getStagedFiles()
  const forbidden = staged.filter(isForbiddenPath)

  if (forbidden.length === 0) return

  console.log(`${EMOJI.warn} Forbidden staged files detected (should NOT be committed):`)
  for (const f of forbidden) console.log(`  - ${f}`)
  console.log('')
  console.log('Choose action:')
  console.log('  1) abort (default)')
  console.log('  2) unstage forbidden files and continue')
  console.log('')

  const a = await prompt('Action [1/2]: ')
  const act = a ? Number(a) : 1

  if (act === 1) die(`${EMOJI.stop} canceled.`, 1)
  if (act !== 2) die(`${EMOJI.err} invalid action: ${a}`)

  for (const f of forbidden) {
    let r = run('git', ['restore', '--staged', '--', f])
    if (r.status !== 0) {
      r = run('git', ['reset', '-q', 'HEAD', '--', f])
      if (r.status !== 0) die(`${EMOJI.err} failed to unstage: ${f}\n${r.stderr || r.stdout}`)
    }
  }

  console.log(`${EMOJI.ok} Unstaged forbidden files.\n`)

  if (!hasStagedChanges()) {
    die(`${EMOJI.err} After filtering, no staged changes remain.\nTIP: stage valid files and retry.`)
  }
}

/**
 * @param {string} genOut
 * @returns {string}
 */
function extractCommitMessage(genOut) {
  const lines = String(genOut ?? '').split(/\r?\n/)
  const start = lines.findIndex((l) => l.trim() === '===== COMMIT MESSAGE =====')
  if (start < 0) return ''

  let end = -1
  for (let i = start + 1; i < lines.length; i++) {
    if (lines[i]?.trim() === '==========================') {
      end = i
      break
    }
  }
  if (end < 0) return ''

  return lines.slice(start + 1, end).join('\n').trim()
}

/**
 * @param {string} commitType
 * @param {string} msg
 * @returns {string}
 */
function applyType(commitType, msg) {
  const lines = msg.split(/\r?\n/)
  const firstNonEmptyIdx = lines.findIndex((l) => l.trim().length > 0)

  const subject0 = firstNonEmptyIdx >= 0 ? (lines[firstNonEmptyIdx]?.trim() ?? '') : ''
  const body = firstNonEmptyIdx >= 0 ? lines.slice(firstNonEmptyIdx + 1).join('\n') : ''

  const re = /^(feat|fix|refactor|chore|docs|test|perf)(\([^)]+\))?:\s+.+/
  let subject = subject0

  if (re.test(subject0)) {
    subject = subject0.replace(/^(feat|fix|refactor|chore|docs|test|perf)/, commitType)
  } else {
    subject = `${commitType}: ${subject0 || 'update'}`
  }

  const out = [subject]
  if (body.trim().length > 0) out.push('', body.trimEnd())
  return out.join('\n')
}

/**
 * @returns {CmdResult}
 */
function runGenerator() {
  const isWin = process.platform === 'win32'
  if (isWin) return run('bash', [GEN_SCRIPT], { cwd: TOOLS_ROOT })
  return run(GEN_SCRIPT, [], { cwd: TOOLS_ROOT })
}

/**
 * @param {string} message
 * @returns {CmdResult}
 */
function gitCommit(message) {
  return run('git', ['commit', '--file=-'], { input: message })
}

/**
 * @returns {Promise<boolean>}
 */
async function confirmCommit() {
  // eslint-disable-next-line no-constant-condition
  while (true) {
    const a = await prompt('Commit now? [Y/n]: ')
    const s = String(a ?? '').trim().toLowerCase()

    if (!s) return true
    if (s === 'y' || s === 'yes') return true
    if (s === 'n' || s === 'no') return false

    console.log(`${EMOJI.info} please answer y/yes or n/no.`)
  }
}

/**
 * @param {string} finalMsg
 * @returns {string}
 */
function getSubjectLine(finalMsg) {
  const first = finalMsg.split(/\r?\n/).find((l) => l.trim().length > 0)
  return (first ?? '').trim()
}

/**
 * @returns {Promise<void>}
 */
async function main() {
  process.on('SIGINT', () => {
    console.log(`\n${EMOJI.stop} aborted.`)
    process.exit(130)
  })

  if (!fs.existsSync(GEN_SCRIPT)) die(`${EMOJI.err} generator not found: ${GEN_SCRIPT}`)
  if (!isGitRepo()) die(`${EMOJI.err} Not inside a git repository.`)
  if (!hasStagedChanges()) die(`${EMOJI.err} No staged changes.\nTIP: git add -A`)

  const commitType = await selectCommitType()
  await handleForbiddenFiles()

  console.log(`${EMOJI.run} Running generator:`)
  console.log(`  ${GEN_SCRIPT}\n`)

  const r = runGenerator()
  if (r.status !== 0) {
    die(
      `${EMOJI.err} Failed to run generator (exit=${r.status ?? 'null'})\n\n----- generator output -----\n${r.stdout || r.stderr
      }\n---------------------------`
    )
  }

  const block = extractCommitMessage(r.stdout || '')
  if (!block.trim()) {
    die(
      `${EMOJI.err} Could not extract commit message from generator output.\n\n----- generator output -----\n${r.stdout || ''
      }\n---------------------------`
    )
  }

  const finalMsg = applyType(commitType, block)
  const subject = getSubjectLine(finalMsg) || `${commitType}: update`

  console.log('\n===== COMMIT MESSAGE (PREVIEW) =====\n')
  console.log(finalMsg)
  console.log('\n====================================\n')

  const ok = await confirmCommit()
  if (!ok) {
    console.log(`${EMOJI.stop} canceled. (no commit)`)
    return
  }

  console.log(`${EMOJI.run} git commit ...`)
  const c = gitCommit(finalMsg)

  if (c.status !== 0) {
    die(
      `${EMOJI.err} git commit failed (exit=${c.status ?? 'null'})\n\n----- git output -----\n${c.stdout || c.stderr
      }\n----------------------`
    )
  }

  console.log(`${EMOJI.ok} committed: ${subject}`)

  const status = run('git', ['status', '-sb'])
  if (status.status === 0) {
    const line = status.stdout.split(/\r?\n/).find((l) => l.trim().length > 0)
    if (line) console.log(line.trim())
  }
}

/**
 * @param {unknown} e
 * @returns {never}
 */
function crash(e) {
  const msg =
    e && typeof e === 'object' && 'stack' in e
      ? String(/** @type {{stack?: unknown}} */(e).stack)
      : String(e)
  die(`${EMOJI.err} ${msg}`, 1)
}

main().catch(crash)
