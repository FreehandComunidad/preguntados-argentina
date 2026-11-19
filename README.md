# FREEHAND · Preguntados Argentina

## Arquitectura vigente

- `index.html`: juego de preguntas, ranking y ruleta.
- `roulette-admin.html`: panel administrativo exclusivo de la ruleta.
- **Supabase `freehand-roulette`** (ref `yiznobpjxksymqqazryr`, región `sa-east-1`): base de datos de la ruleta.
- Edge Function activa `roulette`: valida PIN, consulta oportunidades, gira, administra jugadores y aprueba/regala ciclos.
- Tablas privadas `public.roulette_players` y `public.roulette_spins`, ambas con RLS habilitado.
- Funciones SQL transaccionales: `roulette_verify_player_pin`, `roulette_apply_spin`, `roulette_admin_create_player` y `roulette_admin_grant_cycles`.

El jugador y el panel llaman directamente a `https://yiznobpjxksymqqazryr.supabase.co/functions/v1/roulette`. El navegador utiliza únicamente la clave **publishable**. La clave administrativa se envía en el encabezado `x-admin-key` y se valida contra el secreto `ROULETTE_ADMIN_KEY` guardado en Supabase; nunca se escribe en el HTML ni en GitHub.

El resto del juego de Preguntados todavía utiliza Firebase Authentication/Firestore para las colecciones `questions_public`, `players_private` y `ranking_public`. Esa parte no forma parte de la base de datos de la ruleta y se conserva sin cambios en esta actualización.

## Reglas de una oportunidad

Cada carga aprobada equivale a **un ciclo**. Un ciclo tiene dos giros normales. Solo cuando los dos resultados son `SIN PREMIO` se habilita el tercer giro especial. Si hay otras cargas aprobadas u oportunidades regaladas mientras la persona juega, quedan en cola y se habilitan al terminar el ciclo activo.

Cada giro es independiente. La selección del premio se ejecuta en PostgreSQL dentro de una transacción que bloquea la fila del jugador, valida el PIN, registra el giro y actualiza el saldo. No se sortea desde el navegador.

## Probabilidades

### Dos primeros giros

| Premio | Probabilidad |
|---|---:|
| SIN PREMIO | 59,94% |
| BONUS 5% | 20% |
| BONUS 10% | 10% |
| BONUS 15% | 2% |
| BONUS 20% | 1% |
| 1.000 fichas | 5% |
| 3.000 fichas | 1,5% |
| 5.000 fichas | 0,4% |
| Número a elección para el sorteo del cuatriciclo | 0,1% |
| 50.000 fichas | **0,05%** |
| 100.000 fichas | **0,01%** |
| **Total** | **100%** |

### Tercer giro especial

| Premio | Probabilidad |
|---|---:|
| SIN PREMIO | 49,94% |
| BONUS 5% | 12% |
| BONUS 10% | 8% |
| BONUS 15% | 3% |
| BONUS 20% | 2% |
| 1.000 fichas | 17% |
| 3.000 fichas | 6% |
| 5.000 fichas | 1,5% |
| Número a elección para el sorteo del cuatriciclo | 0,5% |
| 50.000 fichas | **0,05%** |
| 100.000 fichas | **0,01%** |
| **Total** | **100%** |

Los premios grandes tienen probabilidades muy bajas en cada giro: 50.000 fichas equivale a 1 en 2.000 y 100.000 fichas a 1 en 10.000. El importe se suma a `fichas_balance` y el giro queda auditado en `roulette_spins`.

## Archivos de backend en este repositorio

- `supabase/functions/roulette/index.ts`: copia de la Edge Function activa en Supabase (versión 11).
- `supabase/migrations/20261117145923_add_50000_and_100000_fichas_prizes.sql`: migración aplicada sobre la base existente para agregar ambos premios a la selección y a la acreditación.
- Las migraciones previas de creación del esquema, PIN, RLS y sorteo atómico ya constan en el historial del proyecto Supabase.

## Publicación

- La página pública se publica con GitHub Pages desde `main`.
- Los cambios de estructura o lógica del sorteo se aplican en el proyecto Supabase existente. Para esta actualización se reemplazó `public.roulette_apply_spin`; no se creó otra base ni se modificaron las tablas de jugadores.
- La Edge Function `roulette` ya estaba desplegada y no requirió cambios de código: delega el sorteo a la función SQL transaccional.
- El secreto `ROULETTE_ADMIN_KEY` debe permanecer configurado en Supabase Edge Function Secrets. No subirlo al repositorio.
- El proyecto usa Firebase Auth/Firestore únicamente en el juego de preguntas y su ranking; las llamadas del módulo de ruleta y del panel administrativo ya no dependen de Firebase Callable Functions.

## Seguridad y datos

- Los datos existentes de jugadores y giros permanecen en Supabase.
- RLS continúa habilitado en las dos tablas de ruleta; el acceso se realiza por la Edge Function con credenciales de servidor.
- Los PIN nuevos y los PIN restablecidos tienen 4 dígitos y se guardan como hash. Por compatibilidad, los usuarios existentes pueden seguir usando su PIN anterior de 8 dígitos hasta que el administrador lo restablezca. Cinco intentos fallidos bloquean el PIN durante 15 minutos.


## Cargas aprobadas por usuario

La tabla `public.roulette_players` tiene el contador `approved_loads_count`. La acción administrativa `adminApproveLoad` llama a `roulette_admin_grant_cycles` con `p_source='load-approved'`; esa función incrementa el contador en la misma transacción que habilita el ciclo. Los regalos administrativos (`p_source='admin'`) no incrementan este contador. La Edge Function `roulette` devuelve el valor como `approvedLoads` y el panel lo muestra por jugador.

El contador se empezó a registrar el 19/11/2026. Se conservaron dos aprobaciones anteriores que pudieron identificarse con certeza (Gaby y julioponce: una cada uno). Las aprobaciones históricas ya finalizadas no se podían reconstruir de forma fiable porque el esquema anterior no conservaba el origen de cada ciclo completado ni de las oportunidades en cola.


## Archivo de bonos utilizados y anulación de cargas

- Los bonos pendientes se muestran hasta que el administrador elige **MARCAR USADO**. La acción mueve el bono de `bonus_prizes` a `used_bonus_prizes`, registra `usedAt` y lo retira de la lista principal; el panel conserva solamente un contador de bonos archivados.
- La tabla privada `public.roulette_opportunities` registra el origen de cada oportunidad (`load-approved`, `admin` o `legacy`) y su estado (`active`, `queued`, `completed`, `cancelled`).
- **ANULAR ÚLTIMA CARGA** solo puede cancelar una oportunidad pagada que todavía esté en cola o esté activa sin ningún giro. Si ya tuvo giros, no se puede anular. Las oportunidades regaladas y las oportunidades históricas sin origen verificable no se tocan.
- Los ciclos y colas anteriores a este registro se preservaron como `legacy`, para no confundirlos con cargas pagadas ni con regalos.


## Control manual de premios y archivo

- Cada premio con resultado distinto de SIN PREMIO genera un registro único en `public.roulette_prize_awards`, vinculado a su giro y jugador.
- **Fichas:** los nuevos premios (1.000, 3.000, 5.000, 50.000 y 100.000) quedan como `pending_delivery`. El saldo `fichas_balance` solo aumenta cuando el administrador usa **CONFIRMAR ENTREGA**. La función bloquea el premio y cambia su estado en una única transacción, evitando acreditaciones duplicadas.
- **Bonos:** quedan como `pending_use`; **MARCAR CANJEADO** los retira de la lista pendiente, los conserva en `used_bonus_prizes` y archiva el premio como `redeemed`.
- **Número para cuatriciclo:** queda como `pending_assignment`; el administrador registra el número elegido y queda archivado como `assigned`.
- La pestaña **PENDIENTES** muestra solo premios que requieren acción. **ARCHIVO** conserva entregados, canjeados, asignados y anulados.
- `public.roulette_prize_events` conserva el movimiento de cada premio y quién lo resolvió. Cada fila del panel incluye **VER MOVIMIENTOS** para consultar cuándo se obtuvo, acreditó, canjeó o asignó.
- Premios históricos importados: las fichas ya acreditadas por el sistema anterior se marcan como entregadas sin volver a sumarlas; los bonos respetan su estado previo.
- El mensaje de la ruleta aclara que una ganancia de fichas queda pendiente hasta que FREEHAND confirme la entrega.
