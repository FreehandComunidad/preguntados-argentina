# Informe de pruebas de la ruleta FREEHAND — 17/11/2026

## Estado y alcance

- Proyecto probado: `freehand-roulette` (región São Paulo).
- Edge Function `roulette`: versión 6, estado ACTIVE.
- Se probó la lógica de la base de datos Supabase, que decide el premio, registra el giro, actualiza saldo/bonos y avanza los ciclos.
- Las pruebas usaron únicamente cuentas identificadas como SELFTEST. No se usaron ni consumieron oportunidades de jugadores reales.
- Al finalizar, se borraron los jugadores y giros de prueba.

## Error encontrado y corregido

En la primera corrida previa a esta corrección, la función acumulaba los pesos y además restaba el peso anterior del valor aleatorio. Eso alteraba la selección y concentraba los resultados en dos premios. Esa corrida fue descartada y sus registros se eliminaron.

Se corrigió `roulette_apply_spin`: ahora mantiene el valor aleatorio y lo compara con los límites acumulados. La corrección quedó aplicada en Supabase y versionada en `supabase/migrations/20261117120746_fix_roulette_weight_selection.sql`.

## Simulaciones posteriores a la corrección

Se ejecutaron 50.000 giros válidos a través de la función transaccional de PostgreSQL:
- 10.000 giros normales (spin 1).
- 40.000 giros especiales (spin 3), preparando el estado de dos `SIN PREMIO` anteriores para cada intento.

### Giros normales — 10.000

| Premio | Probabilidad configurada | Veces | Observado |
|---|---:|---:|---:|
| SIN PREMIO | 60% | 5.933 | 59,330% |
| BONUS 5% | 20% | 2.085 | 20,850% |
| BONUS 10% | 10% | 1.001 | 10,010% |
| BONUS 15% | 2% | 198 | 1,980% |
| BONUS 20% | 1% | 95 | 0,950% |
| 1.000 fichas | 5% | 502 | 5,020% |
| 3.000 fichas | 1,5% | 141 | 1,410% |
| 5.000 fichas | 0,4% | 35 | 0,350% |
| Número para sorteo del cuatriciclo | 0,1% | 10 | 0,100% |
| **Total** | **100%** | **10.000** | **100%** |

Resultados con premio: 4.067 (40,67%). Sin premio: 5.933 (59,33%).

### Giro especial — 40.000

| Premio | Probabilidad configurada | Veces | Observado |
|---|---:|---:|---:|
| SIN PREMIO | 50% | 19.961 | 49,903% |
| BONUS 5% | 12% | 4.751 | 11,878% |
| BONUS 10% | 8% | 3.202 | 8,005% |
| BONUS 15% | 3% | 1.252 | 3,130% |
| BONUS 20% | 2% | 859 | 2,148% |
| 1.000 fichas | 17% | 6.954 | 17,385% |
| 3.000 fichas | 6% | 2.272 | 5,680% |
| 5.000 fichas | 1,5% | 542 | 1,355% |
| Número para sorteo del cuatriciclo | 0,5% | 207 | 0,518% |
| **Total** | **100%** | **40.000** | **100%** |

Resultados con premio: 20.039 (50,10%). Sin premio: 19.961 (49,90%).

## Validaciones adicionales

- Recorrido exhaustivo de los 10.000 valores posibles del generador: los nueve premios recibieron exactamente la cantidad de valores correspondiente a su peso, tanto para la tabla normal como para la especial.
- Muestra independiente de 100.000 valores aleatorios: distribución uniforme consistente con los intervalos.
- 100 ciclos completos: el tercer giro sólo se habilitó cuando los dos primeros fueron `SIN PREMIO`; en los demás casos el ciclo finalizó tras el segundo.
- Ciclos en cola: se concedieron tres ciclos, se consumió uno y se verificó que el siguiente quedara activo y la cola bajara de dos a uno.
- PIN: cinco intentos incorrectos bloquean durante 15 minutos; un PIN correcto tras el desbloqueo limpia el contador.
- RLS y permisos: `anon` y `authenticated` no pueden leer/escribir las tablas privadas ni ejecutar la función de giro; `service_role` sí.
- Registros temporales: eliminados. No queda ningún jugador ni giro de simulación.

## Observación estadística

La prueba normal tuvo un ajuste estadístico compatible con los pesos configurados (chi-cuadrado, p≈0,669). La muestra especial mostró una desviación más marcada (p≈0,0029), concentrada sobre todo en 1.000/3.000/5.000 fichas. Sin embargo, la prueba exhaustiva de los 10.000 valores confirmó que los intervalos del código asignan exactamente 50%, 12%, 8%, 3%, 2%, 17%, 6%, 1,5% y 0,5%. Esto no prueba un sesgo del código: las frecuencias observadas son una muestra aleatoria y no tienen que coincidir exactamente con los porcentajes. Conviene seguir observando la frecuencia de giros especiales cuando haya tráfico real.

## Límites de esta prueba

La simulación llamó directamente a la función transaccional de PostgreSQL. No se pudo completar una prueba HTTP real desde el navegador en esta sesión; por eso todavía falta una prueba manual de inicio de sesión, creación de jugador y aprobación desde `roulette-admin.html`. La rama de trabajo sigue siendo `migracion-supabase`; `main` no fue modificada.
