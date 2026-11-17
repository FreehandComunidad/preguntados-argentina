-- FREEHAND Roulette — Supabase schema and transactional operations
create extension if not exists pgcrypto;
create table if not exists public.roulette_players (
 id text primary key, username text not null, pin_hash text not null,
 active_cycle jsonb, queued_cycles integer not null default 0 check(queued_cycles>=0),
 fichas_balance bigint not null default 0, bonus_prizes jsonb not null default '[]'::jsonb,
 quad_bike_numbers integer not null default 0, created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(), last_spin_at timestamptz
);
create table if not exists public.roulette_spins (
 id uuid primary key default gen_random_uuid(),
 player_id text not null references public.roulette_players(id), username text not null,
 cycle_id uuid not null, spin_number integer not null check(spin_number between 1 and 3),
 prize_key text not null, result text not null, bonus_percent integer not null default 0,
 created_at timestamptz not null default now()
);
create index if not exists roulette_spins_player_created_idx on public.roulette_spins(player_id,created_at desc);
create index if not exists roulette_players_created_idx on public.roulette_players(created_at desc);
alter table public.roulette_players enable row level security;
alter table public.roulette_spins enable row level security;
revoke all on public.roulette_players from anon,authenticated;
revoke all on public.roulette_spins from anon,authenticated;
grant all on public.roulette_players to service_role;
grant all on public.roulette_spins to service_role;

create or replace function public.roulette_apply_spin(p_player_id text,p_pin_hash text,p_prize_key text,p_result text,p_bonus integer,p_fichas integer)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare p public.roulette_players%rowtype; c jsonb; spins jsonb; n integer; third_ok boolean; spin_no integer; cid uuid; remaining integer; completed boolean; queued integer; next_cycle jsonb; now_iso text:=now()::text;
begin
 select * into p from public.roulette_players where id=p_player_id for update;
 if not found then raise exception 'PLAYER_NOT_FOUND'; end if;
 if p.pin_hash<>p_pin_hash then raise exception 'INVALID_CREDENTIALS'; end if;
 c:=p.active_cycle;
 if c is null or coalesce(c->>'status','')<>'active' then raise exception 'NO_ACTIVE_CYCLE'; end if;
 spins:=coalesce(c->'spins','[]'::jsonb); n:=jsonb_array_length(spins);
 third_ok:=n=2 and spins->0->>'result'='SIN PREMIO' and spins->1->>'result'='SIN PREMIO';
 if n>=3 or (n>=2 and not third_ok) then raise exception 'CYCLE_FINISHED'; end if;
 spin_no:=n+1; cid:=(c->>'id')::uuid;
 spins:=spins||jsonb_build_array(jsonb_build_object('spinNumber',spin_no,'key',p_prize_key,'result',p_result,'bonus',p_bonus,'createdAt',now_iso));
 remaining:=case when spin_no=1 then 1 when spin_no=2 and third_ok then 1 else 0 end; completed:=remaining=0; queued:=p.queued_cycles;
 next_cycle:=c||jsonb_build_object('spins',spins);
 if completed then
  if queued>0 then queued:=queued-1; next_cycle:=jsonb_build_object('id',gen_random_uuid(),'source','queued','spins','[]'::jsonb,'status','active','createdAt',now_iso);
  else next_cycle:=null; end if;
 end if;
 update public.roulette_players set active_cycle=next_cycle,queued_cycles=queued,fichas_balance=fichas_balance+p_fichas,
 bonus_prizes=case when p_bonus>0 then bonus_prizes||jsonb_build_array(jsonb_build_object('percent',p_bonus,'cycleId',cid,'spinNumber',spin_no,'createdAt',now_iso)) else bonus_prizes end,
 quad_bike_numbers=quad_bike_numbers+case when p_prize_key='number' then 1 else 0 end,last_spin_at=now(),updated_at=now() where id=p_player_id;
 insert into public.roulette_spins(player_id,username,cycle_id,spin_number,prize_key,result,bonus_percent) values(p_player_id,p.username,cid,spin_no,p_prize_key,p_result,p_bonus);
 return jsonb_build_object('username',p.username,'cycleId',cid,'spinNumber',spin_no,
 'result',jsonb_build_object('key',p_prize_key,'label',p_result,'bonus',p_bonus),
 'spinsLeft',remaining,'thirdAvailable',remaining=1 and spin_no=2,'cycleCompleted',completed,
 'queuedCycles',queued,'fichasBalance',p.fichas_balance+p_fichas);
end; $$;

create or replace function public.roulette_admin_create_player(p_id text,p_username text,p_pin_hash text)
returns void language plpgsql security definer set search_path=public,pg_temp as $$
begin insert into public.roulette_players(id,username,pin_hash) values(p_id,p_username,p_pin_hash); end; $$;
create or replace function public.roulette_admin_grant_cycles(p_id text,p_count integer,p_source text)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare p public.roulette_players%rowtype; active jsonb; queued integer; add_queue integer;
begin
 select * into p from public.roulette_players where id=p_id for update;
 if not found then raise exception 'PLAYER_NOT_FOUND'; end if;
 active:=p.active_cycle; queued:=p.queued_cycles; add_queue:=greatest(1,least(100,p_count));
 if active is null then active:=jsonb_build_object('id',gen_random_uuid(),'source',p_source,'spins','[]'::jsonb,'status','active','createdAt',now()::text); add_queue:=add_queue-1; end if;
 queued:=queued+add_queue;
 update public.roulette_players set active_cycle=active,queued_cycles=queued,updated_at=now() where id=p_id;
 return jsonb_build_object('username',p.username,'active',true,'queuedCycles',queued,'granted',greatest(1,least(100,p_count)));
end; $$;
revoke all on function public.roulette_apply_spin(text,text,text,text,integer,integer) from public,anon,authenticated;
revoke all on function public.roulette_admin_create_player(text,text,text) from public,anon,authenticated;
revoke all on function public.roulette_admin_grant_cycles(text,integer,text) from public,anon,authenticated;
grant execute on function public.roulette_apply_spin(text,text,text,text,integer,integer) to service_role;
grant execute on function public.roulette_admin_create_player(text,text,text) to service_role;
grant execute on function public.roulette_admin_grant_cycles(text,integer,text) to service_role;
comment on table public.roulette_players is 'Private roulette accounts; access only through Edge Function service role.';
comment on table public.roulette_spins is 'Private roulette audit log; access only through Edge Function service role.';
