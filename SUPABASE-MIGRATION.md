# Migración de la ruleta FREEHAND a Supabase

## Estado actual

- Rama de trabajo: `migracion-supabase`. La rama `main` no se modificó.
- Proyecto Supabase: `freehand-roulette` (`yiznobpjxksymqqazryr`), región São Paulo.
- Siete migraciones aplicadas, incluyendo esquema privado, giro atómico, aleatoriedad criptográfica, PIN, seguridad de funciones y corrección de probabilidades.
- Tablas `roulette_players` y `roulette_spins` creadas con RLS activado.
- Edge Function `roulette`: activa (versión 7).
- `index.html`: Preguntados y ranking siguen usando Firebase; la ruleta usa Supabase.
- `roulette-admin.html`: preparado para Supabase.
- No se publicó nada en `main` ni se desconectó Firebase.

## Secretos

El administrador informó que configuró `ROULETTE_ADMIN_KEY` en Supabase. Debe permanecer privada y no incluirse en HTML ni en GitHub. La Publishable key sí está en los dos archivos de navegador y se envía únicamente en la cabecera `apikey`.

La Edge Function valida la Publishable key con `withSupabase` y obtiene el cliente privilegiado del servidor mediante el SDK oficial. No se debe poner una Secret key ni una `service_role` key en archivos públicos.

## Pruebas realizadas

- Se realizaron 50.000 simulaciones válidas después de corregir la selección de premios: 10.000 giros normales y 40.000 giros especiales. Ver [ROULETTE-TEST-REPORT-2026-11-17.md](ROULETTE-TEST-REPORT-2026-11-17.md).
- La primera simulación detectó que se restaba el peso anterior además de compararlo con el acumulado. Esa corrida se descartó y se borraron sus registros. La corrección está versionada en `supabase/migrations/20261117120746_fix_roulette_weight_selection.sql`.
- Se recorrieron exhaustivamente los 10.000 valores posibles del selector. Cada premio recibió exactamente su cantidad configurada de valores, tanto para el giro normal como para el especial.
- Se probaron 100 ciclos completos: el tercer giro sólo se desbloquea cuando los dos primeros son `SIN PREMIO`.
- Se probó la cola: al terminar un ciclo, se activa el siguiente y baja el contador de pendientes.
- Se comprobó el bloqueo tras cinco PIN incorrectos durante 15 minutos y el reinicio del contador al validar un PIN correcto.
- Se comprobaron los permisos: `anon` y `authenticated` no pueden leer ni escribir directamente las tablas privadas ni ejecutar la función de giro; el backend privilegiado sí puede.
- Se eliminaron todos los jugadores y giros de simulación. Las tablas quedaron sin registros de prueba.
- El asesor de seguridad sólo informa que las tablas privadas tienen RLS activado y no tienen políticas para navegadores; es intencional. El asesor de salud no informó problemas.

## Pendiente

La simulación ejercitó directamente la función transaccional de PostgreSQL. Todavía falta una prueba HTTP real desde un navegador para comprobar inicio administrativo, creación de jugador, PIN, aprobación de carga y regalo de ciclo. En los registros todavía no aparecen invocaciones HTTP a la función de ruleta.

Antes de activar la versión nueva para jugadores, hacer esa prueba desde una vista previa de la rama `migracion-supabase`. No hacer merge a `main` hasta terminar la prueba.

## Seguridad y arquitectura

- Las tablas privadas no tienen políticas RLS para usuarios públicos. Los navegadores no acceden directamente a los datos; todo pasa por la Edge Function.
- El cálculo de premios y el avance de ciclo ocurren dentro de una transacción PostgreSQL con bloqueo de fila y aleatoriedad criptográfica. Esto evita que dos solicitudes simultáneas consuman el mismo ciclo o usen la probabilidad equivocada.
- Tras cinco PIN incorrectos, el acceso del jugador se bloquea durante 15 minutos; un PIN correcto reinicia el contador.
- El panel administra manualmente las cargas aprobadas por WhatsApp y los ciclos regalados. No integra pagos de forma automática.
- Mantener Firebase activo para Preguntados y el ranking. No borrar las Firebase Functions antiguas hasta finalizar las pruebas y confirmar la migración.
