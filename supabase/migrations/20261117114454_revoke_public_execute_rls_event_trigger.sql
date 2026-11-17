-- The project already has an event trigger that enforces RLS on new public tables.
-- It is invoked by PostgreSQL's DDL event system, not by application clients.
-- Revoke the unnecessary direct EXECUTE grant that triggered the security advisor warning.
revoke all on function public.rls_auto_enable() from public, anon, authenticated;
