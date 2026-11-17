# FREEHAND · Ruleta administrada

Esta entrega conserva la aplicación original de Preguntados y su estética verde/dorada. Los cambios se limitan a la ruleta, los premios, la identificación por PIN y la gestión de oportunidades.

## Qué incluye

- `index.html`: página de jugador actualizada. El jugador escribe su usuario y un PIN de 8 dígitos entregado por FREEHAND.
- `roulette-admin.html`: panel separado para crear jugadores, generar/restablecer PIN, aprobar una carga (siempre 1 ciclo) y regalar ciclos manualmente.
- `functions/`: backend Firebase Callable Functions. Los resultados y el uso de oportunidades se resuelven en el servidor dentro de una transacción Firestore.
- `firestore.roulette.rules.snippet`: reglas que hay que incorporar a las reglas actuales de Firestore para impedir escrituras directas del navegador en las colecciones privadas de la ruleta.

## Reglas de una oportunidad

Cada carga aprobada equivale a **un ciclo**. Un ciclo tiene dos giros normales. Solo cuando los dos resultados son `SIN PREMIO` se habilita el tercer giro especial. Si hay otra carga aprobada o ciclos regalados mientras la persona está jugando, quedan en cola y se habilitan al terminar el ciclo activo.

Los giros tienen probabilidades independientes. Cada giro comienza con la tabla de probabilidad correspondiente; no se reduce la posibilidad porque otras personas hayan jugado antes.

### Probabilidades de los dos primeros giros

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
| Número para sorteo del cuatriciclo | 0,1% |
| 50.000 fichas | 0,05% |
| 100.000 fichas | 0,01% |
| **Total** | **100%** |

### Probabilidades del tercer giro especial

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
| Número para sorteo del cuatriciclo | 0,5% |
| 50.000 fichas | 0,05% |
| 100.000 fichas | 0,01% |
| **Total** | **100%** |

Los premios grandes tienen probabilidades muy bajas e iguales en los giros normales y en el tercer giro especial: 50.000 fichas, 0,05% (1 en 2.000); 100.000 fichas, 0,01% (1 en 10.000). La probabilidad restante se descuenta de SIN PREMIO para mantener cada tabla en 100%.

Los resultados de fichas incrementan `fichasBalance`; los bonus se guardan como entradas individuales en `bonusPrizes`; el premio del cuatriciclo incrementa `quadBikeNumbers`. Los giros quedan registrados en `roulette_spins`.

## Configuración y despliegue

**No se debe publicar la página nueva antes de desplegar las Functions y configurar la clave administrativa.** La versión nueva consulta estas Functions; no vuelve a sortear en el navegador.

1. Abrí una terminal con Firebase CLI instalada y autenticá el proyecto:

   ```bash
   firebase login
   firebase use preguntados-argentina
   ```

2. Configurá una clave administrativa larga (recomendado: 32 caracteres aleatorios como mínimo). No la agregues al repositorio ni al HTML:

   ```bash
   firebase functions:secrets:set ROULETTE_ADMIN_KEY --project preguntados-argentina
   ```

3. Instalá dependencias y desplegá las Functions:

   ```bash
   cd functions
   npm install
   cd ..
   firebase deploy --only functions --project preguntados-argentina
   ```

4. Incorporá el contenido de `firestore.roulette.rules.snippet` dentro del `service cloud.firestore` y del `match /databases/{database}/documents` de las reglas existentes. No reemplaces todas las reglas actuales: la aplicación principal también usa colecciones de Preguntados y ranking. Luego publicá las reglas desde Firebase Console o Firebase CLI según la configuración existente.

5. Publicá `index.html` en la raíz del sitio de GitHub Pages, reemplazando el actual, y publicá `roulette-admin.html` con ese nombre en la misma raíz. El panel se abre en:

   `https://freehandcomunidad.github.io/preguntados-argentina/roulette-admin.html`

6. Abrí el panel, ingresá la clave de administración, creá cada jugador y compartile el PIN que aparece. Al confirmar una carga por WhatsApp, buscá al usuario y presioná **APROBAR CARGA**. Ese botón siempre concede un ciclo. **REGALAR OPORTUNIDAD** permite conceder ciclos extra y seleccionar cuántos.

## Reglas de Firestore que hay que añadir

```text
match /roulette_players/{playerId} {
  allow read, write: if false;
}
match /roulette_spins/{spinId} {
  allow read, write: if false;
}
```

Las Cloud Functions usan Admin SDK y pueden escribir esos documentos; el navegador no. Las reglas actuales de las demás colecciones deben conservarse.

## Comprobaciones

- `node --check functions/index.js`
- Validación sintáctica del módulo JavaScript de `index.html` y `roulette-admin.html`.
- Las dos tablas de probabilidades suman 100% cada una.
- El sitio público existente no fue modificado por este paquete; requiere el despliegue descrito arriba.

## Consideraciones

- El usuario necesita conservar su PIN de 8 dígitos. Si lo pierde, se puede restablecer desde el panel; el PIN anterior queda invalidado.
- El panel administra altas y aprobaciones manuales; no recibe pagos ni comprobantes automáticamente desde WhatsApp.
- La primera carga de un jugador requiere crearlo en el panel para generar usuario y PIN.
- Aún no se desplegaron las Functions, no se configuró `ROULETTE_ADMIN_KEY` y no se modificó la rama `main`.
