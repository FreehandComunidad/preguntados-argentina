# Migración de la ruleta FREEHAND a Supabase

## Estado actual
- Rama de trabajo: `migracion-supabase`. La rama `main` no se modificó.
- Proyecto Supabase: `freehand-roulette` (`yiznobpjxksymqqazryr`), región São Paulo.
- Migraciones aplicadas: siete en total, incluyendo esquema privado, giro atómico, aleatoriedad criptográfica, endurecimiento de funciones, bloqueo de PIN, permisos del trigger automático de RLS y corrección de selección acumulada de premios.
- Tablas creadas: `roulette_players` y `roulette_spins`, ambas con RLS activado.
- Edge Function `roulette`: desplegada y activa (versión 6).
- `index.html`: Preguntados y ranking permanecen en Firebase; las acciones de ruleta usan Supabase.
- `roulette-admin.html`: panel de administración preparado para Supabase.
- No se ha publicado nada a `main` ni se ha apagado Firebase.

## Pendiente antes de probar el panel
Configurar el secreto de administración desde el Dashboard de Supabase:

1. Abrir [Edge Function Secrets](https://supabase.com/dashboard/project/yiznobpjxksymqqazryr/functions/secrets).
2. Crear un secreto con nombre exacto `ROULETTE_ADMIN_KEY`.
3. Como valor, usar una clave aleatoria larga (al menos 32 caracteres), distinta de la contraseña de la base de datos y de las API keys.
4. Guardarla en un gestor de contraseñas. No incluirla en HTML, GitHub, WhatsApp ni enviarla por este chat.
5. Para ingresar a `roulette-admin.html`, introducir esa misma clave en el formulario de acceso.

La Edge Function valida la Publishable key con `withSupabase` y obtiene el cliente privilegiado del servidor mediante el SDK oficial. La Publishable key está configurada sólo en los dos archivos de navegador. No se debe poner una Secret key ni una service_role key en archivos públicos.

## Pruebas realizadas
- Se ejecutaron 50.000 simulaciones después de corregir la selección de premios: 10.000 giros normales y 40.000 giros especiales. El detalle queda registrado en [ROULETTE-TEST-REPORT-2026-11-17.md](ROULETTE-TEST-REPORT-2026-11-17.md).\n- Se detectó y corrigió una resta indebida en el algoritmo de pesos acumulados; la primera corrida afectada fue descartada y sus registros se eliminaron. La corrección está versionada en `supabase/migrations/20261117120746_fix_roulette_weight_selection.sql`.\n- Se ejecutaron pruebas SQL dentro de bloques transaccionales y se eliminaron los jugadores/giro de prueba al terminar.
- Se comprobó la secuencia de dos giros, el desbloqueo y consumo del tercer giro especial. También se recorrieron los 10.000 valores posibles del selector y cada premio recibió exactamente el número de valores indicado por sus pesos.
- Se comprobó que al terminar un ciclo se habilita el siguiente ciclo pendiente y disminuye la cola.
- Se comprobó el bloqueo tras cinco PIN incorrectos y el desbloqueo tras 15 minutos; el panel permite restablecer PIN y quitar el bloqueo.\n- Se comprobó que no quedaron registros de prueba.
- Se comprobó que los roles `anon` y `authenticated` no tienen permisos directos sobre las dos tablas ni sobre la función de giro; `service_role` sí.
- La Edge Function está activa y `ROULETTE_ADMIN_KEY` fue configurada por el administrador. La prueba funcional por HTTP desde un navegador todavía está pendiente; esta sesión validó la función transaccional directamente en PostgreSQL.

## Seguridad y arquitectura
- La Publishable key se envía sólo en la cabecera `apikey`; no se usa como bearer token.
- Las tablas privadas no tienen políticas RLS para usuarios públicos. Esto es intencional: los navegadores no acceden directamente a los datos; todo pasa por la Edge Function.
- El cálculo de premios y el avance de ciclo ocurren dentro de una transacción PostgreSQL con bloqueo de fila y aleatoriedad criptográfica. Esto evita que dos solicitudes simultáneas consuman el mismo ciclo o usen la probabilidad equivocada.\n- Tras cinco PIN incorrectos, el acceso del jugador se bloquea durante 15 minutos; un PIN correcto reinicia el contador. El panel restablece PIN y contador.
- El panel administra manualmente las cargas aprobadas por WhatsApp y los ciclos regalados. No integra pagos de forma automática.
- No borrar todavía las Firebase Functions antiguas: dejarlas sin uso hasta finalizar pruebas y confirmar la migración.

## Próximos pasos
1. Configurar `ROULETTE_ADMIN_KEY` en Supabase.
2. Probar la creación de un jugador de prueba y validar su PIN desde la página de la ruleta en una vista previa/branch de prueba.
3. Probar aprobación de carga, regalo de ciclo, cola, restablecimiento de PIN y revisión de premios.
4. Sólo después de esas pruebas, revisar el diff y decidir el merge a `main`.
