const DEFAULT_MAX_LEN = 2000

/**
 * Discord webhook payload sender.
 * @param {{
 *  webhookUrl: string,
 *  content: string,
 *  maxLen?: number,
 *  username?: string,
 *  avatarUrl?: string,
 * }} params
 */
export async function sendDiscordWebhook({
  webhookUrl,
  content,
  maxLen = DEFAULT_MAX_LEN,
  username,
  avatarUrl
}) {
  if (!webhookUrl) throw new Error('webhookUrl is required')
  if (typeof content !== 'string') content = String(content ?? '')

  const chunks = splitDiscordMessage(content, maxLen)

  for (const chunk of chunks) {
    const body = {
      content: chunk
    }
    if (username) body.username = username
    if (avatarUrl) body.avatar_url = avatarUrl

    const res = await fetch(webhookUrl, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(body)
    })

    if (!res.ok) {
      const text = await safeReadText(res)
      throw new Error(`Discord webhook failed: HTTP ${res.status} ${res.statusText}\n${text}`)
    }
  }

  return { sent: chunks.length }
}

/**
 * Splits message into <= maxLen chunks.
 * - Keeps paragraphs when possible.
 * - Falls back to hard split for long lines.
 */
export function splitDiscordMessage(input, maxLen = DEFAULT_MAX_LEN) {
  const s = String(input ?? '').replace(/\r\n/g, '\n')
  if (!s.trim()) return ['(empty message)']
  if (maxLen < 50) maxLen = DEFAULT_MAX_LEN

  // Prefer paragraph boundaries
  const paras = s.split('\n\n')
  /** @type {string[]} */
  const out = []
  let cur = ''

  const pushCur = () => {
    const v = cur.trimEnd()
    if (v) out.push(v)
    cur = ''
  }

  for (const p of paras) {
    const block = p.trimEnd()

    // If block alone is too big, break it by lines then hard split
    if (block.length > maxLen) {
      pushCur()
      const lines = block.split('\n')
      for (const line of lines) {
        if (line.length <= maxLen) {
          // accumulate line-wise
          if (!cur) cur = line
          else if (cur.length + 1 + line.length <= maxLen) cur += '\n' + line
          else {
            pushCur()
            cur = line
          }
        } else {
          // hard split the long line
          pushCur()
          for (const part of hardSplit(line, maxLen)) out.push(part)
        }
      }
      pushCur()
      continue
    }

    // Normal accumulate by paragraph
    if (!cur) cur = block
    else if (cur.length + 2 + block.length <= maxLen) cur += '\n\n' + block
    else {
      pushCur()
      cur = block
    }
  }

  pushCur()
  return out.length ? out : ['(empty message)']
}

function hardSplit(line, maxLen) {
  /** @type {string[]} */
  const parts = []
  let i = 0
  while (i < line.length) {
    parts.push(line.slice(i, i + maxLen))
    i += maxLen
  }
  return parts
}

async function safeReadText(res) {
  try {
    return await res.text()
  } catch {
    return ''
  }
}
