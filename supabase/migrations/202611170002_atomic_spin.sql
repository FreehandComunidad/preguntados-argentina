-- Roulette spin must be selected and committed while the player row is locked.
drop function if exists public.roulette_apply_spin(text,text,text,text,integer,integer);
drop function if exists public.roulette_apply_spin(text,text);
create function public.roulette_apply_spin(p_player_id text,p_pin_hash text)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare
 p public.roulette_players%rowtype; c jsonb; spins jsonb; n integer; third_ok boolean; third_after boolean;
 spin_no integer; cid uuid; remaining integer; completed boolean; queued integer; next_cycle jsonb;
 now_iso text:=now()::text; weights integer[]; random_bytes bytea; random_value bigint;
 roll integer; total integer:=0; i integer; prize_key text; prize_label text; prize_bonus integer:=0; prize_fichas integer:=0;
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
 if spin_no=3 then weights:=array[5000,1200,800,300,200,1700,600,150,50];
 else weights:=array[6000,2000,1000,200,100,500,150,40,10]; end if;
 loop
  random_bytes:=gen_random_bytes(4);
  random_value:=get_byte(random_bytes,0)::bigint*16777216+get_byte(random_bytes,1)::bigint*65536+get_byte(random_bytes,2)::bigint*256+get_byte(random_bytes,3)::bigint;
  exit when random_value<4294960000;
 end loop;
 roll:=mod(random_value,10000)::integer;
 for i in 1..array_length(weights,1) loop
  total:=total+weights[i];
  if roll<total then
   case i
    when 1 then prize_key:='none'; prize_label:='SIN PREMIO';
    when 2 then prize_key:='b5'; prize_label:='BONUS 5%'; prize_bonus:=5;
    when 3 then prize_key:='b10'; prize_label:='BONUS 10%'; prize_bonus:=10;
    when 4 then prize_key:='b15'; prize_label:='BONUS 15%'; prize_bonus:=15;
    when 5 then prize_key:='b20'; prize_label:='BONUS 20%'; prize_bonus:=20;
    when 6 then prize_key:='t1000'; prize_label:='1.000 FICHAS'; prize_fichas:=1000;
    when 7 then prize_key:='t3000'; prize_label:='3.000 FICHAS'; prize_fichas:=3000;
    when 8 then prize_key:='t5000'; prize_label:='5.000 FICHAS'; prize_fichas:=5000;
    when 9 then prize_key:='number'; prize_label:='NÚMERO A ELECCIÓN PARA EL SORTEO DEL CUATRICICLO';
   end case;
   exit;
  end if;
  roll:=roll-weights[i];
 end loop;
 spins:=spins||jsonb_build_array(jsonb_build_object('spinNumber',spin_no,'key',prize_key,'result',prize_label,'bonus',prize_bonus,'createdAt',now_iso));
 third_after:=spin_no=2 and spins->0->>'result'='SIN PREMIO' and prize_label='SIN PREMIO';
 remaining:=case when spin_no=1 then 1 when third_after then 1 else 0 end; completed:=remaining=0; queued:=p.queued_cycles;
 next_cycle:=c||jsonb_build_object('spins',spins);
 if completed then
  if queued>0 then queued:=queued-1; next_cycle:=jsonb_build_object('id',gen_random_uuid(),'source','queued','spins','[]'::jsonb,'status','active','createdAt',now_iso);
  else next_cycle:=null; end if;
 end if;
 update public.roulette_players set active_cycle=next_cycle,queued_cycles=queued,fichas_balance=fichas_balance+prize_fichas,
 bonus_prizes=case when prize_bonus>0 then bonus_prizes||jsonb_build_array(jsonb_build_object('percent',prize_bonus,'cycleId',cid,'spinNumber',spin_no,'createdAt',now_iso)) else bonus_prizes end,
 quad_bike_numbers=quad_bike_numbers+case when prize_key='number' then 1 else 0 end,last_spin_at=now(),updated_at=now() where id=p_player_id;
 insert into public.roulette_spins(player_id,username,cycle_id,spin_number,prize_key,result,bonus_percent) values(p_player_id,p.username,cid,spin_no,prize_key,prize_label,prize_bonus);
 return jsonb_build_object('username',p.username,'cycleId',cid,'spinNumber',spin_no,'result',jsonb_build_object('key',prize_key,'label',prize_label,'bonus',prize_bonus),'spinsLeft',remaining,'thirdAvailable',third_after,'cycleCompleted',completed,'queuedCycles',queued,'fichasBalance',p.fichas_balance+prize_fichas);
end; $$;
revoke all on function public.roulette_apply_spin(text,text) from public,anon,authenticated;
grant execute on function public.roulette_apply_spin(text,text) to service_role;
