import { createClient } from "npm:@supabase/supabase-js@2";

const url = Deno.env.get("SUPABASE_URL")!;
const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const adminSecret = Deno.env.get("ROULETTE_ADMIN_KEY")!;
const db = createClient(url, serviceKey, { auth: { persistSession: false } });

const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), {
  status, headers: { "content-type": "application/json", "access-control-allow-origin": "*",
    "access-control-allow-headers": "authorization, apikey, content-type, x-admin-key",
    "access-control-allow-methods": "POST, OPTIONS" }
});
function nameOf(v: unknown) {
  if (typeof v !== "string") throw new Error("Ingresá tu nombre de usuario.");
  const n = v.trim().replace(/\s+/g, " ");
  if (n.length < 2 || n.length > 20) throw new Error("El usuario debe tener entre 2 y 20 caracteres.");
  return n;
}
function slugOf(name: string) {
  const bytes = new TextEncoder().encode(name.normalize("NFKC").toLocaleLowerCase("es"));
  let binary = ""; for (const b of bytes) binary += String.fromCharCode(b);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}
async function hash(value: string) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return [...new Uint8Array(digest)].map(b => b.toString(16).padStart(2, "0")).join("");
}
function randomPin() {
  const range = 90000000;
  const limit = Math.floor(0x100000000 / range) * range;
  const a = new Uint32Array(1);
  do { crypto.getRandomValues(a); } while (a[0] >= limit);
  return String(10000000 + (a[0] % range));
}
function requireAdmin(req: Request) {
  const supplied = req.headers.get("x-admin-key") || "";
  if (!adminSecret || supplied.length !== adminSecret.length) throw new Error("Clave de administración incorrecta.");
  let diff = 0; for (let i=0;i<supplied.length;i++) diff |= supplied.charCodeAt(i) ^ adminSecret.charCodeAt(i);
  if (diff) throw new Error("Clave de administración incorrecta.");
}
async function playerCredentials(body: any) {
  const username = nameOf(body.username), pin = String(body.pin || "").trim();
  if (!/^\d{8}$/.test(pin)) throw new Error("El PIN debe tener 8 números.");
  const id = slugOf(username);
  return { username, id, pinHash: await hash(id + ":" + pin) };
}
function errorStatus(message: string) {
  if (message.includes("PLAYER_NOT_FOUND")) return 404;
  if (message.includes("INVALID_CREDENTIALS")) return 403;
  if (message.includes("NO_ACTIVE_CYCLE") || message.includes("CYCLE_FINISHED")) return 409;
  return 400;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return json({ ok: true });
  if (req.method !== "POST") return json({ error: "Método no permitido." }, 405);
  try {
    const body = await req.json();
    const action = String(body.action || "");
    if (action.startsWith("admin")) requireAdmin(req);

    if (action === "status") {
      const c = await playerCredentials(body);
      const { data: verification, error: verifyError } = await db.rpc("roulette_verify_player_pin", {
        p_player_id: c.id, p_pin_hash: c.pinHash
      });
      if (verifyError) throw verifyError;
      if (!verification?.ok) {
        const code = verification?.code || "INVALID_CREDENTIALS";
        const statusCode = code === "PLAYER_NOT_FOUND" ? 404 : code === "PIN_LOCKED" ? 429 : 403;
        return json({ error: code, retryAt: verification?.retryAt, retryMinutes: verification?.retryMinutes,
          attemptsRemaining: verification?.attemptsRemaining }, statusCode);
      }
      const { data: p, error } = await db.from("roulette_players").select("*").eq("id", c.id).maybeSingle();
      if (error) throw error;
      if (!p) throw new Error("PLAYER_NOT_FOUND");
      const cycle = p.active_cycle || null, spins = cycle?.spins || [];
      const thirdAvailable = spins.length === 2 && spins.every((s: any) => s.result === "SIN PREMIO");
      return json({ username: p.username, activeCycle: !!cycle, cycleId: cycle?.id || null,
        spinsLeft: cycle ? (spins.length === 0 ? 2 : spins.length === 1 ? 1 : thirdAvailable ? 1 : 0) : 0,
        used: spins.length, thirdAvailable, queuedCycles: p.queued_cycles,
        fichasBalance: p.fichas_balance, bonusCount: (p.bonus_prizes || []).length,
        quadBikeNumbers: p.quad_bike_numbers, recentResults: spins.map((s: any) => ({ result:s.result,key:s.key,bonus:s.bonus })) });
    }

    if (action === "spin") {
      const c = await playerCredentials(body);
      // Selection and commit happen under the same PostgreSQL row lock.
      // The database transaction chooses the correct odds for the actual spin number.
      const { data, error } = await db.rpc("roulette_apply_spin", {
        p_player_id: c.id, p_pin_hash: c.pinHash
      });
      if (error) throw error;
      if (data?.error) {
        const statusCode = data.error === "PLAYER_NOT_FOUND" ? 404 : data.error === "PIN_LOCKED" ? 429 :
          data.error === "INVALID_CREDENTIALS" ? 403 : 409;
        return json({ error:data.error, retryAt:data.retryAt, retryMinutes:data.retryMinutes,
          attemptsRemaining:data.attemptsRemaining }, statusCode);
      }
      return json(data);
    }

    if (action === "adminListPlayers") {
      const { data, error } = await db.from("roulette_players").select("*").order("created_at", { ascending:false }).limit(250);
      if (error) throw error;
      return json({ players:(data || []).map((p:any) => {
        const cycle=p.active_cycle||null, spins=cycle?.spins||[];
        const thirdAvailable=spins.length===2 && spins.every((s:any)=>s.result==="SIN PREMIO");
        return { username:p.username, active:!!cycle, used:spins.length,
          spinsLeft:cycle?(spins.length===0?2:spins.length===1?1:thirdAvailable?1:0):0,
          thirdAvailable, queuedCycles:p.queued_cycles, fichasBalance:p.fichas_balance,
          bonusCount:(p.bonus_prizes||[]).length, quadBikeNumbers:p.quad_bike_numbers };
      }) });
    }

    const username = nameOf(body.username), id = slugOf(username);
    if (action === "adminCreatePlayer") {
      const pin = randomPin(), pinHash = await hash(id + ":" + pin);
      const { error } = await db.rpc("roulette_admin_create_player", { p_id:id, p_username:username, p_pin_hash:pinHash });
      if (error) throw error;
      return json({ username, pin });
    }
    if (action === "adminGrantCycles" || action === "adminApproveLoad") {
      const count = action === "adminApproveLoad" ? 1 : Math.max(1, Math.min(100, Math.floor(Number(body.count || 1))));
      const { data, error } = await db.rpc("roulette_admin_grant_cycles", { p_id:id, p_count:count, p_source:action === "adminApproveLoad" ? "load-approved" : "admin" });
      if (error) throw error;
      return json(data);
    }
    if (action === "adminResetPin") {
      const pin = randomPin(), pinHash = await hash(id + ":" + pin);
      const { data, error } = await db.from("roulette_players").update({ pin_hash:pinHash,pin_failed_attempts:0,pin_locked_until:null,updated_at:new Date().toISOString() }).eq("id",id).select("username").maybeSingle();
      if (error) throw error; if (!data) throw new Error("PLAYER_NOT_FOUND");
      return json({ username:data.username, pin });
    }
    return json({ error:"Acción desconocida." }, 400);
  } catch (e) {
    const message = String((e as Error)?.message || "Error interno.");
    return json({ error:message }, errorStatus(message));
  }
});
