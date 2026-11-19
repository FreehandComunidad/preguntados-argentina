-- FREEHAND migration 20261119043500.
-- Archive used bonuses and track the source/status of opportunities for safe load cancellation.
-- Applied to the existing freehand-roulette Supabase project.

ALTER TABLE public.roulette_players
  ADD COLUMN IF NOT EXISTS used_bonus_prizes jsonb NOT NULL DEFAULT '[]'::jsonb;

CREATE TABLE IF NOT EXISTS public.roulette_opportunities (
  id uuid PRIMARY KEY DEFAULT pg_catalog.gen_random_uuid(),
  player_id text NOT NULL REFERENCES public.roulette_players(id) ON DELETE CASCADE,
  source text NOT NULL CHECK (source IN ('load-approved', 'admin', 'legacy')),
  status text NOT NULL CHECK (status IN ('active', 'queued', 'completed', 'cancelled')),
  cycle_id uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  activated_at timestamptz,
  completed_at timestamptz,
  cancelled_at timestamptz
);

ALTER TABLE public.roulette_opportunities ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.roulette_opportunities FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.roulette_opportunities TO service_role;
CREATE INDEX IF NOT EXISTS roulette_opportunities_player_queue_idx
  ON public.roulette_opportunities(player_id, status, created_at, id);
CREATE INDEX IF NOT EXISTS roulette_opportunities_load_undo_idx
  ON public.roulette_opportunities(player_id, source, status, created_at DESC)
  WHERE source = 'load-approved' AND status IN ('active', 'queued');

-- Backfill only active cycles not already linked; queued legacy entries are backfilled to the shortfall.
DO $$
DECLARE r record; v_opportunity_id uuid; v_source text; v_cycle_id uuid;
BEGIN
  FOR r IN SELECT id, active_cycle, updated_at FROM public.roulette_players
           WHERE active_cycle IS NOT NULL AND active_cycle->>'opportunityId' IS NULL
  LOOP
    v_opportunity_id := pg_catalog.gen_random_uuid();
    v_cycle_id := NULLIF(r.active_cycle->>'id','')::uuid;
    v_source := CASE
      WHEN r.active_cycle->>'source'='load-approved' THEN 'load-approved'
      WHEN r.active_cycle->>'source'='admin' THEN 'admin'
      ELSE 'legacy' END;
    INSERT INTO public.roulette_opportunities(id,player_id,source,status,cycle_id,created_at,activated_at)
    VALUES(v_opportunity_id,r.id,v_source,'active',v_cycle_id,
      COALESCE(NULLIF(r.active_cycle->>'createdAt','')::timestamptz,r.updated_at,now()),now());
    UPDATE public.roulette_players
    SET active_cycle=active_cycle||pg_catalog.jsonb_build_object('opportunityId',v_opportunity_id::text)
    WHERE id=r.id;
  END LOOP;

  FOR r IN
    SELECT p.id,p.queued_cycles,
      (SELECT count(*) FROM public.roulette_opportunities o WHERE o.player_id=p.id AND o.status='queued') AS ledger_queued,
      p.updated_at
    FROM public.roulette_players p
    WHERE p.queued_cycles > 0
  LOOP
    IF r.queued_cycles > r.ledger_queued THEN
      INSERT INTO public.roulette_opportunities(player_id,source,status,created_at)
      SELECT r.id,'legacy','queued',COALESCE(r.updated_at,now())+(g.n*interval '1 microsecond')
      FROM generate_series(1,r.queued_cycles-r.ledger_queued) AS g(n);
    END IF;
  END LOOP;
END
$$;

CREATE OR REPLACE FUNCTION public.roulette_admin_grant_cycles(p_id text, p_count integer, p_source text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  p public.roulette_players%rowtype;
  v_active jsonb;
  v_queued integer;
  v_total integer;
  v_remaining integer;
  v_i integer;
  v_opportunity_id uuid;
  v_cycle_id uuid;
  v_approved_total integer;
BEGIN
  IF p_source NOT IN ('load-approved', 'admin') THEN
    RAISE EXCEPTION 'INVALID_OPPORTUNITY_SOURCE';
  END IF;

  SELECT * INTO p
  FROM public.roulette_players
  WHERE id = p_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'PLAYER_NOT_FOUND';
  END IF;

  v_active := p.active_cycle;
  v_queued := p.queued_cycles;
  v_total := GREATEST(1, LEAST(100, p_count));
  v_remaining := v_total;

  IF v_active IS NULL THEN
    v_opportunity_id := pg_catalog.gen_random_uuid();
    v_cycle_id := pg_catalog.gen_random_uuid();

    INSERT INTO public.roulette_opportunities
      (id, player_id, source, status, cycle_id, activated_at)
    VALUES
      (v_opportunity_id, p_id, p_source, 'active', v_cycle_id, now());

    v_active := pg_catalog.jsonb_build_object(
      'id', v_cycle_id,
      'source', p_source,
      'opportunityId', v_opportunity_id,
      'spins', '[]'::jsonb,
      'status', 'active',
      'createdAt', now()::text
    );
    v_remaining := v_total - 1;
  END IF;

  IF v_remaining > 0 THEN
    FOR v_i IN 1..v_remaining LOOP
      INSERT INTO public.roulette_opportunities
        (player_id, source, status)
      VALUES
        (p_id, p_source, 'queued');
    END LOOP;
  END IF;

  v_queued := v_queued + v_remaining;
  v_approved_total := COALESCE(p.approved_loads_count, 0)
    + CASE WHEN p_source = 'load-approved' THEN v_total ELSE 0 END;

  UPDATE public.roulette_players
  SET active_cycle = v_active,
      queued_cycles = v_queued,
      approved_loads_count = v_approved_total,
      updated_at = now()
  WHERE id = p_id;

  RETURN pg_catalog.jsonb_build_object(
    'username', p.username,
    'active', true,
    'queuedCycles', v_queued,
    'granted', v_total,
    'approvedLoads', v_approved_total
  );
END;
$function$

CREATE OR REPLACE FUNCTION public.roulette_admin_cancel_last_load(p_id text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  p public.roulette_players%rowtype;
  v_target public.roulette_opportunities%rowtype;
  v_next public.roulette_opportunities%rowtype;
  v_active jsonb;
  v_cycle_id uuid;
  v_queued integer;
  v_approved_total integer;
BEGIN
  SELECT * INTO p
  FROM public.roulette_players
  WHERE id = p_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'PLAYER_NOT_FOUND';
  END IF;

  SELECT o.* INTO v_target
  FROM public.roulette_opportunities o
  WHERE o.player_id = p_id
    AND o.source = 'load-approved'
    AND (
      o.status = 'queued'
      OR (
        o.status = 'active'
        AND p.active_cycle->>'opportunityId' = o.id::text
        AND COALESCE(pg_catalog.jsonb_array_length(p.active_cycle->'spins'), 0) = 0
      )
    )
  ORDER BY o.created_at DESC, o.id DESC
  LIMIT 1
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'NO_CANCELLABLE_LOAD';
  END IF;

  v_queued := p.queued_cycles;
  v_approved_total := GREATEST(0, COALESCE(p.approved_loads_count, 0) - 1);

  UPDATE public.roulette_opportunities
  SET status = 'cancelled', cancelled_at = now()
  WHERE id = v_target.id;

  IF v_target.status = 'queued' THEN
    v_queued := GREATEST(0, v_queued - 1);
    UPDATE public.roulette_players
    SET queued_cycles = v_queued,
        approved_loads_count = v_approved_total,
        updated_at = now()
    WHERE id = p_id;
  ELSE
    SELECT o.* INTO v_next
    FROM public.roulette_opportunities o
    WHERE o.player_id = p_id AND o.status = 'queued'
    ORDER BY o.created_at, o.id
    LIMIT 1
    FOR UPDATE;

    IF FOUND THEN
      v_cycle_id := pg_catalog.gen_random_uuid();
      UPDATE public.roulette_opportunities
      SET status = 'active', cycle_id = v_cycle_id, activated_at = now()
      WHERE id = v_next.id;

      v_active := pg_catalog.jsonb_build_object(
        'id', v_cycle_id,
        'source', v_next.source,
        'opportunityId', v_next.id,
        'spins', '[]'::jsonb,
        'status', 'active',
        'createdAt', now()::text
      );
      v_queued := GREATEST(0, v_queued - 1);
    ELSE
      v_active := NULL;
    END IF;

    UPDATE public.roulette_players
    SET active_cycle = v_active,
        queued_cycles = v_queued,
        approved_loads_count = v_approved_total,
        updated_at = now()
    WHERE id = p_id;
  END IF;

  RETURN pg_catalog.jsonb_build_object(
    'username', p.username,
    'cancelledOpportunityId', v_target.id,
    'cancelledStatus', v_target.status,
    'active', v_active IS NOT NULL,
    'queuedCycles', v_queued,
    'approvedLoads', v_approved_total
  );
END;
$function$

CREATE OR REPLACE FUNCTION public.roulette_admin_mark_bonus_used(p_id text, p_cycle_id uuid, p_spin_number integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  p public.roulette_players%rowtype;
  v_bonus jsonb;
  v_pending jsonb;
  v_used jsonb;
BEGIN
  SELECT * INTO p FROM public.roulette_players WHERE id = p_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'PLAYER_NOT_FOUND';
  END IF;

  SELECT e.value INTO v_bonus
  FROM pg_catalog.jsonb_array_elements(COALESCE(p.bonus_prizes, '[]'::jsonb)) AS e(value)
  WHERE e.value->>'cycleId' = p_cycle_id::text
    AND COALESCE((e.value->>'spinNumber')::integer, 0) = p_spin_number
  LIMIT 1;

  IF v_bonus IS NULL THEN
    RAISE EXCEPTION 'BONUS_NOT_FOUND';
  END IF;

  SELECT COALESCE(pg_catalog.jsonb_agg(e.value ORDER BY e.ordinality), '[]'::jsonb)
  INTO v_pending
  FROM pg_catalog.jsonb_array_elements(COALESCE(p.bonus_prizes, '[]'::jsonb))
    WITH ORDINALITY AS e(value, ordinality)
  WHERE NOT (
    e.value->>'cycleId' = p_cycle_id::text
    AND COALESCE((e.value->>'spinNumber')::integer, 0) = p_spin_number
  );

  v_used := COALESCE(p.used_bonus_prizes, '[]'::jsonb)
    || pg_catalog.jsonb_build_array(v_bonus || pg_catalog.jsonb_build_object('usedAt', now()::text));

  UPDATE public.roulette_players
  SET bonus_prizes = v_pending, used_bonus_prizes = v_used, updated_at = now()
  WHERE id = p_id;

  RETURN pg_catalog.jsonb_build_object(
    'username', p.username,
    'pendingBonuses', pg_catalog.jsonb_array_length(v_pending),
    'usedBonuses', pg_catalog.jsonb_array_length(v_used)
  );
END;
$function$

CREATE OR REPLACE FUNCTION public.roulette_apply_spin(p_player_id text, p_pin_hash text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  p public.roulette_players%rowtype;
  c jsonb;
  spins jsonb;
  n integer;
  third_ok boolean;
  third_after boolean;
  spin_no integer;
  cid uuid;
  opportunity_id uuid;
  remaining integer;
  completed boolean;
  queued integer;
  next_cycle jsonb;
  next_opportunity public.roulette_opportunities%rowtype;
  next_cycle_id uuid;
  now_iso text := now()::text;
  weights integer[];
  random_bytes bytea;
  random_value bigint;
  roll integer;
  total integer := 0;
  i integer;
  prize_key text;
  prize_label text;
  prize_bonus integer := 0;
  prize_fichas integer := 0;
  attempts integer;
BEGIN
  SELECT * INTO p
  FROM public.roulette_players
  WHERE id = p_player_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object('error', 'PLAYER_NOT_FOUND');
  END IF;

  IF p.pin_locked_until IS NOT NULL AND p.pin_locked_until > now() THEN
    RETURN pg_catalog.jsonb_build_object('error', 'PIN_LOCKED', 'retryAt', p.pin_locked_until);
  END IF;

  IF p.pin_hash <> p_pin_hash THEN
    attempts := p.pin_failed_attempts + 1;
    IF attempts >= 5 THEN
      UPDATE public.roulette_players
      SET pin_failed_attempts = 0, pin_locked_until = now() + interval '15 minutes', updated_at = now()
      WHERE id = p_player_id;
      RETURN pg_catalog.jsonb_build_object('error', 'PIN_LOCKED', 'retryMinutes', 15);
    END IF;
    UPDATE public.roulette_players
    SET pin_failed_attempts = attempts, updated_at = now()
    WHERE id = p_player_id;
    RETURN pg_catalog.jsonb_build_object('error', 'INVALID_CREDENTIALS', 'attemptsRemaining', 5 - attempts);
  END IF;

  IF p.pin_failed_attempts <> 0 OR p.pin_locked_until IS NOT NULL THEN
    UPDATE public.roulette_players
    SET pin_failed_attempts = 0, pin_locked_until = NULL
    WHERE id = p_player_id;
  END IF;

  c := p.active_cycle;
  IF c IS NULL OR COALESCE(c->>'status', '') <> 'active' THEN
    RETURN pg_catalog.jsonb_build_object('error', 'NO_ACTIVE_CYCLE');
  END IF;

  spins := COALESCE(c->'spins', '[]'::jsonb);
  n := pg_catalog.jsonb_array_length(spins);
  third_ok := n = 2 AND spins->0->>'result' = 'SIN PREMIO' AND spins->1->>'result' = 'SIN PREMIO';

  IF n >= 3 OR (n >= 2 AND NOT third_ok) THEN
    RETURN pg_catalog.jsonb_build_object('error', 'CYCLE_FINISHED');
  END IF;

  spin_no := n + 1;
  cid := (c->>'id')::uuid;
  opportunity_id := NULLIF(c->>'opportunityId', '')::uuid;

  IF spin_no = 3 THEN
    weights := ARRAY[4994,1200,800,300,200,1700,600,150,50,5,1];
  ELSE
    weights := ARRAY[5994,2000,1000,200,100,500,150,40,10,5,1];
  END IF;

  LOOP
    random_bytes := extensions.gen_random_bytes(4);
    random_value := get_byte(random_bytes,0)::bigint*16777216
      + get_byte(random_bytes,1)::bigint*65536
      + get_byte(random_bytes,2)::bigint*256
      + get_byte(random_bytes,3)::bigint;
    EXIT WHEN random_value < 4294960000;
  END LOOP;
  roll := mod(random_value, 10000)::integer;

  FOR i IN 1..array_length(weights, 1) LOOP
    total := total + weights[i];
    IF roll < total THEN
      CASE i
        WHEN 1 THEN prize_key := 'none'; prize_label := 'SIN PREMIO';
        WHEN 2 THEN prize_key := 'b5'; prize_label := 'BONUS 5%'; prize_bonus := 5;
        WHEN 3 THEN prize_key := 'b10'; prize_label := 'BONUS 10%'; prize_bonus := 10;
        WHEN 4 THEN prize_key := 'b15'; prize_label := 'BONUS 15%'; prize_bonus := 15;
        WHEN 5 THEN prize_key := 'b20'; prize_label := 'BONUS 20%'; prize_bonus := 20;
        WHEN 6 THEN prize_key := 't1000'; prize_label := '1.000 FICHAS'; prize_fichas := 1000;
        WHEN 7 THEN prize_key := 't3000'; prize_label := '3.000 FICHAS'; prize_fichas := 3000;
        WHEN 8 THEN prize_key := 't5000'; prize_label := '5.000 FICHAS'; prize_fichas := 5000;
        WHEN 9 THEN prize_key := 'number'; prize_label := 'NÚMERO A ELECCIÓN PARA EL SORTEO DEL CUATRICICLO';
        WHEN 10 THEN prize_key := 't50000'; prize_label := '50.000 FICHAS'; prize_fichas := 50000;
        WHEN 11 THEN prize_key := 't100000'; prize_label := '100.000 FICHAS'; prize_fichas := 100000;
      END CASE;
      EXIT;
    END IF;
  END LOOP;

  spins := spins || pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
    'spinNumber', spin_no, 'key', prize_key, 'result', prize_label,
    'bonus', prize_bonus, 'createdAt', now_iso
  ));

  third_after := spin_no = 2 AND spins->0->>'result' = 'SIN PREMIO' AND prize_label = 'SIN PREMIO';
  remaining := CASE WHEN spin_no = 1 THEN 1 WHEN third_after THEN 1 ELSE 0 END;
  completed := remaining = 0;
  queued := p.queued_cycles;
  next_cycle := c || pg_catalog.jsonb_build_object('spins', spins);

  IF completed THEN
    IF opportunity_id IS NOT NULL THEN
      UPDATE public.roulette_opportunities
      SET status = 'completed', completed_at = now()
      WHERE id = opportunity_id AND player_id = p_player_id AND status = 'active';
    END IF;

    IF queued > 0 THEN
      SELECT o.* INTO next_opportunity
      FROM public.roulette_opportunities o
      WHERE o.player_id = p_player_id AND o.status = 'queued'
      ORDER BY o.created_at, o.id
      LIMIT 1
      FOR UPDATE;

      IF FOUND THEN
        next_cycle_id := pg_catalog.gen_random_uuid();
        UPDATE public.roulette_opportunities
        SET status = 'active', cycle_id = next_cycle_id, activated_at = now()
        WHERE id = next_opportunity.id;

        next_cycle := pg_catalog.jsonb_build_object(
          'id', next_cycle_id,
          'source', next_opportunity.source,
          'opportunityId', next_opportunity.id,
          'spins', '[]'::jsonb,
          'status', 'active',
          'createdAt', now_iso
        );
      ELSE
        -- Defensive repair: preserve the legacy queue count if its ledger row is missing.
        next_opportunity.id := pg_catalog.gen_random_uuid();
        next_cycle_id := pg_catalog.gen_random_uuid();
        INSERT INTO public.roulette_opportunities
          (id, player_id, source, status, cycle_id, activated_at)
        VALUES
          (next_opportunity.id, p_player_id, 'legacy', 'active', next_cycle_id, now());
        next_cycle := pg_catalog.jsonb_build_object(
          'id', next_cycle_id,
          'source', 'legacy',
          'opportunityId', next_opportunity.id,
          'spins', '[]'::jsonb,
          'status', 'active',
          'createdAt', now_iso
        );
      END IF;

      queued := queued - 1;
    ELSE
      next_cycle := NULL;
    END IF;
  END IF;

  UPDATE public.roulette_players
  SET active_cycle = next_cycle,
      queued_cycles = queued,
      fichas_balance = fichas_balance + prize_fichas,
      bonus_prizes = CASE WHEN prize_bonus > 0
        THEN bonus_prizes || pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
          'percent', prize_bonus, 'cycleId', cid, 'spinNumber', spin_no, 'createdAt', now_iso
        ))
        ELSE bonus_prizes END,
      quad_bike_numbers = quad_bike_numbers + CASE WHEN prize_key = 'number' THEN 1 ELSE 0 END,
      last_spin_at = now(),
      updated_at = now()
  WHERE id = p_player_id;

  INSERT INTO public.roulette_spins(player_id, username, cycle_id, spin_number, prize_key, result, bonus_percent)
  VALUES (p_player_id, p.username, cid, spin_no, prize_key, prize_label, prize_bonus);

  RETURN pg_catalog.jsonb_build_object(
    'username', p.username, 'cycleId', cid, 'spinNumber', spin_no,
    'result', pg_catalog.jsonb_build_object('key', prize_key, 'label', prize_label, 'bonus', prize_bonus),
    'spinsLeft', remaining, 'thirdAvailable', third_after, 'cycleCompleted', completed,
    'queuedCycles', queued, 'fichasBalance', p.fichas_balance + prize_fichas
  );
END;
$function$


REVOKE ALL ON FUNCTION public.roulette_admin_grant_cycles(text,integer,text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.roulette_admin_cancel_last_load(text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.roulette_admin_mark_bonus_used(text,uuid,integer) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.roulette_apply_spin(text,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.roulette_admin_grant_cycles(text,integer,text) TO service_role;
GRANT EXECUTE ON FUNCTION public.roulette_admin_cancel_last_load(text) TO service_role;
GRANT EXECUTE ON FUNCTION public.roulette_admin_mark_bonus_used(text,uuid,integer) TO service_role;
GRANT EXECUTE ON FUNCTION public.roulette_apply_spin(text,text) TO service_role;
