-- FREEHAND prize delivery management (applied to Supabase project freehand-roulette).
-- Prize ledger with pending/archived states; manual fichas credit only after admin confirmation.

CREATE TABLE IF NOT EXISTS public.roulette_prize_awards (
  id uuid PRIMARY KEY DEFAULT pg_catalog.gen_random_uuid(),
  player_id text NOT NULL REFERENCES public.roulette_players(id) ON DELETE RESTRICT,
  username text NOT NULL,
  spin_id uuid NOT NULL UNIQUE REFERENCES public.roulette_spins(id) ON DELETE RESTRICT,
  cycle_id uuid NOT NULL,
  spin_number integer NOT NULL CHECK (spin_number BETWEEN 1 AND 3),
  prize_key text NOT NULL,
  prize_label text NOT NULL,
  prize_type text NOT NULL CHECK (prize_type IN ('fichas','bonus','raffle')),
  fichas_amount bigint NOT NULL DEFAULT 0 CHECK (fichas_amount >= 0),
  bonus_percent integer NOT NULL DEFAULT 0 CHECK (bonus_percent BETWEEN 0 AND 100),
  status text NOT NULL CHECK (status IN ('pending_delivery','delivered','pending_use','redeemed','pending_assignment','assigned','cancelled')),
  assigned_number text,
  created_at timestamptz NOT NULL DEFAULT now(),
  resolved_at timestamptz,
  resolved_by text,
  resolution_note text,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb
);
CREATE INDEX IF NOT EXISTS roulette_prize_awards_pending_idx ON public.roulette_prize_awards(status,created_at DESC);
CREATE INDEX IF NOT EXISTS roulette_prize_awards_player_idx ON public.roulette_prize_awards(player_id,created_at DESC);
ALTER TABLE public.roulette_prize_awards ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.roulette_prize_awards FROM PUBLIC,anon,authenticated;
GRANT SELECT,INSERT,UPDATE,DELETE ON TABLE public.roulette_prize_awards TO service_role;

CREATE TABLE IF NOT EXISTS public.roulette_prize_events (
  id uuid PRIMARY KEY DEFAULT pg_catalog.gen_random_uuid(),
  award_id uuid NOT NULL REFERENCES public.roulette_prize_awards(id) ON DELETE RESTRICT,
  player_id text NOT NULL REFERENCES public.roulette_players(id) ON DELETE RESTRICT,
  event_type text NOT NULL CHECK (event_type IN ('awarded','legacy_imported','delivered','redeemed','assigned','cancelled')),
  actor text NOT NULL DEFAULT 'sistema',
  note text,
  details jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS roulette_prize_events_award_idx ON public.roulette_prize_events(award_id,created_at);
ALTER TABLE public.roulette_prize_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.roulette_prize_events FROM PUBLIC,anon,authenticated;
GRANT SELECT,INSERT,UPDATE,DELETE ON TABLE public.roulette_prize_events TO service_role;

-- Historical fichas were already credited by the previous code. Import them as delivered without changing balances.
-- Historical bonuses keep pending/redeemed status according to used_bonus_prizes. Raffle prizes wait for assignment.
INSERT INTO public.roulette_prize_awards (
 player_id,username,spin_id,cycle_id,spin_number,prize_key,prize_label,
 prize_type,fichas_amount,bonus_percent,status,created_at,resolved_at,resolved_by,resolution_note,metadata
)
SELECT s.player_id,s.username,s.id,s.cycle_id,s.spin_number,s.prize_key,s.result,
 CASE WHEN s.prize_key IN ('t1000','t3000','t5000','t50000','t100000') THEN 'fichas'
      WHEN s.prize_key IN ('b5','b10','b15','b20') THEN 'bonus' ELSE 'raffle' END,
 CASE s.prize_key WHEN 't1000' THEN 1000 WHEN 't3000' THEN 3000 WHEN 't5000' THEN 5000
      WHEN 't50000' THEN 50000 WHEN 't100000' THEN 100000 ELSE 0 END,
 s.bonus_percent,
 CASE WHEN s.prize_key IN ('t1000','t3000','t5000','t50000','t100000') THEN 'delivered'
      WHEN s.prize_key IN ('b5','b10','b15','b20') AND EXISTS (
        SELECT 1 FROM pg_catalog.jsonb_array_elements(COALESCE(p.used_bonus_prizes,'[]'::jsonb)) u(value)
        WHERE u.value->>'cycleId'=s.cycle_id::text
          AND COALESCE((u.value->>'spinNumber')::integer,0)=s.spin_number
      ) THEN 'redeemed'
      WHEN s.prize_key IN ('b5','b10','b15','b20') THEN 'pending_use'
      ELSE 'pending_assignment' END,
 s.created_at,
 CASE WHEN s.prize_key IN ('t1000','t3000','t5000','t50000','t100000') THEN s.created_at
      ELSE (SELECT NULLIF(u.value->>'usedAt','')::timestamptz
            FROM pg_catalog.jsonb_array_elements(COALESCE(p.used_bonus_prizes,'[]'::jsonb)) u(value)
            WHERE u.value->>'cycleId'=s.cycle_id::text
              AND COALESCE((u.value->>'spinNumber')::integer,0)=s.spin_number LIMIT 1) END,
 CASE WHEN s.prize_key IN ('t1000','t3000','t5000','t50000','t100000') THEN 'migracion_saldo_ya_acreditado'
      WHEN EXISTS (SELECT 1 FROM pg_catalog.jsonb_array_elements(COALESCE(p.used_bonus_prizes,'[]'::jsonb)) u(value)
                   WHERE u.value->>'cycleId'=s.cycle_id::text
                     AND COALESCE((u.value->>'spinNumber')::integer,0)=s.spin_number)
      THEN 'migracion_bono_ya_canjeado' ELSE NULL END,
 CASE WHEN s.prize_key IN ('t1000','t3000','t5000','t50000','t100000')
      THEN 'Premio histórico; las fichas ya estaban acreditadas por el sistema anterior.'
      WHEN s.prize_key IN ('b5','b10','b15','b20') THEN 'Bono histórico importado desde el registro del jugador.'
      ELSE 'Premio histórico pendiente de asignación.' END,
 pg_catalog.jsonb_build_object('importedFrom','roulette_spins','legacy',true)
FROM public.roulette_spins s
JOIN public.roulette_players p ON p.id=s.player_id
WHERE s.prize_key IN ('t1000','t3000','t5000','t50000','t100000','b5','b10','b15','b20','number')
ON CONFLICT(spin_id) DO NOTHING;

INSERT INTO public.roulette_prize_events(award_id,player_id,event_type,actor,note,details,created_at)
SELECT a.id,a.player_id,'legacy_imported','migracion',COALESCE(a.resolution_note,'Premio importado del historial.'),
       pg_catalog.jsonb_build_object('status',a.status,'prizeKey',a.prize_key,'amount',a.fichas_amount),a.created_at
FROM public.roulette_prize_awards a
WHERE a.metadata->>'legacy'='true'
 AND NOT EXISTS(SELECT 1 FROM public.roulette_prize_events e WHERE e.award_id=a.id);

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
  v_award public.roulette_prize_awards%rowtype;
BEGIN
  SELECT * INTO p FROM public.roulette_players WHERE id=p_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'PLAYER_NOT_FOUND'; END IF;

  SELECT e.value INTO v_bonus
  FROM pg_catalog.jsonb_array_elements(COALESCE(p.bonus_prizes,'[]'::jsonb)) AS e(value)
  WHERE e.value->>'cycleId'=p_cycle_id::text
    AND COALESCE((e.value->>'spinNumber')::integer,0)=p_spin_number
  LIMIT 1;
  IF v_bonus IS NULL THEN RAISE EXCEPTION 'BONUS_NOT_FOUND'; END IF;

  SELECT * INTO v_award
  FROM public.roulette_prize_awards
  WHERE player_id=p_id AND cycle_id=p_cycle_id AND spin_number=p_spin_number
    AND prize_type='bonus' AND status='pending_use'
  FOR UPDATE;

  IF NOT FOUND THEN RAISE EXCEPTION 'BONUS_AWARD_NOT_PENDING'; END IF;

  SELECT COALESCE(pg_catalog.jsonb_agg(e.value ORDER BY e.ordinality),'[]'::jsonb)
  INTO v_pending
  FROM pg_catalog.jsonb_array_elements(COALESCE(p.bonus_prizes,'[]'::jsonb))
    WITH ORDINALITY AS e(value,ordinality)
  WHERE NOT (e.value->>'cycleId'=p_cycle_id::text
    AND COALESCE((e.value->>'spinNumber')::integer,0)=p_spin_number);

  v_used:=COALESCE(p.used_bonus_prizes,'[]'::jsonb)
    || pg_catalog.jsonb_build_array(v_bonus||pg_catalog.jsonb_build_object('usedAt',now()::text));

  UPDATE public.roulette_players
  SET bonus_prizes=v_pending,used_bonus_prizes=v_used,updated_at=now()
  WHERE id=p_id;

  UPDATE public.roulette_prize_awards
  SET status='redeemed',resolved_at=now(),resolved_by='administrador',
      resolution_note='Bono marcado como utilizado desde el panel.'
  WHERE id=v_award.id;

  INSERT INTO public.roulette_prize_events(award_id,player_id,event_type,actor,note)
  VALUES(v_award.id,p_id,'redeemed','administrador','Bono marcado como canjeado desde el panel.');

  RETURN pg_catalog.jsonb_build_object(
    'username',p.username,
    'pendingBonuses',pg_catalog.jsonb_array_length(v_pending),
    'usedBonuses',pg_catalog.jsonb_array_length(v_used),
    'awardId',v_award.id
  );
END;
$function$

CREATE OR REPLACE FUNCTION public.roulette_admin_confirm_fichas_delivery(p_award_id uuid, p_actor text DEFAULT 'administrador'::text, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_award public.roulette_prize_awards%rowtype;
  v_player public.roulette_players%rowtype;
  v_new_balance bigint;
BEGIN
  SELECT * INTO v_award
  FROM public.roulette_prize_awards
  WHERE id=p_award_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'AWARD_NOT_FOUND'; END IF;
  IF v_award.prize_type<>'fichas' OR v_award.status<>'pending_delivery' THEN
    RAISE EXCEPTION 'AWARD_NOT_PENDING_DELIVERY';
  END IF;

  SELECT * INTO v_player
  FROM public.roulette_players
  WHERE id=v_award.player_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'PLAYER_NOT_FOUND'; END IF;

  UPDATE public.roulette_players
  SET fichas_balance=fichas_balance+v_award.fichas_amount,updated_at=now()
  WHERE id=v_award.player_id
  RETURNING fichas_balance INTO v_new_balance;

  UPDATE public.roulette_prize_awards
  SET status='delivered',resolved_at=now(),resolved_by=COALESCE(NULLIF(p_actor,''),'administrador'),
      resolution_note=NULLIF(p_note,'')
  WHERE id=p_award_id;

  INSERT INTO public.roulette_prize_events(award_id,player_id,event_type,actor,note,details)
  VALUES(p_award_id,v_award.player_id,'delivered',COALESCE(NULLIF(p_actor,''),'administrador'),
    COALESCE(NULLIF(p_note,''),'Fichas acreditadas manualmente desde el panel.'),
    pg_catalog.jsonb_build_object('amount',v_award.fichas_amount,'newBalance',v_new_balance));

  RETURN pg_catalog.jsonb_build_object(
    'awardId',p_award_id,'username',v_award.username,
    'creditedFichas',v_award.fichas_amount,'fichasBalance',v_new_balance,
    'status','delivered'
  );
END;
$function$

CREATE OR REPLACE FUNCTION public.roulette_admin_assign_raffle_award(p_award_id uuid, p_number text, p_actor text DEFAULT 'administrador'::text, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_award public.roulette_prize_awards%rowtype;
  v_number text:=NULLIF(pg_catalog.btrim(p_number),'');
BEGIN
  IF v_number IS NULL OR pg_catalog.length(v_number)>30 THEN
    RAISE EXCEPTION 'INVALID_RAFFLE_NUMBER';
  END IF;

  SELECT * INTO v_award
  FROM public.roulette_prize_awards
  WHERE id=p_award_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'AWARD_NOT_FOUND'; END IF;
  IF v_award.prize_type<>'raffle' OR v_award.status<>'pending_assignment' THEN
    RAISE EXCEPTION 'AWARD_NOT_PENDING_ASSIGNMENT';
  END IF;

  UPDATE public.roulette_prize_awards
  SET status='assigned',assigned_number=v_number,resolved_at=now(),
      resolved_by=COALESCE(NULLIF(p_actor,''),'administrador'),
      resolution_note=NULLIF(p_note,'')
  WHERE id=p_award_id;

  INSERT INTO public.roulette_prize_events(award_id,player_id,event_type,actor,note,details)
  VALUES(p_award_id,v_award.player_id,'assigned',COALESCE(NULLIF(p_actor,''),'administrador'),
    COALESCE(NULLIF(p_note,''),'Número asignado desde el panel.'),
    pg_catalog.jsonb_build_object('number',v_number));

  RETURN pg_catalog.jsonb_build_object(
    'awardId',p_award_id,'username',v_award.username,'assignedNumber',v_number,'status','assigned'
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
  now_iso text:=now()::text;
  weights integer[];
  random_bytes bytea;
  random_value bigint;
  roll integer;
  total integer:=0;
  i integer;
  prize_key text;
  prize_label text;
  prize_bonus integer:=0;
  prize_fichas integer:=0;
  prize_type text;
  prize_status text;
  prize_spin_id uuid;
  attempts integer;
BEGIN
  SELECT * INTO p FROM public.roulette_players WHERE id=p_player_id FOR UPDATE;
  IF NOT FOUND THEN RETURN pg_catalog.jsonb_build_object('error','PLAYER_NOT_FOUND'); END IF;

  IF p.pin_locked_until IS NOT NULL AND p.pin_locked_until>now() THEN
    RETURN pg_catalog.jsonb_build_object('error','PIN_LOCKED','retryAt',p.pin_locked_until);
  END IF;

  IF p.pin_hash<>p_pin_hash THEN
    attempts:=p.pin_failed_attempts+1;
    IF attempts>=5 THEN
      UPDATE public.roulette_players
      SET pin_failed_attempts=0,pin_locked_until=now()+interval '15 minutes',updated_at=now()
      WHERE id=p_player_id;
      RETURN pg_catalog.jsonb_build_object('error','PIN_LOCKED','retryMinutes',15);
    END IF;
    UPDATE public.roulette_players SET pin_failed_attempts=attempts,updated_at=now() WHERE id=p_player_id;
    RETURN pg_catalog.jsonb_build_object('error','INVALID_CREDENTIALS','attemptsRemaining',5-attempts);
  END IF;

  IF p.pin_failed_attempts<>0 OR p.pin_locked_until IS NOT NULL THEN
    UPDATE public.roulette_players SET pin_failed_attempts=0,pin_locked_until=NULL WHERE id=p_player_id;
  END IF;

  c:=p.active_cycle;
  IF c IS NULL OR COALESCE(c->>'status','')<>'active' THEN
    RETURN pg_catalog.jsonb_build_object('error','NO_ACTIVE_CYCLE');
  END IF;

  spins:=COALESCE(c->'spins','[]'::jsonb);
  n:=pg_catalog.jsonb_array_length(spins);
  third_ok:=n=2 AND spins->0->>'result'='SIN PREMIO' AND spins->1->>'result'='SIN PREMIO';
  IF n>=3 OR (n>=2 AND NOT third_ok) THEN
    RETURN pg_catalog.jsonb_build_object('error','CYCLE_FINISHED');
  END IF;

  spin_no:=n+1;
  cid:=(c->>'id')::uuid;
  opportunity_id:=NULLIF(c->>'opportunityId','')::uuid;

  IF spin_no=3 THEN
    weights:=ARRAY[4994,1200,800,300,200,1700,600,150,50,5,1];
  ELSE
    weights:=ARRAY[5994,2000,1000,200,100,500,150,40,10,5,1];
  END IF;

  LOOP
    random_bytes:=extensions.gen_random_bytes(4);
    random_value:=get_byte(random_bytes,0)::bigint*16777216
      +get_byte(random_bytes,1)::bigint*65536
      +get_byte(random_bytes,2)::bigint*256
      +get_byte(random_bytes,3)::bigint;
    EXIT WHEN random_value<4294960000;
  END LOOP;
  roll:=mod(random_value,10000)::integer;

  FOR i IN 1..array_length(weights,1) LOOP
    total:=total+weights[i];
    IF roll<total THEN
      CASE i
        WHEN 1 THEN prize_key:='none';prize_label:='SIN PREMIO';
        WHEN 2 THEN prize_key:='b5';prize_label:='BONUS 5%';prize_bonus:=5;
        WHEN 3 THEN prize_key:='b10';prize_label:='BONUS 10%';prize_bonus:=10;
        WHEN 4 THEN prize_key:='b15';prize_label:='BONUS 15%';prize_bonus:=15;
        WHEN 5 THEN prize_key:='b20';prize_label:='BONUS 20%';prize_bonus:=20;
        WHEN 6 THEN prize_key:='t1000';prize_label:='1.000 FICHAS';prize_fichas:=1000;
        WHEN 7 THEN prize_key:='t3000';prize_label:='3.000 FICHAS';prize_fichas:=3000;
        WHEN 8 THEN prize_key:='t5000';prize_label:='5.000 FICHAS';prize_fichas:=5000;
        WHEN 9 THEN prize_key:='number';prize_label:='NÚMERO A ELECCIÓN PARA EL SORTEO DEL CUATRICICLO';
        WHEN 10 THEN prize_key:='t50000';prize_label:='50.000 FICHAS';prize_fichas:=50000;
        WHEN 11 THEN prize_key:='t100000';prize_label:='100.000 FICHAS';prize_fichas:=100000;
      END CASE;
      EXIT;
    END IF;
  END LOOP;

  IF prize_fichas>0 THEN
    prize_type:='fichas';prize_status:='pending_delivery';
  ELSIF prize_bonus>0 THEN
    prize_type:='bonus';prize_status:='pending_use';
  ELSIF prize_key='number' THEN
    prize_type:='raffle';prize_status:='pending_assignment';
  END IF;

  spins:=spins||pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
    'spinNumber',spin_no,'key',prize_key,'result',prize_label,
    'bonus',prize_bonus,'createdAt',now_iso
  ));

  third_after:=spin_no=2 AND spins->0->>'result'='SIN PREMIO' AND prize_label='SIN PREMIO';
  remaining:=CASE WHEN spin_no=1 THEN 1 WHEN third_after THEN 1 ELSE 0 END;
  completed:=remaining=0;
  queued:=p.queued_cycles;
  next_cycle:=c||pg_catalog.jsonb_build_object('spins',spins);

  IF completed THEN
    IF opportunity_id IS NOT NULL THEN
      UPDATE public.roulette_opportunities SET status='completed',completed_at=now()
      WHERE id=opportunity_id AND player_id=p_player_id AND status='active';
    END IF;

    IF queued>0 THEN
      SELECT o.* INTO next_opportunity FROM public.roulette_opportunities o
      WHERE o.player_id=p_player_id AND o.status='queued'
      ORDER BY o.created_at,o.id LIMIT 1 FOR UPDATE;
      IF FOUND THEN
        next_cycle_id:=pg_catalog.gen_random_uuid();
        UPDATE public.roulette_opportunities SET status='active',cycle_id=next_cycle_id,activated_at=now()
        WHERE id=next_opportunity.id;
        next_cycle:=pg_catalog.jsonb_build_object(
          'id',next_cycle_id,'source',next_opportunity.source,'opportunityId',next_opportunity.id,
          'spins','[]'::jsonb,'status','active','createdAt',now_iso
        );
      ELSE
        next_opportunity.id:=pg_catalog.gen_random_uuid();
        next_cycle_id:=pg_catalog.gen_random_uuid();
        INSERT INTO public.roulette_opportunities(id,player_id,source,status,cycle_id,activated_at)
        VALUES(next_opportunity.id,p_player_id,'legacy','active',next_cycle_id,now());
        next_cycle:=pg_catalog.jsonb_build_object(
          'id',next_cycle_id,'source','legacy','opportunityId',next_opportunity.id,
          'spins','[]'::jsonb,'status','active','createdAt',now_iso
        );
      END IF;
      queued:=queued-1;
    ELSE
      next_cycle:=NULL;
    END IF;
  END IF;

  UPDATE public.roulette_players
  SET active_cycle=next_cycle,
      queued_cycles=queued,
      -- Fichas are deliberately NOT credited here. The admin confirms manual delivery.
      bonus_prizes=CASE WHEN prize_bonus>0
        THEN bonus_prizes||pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
          'percent',prize_bonus,'cycleId',cid,'spinNumber',spin_no,'createdAt',now_iso
        ))
        ELSE bonus_prizes END,
      quad_bike_numbers=quad_bike_numbers+CASE WHEN prize_key='number' THEN 1 ELSE 0 END,
      last_spin_at=now(),
      updated_at=now()
  WHERE id=p_player_id;

  INSERT INTO public.roulette_spins(player_id,username,cycle_id,spin_number,prize_key,result,bonus_percent)
  VALUES(p_player_id,p.username,cid,spin_no,prize_key,prize_label,prize_bonus)
  RETURNING id INTO prize_spin_id;

  IF prize_key<>'none' THEN
    INSERT INTO public.roulette_prize_awards(
      player_id,username,spin_id,cycle_id,spin_number,prize_key,prize_label,
      prize_type,fichas_amount,bonus_percent,status
    )
    VALUES(
      p_player_id,p.username,prize_spin_id,cid,spin_no,prize_key,prize_label,
      prize_type,prize_fichas,prize_bonus,prize_status
    );

    INSERT INTO public.roulette_prize_events(award_id,player_id,event_type,actor,note,details)
    VALUES(
      (SELECT id FROM public.roulette_prize_awards WHERE spin_id=prize_spin_id),
      p_player_id,'awarded','sistema','Premio obtenido en la ruleta.',
      pg_catalog.jsonb_build_object('prizeKey',prize_key,'fichasAmount',prize_fichas,'bonusPercent',prize_bonus)
    );
  END IF;

  RETURN pg_catalog.jsonb_build_object(
    'username',p.username,'cycleId',cid,'spinNumber',spin_no,
    'result',pg_catalog.jsonb_build_object('key',prize_key,'label',prize_label,'bonus',prize_bonus),
    'spinsLeft',remaining,'thirdAvailable',third_after,'cycleCompleted',completed,
    'queuedCycles',queued,'fichasBalance',p.fichas_balance,
    'prizePendingDelivery',prize_status='pending_delivery',
    'pendingFichas',CASE WHEN prize_fichas>0 THEN prize_fichas ELSE 0 END
  );
END;
$function$


REVOKE ALL ON FUNCTION public.roulette_admin_mark_bonus_used(text,uuid,integer) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.roulette_admin_confirm_fichas_delivery(uuid,text,text) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.roulette_admin_assign_raffle_award(uuid,text,text,text) FROM PUBLIC,anon,authenticated;
REVOKE ALL ON FUNCTION public.roulette_apply_spin(text,text) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.roulette_admin_mark_bonus_used(text,uuid,integer) TO service_role;
GRANT EXECUTE ON FUNCTION public.roulette_admin_confirm_fichas_delivery(uuid,text,text) TO service_role;
GRANT EXECUTE ON FUNCTION public.roulette_admin_assign_raffle_award(uuid,text,text,text) TO service_role;
GRANT EXECUTE ON FUNCTION public.roulette_apply_spin(text,text) TO service_role;
