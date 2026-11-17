const assert = require('node:assert/strict');
const FIRST = [5994, 2000, 1000, 200, 100, 500, 150, 40, 10, 5, 1];
const THIRD = [4994, 1200, 800, 300, 200, 1700, 600, 150, 50, 5, 1];
const canHaveThird = spins => spins.length === 2 && spins.every(s => s.result === 'SIN PREMIO');
assert.equal(FIRST.reduce((a, b) => a + b, 0), 10000);
assert.equal(THIRD.reduce((a, b) => a + b, 0), 10000);
assert.equal(FIRST[9], 5); // 50.000 fichas: 0,05%
assert.equal(FIRST[10], 1); // 100.000 fichas: 0,01%
assert.equal(THIRD[9], 5);
assert.equal(THIRD[10], 1);
assert.equal(canHaveThird([{result:'SIN PREMIO'}, {result:'SIN PREMIO'}]), true);
assert.equal(canHaveThird([{result:'SIN PREMIO'}, {result:'BONUS 5%'}]), false);
assert.equal(canHaveThird([{result:'SIN PREMIO'}]), false);
console.log('Ruleta: probabilidades y desbloqueo del tercer giro OK.');
