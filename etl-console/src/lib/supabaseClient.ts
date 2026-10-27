// The ONE place the app creates its Supabase connection.
// The console uses it only for sign-in (the same accounts as the ERP); warehouse
// data goes through the console server API in lib/api.ts.
import { createClient, type SupabaseClient } from '@supabase/supabase-js'

const url = import.meta.env.VITE_SUPABASE_URL as string | undefined
const key = import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY as string | undefined

/** Returns a human-readable problem with the configuration, or null if it looks fine. */
export function configProblem(): string | null {
  if (!url || !key) {
    return 'Missing VITE_SUPABASE_URL or VITE_SUPABASE_PUBLISHABLE_KEY. Copy .env.example to .env.local and fill in both values.'
  }
  if (!/^https:\/\/.+/.test(url)) return 'VITE_SUPABASE_URL must start with https://'
  if (looksPrivileged(key)) {
    return 'The configured key is a secret/service-role key. Only the publishable (or legacy anon) key may be used in the browser. Replace it and rotate the secret key in Supabase.'
  }
  return null
}

// Refuse to run with a privileged key, even by accident. We only inspect the
// key's type here and never print the key itself.
function looksPrivileged(k: string): boolean {
  if (k.startsWith('sb_secret_')) return true
  const parts = k.split('.')
  if (parts.length === 3) {
    try {
      const payload = JSON.parse(atob(parts[1].replace(/-/g, '+').replace(/_/g, '/')))
      return payload?.role === 'service_role'
    } catch {
      return false
    }
  }
  return false
}

let client: SupabaseClient | null = null

/** The shared Supabase client. Throws if configuration is missing or unsafe. */
export function getClient(): SupabaseClient {
  const problem = configProblem()
  if (problem) throw new Error(problem)
  if (!client) {
    client = createClient(url!, key!, {
      auth: { persistSession: true, autoRefreshToken: true },
    })
  }
  return client
}

