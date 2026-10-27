// The console's only server endpoint: GET /api/console. Runs as a Vercel
// Function, so the warehouse password never reaches the browser.
import { verifyUser } from './_lib/auth.js'
import { readConfig } from './_lib/config.js'
import { getPool, readOnly, writeVia } from './_lib/db.js'
import { errorResponse, handle } from './_lib/handlers.js'

async function run(req: Request): Promise<Response> {
  try {
    const cfg = readConfig()
    const pool = getPool(cfg)
    return await handle(req, { read: (fn) => readOnly(pool, fn), write: (fn) => writeVia(pool, fn), verify: (h) => verifyUser(cfg, h) })
  } catch (e) {
    return errorResponse(e)
  }
}

export const GET = run
export const POST = run
