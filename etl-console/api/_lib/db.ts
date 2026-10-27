// The one place the server connects to the warehouse. The login can only
// SELECT the analytics views and call the three console.* functions; reads
// also run in a READ ONLY transaction.
import pg from 'pg'
import { ConfigError, type ServerConfig } from './config.js'

// Timestamps arrive as Dates (sent to the browser as ISO text); NUMERIC and BIGINT become numbers (counts and minutes).
pg.types.setTypeParser(1082, (v) => v)
pg.types.setTypeParser(1700, (v) => Number(v))
pg.types.setTypeParser(20, (v) => Number(v))

export type Query = <T = Record<string, unknown>>(sql: string, params?: unknown[]) => Promise<T[]>

let pool: pg.Pool | null = null

export function sslOptions(url: string, ca: string | null): pg.PoolConfig['ssl'] {
  const host = new URL(url).hostname
  if (host === 'localhost' || host === '127.0.0.1') return false
  if (!ca) throw new ConfigError('Server setup: WAREHOUSE_DATABASE_CA is not set. Paste the certificate from the warehouse project (Database settings > SSL Configuration > Download certificate) into Vercel.')
  return { ca, rejectUnauthorized: true }
}

export function getPool(cfg: ServerConfig): pg.Pool {
  if (!pool) {
    const url = new URL(cfg.databaseUrl)
    // sslmode in the URL would override the ssl object below, so TLS is set only here.
    url.searchParams.delete('sslmode')
    pool = new pg.Pool({
      connectionString: url.toString(),
      ssl: sslOptions(cfg.databaseUrl, cfg.databaseCa),
      max: 2,
      idleTimeoutMillis: 10_000,
      connectionTimeoutMillis: 8_000,
    })
  }
  return pool
}

/** Runs fn inside one READ ONLY transaction, so every view is read at the same moment. */
export function readOnly<T>(p: pg.Pool, fn: (q: Query) => Promise<T>): Promise<T> {
  return inTransaction(p, 'begin transaction isolation level repeatable read read only', fn)
}

/**
 * Runs fn in a read-write transaction. The login's only write rights are
 * EXECUTE on the console.* functions (schedule and Run now), so this cannot
 * touch any table directly.
 */
export function writeVia<T>(p: pg.Pool, fn: (q: Query) => Promise<T>): Promise<T> {
  return inTransaction(p, 'begin transaction read write', fn)
}

async function inTransaction<T>(p: pg.Pool, begin: string, fn: (q: Query) => Promise<T>): Promise<T> {
  const client = await p.connect()
  try {
    await client.query(begin)
    const result = await fn(async (sql, params = []) => (await client.query(sql, params)).rows)
    await client.query('commit')
    return result
  } catch (e) {
    await client.query('rollback').catch(() => {})
    throw e
  } finally {
    client.release()
  }
}
