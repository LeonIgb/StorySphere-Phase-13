// Supabase Edge Function: delete the CALLER's account.
//
// STATUS: written but NOT deployed and NOT run (no Supabase project or Deno runtime was available
// when it was written). Treat it as unverified until you deploy it and test it, see supabase/README.md.
//
// Why a server function: deleting an auth user needs the service_role key, which must never be in
// the app. Supabase injects SUPABASE_SERVICE_ROLE_KEY into Edge Functions as a server-side secret.
// Deleting the auth user cascades to profiles and everything the user owns (see the schema).
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.4';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return json(405, { error: 'method_not_allowed' });

  const authHeader = req.headers.get('Authorization') ?? '';
  if (!authHeader.startsWith('Bearer ')) return json(401, { error: 'not_authenticated' });

  const url = Deno.env.get('SUPABASE_URL')!;
  // 1. Who is calling? Verify the JWT with Supabase Auth (never trust a user id from the body).
  const asCaller = createClient(url, Deno.env.get('SUPABASE_ANON_KEY')!, {
    global: { headers: { Authorization: authHeader } },
    auth: { persistSession: false },
  });
  const { data, error } = await asCaller.auth.getUser();
  if (error || !data.user) return json(401, { error: 'not_authenticated' });

  // 2. Delete exactly that user with the privileged client. This key exists only on the server.
  const admin = createClient(url, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { error: delError } = await admin.auth.admin.deleteUser(data.user.id);
  if (delError) return json(500, { error: 'delete_failed' });
  return json(200, { ok: true });
});
