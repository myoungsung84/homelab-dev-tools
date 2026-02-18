#!/usr/bin/env node
import fs from 'node:fs'
import path from 'node:path'
import process from 'node:process'
import { fileURLToPath } from 'node:url'
import { sendDiscordWebhook } from './send-webhook.mjs'

const __filename = fileURLToPath(import.meta.url)
const __dir = path.dirname(__filename)
const ENV_PATH = path.join(__dir, '.env')

const EMOJI = {
  ok: '✅',
  warn: '⚠️',
  err: '❌',
  info: 'ℹ️'
}

const DEFAULT_ALIAS = 'infra'
const ALLOWED_ALIASES = new Set([DEFAULT_ALIAS])

// 지금 단계에서는 infra만 쓰니까 env key도 고정
function getWebhookEnvKey(alias) {
  if (alias !== 'infra') return null
  return 'DISCORD_WEBHOOK_INFRA'
}

main().catch((e) => die(e?.message || String(e)))

async function main() {
  // args:
  //  - discord [alias] [text...]
  //  - echo "hello" | discord [alias]
  const [, , a0, ...rest0] = process.argv

  if (a0 === '-h' || a0 === '--help') {
    printHelp()
    process.exit(0)
  }

  // load discord/.env only
  loadDotEnv(ENV_PATH)

  // alias 생략하면 infra
  const { alias, rest } = parseAliasAndText(a0, rest0)

  if (!ALLOWED_ALIASES.has(alias)) {
    die(
      `Unsupported alias: "${alias}"\n` +
      `Currently supported: ${Array.from(ALLOWED_ALIASES).join(', ')}`
    )
  }

  const envKey = getWebhookEnvKey(alias)
  if (!envKey) die(`Invalid alias mapping: "${alias}"`)

  const webhookUrl = process.env[envKey]
  if (!webhookUrl) {
    die(
      `${envKey} is missing.\n` +
      ` - Put it in discord/.env (or export it in environment)\n` +
      ` - Example: ${envKey}=https://discord.com/api/webhooks/...`
    )
  }

  const text = rest.length ? rest.join(' ') : await readStdinIfAny()
  if (!text || !text.trim()) die('No message content. Provide text args or pipe stdin.')

  const maxLen = parseInt(process.env.DISCORD_MAX_LEN || '2000', 10) || 2000
  const username = (process.env.DISCORD_USERNAME || '').trim() || undefined
  const avatarUrl = (process.env.DISCORD_AVATAR_URL || '').trim() || undefined

  const { sent } = await sendDiscordWebhook({
    webhookUrl,
    content: text,
    maxLen,
    username,
    avatarUrl
  })

  // keep stdout clean (pipeline friendly). Use stderr for logs.
  console.error(`${EMOJI.ok} sent ${sent} message(s) to "${alias}"`)
}

function parseAliasAndText(a0, rest0) {
  // 기본 UX: alias 생략 가능 -> infra
  // - discord "hello"        => alias=infra, text=["hello"]
  // - discord infra "hello"  => alias=infra, text=["hello"]
  // - echo hi | discord      => alias=infra, stdin
  //
  // 규칙:
  // 첫 토큰이 허용 alias면 alias로 처리, 아니면 텍스트로 간주하고 alias=infra
  if (!a0) return { alias: DEFAULT_ALIAS, rest: [] }

  const maybe = String(a0).trim()
  if (ALLOWED_ALIASES.has(maybe)) return { alias: maybe, rest: rest0 }

  // alias가 아니라 텍스트 시작
  return { alias: DEFAULT_ALIAS, rest: [a0, ...rest0] }
}

function printHelp() {
  console.log(
    [
      'Usage:',
      '  discord [text...]',
      '  discord infra [text...]',
      '  echo "hello" | discord',
      '',
      'Examples:',
      '  discord "infra 테스트"',
      '  discord infra "수동 리포트"',
      '  echo "pipe 테스트" | discord',
      '',
      'Env (discord/.env only):',
      '  DISCORD_WEBHOOK_INFRA=https://discord.com/api/webhooks/...',
      '  DISCORD_MAX_LEN=2000 (optional)',
      '  DISCORD_USERNAME= (optional)',
      '  DISCORD_AVATAR_URL= (optional)'
    ].join('\n')
  )
}

function die(msg, code = 1) {
  console.error(`${EMOJI.err} ${msg}`)
  process.exit(code)
}

async function readStdinIfAny() {
  if (process.stdin.isTTY) return ''
  const chunks = []
  for await (const chunk of process.stdin) chunks.push(Buffer.from(chunk))
  return Buffer.concat(chunks).toString('utf8')
}

/**
 * Minimal .env loader (KEY=VALUE)
 * - supports quotes, ignores comments (#) and blank lines
 * - does NOT expand variables
 */
function loadDotEnv(envPath) {
  if (!fs.existsSync(envPath)) return
  const raw = fs.readFileSync(envPath, 'utf8')

  for (const line of raw.split(/\r?\n/)) {
    const trimmed = line.trim()
    if (!trimmed || trimmed.startsWith('#')) continue

    const idx = trimmed.indexOf('=')
    if (idx <= 0) continue

    const key = trimmed.slice(0, idx).trim()
    let val = trimmed.slice(idx + 1).trim()

    // strip inline comments: KEY=VALUE # comment  (only if not quoted)
    if (!(val.startsWith('"') || val.startsWith("'"))) {
      const hash = val.indexOf(' #')
      if (hash !== -1) val = val.slice(0, hash).trim()
    }

    // remove quotes
    if (
      (val.startsWith('"') && val.endsWith('"')) ||
      (val.startsWith("'") && val.endsWith("'"))
    ) {
      val = val.slice(1, -1)
    }

    if (!(key in process.env)) process.env[key] = val
  }
}
