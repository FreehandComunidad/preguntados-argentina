-- Transactional admin operations for the private roulette backend.
create or replace function public.roulette_admin_create_player(p_id text,p_username text,p_pin_hash text)
returns void language plpgsql security definer set search_path=public,pg_temp as $$
begin
  insert into public.roulette_players(id,username,pin_hash)
  values(p_id,p_username,p_pin_hash);
end; $$;

create or replace function public.roulette_admin_grant_cycles(p_id text,p_count integer,p_source text)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare p public.roulette_players%rowtype; active jsonb; queued integer; add_queue integer;
begin
  select * into p from public.roulette_players where id=p_id for update;
  if not found then raise exception 'PLAYER_NOT_FOUND'; end if;
  active:=p.active_cycle; queued:=p.queued_cycles; add_queue:=greatest(1,least(100,p_count));
  if active is null then
    active:=jsonb_build_object('id',gen_random_uuid(),'source',p_source,'spins','[]'::jsonb,'status','active','createdAt',now()::text);
    add_queue:=add_queue-1;
  end if;
  queued:=queued+add_queue;
  update public.roulette_players set active_cycle=active,queued_cycles=queued,updated_at=now() where id=p_id;
  return jsonb_build_object('username',p.username,'active',true,'queuedCycles',queued,'granted',greatest(1,least(100,p_count)));
end; $$;

revoke all on function public.roulette_admin_create_player(text,text,text) from public,anon,authenticated;
revoke all on function public.roulette_admin_grant_cycles(text,integer,text) from public,anon,authenticated;
grant execute on function public.roulette_admin_create_player(text,text,text) to service_role;
grant execute on function public.roulette_admin_grant_cycles(text,integer,text) to service_role;
