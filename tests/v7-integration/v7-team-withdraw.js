/* JKBat Équipe V7 : retrait non destructif. Désactivé jusqu'à la migration serveur. */
(function(global){
  'use strict';
  const ENABLED=false; // NEVER change without backed-up, validated SQL/RLS deployment
  const busy=new Set();
  function norm(v){return String(v||'').normalize('NFD').replace(/[\u0300-\u036f]/g,'').trim().toUpperCase();}
  function canWithdraw(a){
    return !!a && !a.archived_at && !!user?.id &&
      String(a.staff_user_id)===String(user.id) &&
      ['RDV','TACHE','RECURRENCE','INTERVENTION'].includes(norm(a.source_type)) &&
      ['A FAIRE','A_FAIRE'].includes(norm(a.status)) && !a.completed_at;
  }
  async function withdraw(assignmentId){
    if(!ENABLED)throw Error('Retrait V7 indisponible : migration serveur non validée');
    const id=String(assignmentId||'');
    if(!id||busy.has(id))return false;
    const a=(assignments||[]).find(x=>String(x.id)===id);
    if(!canWithdraw(a))throw Error('Mission non éligible au retrait');
    if(!global.confirm('Retirer cette mission de votre planning ? Elle restera dans JKBat Pro.'))return false;
    if(typeof api!=='function')throw Error('Connexion Supabase indisponible');
    busy.add(id);
    try{
      const response=await api('/rest/v1/rpc/jkbat_v7_withdraw_own_assignment',{
        method:'POST',body:JSON.stringify({p_assignment_id:id})
      });
      if(!response||response.ok!==true||!['withdrawn','already_withdrawn'].includes(response.result))
        throw Error('Retrait non confirmé par Supabase');
      assignments=(assignments||[]).filter(x=>String(x.id)!==id);
      if(typeof closeModal==='function')closeModal();
      if(typeof renderAll==='function')renderAll();
      if(typeof refreshAll==='function')await refreshAll();
      if(typeof toast==='function')toast('Mission retirée · conservée dans JKBat Pro');
      return true;
    }catch(e){
      if(typeof toast==='function')toast(e.message||'Retrait impossible');
      throw e;
    }finally{busy.delete(id);}
  }
  function inject(assignmentId){
    if(!ENABLED)return;
    const id=String(assignmentId||'');
    const a=(assignments||[]).find(x=>String(x.id)===id);
    if(!canWithdraw(a))return;
    const body=global.document.getElementById('modalBody');
    if(!body||body.querySelector('[data-jkbat-v7-withdraw]'))return;
    const btn=global.document.createElement('button');
    btn.type='button';btn.className='btn danger full';
    btn.dataset.jkbatV7Withdraw='1';
    btn.textContent='Retirer cette mission de mon planning';
    btn.addEventListener('click',async()=>{
      btn.disabled=true;
      try{await withdraw(id);}
      catch(e){global.console?.warn('V7 retrait refusé',e);}
      finally{btn.disabled=false;}
    });
    body.appendChild(btn);
  }
  const previous=global.openAssignment;
  if(typeof previous==='function'){
    global.openAssignment=function(id){
      const result=previous.apply(this,arguments);
      if(ENABLED){global.setTimeout(()=>inject(id),0);global.setTimeout(()=>inject(id),150);}
      return result;
    };
    try{openAssignment=global.openAssignment;}catch(_){}
  }
  global.JKBatV7TeamWithdraw=Object.freeze({enabled:()=>ENABLED,withdraw,canWithdraw});
})(window);
