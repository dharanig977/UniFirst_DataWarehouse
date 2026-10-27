// Who is calling? The console uses the same sign-in as the ERP and CRM
// (Supabase Auth on the ERP project). Any account with an ERP or CRM role
// ("viewer" or "operator") may look at the console. Only operators may change
// the schedule or press Run now. Nobody can change business data here.

export interface ConsoleUser {
  id: string
  email: string
  role: string | null
}

export class HttpError extends Error {
  status: number
  constructor(status: number, message: string) {
    super(message)
    this.status = status
  }
}

export function roleFrom(appMetadata: Record<string, unknown> | undefined): string | null {
  for (const r of [appMetadata?.etl_role, appMetadata?.crm_role, appMetadata?.erp_role]) {
    if (r === 'viewer' || r === 'operator') return r
  }
  return null
}

const cache = new Map<string, { user: ConsoleUser; until: number }>()

export async function verifyUser(cfg: { supabaseUrl: string; supabaseKey: string }, authHeader: string | null): Promise<ConsoleUser> {
  const token = authHeader?.match(/^Bearer\s+(.+)$/i)?.[1]
  if (!token) throw new HttpError(401, 'Not signed in.')
  const hit = cache.get(token)
  if (hit && hit.until > Date.now()) return hit.user
  const res = await fetch(`${cfg.supabaseUrl}/auth/v1/user`, { headers: { apikey: cfg.supabaseKey, Authorization: `Bearer ${token}` } })
  if (res.status === 401 || res.status === 403) throw new HttpError(401, 'Your session has expired. Sign in again.')
  if (!res.ok) throw new HttpError(502, `Could not check your sign-in with Supabase (HTTP ${res.status}).`)
  const body = (await res.json()) as { id: string; email?: string; app_metadata?: Record<string, unknown> }
  const user: ConsoleUser = { id: body.id, email: body.email ?? '', role: roleFrom(body.app_metadata) }
  if (cache.size > 500) cache.clear()
  cache.set(token, { user, until: Date.now() + 60_000 })
  return user
}

export function requireRead(u: ConsoleUser) {
  if (!u.role) throw new HttpError(403, 'Your account has no role yet. An administrator must set erp_role (or etl_role) to "viewer" or "operator".')
}

export function requireOperator(u: ConsoleUser) {
  requireRead(u)
  if (u.role !== 'operator') throw new HttpError(403, 'Only operators can change the schedule or start a run. Your role is viewer.')
}
