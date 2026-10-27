// Talks to the console server (/api/console). Every call carries the user's
// sign-in token; the server checks it with Supabase before reading anything.
import { getClient } from './supabaseClient'
import type { ConsoleData } from './types'

export async function loadConsole(): Promise<ConsoleData> {
  const { data } = await getClient().auth.getSession()
  const token = data.session?.access_token
  if (!token) throw new Error('You are signed out. Sign in again.')
  let res: Response
  try {
    res = await fetch('/api/console', { headers: { authorization: `Bearer ${token}` } })
  } catch {
    throw new Error('Could not reach the console server. Check your connection and try again.')
  }
  const text = await res.text()
  let parsed: unknown = null
  try {
    parsed = text ? JSON.parse(text) : null
  } catch {
    // Non-JSON means the server function itself failed (or isn't deployed).
  }
  if (!res.ok) {
    const msg = (parsed as { error?: string } | null)?.error
    throw new Error(msg ?? `The console server returned HTTP ${res.status}. If this is a new deployment, check the Vercel function logs.`)
  }
  return parsed as ConsoleData
}
