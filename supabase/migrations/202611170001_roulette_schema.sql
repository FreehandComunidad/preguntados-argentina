-- FREEHAND Roulette — Supabase schema
-- Run in Supabase SQL Editor. All player/admin data is private; browser access is denied.
create extension if not exists pgcrypto;

create table if not exists public.roulette_players (
  id text primary key,
  username text not null,
  pin_hash text not null,
  active_cycle jsonb,
  queued_cycles integer not null default 0 check (queued_cycles >= 0),
  fichas_balance bigint not null default 0,
  bonus_prizes jsonb not null default '[]'::jsonb,
  quad_bike_numbers integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  last_spin_at timestamptz
);

create table if not exists public.roulette_spins (
  id uuid primary key default gen_random_uuid(),
  player_id text not null references public.roulette_players(id),
  username text not null,
  cycle_id uuid not null,
  spin_number integer not null check (spin_number between 1 and 3),
  prize_key text not null,
  result text not null,
  bonus_percent integer not null default 0,
  created_at timestamptz not null default now()
);
create index if not exists roulette_spins_player_created_idx on public.roulette_spins(player_id, created_at desc);
create index if not exists roulette_players_created_idx on public.roulette_players(created_at desc);

alter table public.roulette_players enable row level security;
alter table public.roulette_spins enable row level security;
revoke all on public.roulette_players from anon, authenticated;
revoke all on public.roulette_spins from anon, authenticated;
grant all on public.roulette_players to service_role;
grant all on public.roulette_spins to service_role;

-- One atomic server-side spin. The Edge Function supplies a cryptographically
-- selected prize; this transaction validates cycle state and records it exactly once.
create or replace function public.roulette_apply_spin(
  p_player_id text,
  p_pin_hash text,
  p_prize_key text,
  p_result text,
  p_bonus integer,
  p_fichas integer
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  p public.roulette_players%rowtype;
  c jsonb;
  spins jsonb;
  spin_count integer;
  third_ok boolean;
  spin_no integer;
  cycle_id uuid;
  remaining integer;
  completed boolean;
  queued integer;
  next_cycle jsonb;
  now_iso text := now()::text;
begin
  select * into p from public.roulette_players where id=p_player_id for update;
  if not found then raise exception 'PLAYER_NOT_FOUND'; end if;
  if p.pin_hash <> p_pin_hash then raise exception 'INVALID_CREDENTIALS'; end if;
  c := p.active_cycle;
  if c is null or coalesce(c->>'status','') <> 'active' then raise exception 'NO_ACTIVE_CYCLE'; end if;
  spins := coalesce(c->'spins','[]'::jsonb);
  spin_count := jsonb_array_length(spins);
  third_ok := spin_count=2 and
    spins->0->>'result'='SIN PREMIO' and spins->1->>'result'='SIN PREMIO';
  if spin_count>=3 or (spin_count>=2 and not third_ok) then raise exception 'CYCLE_FINISHED'; end if;
  spin_no := spin_count+1;
  cycle_id := (c->>'id')::uuid;
  remaining := case when spin_no=1 then 1 when spin_no=2 and third_ok then 1 else 0 end;
  completed := remaining=0;
  spins := spins || jsonb_build_array(jsonb_build_object(
    'spinNumber',spin_no,'key',p_prize_key,'result',p_result,'bonus',p_bonus,'createdAt',now_iso
  ));
  queued := p.queued_cycles;
  next_cycle := c || jsonb_build_object('spins',spins);
  if completed then
    if queued>0 then
      queued := queued-1;
      next_cycle := jsonb_build_object('id',gen_random_uuid(),'source','queued','spins','[]'::jsonb,'status','active','createdAt',now_iso);
    else
      next_cycle := null;
    end if;
  end if;
  update public.roulette_players set
    active_cycle=next_cycle,
    queued_cycles=queued,
    fichas_balance=fichas_balance+p_fichas,
    bonus_prizes=case when p_bonus>0 then bonus_prizes || jsonb_build_array(jsonb_build_object('percent',p_bonus,'cycleId',cycle_id,'spinNumber',spin_no,'createdAt',now_iso)) else bonus_prizes end,
    quad_bike_numbers=quad_bike_numbers + case when p_prize_key='number' then 1 else 0 end,
    last_spin_at=now(), updated_at=now()
  where id=p_player_id;
  insert into public.roulette_spins(player_id,username,cycle_id,spin_number,prize_key,result,bonus_percent)
  values(p_player_id,p.username,cycle_id,spin_no,p_prize_key,p_result,p_bonus);
  return jsonb_build_object(
    'username',p.username,'cycleId',cycle_id,'spinNumber',spin_no,
    'result',jsonb_build_object('key',p_prize_key,'label',p_result,'bonus',p_bonus),
    'spinsLeft',remaining,'thirdAvailable',spin_no=2 and p_prize_key='none' and spins->0->>'result'='SIN PREMIO',
    'cycleCompleted',completed,'queuedCycles',queued,'fichasBalance',p.fichas_balance+p_fichas
  );
end; $$;
revoke all on function public.roulette_apply_spin(text,text,text,text,integer,integer) from public, anon, authenticated;
grant execute on function public.roulette_apply_spin(text,text,text,text,integer,integer) to service_role;

-- Prevent PostgREST from exposing the internal tables/functions to browser roles.
comment on table public.roulette_players is 'Private roulette accounts; access only through Edge Function service role.';
comment on table public.roulette_spins is 'Private audit log; access only through Edge Function service role.';
