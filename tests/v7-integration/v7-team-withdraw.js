/* JKBat Équipe V7 — règle métier 2026-10-28 :
 * Le technicien ne retire PAS ses tâches. JKBat Pro garde la maîtrise.
 * Module neutre pour éviter tout appel à la RPC de retrait.
 */
(function(global){
  'use strict';
  global.JKBatV7TeamWithdraw=Object.freeze({
    enabled:()=>false,
    canWithdraw:()=>false,
    withdraw:async()=>{throw new Error('Retrait interdit dans JKBat Équipe : contacter JKBat Pro');}
  });
})(window);
