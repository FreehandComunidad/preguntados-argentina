import { withSupabase } from "npm:@supabase/server@^1";

const adminSecret = Deno.env.get("ROULETTE_ADMIN_KEY")!;

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
  const range = 10000;
  const limit = Math.floor(0x100000000 / range) * range;
  const a = new Uint32Array(1);
  do { crypto.getRandomValues(a); } while (a[0] >= limit);
  return String(a[0] % range).padStart(4, "0");
}
function constantTimeEqual(left:string,right:string){
  if(left.length!==right.length)return false;
  let diff=0;for(let i=0;i<left.length;i++)diff|=left.charCodeAt(i)^right.charCodeAt(i);
  return diff===0;
}
function randomHex(bytesLength:number){
  const bytes=new Uint8Array(bytesLength);crypto.getRandomValues(bytes);
  return [...bytes].map(x=>x.toString(16).padStart(2,"0")).join("");
}
async function passwordDigest(password:string,saltHex:string){
  const salt=new Uint8Array(saltHex.match(/.{2}/g)?.map(x=>parseInt(x,16))||[]);
  const key=await crypto.subtle.importKey("raw",new TextEncoder().encode(password),"PBKDF2",false,["deriveBits"]);
  const bits=await crypto.subtle.deriveBits({name:"PBKDF2",salt,iterations:120000,hash:"SHA-256"},key,256);
  return [...new Uint8Array(bits)].map(x=>x.toString(16).padStart(2,"0")).join("");
}
async function requireAdmin(req: Request,db:any){
  const supplied=req.headers.get("x-admin-key")||"";
  if(adminSecret&&constantTimeEqual(supplied,adminSecret)){
    return {role:"owner",username:"Administrador principal",userId:null,isMaster:true,tokenHash:null};
  }
  if(!supplied||supplied.length>256)throw new Error("ADMIN_SESSION_INVALID");
  const tokenHash=await hash(supplied);
  const {data:session,error:sessionError}=await db.from("roulette_admin_sessions")
    .select("admin_user_id").eq("token_hash",tokenHash).is("revoked_at",null)
    .gt("expires_at",new Date().toISOString()).maybeSingle();
  if(sessionError)throw sessionError;
  if(!session)throw new Error("ADMIN_SESSION_INVALID");
  const {data:user,error:userError}=await db.from("roulette_admin_users")
    .select("id,username,role,is_active").eq("id",session.admin_user_id).maybeSingle();
  if(userError)throw userError;
  if(!user||!user.is_active)throw new Error("ADMIN_SESSION_INVALID");
  const {error:updateError}=await db.from("roulette_admin_sessions")
    .update({last_used_at:new Date().toISOString()}).eq("token_hash",tokenHash);
  if(updateError)throw updateError;
  return {role:user.role,username:user.username,userId:user.id,isMaster:false,tokenHash};
}
const ADMIN_READ_ONLY_ACTIONS=new Set([
  "adminListPlayers","adminListPrizes","adminListPrizeEvents","adminGetPlayerProfile",
  "adminListCatalog","adminGetReports","adminListNotifications"
]);
const ADMIN_OWNER_ONLY_ACTIONS=new Set([
  "adminSaveCatalog","adminAdjustFichas","adminResetPin","adminCancelLoad",
  "adminCreateAdminUser","adminUpdateAdminUser","adminListAdminUsers"
]);
function authorizeAdminAction(action:string,identity:any){
  if(identity.role==="auditor"&&!ADMIN_READ_ONLY_ACTIONS.has(action)&&action!=="adminLogout")throw new Error("ADMIN_FORBIDDEN");
  if(identity.role==="operator"&&ADMIN_OWNER_ONLY_ACTIONS.has(action))throw new Error("ADMIN_FORBIDDEN");
}
async function playerCredentials(body: any) {
  const username = nameOf(body.username), pin = String(body.pin || "").trim();
  if (!/^(?:\d{4}|\d{8})$/.test(pin)) throw new Error("El PIN debe tener 4 números (o 8 para cuentas anteriores).");
  const id = slugOf(username);
  return { username, id, pinHash: await hash(id + ":" + pin) };
}
function errorStatus(message: string) {
  if (message.includes("PLAYER_NOT_FOUND") || message.includes("BONUS_NOT_FOUND")) return 404;
  if(message.includes("ADMIN_LOGIN_LOCKED"))return 429;
  if (message.includes("INVALID_CREDENTIALS") || message.includes("ADMIN_INVALID_CREDENTIALS") ||
      message.includes("ADMIN_SESSION_INVALID") || message.includes("ADMIN_FORBIDDEN")) return 403;
  if (message.includes("NO_ACTIVE_CYCLE") || message.includes("CYCLE_FINISHED") ||
      message.includes("NO_CANCELLABLE_LOAD")) return 409;
  return 400;
}

const handler = withSupabase({ auth: "publishable" }, async (req, ctx) => {
  const db = ctx.supabaseAdmin;
  if (req.method !== "POST") return json({ error: "Método no permitido." }, 405);
  try {
    const body = await req.json();
    const action = String(body.action || "");
    let adminContext:any=null;

    if(action==="adminLogin"){
      const username=String(body.username||"").trim().toLowerCase();
      const password=String(body.password||"");
      if(!/^[a-z0-9._-]{3,30}$/.test(username)||password.length<10||password.length>128)return json({error:"ADMIN_INVALID_CREDENTIALS"},403);
      const {data:user,error:userError}=await db.from("roulette_admin_users")
        .select("id,username,password_salt,password_hash,role,is_active,login_failed_attempts,login_locked_until")
        .eq("username",username).maybeSingle();
      if(userError)throw userError;
      if(!user||!user.is_active)return json({error:"ADMIN_INVALID_CREDENTIALS"},403);
      if(user.login_locked_until&&new Date(user.login_locked_until).getTime()>Date.now()){
        return json({error:"ADMIN_LOGIN_LOCKED",retryAt:user.login_locked_until},429);
      }
      const candidate=await passwordDigest(password,user.password_salt);
      if(!constantTimeEqual(candidate,user.password_hash)){
        const attempts=Number(user.login_failed_attempts||0)+1;
        const locked=attempts>=5;
        const {error:failedUpdateError}=await db.from("roulette_admin_users").update({
          login_failed_attempts:locked?0:attempts,
          login_locked_until:locked?new Date(Date.now()+15*60*1000).toISOString():null
        }).eq("id",user.id);
        if(failedUpdateError)throw failedUpdateError;
        return locked?json({error:"ADMIN_LOGIN_LOCKED",retryMinutes:15},429):json({error:"ADMIN_INVALID_CREDENTIALS"},403);
      }
      const token=randomHex(32),tokenHash=await hash(token);
      const expiresAt=new Date(Date.now()+12*60*60*1000).toISOString();
      const {error:sessionInsertError}=await db.from("roulette_admin_sessions").insert({token_hash:tokenHash,admin_user_id:user.id,expires_at:expiresAt});
      if(sessionInsertError)throw sessionInsertError;
      const {error:loginUpdateError}=await db.from("roulette_admin_users").update({last_login_at:new Date().toISOString(),login_failed_attempts:0,login_locked_until:null}).eq("id",user.id);
      if(loginUpdateError)throw loginUpdateError;
      return json({token,username:user.username,role:user.role,expiresAt});
    }

    if(action.startsWith("admin")){
      adminContext=await requireAdmin(req,db);
      authorizeAdminAction(action,adminContext);
    }

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
      const { data: prizeRows, error: prizeRowsError } = await db
        .from("roulette_prize_awards")
        .select("prize_type,prize_label,fichas_amount,bonus_percent,status,created_at,resolved_at")
        .eq("player_id", c.id)
        .in("prize_type", ["bonus", "fichas"])
        .order("created_at", { ascending:false })
        .limit(100);
      if (prizeRowsError) throw prizeRowsError;
      const [spinHistoryResult,catalogResult]=await Promise.all([
        db.from("roulette_spins").select("id,spin_number,prize_key,result,bonus_percent,created_at")
          .eq("player_id",c.id).order("created_at",{ascending:false}).limit(40),
        db.from("roulette_prize_catalog").select("prize_key,label,prize_type,fichas_amount,bonus_percent,image_url,sort_order")
          .eq("is_active",true).order("sort_order",{ascending:true})
      ]);
      if(spinHistoryResult.error)throw spinHistoryResult.error;
      if(catalogResult.error)throw catalogResult.error;
      const prizeHistory = (prizeRows || []).map((a:any) => ({
        prizeType:a.prize_type,
        prizeLabel:a.prize_label,
        fichasAmount:Number(a.fichas_amount||0),
        bonusPercent:Number(a.bonus_percent||0),
        status:a.status,
        createdAt:a.created_at,
        resolvedAt:a.resolved_at
      }));
      return json({ username: p.username, activeCycle: !!cycle, cycleId: cycle?.id || null,
        spinsLeft: cycle ? (spins.length === 0 ? 2 : spins.length === 1 ? 1 : thirdAvailable ? 1 : 0) : 0,
        used: spins.length, thirdAvailable, queuedCycles: p.queued_cycles,
        fichasBalance: p.fichas_balance, bonusCount: (p.bonus_prizes || []).length,
        quadBikeNumbers: p.quad_bike_numbers, bonusPrizes: (p.bonus_prizes || []).map((b:any) => ({ percent:Number(b.percent||0), cycleId:b.cycleId||null, spinNumber:Number(b.spinNumber||0), createdAt:b.createdAt||null })),
        prizeHistory,
        recentSpins:spinHistoryResult.data||[],
        prizeCatalog:catalogResult.data||[],
        recentResults: spins.map((s: any) => ({ result:s.result,key:s.key,bonus:s.bonus })) });
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
      if(data?.result?.key){
        const {data:catalogPrize,error:catalogError}=await db.from("roulette_prize_catalog")
          .select("prize_type,fichas_amount,bonus_percent,image_url")
          .eq("prize_key",data.result.key).maybeSingle();
        if(catalogError)throw catalogError;
        if(catalogPrize){
          data.result.prizeType=catalogPrize.prize_type;
          data.result.fichasAmount=Number(catalogPrize.fichas_amount||0);
          data.result.imageUrl=catalogPrize.image_url||null;
        }
      }
      return json(data);
    }

    if(action==="adminListAdminUsers"){
      const {data,error}=await db.from("roulette_admin_users")
        .select("id,username,role,is_active,created_by,created_at,last_login_at")
        .order("created_at",{ascending:false}).limit(100);
      if(error)throw error;
      return json({users:data||[]});
    }

    if(action==="adminCreateAdminUser"){
      const username=String(body.username||"").trim().toLowerCase();
      const password=String(body.password||"");
      const role=String(body.role||"operator");
      if(!/^[a-z0-9._-]{3,30}$/.test(username))throw new Error("El usuario administrativo debe tener entre 3 y 30 caracteres (letras, números, punto, guion o guion bajo).");
      if(password.length<10||password.length>128)throw new Error("La contraseña debe tener entre 10 y 128 caracteres.");
      if(!["owner","operator","auditor"].includes(role))throw new Error("El rol administrativo no es válido.");
      const salt=randomHex(16),passwordHash=await passwordDigest(password,salt);
      const {data,error}=await db.from("roulette_admin_users")
        .insert({username,password_salt:salt,password_hash:passwordHash,role,is_active:true,created_by:adminContext.username})
        .select("id,username,role,is_active,created_at").single();
      if(error){
        if(String(error.message||"").includes("duplicate key"))throw new Error("Ya existe una cuenta administrativa con ese usuario.");
        throw error;
      }
      return json({user:data});
    }

    if(action==="adminUpdateAdminUser"){
      const userId=String(body.userId||"").trim();
      if(!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(userId))throw new Error("No se pudo identificar la cuenta administrativa.");
      const role=String(body.role||"");
      const isActive=body.isActive===true;
      if(!["owner","operator","auditor"].includes(role))throw new Error("El rol administrativo no es válido.");
      if(adminContext.userId===userId&&(!isActive||role!=="owner"))throw new Error("No podés quitarte a vos mismo el acceso de propietario. Usá otra cuenta propietaria.");
      const update:any={role,is_active:isActive,updated_at:new Date().toISOString()};
      if(body.password){
        const password=String(body.password);
        if(password.length<10||password.length>128)throw new Error("La nueva contraseña debe tener entre 10 y 128 caracteres.");
        const salt=randomHex(16);update.password_salt=salt;update.password_hash=await passwordDigest(password,salt);
      }
      const {data,error}=await db.from("roulette_admin_users").update(update).eq("id",userId).select("id,username,role,is_active").maybeSingle();
      if(error)throw error;
      if(!data)throw new Error("ADMIN_USER_NOT_FOUND");
      const {error:revokeError}=await db.from("roulette_admin_sessions").update({revoked_at:new Date().toISOString()}).eq("admin_user_id",userId).is("revoked_at",null);
      if(revokeError)throw revokeError;
      return json({user:data,sessionsRevoked:true});
    }

    if(action==="adminLogout"){
      if(adminContext.tokenHash){
        const {error}=await db.from("roulette_admin_sessions").update({revoked_at:new Date().toISOString()}).eq("token_hash",adminContext.tokenHash);
        if(error)throw error;
      }
      return json({ok:true});
    }

    if (action === "adminGetPlayerProfile") {
      const username = nameOf(body.username);
      const id = slugOf(username);
      const [playerResult, awardsResult, spinsResult, opportunitiesResult, ledgerResult] = await Promise.all([
        db.from("roulette_players")
          .select("id,username,active_cycle,queued_cycles,fichas_balance,approved_loads_count,bonus_prizes,used_bonus_prizes,quad_bike_numbers,created_at,last_spin_at")
          .eq("id",id).maybeSingle(),
        db.from("roulette_prize_awards").select("id,spin_id,cycle_id,spin_number,prize_key,prize_label,prize_type,fichas_amount,bonus_percent,status,created_at,resolved_at,resolved_by,resolution_note")
          .eq("player_id",id).order("created_at",{ascending:false}).limit(500),
        db.from("roulette_spins").select("id,cycle_id,spin_number,prize_key,result,bonus_percent,created_at")
          .eq("player_id",id).order("created_at",{ascending:false}).limit(500),
        db.from("roulette_opportunities").select("id,source,status,created_at,activated_at,completed_at,cancelled_at")
          .eq("player_id",id).order("created_at",{ascending:false}).limit(500),
        db.from("roulette_fichas_ledger").select("id,movement_type,amount_delta,balance_before,balance_after,description,actor,award_id,created_at")
          .eq("player_id",id).order("created_at",{ascending:false}).limit(500)
      ]);
      for (const item of [playerResult,awardsResult,spinsResult,opportunitiesResult,ledgerResult]) {
        if (item.error) throw item.error;
      }
      const p=playerResult.data;
      if(!p) throw new Error("PLAYER_NOT_FOUND");
      return json({
        player:{
          username:p.username,fichasBalance:Number(p.fichas_balance||0),
          approvedLoads:Number(p.approved_loads_count||0),queuedCycles:Number(p.queued_cycles||0),
          activeCycle:p.active_cycle||null,bonusPrizes:p.bonus_prizes||[],
          usedBonusPrizes:p.used_bonus_prizes||[],quadBikeNumbers:Number(p.quad_bike_numbers||0),
          createdAt:p.created_at,lastSpinAt:p.last_spin_at
        },
        awards:awardsResult.data||[],spins:spinsResult.data||[],
        opportunities:opportunitiesResult.data||[],ledger:ledgerResult.data||[]
      });
    }

    if (action === "adminListCatalog") {
      const {data,error}=await db.from("roulette_prize_catalog").select("*").order("sort_order",{ascending:true});
      if(error)throw error;
      return json({items:data||[]});
    }

    if (action === "adminSaveCatalog") {
      const rows=Array.isArray(body.items)?body.items:[];
      if(rows.length<2||rows.length>40)throw new Error("El catálogo debe contener entre 2 y 40 premios.");
      const seen=new Set();
      const clean=rows.map((item:any,index:number)=>{
        const prizeKey=String(item.prize_key||"").trim().toLowerCase();
        const label=String(item.label||"").trim();
        const prizeType=String(item.prize_type||"");
        const fichasAmount=Number(item.fichas_amount||0);
        const bonusPercent=Number(item.bonus_percent||0);
        const probabilityFirst=Number(item.probability_first||0);
        const probabilityThird=Number(item.probability_third||0);
        const sortOrder=Number(item.sort_order??index);
        const isActive=item.is_active===true;
        const imageUrl=item.image_url?String(item.image_url).trim():null;
        if(!/^[a-z0-9_-]{2,40}$/.test(prizeKey)||seen.has(prizeKey))throw new Error("Cada premio necesita una clave única de 2 a 40 caracteres.");
        seen.add(prizeKey);
        if(label.length<2||label.length>100)throw new Error("El nombre de cada premio debe tener entre 2 y 100 caracteres.");
        if(!["none","bonus","fichas","raffle"].includes(prizeType))throw new Error("La categoría de un premio no es válida.");
        if(!Number.isSafeInteger(fichasAmount)||fichasAmount<0||!Number.isInteger(bonusPercent)||bonusPercent<0||bonusPercent>100)throw new Error("El importe o porcentaje del premio no es válido.");
        if(!Number.isInteger(probabilityFirst)||probabilityFirst<0||probabilityFirst>10000||!Number.isInteger(probabilityThird)||probabilityThird<0||probabilityThird>10000)throw new Error("Las probabilidades deben ser porcentajes válidos con hasta dos decimales.");
        if(!Number.isInteger(sortOrder)||sortOrder<0||sortOrder>10000)throw new Error("El orden del premio no es válido.");
        if(prizeType==="none"&&(fichasAmount!==0||bonusPercent!==0))throw new Error("SIN PREMIO no puede tener fichas ni porcentaje.");
        if(prizeType==="bonus"&&(fichasAmount!==0||bonusPercent===0))throw new Error("Un bono debe tener un porcentaje y no puede tener fichas.");
        if(prizeType==="fichas"&&(fichasAmount<=0||bonusPercent!==0))throw new Error("Un premio de fichas debe tener una cantidad mayor a cero.");
        if(prizeType==="raffle"&&(fichasAmount!==0||bonusPercent!==0))throw new Error("Un premio de sorteo no puede sumar fichas ni porcentaje.");
        if(imageUrl&&(!/^https:\/\//i.test(imageUrl)||imageUrl.length>1000))throw new Error("Las imágenes del catálogo deben usar una dirección HTTPS válida.");
        return {prize_key:prizeKey,label,prize_type:prizeType,fichas_amount:fichasAmount,
          bonus_percent:bonusPercent,probability_first:probabilityFirst,probability_third:probabilityThird,
          image_url:imageUrl,is_active:isActive,sort_order:sortOrder,updated_at:new Date().toISOString()};
      });
      const active=clean.filter((item:any)=>item.is_active);
      const totalFirst=active.reduce((sum:number,item:any)=>sum+item.probability_first,0);
      const totalThird=active.reduce((sum:number,item:any)=>sum+item.probability_third,0);
      if(totalFirst!==10000||totalThird!==10000)throw new Error("Las probabilidades activas deben sumar exactamente 100,00% en los dos tipos de giro.");
      if(!active.some((item:any)=>item.prize_type==="none"))throw new Error("Debe quedar al menos un resultado SIN PREMIO activo.");
      const {data,error}=await db.from("roulette_prize_catalog").upsert(clean,{onConflict:"prize_key"}).select("*").order("sort_order",{ascending:true});
      if(error)throw error;
      return json({items:data||[],probabilityFirst:totalFirst,probabilityThird:totalThird});
    }

    if (action === "adminGetReports") {
      const [playersResult,spinsResult,awardsResult,opportunitiesResult,ledgerResult]=await Promise.all([
        db.from("roulette_players").select("id,username,fichas_balance,approved_loads_count,queued_cycles,created_at,last_spin_at").order("created_at",{ascending:false}).limit(1000),
        db.from("roulette_spins").select("id,username,prize_key,result,bonus_percent,created_at").order("created_at",{ascending:false}).limit(5000),
        db.from("roulette_prize_awards").select("id,username,prize_type,prize_label,fichas_amount,bonus_percent,status,created_at,resolved_at").order("created_at",{ascending:false}).limit(5000),
        db.from("roulette_opportunities").select("id,player_id,source,status,created_at,completed_at,cancelled_at").order("created_at",{ascending:false}).limit(5000),
        db.from("roulette_fichas_ledger").select("id,username,movement_type,amount_delta,balance_before,balance_after,description,actor,created_at").order("created_at",{ascending:false}).limit(5000)
      ]);
      for(const item of [playersResult,spinsResult,awardsResult,opportunitiesResult,ledgerResult])if(item.error)throw item.error;
      return json({generatedAt:new Date().toISOString(),players:playersResult.data||[],spins:spinsResult.data||[],
        awards:awardsResult.data||[],opportunities:opportunitiesResult.data||[],ledger:ledgerResult.data||[]});
    }

    if (action === "adminListNotifications") {
      const {data,error}=await db.from("roulette_prize_awards")
        .select("id,username,prize_type,prize_label,fichas_amount,bonus_percent,status,created_at")
        .in("status",["pending_delivery","pending_use","pending_assignment"])
        .order("created_at",{ascending:true}).limit(200);
      if(error)throw error;
      const items=data||[];
      const now=Date.now();
      const stale=items.filter((item:any)=>now-new Date(item.created_at).getTime()>48*60*60*1000).length;
      return json({items,pendingCount:items.length,staleCount:stale,
        pendingFichas:items.filter((x:any)=>x.status==="pending_delivery").length,
        pendingBonuses:items.filter((x:any)=>x.status==="pending_use").length,
        pendingAssignments:items.filter((x:any)=>x.status==="pending_assignment").length});
    }

    if (action === "adminListPlayers") {
      const { data, error } = await db.from("roulette_players").select("*").order("created_at", { ascending:false }).limit(250);
      if (error) throw error;

      const { data: loadRows, error: loadError } = await db
        .from("roulette_opportunities")
        .select("id,player_id,status")
        .eq("source", "load-approved")
        .in("status", ["active", "queued"]);
      if (loadError) throw loadError;

      const playersById = new Map((data || []).map((p:any) => [p.id, p]));
      const cancellableLoads = new Map<string, number>();
      for (const opportunity of loadRows || []) {
        let canCancel = opportunity.status === "queued";
        if (opportunity.status === "active") {
          const owner:any = playersById.get(opportunity.player_id);
          const cycle = owner?.active_cycle || null;
          const spins = cycle?.spins || [];
          canCancel = cycle?.opportunityId === opportunity.id && spins.length === 0;
        }
        if (canCancel) {
          cancellableLoads.set(
            opportunity.player_id,
            (cancellableLoads.get(opportunity.player_id) || 0) + 1
          );
        }
      }

      return json({ players:(data || []).map((p:any) => {
        const cycle=p.active_cycle||null, spins=cycle?.spins||[];
        const thirdAvailable=spins.length===2 && spins.every((s:any)=>s.result==="SIN PREMIO");
        return {
          username:p.username, active:!!cycle, used:spins.length,
          spinsLeft:cycle?(spins.length===0?2:spins.length===1?1:thirdAvailable?1:0):0,
          thirdAvailable, queuedCycles:p.queued_cycles, fichasBalance:p.fichas_balance,
          bonusCount:(p.bonus_prizes||[]).length,
          usedBonusCount:(p.used_bonus_prizes||[]).length,
          approvedLoads:Number(p.approved_loads_count||0),
          cancellableLoads:cancellableLoads.get(p.id)||0,
          bonusPrizes:(p.bonus_prizes||[]).map((b:any)=>({
            percent:Number(b.percent||0),cycleId:b.cycleId||null,
            spinNumber:Number(b.spinNumber||0),createdAt:b.createdAt||null
          })),
          quadBikeNumbers:p.quad_bike_numbers
        };
      }) });
    }

    if (action === "adminListPrizes") {
      const { data, error } = await db
        .from("roulette_prize_awards")
        .select("*")
        .order("created_at", { ascending:false })
        .limit(1000);
      if (error) throw error;
      const awards = data || [];
      const pending = awards.filter((a:any) => ["pending_delivery","pending_use","pending_assignment"].includes(a.status));
      return json({
        awards,
        summary: {
          pendingCount: pending.length,
          pendingFichasCount: pending.filter((a:any) => a.status === "pending_delivery").length,
          pendingFichasTotal: pending.filter((a:any) => a.status === "pending_delivery").reduce((sum:number,a:any) => sum + Number(a.fichas_amount||0),0),
          pendingBonuses: pending.filter((a:any) => a.status === "pending_use").length,
          pendingAssignments: pending.filter((a:any) => a.status === "pending_assignment").length,
          archivedCount: awards.filter((a:any) => ["delivered","redeemed","assigned","cancelled"].includes(a.status)).length
        }
      });
    }

    if (action === "adminListPrizeEvents") {
      const awardId = String(body.awardId || "").trim();
      if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(awardId)) {
        throw new Error("No se pudo identificar el premio seleccionado.");
      }
      const { data, error } = await db
        .from("roulette_prize_events")
        .select("*")
        .eq("award_id", awardId)
        .order("created_at", { ascending:true });
      if (error) throw error;
      return json({ events:data||[] });
    }

    const username = ["adminConfirmFichasDelivery","adminAssignRaffleAward"].includes(action) ? "" : nameOf(body.username);
    const id = username ? slugOf(username) : "";
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
    if (action === "adminConfirmFichasDelivery") {
      const awardId = String(body.awardId || "").trim();
      if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(awardId)) {
        throw new Error("No se pudo identificar el premio seleccionado.");
      }
      const note = typeof body.note === "string" ? body.note.trim().slice(0,300) : null;
      const { data, error } = await db.rpc("roulette_admin_confirm_fichas_delivery", {
        p_award_id: awardId, p_actor: "administrador", p_note: note
      });
      if (error) throw error;
      return json(data);
    }

    if (action === "adminAssignRaffleAward") {
      const awardId = String(body.awardId || "").trim();
      const number = String(body.number || "").trim();
      if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(awardId)) {
        throw new Error("No se pudo identificar el premio seleccionado.");
      }
      if (!number || number.length > 30) throw new Error("Ingresá el número que asignaste.");
      const note = typeof body.note === "string" ? body.note.trim().slice(0,300) : null;
      const { data, error } = await db.rpc("roulette_admin_assign_raffle_award", {
        p_award_id: awardId, p_number: number, p_actor: "administrador", p_note: note
      });
      if (error) throw error;
      return json(data);
    }

    if (action === "adminAdjustFichas") {
      const delta=Number(body.delta);
      const note=typeof body.note==="string"?body.note.trim().slice(0,300):"";
      if(!Number.isSafeInteger(delta)||delta===0)throw new Error("Ingresá una cantidad de fichas distinta de cero.");
      const {data,error}=await db.rpc("roulette_admin_adjust_fichas",{
        p_id:id,p_delta:delta,p_actor:"administrador",p_note:note
      });
      if(error)throw error;
      return json(data);
    }

    if (action === "adminMarkBonusUsed") {
      const username = nameOf(body.username), id = slugOf(username);
      const cycleId = String(body.cycleId || "").trim();
      const spinNumber = Number(body.spinNumber);
      if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(cycleId)) {
        throw new Error("No se pudo identificar el bono seleccionado.");
      }
      if (!Number.isInteger(spinNumber) || spinNumber < 1 || spinNumber > 3) {
        throw new Error("El número de tiro del bono no es válido.");
      }
      const { data, error } = await db.rpc("roulette_admin_mark_bonus_used", {
        p_id: id, p_cycle_id: cycleId, p_spin_number: spinNumber
      });
      if (error) throw error;
      return json(data);
    }

    if (action === "adminCancelLoad") {
      const username = nameOf(body.username), id = slugOf(username);
      const { data, error } = await db.rpc("roulette_admin_cancel_last_load", { p_id: id });
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
    const friendly = message.includes("NO_CANCELLABLE_LOAD")
      ? "No hay una carga aprobada pendiente que pueda anularse. Si ya tuvo algún giro, no se puede retirar."
      : message.includes("BONUS_NOT_FOUND") || message.includes("BONUS_AWARD_NOT_PENDING")
        ? "Ese bono ya no figura entre los bonos pendientes."
        : message.includes("AWARD_NOT_FOUND")
          ? "Ese premio ya no existe en el registro."
          : message.includes("AWARD_NOT_PENDING_DELIVERY")
            ? "Ese premio ya fue resuelto; no se puede acreditar dos veces."
            : message.includes("AWARD_NOT_PENDING_ASSIGNMENT")
              ? "Ese número ya fue asignado o el premio ya fue resuelto."
              : message.includes("INVALID_RAFFLE_NUMBER")
                ? "Ingresá un número válido para el sorteo."
                : message.includes("INSUFFICIENT_FICHAS_BALANCE")
                  ? "El ajuste dejaría el saldo del jugador por debajo de cero."
                  : message.includes("FICHAS_ADJUSTMENT_REASON_REQUIRED")
                    ? "Indicá el motivo del ajuste de fichas."
                    : message.includes("INVALID_FICHAS_ADJUSTMENT")
                      ? "El importe del ajuste no es válido."
                      : message.includes("PRIZE_CATALOG_PROBABILITIES_MUST_TOTAL_100_PERCENT")
                        ? "El catálogo tiene probabilidades inválidas. Deben sumar 100%."
                        : message;
    return json({ error:friendly }, errorStatus(message));
  }
});

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return json({ ok: true });
  const requestUrl = new URL(req.url);
  if (req.method === "GET" && requestUrl.searchParams.get("health") === "1") {
    return json({
      status: "ok",
      function: "roulette",
      version: 17,
      adminSecretConfigured: Boolean(adminSecret && adminSecret.length >= 32),
      timestamp: new Date().toISOString()
    });
  }
  const response = await handler(req);
  const headers = new Headers(response.headers);
  headers.set("access-control-allow-origin", "*");
  headers.set("access-control-allow-headers", "authorization, apikey, content-type, x-admin-key");
  headers.set("access-control-allow-methods", "POST, OPTIONS");
  return new Response(response.body, { status: response.status, statusText: response.statusText, headers });
});
