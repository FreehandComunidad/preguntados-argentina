const { onCall, HttpsError } = require('firebase-functions/v2/https');
const { defineSecret } = require('firebase-functions/params');
const { initializeApp } = require('firebase-admin/app');
const { getFirestore, FieldValue } = require('firebase-admin/firestore');
const crypto = require('node:crypto');

initializeApp();
const db = getFirestore();
const ADMIN_KEY = defineSecret('ROULETTE_ADMIN_KEY');
const REGION = 'us-central1';

const RESULTS = [
  { key: 'none', label: 'SIN PREMIO', bonus: 0 },
  { key: 'b5', label: 'BONUS 5%', bonus: 5 },
  { key: 'b10', label: 'BONUS 10%', bonus: 10 },
  { key: 'b15', label: 'BONUS 15%', bonus: 15 },
  { key: 'b20', label: 'BONUS 20%', bonus: 20 },
  { key: 't1000', label: '1.000 FICHAS', bonus: 0 },
  { key: 't3000', label: '3.000 FICHAS', bonus: 0 },
  { key: 't5000', label: '5.000 FICHAS', bonus: 0 },
  { key: 'number', label: 'NÚMERO A ELECCIÓN PARA EL SORTEO DEL CUATRICICLO', bonus: 0 },
];
// Enteros en diezmilésimas de porcentaje: suman exactamente 10.000 (=100%).
const FIRST = [6000, 2000, 1000, 200, 100, 500, 150, 40, 10];
const THIRD = [5000, 1200, 800, 300, 200, 1700, 600, 150, 50];

function requireAuth(request) {
  if (!request.auth) throw new HttpsError('unauthenticated', 'Iniciá la sesión para jugar.');
}
function normalizeName(value) {
  if (typeof value !== 'string') throw new HttpsError('invalid-argument', 'Ingresá tu nombre de usuario.');
  const name = value.trim().replace(/\s+/g, ' ');
  if (name.length < 2 || name.length > 20) throw new HttpsError('invalid-argument', 'El usuario debe tener entre 2 y 20 caracteres.');
  return name;
}
function slugFor(name) {
  return Buffer.from(name.normalize('NFKC').toLocaleLowerCase('es')).toString('base64url');
}
function pinHash(slug, pin) {
  return crypto.createHash('sha256').update(`${slug}:${pin}`).digest('hex');
}
function credentials(data) {
  const username = normalizeName(data?.username);
  const pin = String(data?.pin || '').trim();
  if (!/^\d{8}$/.test(pin)) throw new HttpsError('invalid-argument', 'El PIN debe tener 8 números.');
  const slug = slugFor(username);
  return { username, pin, slug, ref: db.collection('roulette_players').doc(slug) };
}
function verifyPlayer(data, snap) {
  if (!snap.exists) throw new HttpsError('not-found', 'No encontramos ese usuario. Pedile tu acceso a FREEHAND.');
  const p = snap.data();
  const expected = Buffer.from(p.pinHash || '', 'hex');
  const supplied = Buffer.from(pinHash(data.slug, data.pin), 'hex');
  if (expected.length !== supplied.length || !crypto.timingSafeEqual(expected, supplied)) {
    throw new HttpsError('permission-denied', 'Usuario o PIN incorrecto.');
  }
  return p;
}
function newCycle(source) {
  return { id: crypto.randomUUID(), source, spins: [], status: 'active', createdAt: FieldValue.serverTimestamp() };
}
function spinThirdUnlocked(spins) {
  return spins.length === 2 && spins.every(s => s.result === 'SIN PREMIO');
}
function spinsLeft(spins) {
  if (spins.length === 0) return 2;
  if (spins.length === 1) return 1;
  return spinThirdUnlocked(spins) ? 1 : 0;
}
function pickResult(isThird) {
  const weights = isThird ? THIRD : FIRST;
  const r = crypto.randomInt(0, 10000);
  let total = 0;
  for (let i = 0; i < weights.length; i += 1) {
    total += weights[i];
    if (r < total) return RESULTS[i];
  }
  return RESULTS[0];
}
function adminCheck(data) {
  const supplied = String(data?.adminKey || '');
  const expected = ADMIN_KEY.value();
  const a = Buffer.from(supplied);
  const b = Buffer.from(expected);
  if (!expected || a.length !== b.length || !crypto.timingSafeEqual(a, b)) {
    throw new HttpsError('permission-denied', 'Clave de administración incorrecta.');
  }
}
function adminName(data) {
  return normalizeName(data?.username);
}

exports.getRouletteStatus = onCall({ region: REGION }, async (request) => {
  requireAuth(request);
  const data = credentials(request.data);
  const snap = await data.ref.get();
  const player = verifyPlayer(data, snap);
  const cycle = player.activeCycle || null;
  const spins = cycle?.spins || [];
  const thirdAvailable = spinThirdUnlocked(spins);
  return {
    username: player.username,
    activeCycle: !!cycle,
    cycleId: cycle?.id || null,
    spinsLeft: cycle ? spinsLeft(spins) : 0,
    used: spins.length,
    thirdAvailable,
    queuedCycles: Number(player.queuedCycles || 0),
    fichasBalance: Number(player.fichasBalance || 0),
    bonusCount: Array.isArray(player.bonusPrizes) ? player.bonusPrizes.length : 0,
    quadBikeNumbers: Number(player.quadBikeNumbers || 0),
    recentResults: spins.map(s => ({ result: s.result, key: s.key, bonus: s.bonus })),
  };
});

exports.spinRoulette = onCall({ region: REGION }, async (request) => {
  requireAuth(request);
  const data = credentials(request.data);
  const spinRef = db.collection('roulette_spins').doc();
  let response;
  await db.runTransaction(async (tx) => {
    const snap = await tx.get(data.ref);
    const player = verifyPlayer(data, snap);
    const cycle = player.activeCycle;
    if (!cycle || cycle.status !== 'active') throw new HttpsError('failed-precondition', 'Todavía no tenés tiros habilitados.');
    const spins = Array.isArray(cycle.spins) ? cycle.spins : [];
    const thirdAvailable = spinThirdUnlocked(spins);
    if (spins.length >= 3 || (spins.length >= 2 && !thirdAvailable)) {
      throw new HttpsError('failed-precondition', 'Tu oportunidad ya finalizó.');
    }
    const spinNumber = spins.length + 1;
    const result = pickResult(spinNumber === 3);
    const entry = { spinNumber, key: result.key, result: result.label, bonus: result.bonus, createdAt: new Date().toISOString() };
    const fichas = result.key === 't1000' ? 1000 : result.key === 't3000' ? 3000 : result.key === 't5000' ? 5000 : 0;
    const bonusPrizes = Array.isArray(player.bonusPrizes) ? [...player.bonusPrizes] : [];
    if (result.bonus > 0) bonusPrizes.push({ percent: result.bonus, cycleId: cycle.id, spinNumber, createdAt: new Date().toISOString() });
    const quadBikeNumbers = Number(player.quadBikeNumbers || 0) + (result.key === 'number' ? 1 : 0);
    const nextSpins = [...spins, entry];
    const remaining = spinsLeft(nextSpins);
    const cycleCompleted = remaining === 0;
    let nextCycle = cycle;
    let queuedCycles = Number(player.queuedCycles || 0);
    if (cycleCompleted) {
      if (queuedCycles > 0) {
        queuedCycles -= 1;
        nextCycle = newCycle('queued');
      } else {
        nextCycle = null;
      }
    } else {
      nextCycle = { ...cycle, spins: nextSpins };
    }
    tx.update(data.ref, {
      activeCycle: nextCycle,
      queuedCycles,
      fichasBalance: Number(player.fichasBalance || 0) + fichas,
      bonusPrizes,
      quadBikeNumbers,
      lastSpinAt: FieldValue.serverTimestamp(),
      updatedAt: FieldValue.serverTimestamp(),
    });
    tx.set(spinRef, {
      playerId: data.slug,
      username: player.username,
      cycleId: cycle.id,
      spinNumber,
      key: result.key,
      result: result.label,
      bonusPercent: result.bonus,
      createdAt: FieldValue.serverTimestamp(),
    });
    response = {
      username: player.username,
      cycleId: cycle.id,
      spinNumber,
      result,
      spinsLeft: remaining,
      thirdAvailable: spinThirdUnlocked(nextSpins),
      cycleCompleted,
      queuedCycles,
      fichasBalance: Number(player.fichasBalance || 0) + fichas,
    };
  });
  return response;
});

exports.adminCreatePlayer = onCall({ region: REGION, secrets: [ADMIN_KEY] }, async (request) => {
  requireAuth(request); adminCheck(request.data);
  const username = adminName(request.data);
  const slug = slugFor(username);
  const ref = db.collection('roulette_players').doc(slug);
  const pin = String(crypto.randomInt(10000000, 100000000));
  await db.runTransaction(async tx => {
    const snap = await tx.get(ref);
    if (snap.exists) throw new HttpsError('already-exists', 'Ese usuario ya está creado.');
    tx.create(ref, {
      username,
      pinHash: pinHash(slug, pin),
      activeCycle: null,
      queuedCycles: 0,
      createdAt: FieldValue.serverTimestamp(),
      updatedAt: FieldValue.serverTimestamp(),
    });
  });
  return { username, pin };
});

async function grantCycles(request, source) {
  requireAuth(request); adminCheck(request.data);
  const username = adminName(request.data);
  const slug = slugFor(username);
  const ref = db.collection('roulette_players').doc(slug);
  const count = Math.max(1, Math.min(100, Math.floor(Number(request.data?.count || 1))));
  let state;
  await db.runTransaction(async tx => {
    const snap = await tx.get(ref);
    if (!snap.exists) throw new HttpsError('not-found', 'Primero creá el jugador y entregale su PIN.');
    const p = snap.data();
    let activeCycle = p.activeCycle || null;
    let queuedCycles = Number(p.queuedCycles || 0);
    let toQueue = count;
    if (!activeCycle) { activeCycle = newCycle(source); toQueue -= 1; }
    queuedCycles += toQueue;
    tx.update(ref, { activeCycle, queuedCycles, updatedAt: FieldValue.serverTimestamp() });
    state = { username: p.username, active: !!activeCycle, queuedCycles, granted: count };
  });
  return state;
}
exports.adminGrantCycles = onCall({ region: REGION, secrets: [ADMIN_KEY] }, request => grantCycles(request, 'admin'));
exports.adminApproveLoad = onCall({ region: REGION, secrets: [ADMIN_KEY] }, request => grantCycles({ auth: request.auth, data: { ...request.data, count: 1 } }, 'load-approved'));

exports.adminListPlayers = onCall({ region: REGION, secrets: [ADMIN_KEY] }, async (request) => {
  requireAuth(request); adminCheck(request.data);
  const snap = await db.collection('roulette_players').orderBy('createdAt', 'desc').limit(250).get();
  return { players: snap.docs.map(d => {
    const p = d.data(); const cycle = p.activeCycle || null; const spins = cycle?.spins || [];
    return { username: p.username, active: !!cycle, used: spins.length, spinsLeft: cycle ? spinsLeft(spins) : 0, thirdAvailable: spinThirdUnlocked(spins), queuedCycles: Number(p.queuedCycles || 0), fichasBalance: Number(p.fichasBalance || 0), bonusCount: (p.bonusPrizes || []).length, quadBikeNumbers: Number(p.quadBikeNumbers || 0) };
  }) };
});

exports.adminResetPin = onCall({ region: REGION, secrets: [ADMIN_KEY] }, async (request) => {
  requireAuth(request); adminCheck(request.data);
  const username = adminName(request.data); const slug = slugFor(username); const ref = db.collection('roulette_players').doc(slug);
  const pin = String(crypto.randomInt(10000000, 100000000));
  await db.runTransaction(async tx => { const snap = await tx.get(ref); if (!snap.exists) throw new HttpsError('not-found', 'Jugador inexistente.'); tx.update(ref, { pinHash: pinHash(slug, pin), updatedAt: FieldValue.serverTimestamp() }); });
  return { username, pin };
});
