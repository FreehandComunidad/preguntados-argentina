-- Pin SECURITY DEFINER functions to an empty search_path.
-- All non-catalog objects in these functions are explicitly schema-qualified.
alter function public.roulette_apply_spin(text,text) set search_path = '';
alter function public.roulette_admin_create_player(text,text,text) set search_path = '';
alter function public.roulette_admin_grant_cycles(text,integer,text) set search_path = '';
