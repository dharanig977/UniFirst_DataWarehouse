// Server-side settings, read from Vercel environment variables. Nothing here
// is ever sent to the browser.

export interface ServerConfig {
  /** Postgres URL for the read-only etl_console_reader login on the warehouse. */
  databaseUrl: string
  /** Supabase's CA certificate (PEM). Required for any non-local database. */
  databaseCa: string | null
  /** The ERP Supabase project, used only to check who is signed in. */
  supabaseUrl: string
  supabaseKey: string
}

export class ConfigError extends Error {
  name = 'ConfigError'
}

export function readConfig(env: Record<string, string | undefined> = process.env): ServerConfig {
  const databaseUrl = env.WAREHOUSE_CONSOLE_URL?.trim()
  const supabaseUrl = (env.SUPABASE_URL ?? env.VITE_SUPABASE_URL)?.trim()
  const supabaseKey = (env.SUPABASE_PUBLISHABLE_KEY ?? env.VITE_SUPABASE_PUBLISHABLE_KEY)?.trim()
  const missing = [
    !databaseUrl && 'WAREHOUSE_CONSOLE_URL',
    !supabaseUrl && 'VITE_SUPABASE_URL',
    !supabaseKey && 'VITE_SUPABASE_PUBLISHABLE_KEY',
  ].filter(Boolean)
  if (missing.length) throw new ConfigError(`Server setup: missing environment variable(s) ${missing.join(', ')} in Vercel.`)
  const ca = env.WAREHOUSE_DATABASE_CA?.trim() || null
  return { databaseUrl: databaseUrl!, databaseCa: ca ? ca.replace(/\\n/g, '\n') : null, supabaseUrl: supabaseUrl!.replace(/\/$/, ''), supabaseKey: supabaseKey! }
}
