# Migración de ruleta a Supabase (rama migracion-supabase)

Esta rama separa la ruleta de Firebase sin modificar la conexión Firebase de Preguntados ni del ranking.

## Archivos
- `supabase/migrations/202611170001_roulette_schema.sql`: tablas privadas, RLS y operaciones transaccionales.
- `supabase/functions/roulette/index.ts`: API de jugador y administración.
- `supabase/config.toml`: configuración de la Edge Function.
- `index.html`: conserva Firebase para Preguntados/ranking y envía la ruleta a Supabase.
- `roulette-admin.html`: panel de administración sobre la misma API.

## Configuración manual pendiente en Supabase
1. Abrir SQL Editor del proyecto y ejecutar el contenido completo de `supabase/migrations/202611170001_roulette_schema.sql`.
2. En Edge Functions, desplegar la función llamada `roulette` desde `supabase/functions/roulette/index.ts`.
3. Configurar secretos de la función:
   - `SUPABASE_URL`: URL del proyecto.
   - `SUPABASE_SERVICE_ROLE_KEY`: clave secreta del proyecto (solo del lado servidor).
   - `ROULETTE_ADMIN_KEY`: una clave administrativa larga y privada.
4. Copiar la Publishable key del proyecto y reemplazar el texto `REEMPLAZAR_CON_SUPABASE_PUBLISHABLE_KEY` en los dos HTML.
5. Probar con un jugador de prueba antes de integrar a producción.

## Seguridad
- Nunca poner `service_role`, claves secretas, contraseña de base de datos o `ROULETTE_ADMIN_KEY` en HTML, GitHub, WhatsApp o mensajes.
- La Publishable key sí está diseñada para estar en el navegador; las tablas tienen RLS activado y no conceden acceso a anon/authenticated.
- La función valida el PIN del jugador y la clave administrativa. La clave administrativa se envía por HTTPS en el encabezado `x-admin-key`.
- La función está configurada con `verify_jwt = false` porque los jugadores no inician sesión en Supabase Auth; la validación propia de usuario+PIN se hace dentro de la función.
- La versión publicada y la rama `main` no se modifican en esta etapa.

## Nota de despliegue
La integración GitHub de Supabase no despliega por sí sola Edge Functions en el plan gratuito en todas las configuraciones. El despliegue puede hacerse con Supabase CLI o desde el flujo de despliegue de Edge Functions. No activar producción hasta verificar las pruebas.
