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
- El PIN tiene 8 dígitos y se guarda como hash. Cinco intentos fallidos bloquean el PIN durante 15 minutos.
