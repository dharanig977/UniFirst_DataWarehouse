import { useEffect, useState, type FormEvent } from 'react'
import type { Session } from '@supabase/supabase-js'
import { Console } from './Console'
import { configProblem, getClient } from './lib/supabaseClient'

export default function App() {
  const problem = configProblem()
  if (problem) {
    return (
      <div className="center">
        <div className="card login">
          <h1>Setup needed</h1>
          <p className="notice error">{problem}</p>
        </div>
      </div>
    )
  }
  return <AuthGate />
}

function AuthGate() {
  const [session, setSession] = useState<Session | null | undefined>(undefined)
  useEffect(() => {
    const client = getClient()
    void client.auth.getSession().then(({ data }) => setSession(data.session))
    const { data } = client.auth.onAuthStateChange((_event, s) => setSession(s))
    return () => data.subscription.unsubscribe()
  }, [])

  if (session === undefined) return <div className="center muted">Checking sign-in…</div>
  if (!session) return <LoginScreen />
  return <Console email={session.user.email ?? ''} onSignOut={() => void getClient().auth.signOut()} />
}

function LoginScreen() {
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const submit = async (e: FormEvent) => {
    e.preventDefault()
    if (!email || !password) return setError('Enter your email and password.')
    setBusy(true)
    setError(null)
    const { error: err } = await getClient().auth.signInWithPassword({ email, password })
    if (err) setError(err.message)
    setBusy(false)
  }

  return (
    <div className="center">
      <form className="card login" onSubmit={submit} noValidate>
        <div className="login-brand">
          <strong>UniFirst ETL Console</strong>
          <span>SCM + CRM → Cloud Data Warehouse → Power BI</span>
        </div>
        <h1>Sign in</h1>
        <p className="muted">Use the same account you use for the UniFirst ERP and CRM.</p>
        <label className="field">
          <span>Email</span>
          <input type="email" autoComplete="username" value={email} onChange={(e) => setEmail(e.target.value)} />
        </label>
        <label className="field">
          <span>Password</span>
          <input type="password" autoComplete="current-password" value={password} onChange={(e) => setPassword(e.target.value)} />
        </label>
        <button className="primary" type="submit" disabled={busy}>
          {busy ? 'Signing in…' : 'Sign in'}
        </button>
        {error && <p className="notice error">{error}</p>}
      </form>
    </div>
  )
}
